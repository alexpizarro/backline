import AVFoundation
import Accelerate
import BacklineKit
import CryptoKit
import Foundation
import Synchronization

/// On-disk library: `~/Library/Application Support/Backline/Songs/<id>/`
///   song.json · <stem>.caf (16-bit ALAC stems) · artwork · the kept original (original.caf or source.<ext>)
nonisolated struct SongStore: Sendable {
    let root: URL

    static let shared: SongStore = {
        let root = BacklineFolders.support.appendingPathComponent("Songs", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return SongStore(root: root)
    }()

    func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    func stemURL(_ id: String, _ kind: StemKind) -> URL { folder(id).appendingPathComponent("\(SongRecord.fileStem(kind)).caf") }
    func mixURL(_ rec: SongRecord, _ kind: StemKind) -> URL {
        folder(rec.id).appendingPathComponent("\(rec.mixFileStem(kind)).caf")
    }
    func otherSplitURL(_ id: String) -> URL { folder(id).appendingPathComponent("other-split.caf") }
    /// The original mix written as Apple Lossless, kept so a cleaner model can split the real audio later.
    func originalURL(_ id: String) -> URL { folder(id).appendingPathComponent("original.caf") }

    /// The name of a kept source file in a song's folder (D18): `source.<ext>`, the extension of the file the
    /// song came from, so it decodes exactly as the import decoded it.
    static func sourceName(extension ext: String) -> String { "source." + ext.lowercased() }
    /// A record's `originalFile` is used only when it is such a name (never a path out of the folder).
    static func isSourceName(_ name: String) -> Bool {
        name.hasPrefix("source.") && name.count > 7 && !name.contains("/") && !name.contains("..")
            && AudioDecoder.isSupported(URL(fileURLWithPath: name))
    }

    /// The song's kept original: the source file (D18) or `original.caf`; nil when the song keeps none.
    func originalURL(_ rec: SongRecord) -> URL? {
        if let name = rec.originalFile, Self.isSourceName(name) { return folder(rec.id).appendingPathComponent(name) }
        return rec.originalScale != nil ? originalURL(rec.id) : nil
    }

    /// The song's original mix at its true level. A kept source is decoded with the same `AudioDecoder.decode`
    /// the import used, so it is sample for sample the audio that was split; `original.caf` has its storage
    /// gain undone.
    func readOriginal(_ rec: SongRecord) throws -> StereoAudio {
        if let name = rec.originalFile, Self.isSourceName(name) {
            return try AudioDecoder.decode(folder(rec.id).appendingPathComponent(name))
        }
        guard let scale = rec.originalScale else { throw CocoaError(.fileNoSuchFile) }
        var audio = try readAudio(originalURL(rec.id))
        var undo = 1 / max(scale, 1e-6)
        if undo != 1 {
            vDSP_vsmul(audio.left, 1, &undo, &audio.left, 1, vDSP_Length(audio.frameCount))
            vDSP_vsmul(audio.right, 1, &undo, &audio.right, 1, vDSP_Length(audio.frameCount))
        }
        return audio
    }
    /// A store in a sibling folder, for writing a complete new set of parts before swapping it in.
    var staging: SongStore { SongStore(root: root.deletingLastPathComponent().appendingPathComponent("Staging", isDirectory: true)) }

    /// Reads a whole stem file into memory (44.1 kHz stereo float), at the part's stored level whatever the file
    /// holds (an AAC part's half amplitude is undone: `formatGain`).
    func readAudio(_ url: URL) throws -> StereoAudio {
        let frames = Self.frameCount(of: url)
        guard frames > 0 else { throw CocoaError(.fileReadCorruptFile) }
        var left = [Float](repeating: 0, count: frames), right = [Float](repeating: 0, count: frames)
        try left.withUnsafeMutableBufferPointer { l in
            try right.withUnsafeMutableBufferPointer { r in
                try readStem(url, left: l.baseAddress!, right: r.baseAddress!, capacity: frames)
            }
        }
        return StereoAudio(left: left, right: right, sampleRate: 44_100)
    }
    func artworkURL(_ id: String) -> URL { folder(id).appendingPathComponent("artwork") }
    func recordURL(_ id: String) -> URL { folder(id).appendingPathComponent("song.json") }

    /// Puts back a song folder left aside by an interrupted cleaner-pass swap (Staging/<id>-old with no
    /// live folder), and clears unfinished staging folders.
    func recoverInterruptedSwaps() {
        let fm = FileManager.default
        let stagingRoot = staging.root
        guard let names = try? fm.contentsOfDirectory(atPath: stagingRoot.path) else { return }
        for name in names {
            let url = stagingRoot.appendingPathComponent(name, isDirectory: true)
            guard name.hasSuffix("-old") else { continue }   // half-written staging is swept later
            let id = String(name.dropLast(4))
            if !fm.fileExists(atPath: folder(id).path) { try? fm.moveItem(at: url, to: folder(id)) }
            // A set-aside folder is kept until the live one is definitely in place (`tidyStaging`): it is the
            // only complete copy of the song while the swap is incomplete, and losing it loses the song.
        }
    }

    /// Clears staging folders whose song is complete on disk. A folder is an unfinished staging pass, not a
    /// backup, whenever the live folder holds a readable song, so this never throws away a real one.
    func tidyStaging() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: staging.root.path) else { return }
        for name in names {
            let id = name.hasSuffix("-old") ? String(name.dropLast(4)) : name
            let record = recordURL(id)
            guard fm.fileExists(atPath: record.path), (try? Data(contentsOf: record)) != nil else { continue }
            try? fm.removeItem(at: staging.root.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// Every song on disk, newest first. The records are read several at once (UIP-05): each is mostly
    /// waveform peaks, and decoding a hundred of them one after another took seconds.
    func loadAll(parallel: Bool = true) -> [SongRecord] {
        recoverInterruptedSwaps()
        tidyStaging()
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        let found: [SongRecord?]
        if parallel {
            let results = Mutex([SongRecord?](repeating: nil, count: ids.count))
            DispatchQueue.concurrentPerform(iterations: ids.count) { i in
                let rec = loadOne(ids[i])
                results.withLock { $0[i] = rec }
            }
            found = results.withLock { $0 }
        } else {
            found = ids.map(loadOne)
        }
        return found.compactMap { $0 }.sorted { $0.lastOpened > $1.lastOpened }
    }

    /// One song's record, or nil when it can't be read or its parts are missing.
    private func loadOne(_ id: String) -> SongRecord? {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: recordURL(id)),
              let rec = try? JSONDecoder().decode(SongRecord.self, from: data),
              rec.stems.allSatisfy({ fm.fileExists(atPath: stemURL(id, $0).path) }) else { return nil }
        var r = rec
        // A split whose files went missing is dropped rather than hiding the song.
        if let gs = r.guitarSplit,
           ![StemKind.leadGuitar, .rhythmGuitar].allSatisfy({ fm.fileExists(atPath: stemURL(id, $0).path) })
            || (gs.otherAdjusted && !fm.fileExists(atPath: otherSplitURL(id).path)) {
            r.guitarSplit = nil
        }
        if r.originalScale != nil, !fm.fileExists(atPath: originalURL(id).path) { r.originalScale = nil }
        if let name = r.originalFile,
           !Self.isSourceName(name) || !fm.fileExists(atPath: folder(id).appendingPathComponent(name).path) {
            r.originalFile = nil
        }
        if r.drumSplit != nil, !StemKind.drumParts.allSatisfy({ fm.fileExists(atPath: stemURL(id, $0).path) }) {
            r.drumSplit = nil
        }
        return r
    }

    // MARK: Leftovers (storage.md F5, split.md F12)

    /// Where `CleanerPartsJob` keeps each song's checkpoint (`Cleaner/<id>`). The other passes' checkpoints are
    /// beside it (`PassCheckpoints`).
    static var cleanerCheckpoints: URL { CleanerPartsJob.checkpointDirectory("-").deletingLastPathComponent() }

    /// What `sweepLeftovers` removed.
    struct Sweep: Equatable, Sendable {
        var songFolders: [String] = []
        var checkpoints: [String] = []
        var unpacks: [String] = []
    }

    /// At launch only, before anything imports, splits or downloads: removes what an interrupted session left
    /// that nothing can reach. An interrupted cleaner swap is put back first. Only a song folder with no
    /// `song.json` at all goes (an import killed before its record was written); a folder whose record
    /// exists but can't be read is a song and stays (D7). Then the checkpoints of the cleaner pass, the kit split
    /// and the lead refinement of songs no longer in the library (those are in folders beside `checkpoints`, listed
    /// as `Kit/<id>` and `Lead/<id>`), the import checkpoints no journal entry names (`running`, as `Import/<id>`),
    /// and half-unpacked downloaded models.
    @discardableResult
    func sweepLeftovers(checkpoints: URL = Self.cleanerCheckpoints, models: URL = ModelStore.directory,
                        keeping running: Set<String> = []) -> Sweep {
        recoverInterruptedSwaps()
        let fm = FileManager.default
        var sweep = Sweep()
        var songs: Set<String> = []
        for id in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folder(id).path, isDirectory: &isDir), isDir.boolValue else { continue }
            if fm.fileExists(atPath: recordURL(id).path) || running.contains(id) { songs.insert(id); continue }
            if (try? fm.removeItem(at: folder(id))) != nil { sweep.songFolders.append(id) }
        }
        for id in (try? fm.contentsOfDirectory(atPath: checkpoints.path)) ?? [] where !songs.contains(id) {
            if (try? fm.removeItem(at: checkpoints.appendingPathComponent(id, isDirectory: true))) != nil {
                sweep.checkpoints.append(id)
            }
        }
        // The other passes' checkpoints, in folders beside the cleaner's: a song's go with the song, an import's
        // when the journal no longer names it (an unfinished import is the only thing that can carry on from it).
        let base = checkpoints.deletingLastPathComponent()
        for kind in [PassCheckpoints.Kind.kit, .lead, .importSplit] {
            let dir = PassCheckpoints.folder(kind, root: base)
            let keep = kind == .importSplit ? running : songs
            for id in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !keep.contains(id) {
                if (try? fm.removeItem(at: dir.appendingPathComponent(id, isDirectory: true))) != nil {
                    sweep.checkpoints.append("\(kind.rawValue)/\(id)")
                }
            }
        }
        for name in (try? fm.contentsOfDirectory(atPath: models.path)) ?? [] where name.hasPrefix(".") && name.hasSuffix("-unpack") {
            if (try? fm.removeItem(at: models.appendingPathComponent(name, isDirectory: true))) != nil {
                sweep.unpacks.append(name)
            }
        }
        return sweep
    }

    func save(_ rec: SongRecord) throws {
        try FileManager.default.createDirectory(at: folder(rec.id), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try enc.encode(rec).write(to: recordURL(rec.id), options: .atomic)
    }

    /// Deletes a song's folder, the leftovers of an interrupted swap and its passes' checkpoints. `keepingImport`:
    /// an import that ended with Try again on screen keeps its split's checkpoint, so Try again carries on.
    func delete(_ id: String, keepingImport: Bool = false) {
        try? FileManager.default.removeItem(at: folder(id))
        // The leftover copy of an interrupted swap goes with it, or the disk keeps a whole song.
        let fm = FileManager.default
        for name in [id, id + "-old"] {
            try? fm.removeItem(at: staging.root.appendingPathComponent(name, isDirectory: true))
        }
        PassCheckpoints.discardAll(id, keepingImport: keepingImport)
    }

    func artwork(_ id: String) -> Data? { try? Data(contentsOf: artworkURL(id)) }

    /// Stable id from file content (so re-importing the same song reopens it instantly).
    static func contentID(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Stem files

    /// Writes a stem losslessly (Apple Lossless, 16-bit, ~50 % of PCM; near-silent stems shrink to almost nothing).
    /// `gain` (the storage gain) is applied to each chunk as it is copied out, so no scaled copy of the song is made.
    func writeStem(_ audio: StereoAudio, to url: URL, gain: Float = 1) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: audio.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitDepthHintKey: 16,
        ]
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: audio.sampleRate, channels: 2, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 1 << 18
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(chunk))!
        var pos = 0
        while pos < audio.frameCount {
            let n = min(chunk, audio.frameCount - pos)
            for (c, side) in [audio.left, audio.right].enumerated() {
                let dst = buf.floatChannelData![c]
                side.withUnsafeBufferPointer { src in
                    if gain == 1 {
                        dst.update(from: src.baseAddress! + pos, count: n)
                    } else {
                        var g = gain
                        vDSP_vsmul(src.baseAddress! + pos, 1, &g, dst, 1, vDSP_Length(n))
                    }
                }
            }
            buf.frameLength = AVAudioFrameCount(n)
            try file.write(from: buf)
            pos += n
        }
    }

    /// Reads a whole stem as Float32, at the part's stored level.
    func readStem(_ url: URL, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, capacity: Int) throws {
        _ = try readStem(url, left: left, right: right, frames: 0..<capacity)
    }

    /// Reads frames `frames` of a stem as Float32 into the same positions of `left` and `right`, at the part's
    /// stored level: an AAC part is doubled here (`formatGain`), so every Float32 reader gets the same samples
    /// from either format. `stop` is asked between chunks; returns false if it stopped.
    @discardableResult
    func readStem(_ url: URL, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Range<Int>,
                  stop: () -> Bool = { false }) throws -> Bool {
        try read(url, as: .pcmFormatFloat32, frames: frames, stop: stop) { buf, pos, n, stereo, gain in
            let ch = buf.floatChannelData!
            if gain == 1 {
                (left + pos).update(from: ch[0], count: n)
                (right + pos).update(from: stereo ? ch[1] : ch[0], count: n)
            } else {
                var g = gain
                vDSP_vsmul(ch[0], 1, &g, left + pos, 1, vDSP_Length(n))
                vDSP_vsmul(stereo ? ch[1] : ch[0], 1, &g, right + pos, 1, vDSP_Length(n))
            }
        }
    }

    /// Reads frames `frames` of a stem into the same positions of the engine's 16-bit buffers (D3). A lossless
    /// part is 16-bit Apple Lossless, so this is the file's own samples: no conversion, and exactly what the
    /// Float32 read gives × 32768. An AAC part (D19) comes in at the half amplitude it is stored at; the mixer
    /// doubles it (`formatGain`, applied with the storage gain in `pushMix`). `stop` is asked between chunks (a
    /// background fill gives way to the next song); returns false if it stopped.
    @discardableResult
    func readStem(_ url: URL, left: UnsafeMutablePointer<Int16>, right: UnsafeMutablePointer<Int16>, frames: Range<Int>,
                  stop: () -> Bool = { false }) throws -> Bool {
        try read(url, as: .pcmFormatInt16, frames: frames, stop: stop) { buf, pos, n, stereo, _ in
            let ch = buf.int16ChannelData!
            (left + pos).update(from: ch[0], count: n)
            (right + pos).update(from: stereo ? ch[1] : ch[0], count: n)
        }
    }

    /// `copy` gets the buffer, its place, its length, whether it is stereo, and the file's `formatGain` (read from
    /// the very file being decoded, so a part swapped meanwhile can't give the wrong level).
    private func read(_ url: URL, as format: AVAudioCommonFormat, frames: Range<Int>, stop: () -> Bool,
                      copy: (AVAudioPCMBuffer, Int, Int, Bool, Float) -> Void) throws -> Bool {
        guard !frames.isEmpty else { return true }
        let file = try AVAudioFile(forReading: url, commonFormat: format, interleaved: false)
        let gain = Self.formatGain(file)
        file.framePosition = AVAudioFramePosition(frames.lowerBound)
        let chunk = 1 << 18
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunk))!
        let stereo = file.processingFormat.channelCount > 1
        var pos = frames.lowerBound
        while pos < frames.upperBound {
            if stop() { return false }
            try file.read(into: buf, frameCount: AVAudioFrameCount(min(chunk, frames.upperBound - pos)))
            let n = Int(buf.frameLength)
            if n == 0 { break }
            copy(buf, pos, n, stereo, gain)
            pos += n
        }
        return true
    }

    // MARK: AAC parts (D19)

    /// An AAC part holds its samples at exactly this fraction of the stored level, so a decoded peak can never clip.
    static let aacLevel: Float = 0.5

    /// AAC-LC, 44.1 kHz, stereo, the encoder's bit-rate-driven constrained variable mode at the owner's 192 kbps
    /// (D19). Measured on four real songs (ios-last, 12 November): their whole mixes (the yardstick) come out at
    /// 195 to 199 kbps by file size, 25.7 to 28.8 dB above the difference from lossless; sparse parts take less
    /// (a bass 141 to 163, a lead 145 to 186 kbps), and a part whose AAC wouldn't be smaller than its lossless
    /// file stays lossless (the check before a swap). Quality 82 of the true variable mode gave 151 to 167.
    static let aacBitRate = 192_000
    static var aacSettings: [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100.0, AVNumberOfChannelsKey: 2,
         AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_VariableConstrained, AVEncoderBitRateKey: aacBitRate]
    }

    /// True when the file holds AAC (an AAC part, D19), from the file's own data format.
    static func isAAC(_ file: AVAudioFile) -> Bool {
        file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC
    }

    /// The one answer to "what gain does this file need" to be at its stored level: 2 for an AAC part, 1 for
    /// anything else. The Float32 readers apply it; the engine applies it in the mixer gain.
    static func formatGain(_ file: AVAudioFile) -> Float { isAAC(file) ? 1 / aacLevel : 1 }

    /// `formatGain` of the file at `url`; 1 when it can't be opened (its reader will say so).
    static func formatGain(of url: URL) -> Float {
        (try? AVAudioFile(forReading: url)).map(formatGain) ?? 1
    }

    /// True when the file at `url` is an AAC part.
    static func isAAC(_ url: URL) -> Bool { (try? AVAudioFile(forReading: url)).map(isAAC) ?? false }

    /// The lossless part couldn't be opened or read (a damaged file, one cut off part way): converting it fails the
    /// same way every time, so the conversion skips it instead of stopping (ios-storage#1).
    struct PartUnreadable: Error {
        var underlying: Error
    }

    /// Writes the lossless part at `source` again as AAC at `destination`, at half its stored amplitude, one chunk
    /// at a time (nothing whole is held). `stop` is asked between chunks; throws `CancellationError` when it says so,
    /// and `PartUnreadable` when the source can't be read.
    func writeAACPart(from source: URL, to destination: URL, stop: () -> Bool = { false }) throws {
        let input: AVAudioFile
        do { input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false) } catch {
            throw PartUnreadable(underlying: error)
        }
        guard input.processingFormat.sampleRate == 44_100, !Self.isAAC(input) else {
            throw PartUnreadable(underlying: CocoaError(.fileReadUnsupportedScheme))
        }
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!
        try? FileManager.default.removeItem(at: destination)
        do {
            let output = try AVAudioFile(forWriting: destination, settings: Self.aacSettings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            let chunk = 1 << 16
            let inBuf = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(chunk))!
            let outBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(chunk))!
            let stereo = input.processingFormat.channelCount > 1
            var half = Self.aacLevel
            while input.framePosition < input.length {
                if stop() { throw CancellationError() }
                do { try input.read(into: inBuf, frameCount: AVAudioFrameCount(chunk)) } catch { throw PartUnreadable(underlying: error) }
                let n = Int(inBuf.frameLength)
                if n == 0 { break }
                let src = inBuf.floatChannelData!, dst = outBuf.floatChannelData!
                vDSP_vsmul(src[0], 1, &half, dst[0], 1, vDSP_Length(n))
                vDSP_vsmul(stereo ? src[1] : src[0], 1, &half, dst[1], 1, vDSP_Length(n))
                outBuf.frameLength = AVAudioFrameCount(n)
                try output.write(from: outBuf)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// What the check before a swap found (the AAC part format, "The check before a swap").
    struct AACCheck: Equatable, Sendable {
        /// The new file decoded to the end.
        var decodes = false
        var frames = 0, sourceFrames = 0
        /// The lag (in frames) at which the two line up best, on the stretch with the most signal; nil when the
        /// part has no stretch with signal.
        var lag: Int?
        /// Correlation of the two at zero lag over that stretch.
        var correlation: Float = 0
        var bytes: Int64 = 0, sourceBytes: Int64 = 0
        /// The whole part's level against its difference from the lossless one, in dB.
        var snr: Float = 0

        /// Every condition holds: it decodes, has the same number of frames, lines up at zero lag, is smaller, and
        /// is the same audio (a stretch correlates and the difference is well below the part: a gross fault such as
        /// a wrong level or another file is caught, not an encoder's ordinary loss).
        var passes: Bool {
            decodes && frames == sourceFrames && frames > 0 && lag == 0 && correlation >= Self.minCorrelation
                && bytes < sourceBytes && snr >= Self.minSNR
        }
        static let minCorrelation: Float = 0.9
        static let minSNR: Float = 10
    }

    /// The check before a swap: decodes `candidate` (AAC) to the end beside `source` (lossless), counting frames
    /// and the difference, then cross-correlates the stretch of `source` with the most signal against the same
    /// stretch of `candidate` at lags up to ±`maxLag` frames. Streams; holds a few hundred kB.
    func checkAACPart(source: URL, candidate: URL, maxLag: Int = 4096, stop: () -> Bool = { false }) throws -> AACCheck {
        var check = AACCheck()
        let fm = FileManager.default
        check.sourceBytes = ((try? fm.attributesOfItem(atPath: source.path)[.size]) as? NSNumber)?.int64Value ?? 0
        check.bytes = ((try? fm.attributesOfItem(atPath: candidate.path)[.size]) as? NSNumber)?.int64Value ?? 0
        let a = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let b: AVAudioFile
        do { b = try AVAudioFile(forReading: candidate, commonFormat: .pcmFormatFloat32, interleaved: false) } catch { return check }
        guard Self.isAAC(b), !Self.isAAC(a) else { return check }
        check.sourceFrames = Int(a.length)
        let gain = Self.formatGain(b)

        // One pass over both: frames, the difference, and the loudest window of the source.
        let chunk = 1 << 16, window = 1 << 15
        let ba = AVAudioPCMBuffer(pcmFormat: a.processingFormat, frameCapacity: AVAudioFrameCount(chunk))!
        let bb = AVAudioPCMBuffer(pcmFormat: b.processingFormat, frameCapacity: AVAudioFrameCount(chunk))!
        var sig: Double = 0, diff: Double = 0
        var best: (start: Int, energy: Float) = (0, 0)
        var pos = 0, decodedFrames = 0
        var scratch = [Float](repeating: 0, count: chunk)
        while true {
            if stop() { throw CancellationError() }
            var na = 0, nb = 0
            if a.framePosition < a.length { try a.read(into: ba, frameCount: AVAudioFrameCount(chunk)); na = Int(ba.frameLength) }
            if b.framePosition < b.length {
                do { try b.read(into: bb, frameCount: AVAudioFrameCount(chunk)) } catch { return check }
                nb = Int(bb.frameLength)
            }
            decodedFrames += nb
            if na == 0 && nb == 0 { break }
            let n = min(na, nb)
            for c in 0..<2 where n > 0 {
                let x = ba.floatChannelData![min(c, Int(a.processingFormat.channelCount) - 1)]
                let y = bb.floatChannelData![min(c, Int(b.processingFormat.channelCount) - 1)]
                var g = gain
                scratch.withUnsafeMutableBufferPointer { d in
                    vDSP_vsmul(y, 1, &g, d.baseAddress!, 1, vDSP_Length(n))
                    vDSP_vsub(d.baseAddress!, 1, x, 1, d.baseAddress!, 1, vDSP_Length(n))   // x − g·y
                    var e: Float = 0, s: Float = 0
                    vDSP_svesq(d.baseAddress!, 1, &e, vDSP_Length(n))
                    vDSP_svesq(x, 1, &s, vDSP_Length(n))
                    diff += Double(e); sig += Double(s)
                }
            }
            // The source's energy per window, both channels.
            var w = 0
            while w + window <= na {
                var l: Float = 0, r: Float = 0
                vDSP_svesq(ba.floatChannelData![0] + w, 1, &l, vDSP_Length(window))
                vDSP_svesq(ba.floatChannelData![a.processingFormat.channelCount > 1 ? 1 : 0] + w, 1, &r, vDSP_Length(window))
                if l + r > best.energy { best = (pos + w, l + r) }
                w += window
            }
            pos += max(na, nb)
        }
        check.decodes = true
        check.frames = decodedFrames
        check.snr = diff > 0 ? Float(10 * log10(max(sig, 1e-30) / diff)) : 200

        // A stretch with signal: the loudest window must be above about −60 dBFS.
        let floor = Float(window) * 2 * 1e-6
        guard best.energy > floor else { return check }
        // The window from both files, the candidate with `maxLag` frames each side, mid of the two channels.
        func mono(_ file: AVAudioFile, from start: Int, count: Int, gain: Float) throws -> [Float] {
            var out = [Float](repeating: 0, count: count)
            let s = max(0, start), skip = s - start
            guard s < Int(file.length) else { return out }
            file.framePosition = AVAudioFramePosition(s)
            let n = min(count - skip, Int(file.length) - s)
            let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n))!
            try file.read(into: buf, frameCount: AVAudioFrameCount(n))
            let ch = buf.floatChannelData!, right = file.processingFormat.channelCount > 1 ? 1 : 0
            out.withUnsafeMutableBufferPointer { o in
                var h = gain / 2
                vDSP_vadd(ch[0], 1, ch[right], 1, o.baseAddress! + skip, 1, vDSP_Length(Int(buf.frameLength)))
                vDSP_vsmul(o.baseAddress! + skip, 1, &h, o.baseAddress! + skip, 1, vDSP_Length(Int(buf.frameLength)))
            }
            return out
        }
        let x = try mono(a, from: best.start, count: window, gain: 1)
        let y = try mono(b, from: best.start - maxLag, count: window + 2 * maxLag, gain: gain)
        // corr[k] = Σ x[i]·y[i + k], k = 0…2·maxLag; lag = k − maxLag. Normalised by the energy of each stretch of
        // `y`, or a louder stretch nearby would win on loudness alone.
        let count = 2 * maxLag + 1
        var corr = [Float](repeating: 0, count: count)
        vDSP_conv(y, 1, x, 1, &corr, 1, vDSP_Length(count), vDSP_Length(window))
        var xx: Float = 0
        vDSP_svesq(x, 1, &xx, vDSP_Length(window))
        // Energy of y[k ..< k + window] for every k, from a running sum of squares (in Double: no drift).
        var cum = [Double](repeating: 0, count: y.count + 1)
        for i in 0..<y.count { cum[i + 1] = cum[i] + Double(y[i]) * Double(y[i]) }
        var bestLag = 0, bestValue = -Float.infinity
        for k in 0..<count {
            let yy = Float(max(cum[k + window] - cum[k], 0))
            let v = corr[k] / max(sqrt(xx * yy), 1e-20)
            if k == maxLag { check.correlation = v }
            if v > bestValue { bestValue = v; bestLag = k - maxLag }
        }
        check.lag = bestLag
        return check
    }

    static func frameCount(of url: URL) -> Int {
        (try? AVAudioFile(forReading: url).length).map(Int.init) ?? 0
    }
}

nonisolated enum Peaks {
    /// Max-abs of the mono mix per bucket, normalised to the loudest stem later.
    static func compute(_ a: StereoAudio, buckets: Int = 1600) -> [Float] {
        let n = a.frameCount
        guard n > 0 else { return [Float](repeating: 0, count: buckets) }
        var out = [Float](repeating: 0, count: buckets)
        a.left.withUnsafeBufferPointer { l in
            a.right.withUnsafeBufferPointer { r in
                for b in 0..<buckets {
                    let s = b * n / buckets, e = max(s + 1, (b + 1) * n / buckets)
                    var ml: Float = 0, mr: Float = 0
                    vDSP_maxmgv(l.baseAddress! + s, 1, &ml, vDSP_Length(e - s))
                    vDSP_maxmgv(r.baseAddress! + s, 1, &mr, vDSP_Length(e - s))
                    out[b] = max(ml, mr)
                }
            }
        }
        return out
    }

    /// Resamples to `count` bars by taking the max of each span.
    static func resample(_ p: [Float], to count: Int) -> [Float] {
        guard count > 0, !p.isEmpty else { return [] }
        return (0..<count).map { i in
            let s = i * p.count / count, e = max(s + 1, (i + 1) * p.count / count)
            return p[s..<min(e, p.count)].max() ?? 0
        }
    }
}

/// `Application Support/Backline`: songs, staged imports, downloads, recordings and the downloaded models.
/// On the Mac only the models stay out of Time Machine (D5): they can be downloaded again, and a Time Machine disk
/// has no quota like iCloud's, so the songs (and their loops and mixes) stay in the backup. The flag on the models
/// folder covers everything in it; it is set at launch and wherever the folder may have to be made again.
nonisolated enum BacklineFolders {
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backline", isDirectory: true)
    }

    /// `Application Support/Backline/Models`, the one folder kept out of Time Machine.
    static var models: URL { support.appendingPathComponent("Models", isDirectory: true) }

    /// Makes `folder` if it isn't there and marks it excluded from backup. True when it ends up marked.
    @discardableResult
    static func ensureExcludedFromBackup(_ folder: URL = models, fm: FileManager = .default) -> Bool {
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if isExcludedFromBackup(folder) { return true }
        var url = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        return (try? url.setResourceValues(values)) != nil
    }

    static func isExcludedFromBackup(_ url: URL) -> Bool {
        // A fresh URL: resource values are cached on the URL value that read them.
        let fresh = URL(fileURLWithPath: url.path, isDirectory: true)
        return (try? fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true
    }
}
