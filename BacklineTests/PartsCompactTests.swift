import Accelerate
import AVFoundation
import BacklineKit
import XCTest
@testable import Backline

/// D19: a song's parts become AAC once no pass will read them again (the AAC part format in
/// docs/release-1.1-everywhere.md). The rule, the writer and its check, an interrupted swap, and a 1.0 song
/// that converts and still plays at the same level.
@MainActor
final class PartsCompactTests: XCTestCase {
    private static var keepAlive: [AppModel] = []

    // MARK: material

    /// Something like music: a few partials with a moving envelope, some noise, and a quiet first second.
    nonisolated static func music(seconds: Double, seed: UInt64 = 1, level: Float = 0.6) -> StereoAudio {
        let n = Int(seconds * 44_100)
        var rng = seed
        func noise() -> Float {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: rng >> 11) % 2000) / 2000 - 0.5
        }
        var l = [Float](repeating: 0, count: n), r = l
        for i in 0..<n {
            let t = Double(i) / 44_100
            let env = Float(t < 1 ? 0.02 : 0.5 + 0.5 * sin(t * 2.1))
            let tone = sin(2 * .pi * 220 * t) + 0.5 * sin(2 * .pi * 330.5 * t) + 0.25 * sin(2 * .pi * 1_234 * t)
            l[i] = level * env * (Float(tone) / 1.75 * 0.8 + 0.2 * noise())
            r[i] = level * env * (Float(sin(2 * .pi * 196 * t + 0.3)) * 0.8 + 0.2 * noise())
        }
        return StereoAudio(left: l, right: r, sampleRate: 44_100)
    }

    private func tempStore() throws -> SongStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PartsCompactTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return SongStore(root: dir)
    }

    private static func analysis() throws -> SongAnalysis {
        let json: [String: Any] = ["bpm": 120.0, "beats": [0.0, 0.5], "downbeats": [0.0], "key": "E minor", "tuningCents": 0.0,
                                   "sections": [] as [Any]]
        return try JSONDecoder().decode(SongAnalysis.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private static func record(_ id: String, stems: [StemKind] = [.vocals, .guitar, .bass, .drums, .keys, .other],
                               seconds: Double = 4) throws -> SongRecord {
        SongRecord(id: id, title: "AAC parts", artist: nil, duration: seconds, sourceName: "t.mp3", addedAt: Date(),
                   lastOpened: Date(), stems: stems, analysis: try analysis(), peaks: [:], storageScale: [:],
                   hasArtwork: false, settings: SongSettings())
    }

    private static func split(_ method: String, otherAdjusted: Bool = true) -> GuitarSplit {
        GuitarSplit(method: method, confidence: 0.8, leadPeaks: [], rhythmPeaks: [], leadScale: 1, rhythmScale: 1,
                    otherAdjusted: otherAdjusted, otherPeaks: [], otherScale: 1)
    }

    private static let kit = DrumSplit(method: DrumSplitJob.method, peaks: [:], scales: [:],
                                       energy: ["kick": 0.3, "snare": 0.3, "hats": 0.3, "toms": 0.1])

    // MARK: the rule

    func testWhichPartsMayConvertInEachStateOfASong() throws {
        let six = ["vocals.caf", "guitar.caf", "bass.caf", "keys.caf", "other.caf"]      // drums waits for the kit
        let split = ["lead.caf", "rhythm.caf", "other-split.caf"]
        let kitFiles = ["kick.caf", "snare.caf", "hats.caf", "toms.caf"]
        func parts(_ r: SongRecord, cleaner: Bool = true, lead: Bool = true) -> Set<String> {
            Set(PartsCompactJob.convertible(r, cleanerInstalled: cleaner, leadModelBundled: lead))
        }

        // A new import: original kept, stereo split waiting for its refinement, cleaner pass to come.
        var r = try Self.record("rule")
        r.originalFile = "source.mp3"
        r.guitarSplit = Self.split(LeadRefineJob.stereoMethod)
        XCTAssertEqual(parts(r), [], "the cleaner pass and the refinement are still to come")
        XCTAssertEqual(parts(r, cleaner: false), [], "the refinement reads Guitar, Other, Lead and the rest for levels")
        XCTAssertEqual(parts(r, cleaner: false, lead: false), Set(six + split), "nothing left to read them: no model, no pass")

        // Refined, then the cleaner pass to come: nothing yet (it writes every part anew).
        r.guitarSplit = Self.split(LeadRefineJob.refinedMethod)
        XCTAssertEqual(parts(r), [])
        // No cleaner model on this device: done.
        XCTAssertEqual(parts(r, cleaner: false), Set(six + split))
        // The cleaner pass has run (and the refinement after it).
        r.separator = CleanerPartsJob.method
        XCTAssertEqual(parts(r), Set(six + split))
        // After the cleaner pass the split is the stereo one again, waiting for its refinement.
        r.guitarSplit = Self.split(LeadRefineJob.stereoMethod)
        XCTAssertEqual(parts(r), [])
        // The model tried and the stereo split was kept on purpose.
        r.guitarSplit = Self.split(LeadRefineJob.keptStereoMethod)
        XCTAssertEqual(parts(r), Set(six + split))
        // Other with the lead taken out only when the split made one.
        r.guitarSplit = Self.split(LeadRefineJob.keptStereoMethod, otherAdjusted: false)
        XCTAssertEqual(parts(r), Set(six + ["lead.caf", "rhythm.caf"]))
        // No guitar split at all: nothing to refine.
        r.guitarSplit = nil
        XCTAssertEqual(parts(r), Set(six))

        // Drums and the kit parts once the kit has been split.
        r.drumSplit = Self.kit
        XCTAssertEqual(parts(r), Set(six + ["drums.caf"] + kitFiles))

        // A song from 1.0: "stereo+ml-go-v1" with original.caf and no cleaner pass yet.
        var old = try Self.record("one-oh")
        old.originalScale = 0.9
        old.guitarSplit = Self.split(LeadRefineJob.refinedMethod)
        XCTAssertEqual(parts(old), [], "its cleaner pass is still to come where the model is installed")
        XCTAssertEqual(parts(old, cleaner: false), Set(six + split))
        // A song that keeps no original can't have a cleaner pass.
        old.originalScale = nil
        XCTAssertEqual(parts(old), Set(six + split))

        // The kept original is never converted, in any state.
        for c in [false, true] { for l in [false, true] {
            XCTAssertFalse(parts(r, cleaner: c, lead: l).contains { $0.hasPrefix("original") || $0.hasPrefix("source") })
        } }
    }

    // MARK: the writer and the check

    func testAnAACPartIsFrameExactAlignedSmallerAndAtTheSameLevel() throws {
        let store = try tempStore()
        let audio = Self.music(seconds: 7.3, level: 0.98)   // close to full scale: the stored part's worst case
        let live = store.root.appendingPathComponent("vocals.caf")
        try store.writeStem(audio, to: live)
        let temp = PartsCompactJob.tempURL(live)
        try store.writeAACPart(from: live, to: temp)

        XCTAssertTrue(SongStore.isAAC(temp))
        XCTAssertFalse(SongStore.isAAC(live))
        XCTAssertEqual(SongStore.formatGain(of: temp), 2)
        XCTAssertEqual(SongStore.formatGain(of: live), 1)
        let check = try store.checkAACPart(source: live, candidate: temp)
        print("[aac] check \(check)")
        XCTAssertTrue(check.decodes)
        XCTAssertEqual(check.frames, audio.frameCount, "frame-exact length")
        XCTAssertEqual(check.sourceFrames, audio.frameCount)
        XCTAssertEqual(check.lag, 0, "lines up at zero lag")
        XCTAssertGreaterThan(check.correlation, 0.99)
        XCTAssertLessThan(check.bytes, check.sourceBytes)
        XCTAssertGreaterThan(check.snr, 15)
        XCTAssertTrue(check.passes)

        // Every Float32 reader gets the part at its stored level from either file.
        let a = try store.readAudio(live), b = try store.readAudio(temp)
        XCTAssertEqual(b.frameCount, a.frameCount)
        var ea: Float = 0, eb: Float = 0, peakFile: Float = 0
        vDSP_svesq(a.left, 1, &ea, vDSP_Length(a.frameCount))
        vDSP_svesq(b.left, 1, &eb, vDSP_Length(b.frameCount))
        XCTAssertEqual(10 * log10(eb / ea), 0, accuracy: 0.2, "same level in dB")
        // The range reader too, part way in.
        var l = [Float](repeating: 0, count: 1000), r = l
        try l.withUnsafeMutableBufferPointer { lp in try r.withUnsafeMutableBufferPointer { rp in
            _ = try store.readStem(temp, left: lp.baseAddress! - 100_000, right: rp.baseAddress! - 100_000, frames: 100_000..<101_000)
        } }
        XCTAssertEqual(l, Array(b.left[100_000..<101_000]))
        // The file holds half amplitude: a decoded peak can't clip.
        let raw = try AVAudioFile(forReading: temp, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: raw.processingFormat, frameCapacity: AVAudioFrameCount(raw.length))!
        try raw.read(into: buf)
        vDSP_maxmgv(buf.floatChannelData![0], 1, &peakFile, vDSP_Length(buf.frameLength))
        XCTAssertLessThan(peakFile, 0.6)
        XCTAssertGreaterThan(peakFile, 0.4)
    }

    /// The owner's figure (D19, ios-last): the encoder's constrained variable mode at 192 kbps, so a dense part
    /// comes out at about 192 kbps (not the 155 to 173 of the quality setting it replaces) and a quiet one at less.
    func testAPartIsWrittenAtAbout192Kbps() throws {
        let settings = SongStore.aacSettings
        XCTAssertEqual(settings[AVEncoderBitRateStrategyKey] as? String, AVAudioBitRateStrategy_VariableConstrained)
        XCTAssertEqual(settings[AVEncoderBitRateKey] as? Int, 192_000)
        XCTAssertNil(settings[AVEncoderAudioQualityForVBRKey])

        func kbps(_ audio: StereoAudio, _ name: String) throws -> Double {
            let store = try tempStore()
            let live = store.root.appendingPathComponent("\(name).caf")
            try store.writeStem(audio, to: live)
            let aac = PartsCompactJob.tempURL(live)
            try store.writeAACPart(from: live, to: aac)
            var file: AudioFileID?
            XCTAssertEqual(AudioFileOpenURL(aac as CFURL, .readPermission, 0, &file), noErr)
            defer { if let file { AudioFileClose(file) } }
            var bytes: UInt64 = 0
            var size = UInt32(MemoryLayout<UInt64>.size)
            XCTAssertEqual(AudioFileGetProperty(file!, kAudioFilePropertyAudioDataByteCount, &size, &bytes), noErr)
            return Double(bytes) * 8 / (Double(audio.frameCount) / 44_100) / 1000
        }
        // Dense: the whole band at once, noise across the spectrum.
        let dense = try kbps(Self.music(seconds: 12, seed: 7, level: 0.9), "dense")
        // Sparse: one soft low tone.
        let n = 12 * 44_100
        var tone = [Float](repeating: 0, count: n)
        for i in 0..<n { tone[i] = Float(0.2 * sin(2.0 * Double.pi * 82.4 * Double(i) / 44_100.0)) }
        let sparse = try kbps(StereoAudio(left: tone, right: tone, sampleRate: 44_100), "sparse")
        print("[aac] dense \(dense) kbps, sparse \(sparse) kbps")
        // The constrained mode goes a little over its target on dense material (real mixes 195 to 199 kbps; this
        // made-up one, a fifth of it white noise, about 209), and well over the quality setting it replaces.
        XCTAssertGreaterThan(dense, 175, "a dense part at about the owner's 192 kbps")
        XCTAssertLessThan(dense, 225)
        XCTAssertLessThan(sparse, dense, "a sparse part takes less")
    }

    func testTheCheckRefusesAFileThatDoesntLineUpOrIsntSmaller() throws {
        let store = try tempStore()
        let audio = Self.music(seconds: 5)
        let live = store.root.appendingPathComponent("guitar.caf")
        try store.writeStem(audio, to: live)

        // Shifted by 300 frames, the same length: decodes, but doesn't line up.
        let shift = 300
        var shifted = audio
        shifted.left = [Float](repeating: 0, count: shift) + audio.left.dropLast(shift)
        shifted.right = [Float](repeating: 0, count: shift) + audio.right.dropLast(shift)
        let shiftedLive = store.root.appendingPathComponent("shifted.caf")
        try store.writeStem(shifted, to: shiftedLive)
        let shiftedAAC = store.root.appendingPathComponent("shifted.compact.caf")
        try store.writeAACPart(from: shiftedLive, to: shiftedAAC)
        let c1 = try store.checkAACPart(source: live, candidate: shiftedAAC)
        XCTAssertEqual(c1.frames, c1.sourceFrames)
        XCTAssertEqual(c1.lag, shift)
        XCTAssertFalse(c1.passes)

        // A different number of frames.
        var longer = audio
        longer.left += [Float](repeating: 0, count: 4_410)
        longer.right += [Float](repeating: 0, count: 4_410)
        let longerLive = store.root.appendingPathComponent("longer.caf")
        try store.writeStem(longer, to: longerLive)
        let longerAAC = store.root.appendingPathComponent("longer.compact.caf")
        try store.writeAACPart(from: longerLive, to: longerAAC)
        let c2 = try store.checkAACPart(source: live, candidate: longerAAC)
        XCTAssertNotEqual(c2.frames, c2.sourceFrames)
        XCTAssertFalse(c2.passes)

        // A silent part: Apple Lossless is next to nothing, so AAC isn't smaller (and has no stretch with signal).
        let silent = store.root.appendingPathComponent("rhythm.caf")
        try store.writeStem(StereoAudio(left: [Float](repeating: 0, count: audio.frameCount),
                                        right: [Float](repeating: 0, count: audio.frameCount), sampleRate: 44_100), to: silent)
        let silentAAC = PartsCompactJob.tempURL(silent)
        try store.writeAACPart(from: silent, to: silentAAC)
        let c3 = try store.checkAACPart(source: silent, candidate: silentAAC)
        XCTAssertFalse(c3.passes)

        // Something that isn't AAC, or doesn't decode.
        XCTAssertFalse(try store.checkAACPart(source: live, candidate: live).passes)
        let garbage = store.root.appendingPathComponent("garbage.compact.caf")
        try Data("not audio".utf8).write(to: garbage)
        XCTAssertFalse(try store.checkAACPart(source: live, candidate: garbage).decodes)
    }

    // MARK: one song

    /// A song on disk in `store`: the six parts (different material each), a 1.0 guitar split, and original.caf.
    private func writeSong(_ id: String, store: SongStore, seconds: Double = 4) throws -> SongRecord {
        try FileManager.default.createDirectory(at: store.folder(id), withIntermediateDirectories: true)
        var rec = try Self.record(id, seconds: seconds)
        var scales: [String: Float] = [:]
        for (i, k) in rec.stems.enumerated() {
            let (_, s) = try ImportPipeline.writeScaled(Self.music(seconds: seconds, seed: UInt64(i + 2), level: 0.4 + 0.15 * Float(i)),
                                                        to: store.stemURL(id, k), store: store)
            scales[k.rawValue] = s
        }
        rec.storageScale = scales
        let (_, ls) = try ImportPipeline.writeScaled(Self.music(seconds: seconds, seed: 20, level: 1.3), to: store.stemURL(id, .leadGuitar), store: store)
        let (_, rs) = try ImportPipeline.writeScaled(Self.music(seconds: seconds, seed: 21), to: store.stemURL(id, .rhythmGuitar), store: store)
        let (_, os) = try ImportPipeline.writeScaled(Self.music(seconds: seconds, seed: 22), to: store.otherSplitURL(id), store: store)
        rec.guitarSplit = GuitarSplit(method: LeadRefineJob.refinedMethod, confidence: 0.8, leadPeaks: [], rhythmPeaks: [],
                                      leadScale: ls, rhythmScale: rs, otherAdjusted: true, otherPeaks: [], otherScale: os)
        rec.originalScale = try ImportPipeline.writeScaled(Self.music(seconds: seconds, seed: 30), to: store.originalURL(id), store: store).1
        try store.save(rec)
        return rec
    }

    func testAnInterruptedSwapLeavesAPlayableSong() async throws {
        let store = try tempStore()
        let rec = try writeSong("interrupted", store: store)
        let parts = PartsCompactJob.convertible(rec, cleanerInstalled: false, leadModelBundled: true)
        XCTAssertEqual(parts.count, 8)
        let before = Dictionary(uniqueKeysWithValues: try parts.map { ($0, try store.readAudio(store.folder(rec.id).appendingPathComponent($0))) })

        // Killed after three swaps, with the fourth part's AAC half written beside it.
        let swaps = SwapCounter(allow: 3)
        let first = await PartsCompactJob.compact(id: rec.id, parts: parts, store: store, stop: { false }, mayGoOn: { true },
                                                  swap: { _, temp, live, was in
            guard swaps.take() else {
                try? Data(count: 1_000).write(to: temp)          // what a kill mid-write leaves
                return false
            }
            return PartsCompactJob.install(temp: temp, live: live, was: was)
        })
        XCTAssertEqual(first.outcome, .stopped)
        XCTAssertEqual(first.converted.count, 3)
        let aac = parts.filter { SongStore.isAAC(store.folder(rec.id).appendingPathComponent($0)) }
        XCTAssertEqual(aac.count, 3, "each part is one format or the other")

        // The song plays: every engine track loads, at the same level as before, from either format.
        let r = try store.readAudio(store.originalURL(rec.id))
        XCTAssertEqual(r.frameCount, Int(rec.duration * 44_100))
        let engine = PlaybackEngine(drivesOutput: false)
        XCTAssertTrue(AppModel.loadEngine(rec, store: store, engine: engine))
        let gains = AppModel.formatGains(rec, store: store)
        for k in rec.engineTracks {
            let name = store.mixURL(rec, k).lastPathComponent
            XCTAssertEqual(gains[k], aac.contains(name) ? 2 : 1, "\(k): the mixer doubles an AAC part only")
        }
        for name in parts {
            let now = try store.readAudio(store.folder(rec.id).appendingPathComponent(name))
            XCTAssertEqual(now.frameCount, before[name]!.frameCount, name)
            XCTAssertEqual(Self.levelDifference(now, before[name]!), 0, accuracy: 0.2, "\(name) at the same level")
        }
        withExtendedLifetime(engine) {}

        // The next visit clears what was left half written and finishes.
        let second = await PartsCompactJob.compact(id: rec.id, parts: parts, store: store, stop: { false }, mayGoOn: { true },
                                                   swap: { _, temp, live, was in PartsCompactJob.install(temp: temp, live: live, was: was) })
        XCTAssertEqual(second.outcome, .finished)
        XCTAssertEqual(second.converted.count, 5)
        let left = try FileManager.default.contentsOfDirectory(atPath: store.folder(rec.id).path)
        XCTAssertFalse(left.contains { $0.hasSuffix(".compact.caf") }, "nothing half written stays")
        XCTAssertFalse(SongStore.isAAC(store.originalURL(rec.id)), "the kept original is never converted")
        XCTAssertFalse(SongStore.isAAC(store.stemURL(rec.id, .drums)), "Drums waits for the kit")
        XCTAssertTrue(parts.allSatisfy { SongStore.isAAC(store.folder(rec.id).appendingPathComponent($0)) })
    }

    func testAPartThatFailsTheCheckStaysLosslessAndIsNotTriedAgain() async throws {
        let store = try tempStore()
        var rec = try writeSong("kept", store: store)
        // A silent Keys part: its AAC file isn't smaller than Apple Lossless's nothing.
        try store.writeStem(StereoAudio(left: [Float](repeating: 0, count: 4 * 44_100), right: [Float](repeating: 0, count: 4 * 44_100),
                                        sampleRate: 44_100), to: store.stemURL(rec.id, .keys))
        rec.guitarSplit = nil
        let parts = PartsCompactJob.convertible(rec, cleanerInstalled: false, leadModelBundled: true)
        let install: @Sendable (String, URL, URL, PartsCompactJob.Identity) async -> Bool = { _, t, l, w in PartsCompactJob.install(temp: t, live: l, was: w) }
        let first = await PartsCompactJob.compact(id: rec.id, parts: parts, store: store, stop: { false }, mayGoOn: { true }, swap: install)
        XCTAssertEqual(first.kept, ["keys.caf"])
        XCTAssertFalse(SongStore.isAAC(store.stemURL(rec.id, .keys)))
        let again = await PartsCompactJob.compact(id: rec.id, parts: parts, store: store, stop: { false }, mayGoOn: { true }, swap: install)
        XCTAssertEqual(again, PartsCompactJob.Report(), "nothing tried again")
        // A new file there (a new split) is tried again.
        try store.writeStem(Self.music(seconds: 4, seed: 9), to: store.stemURL(rec.id, .keys))
        let third = await PartsCompactJob.compact(id: rec.id, parts: parts, store: store, stop: { false }, mayGoOn: { true }, swap: install)
        XCTAssertEqual(third.converted, ["keys.caf"])
    }

    /// ios-storage#1: a part that can't be read is skipped and left as it is; the song's other parts convert and
    /// the visit finishes, so the queue goes on to the next song instead of stopping on this one for good.
    func testAPartThatCantBeReadIsSkippedAndTheVisitFinishes() async throws {
        let store = try tempStore()
        let rec = try writeSong("damaged", store: store)
        let damaged = store.stemURL(rec.id, .vocals)
        try Data(repeating: 0x5A, count: 4096).write(to: damaged)
        let parts = PartsCompactJob.convertible(rec, cleanerInstalled: false, leadModelBundled: true)
        XCTAssertTrue(parts.contains("vocals.caf"))
        let install: @Sendable (String, URL, URL, PartsCompactJob.Identity) async -> Bool = { _, t, l, w in PartsCompactJob.install(temp: t, live: l, was: w) }
        let r = await PartsCompactJob.compact(id: rec.id, parts: parts, store: store, stop: { false }, mayGoOn: { true }, swap: install)
        XCTAssertEqual(r.outcome, .finished, "not a stop: the next song goes")
        XCTAssertEqual(r.unreadable, ["vocals.caf"])
        XCTAssertEqual(r.converted.count, parts.count - 1, "the song's other parts convert")
        XCTAssertEqual(try Data(contentsOf: damaged), Data(repeating: 0x5A, count: 4096), "the damaged file is left as it is")
        let left = try FileManager.default.contentsOfDirectory(atPath: store.folder(rec.id).path)
        XCTAssertFalse(left.contains { $0.hasSuffix(".compact.caf") })
    }

    func testAStopLeavesTheSongAsItWas() async throws {
        let store = try tempStore()
        let rec = try writeSong("stopped", store: store)
        let parts = PartsCompactJob.convertible(rec, cleanerInstalled: false, leadModelBundled: true)
        let r = await PartsCompactJob.compact(id: rec.id, parts: parts, store: store, stop: { true }, mayGoOn: { true },
                                              swap: { _, _, _, _ in XCTFail("no swap after a stop"); return false })
        XCTAssertEqual(r.outcome, .stopped)
        let short = await PartsCompactJob.compact(id: rec.id, parts: parts, store: store, stop: { false }, mayGoOn: { false },
                                                  swap: { _, _, _, _ in XCTFail("no swap when memory is short"); return false })
        XCTAssertEqual(short.outcome, .stopped)
        XCTAssertFalse(parts.contains { SongStore.isAAC(store.folder(rec.id).appendingPathComponent($0)) })
        let left = try FileManager.default.contentsOfDirectory(atPath: store.folder(rec.id).path)
        XCTAssertFalse(left.contains { $0.hasSuffix(".compact.caf") })
    }

    func testASwapNeverReplacesAFileWrittenSinceItWasConverted() throws {
        let store = try tempStore()
        let live = store.root.appendingPathComponent("kick.caf")
        try store.writeStem(Self.music(seconds: 3, seed: 3), to: live)
        let was = try XCTUnwrap(PartsCompactJob.Identity(live))
        let temp = PartsCompactJob.tempURL(live)
        try store.writeAACPart(from: live, to: temp)
        // A new kit split writes kick.caf meanwhile.
        try store.writeStem(Self.music(seconds: 3, seed: 4), to: live)
        XCTAssertFalse(PartsCompactJob.install(temp: temp, live: live, was: was))
        XCTAssertFalse(SongStore.isAAC(live), "the new lossless file stays")
    }

    // MARK: in the app

    /// A 1.0 song (a refined guitar split, original.caf) opens, converts while it is open, and plays the same
    /// afterwards: the export of the whole mix from the engine (as Save track makes it) is the same audio at the
    /// same level, read from AAC parts the second time.
    func testASongFrom10ConvertsAndStillPlays() async throws {
        let store = SongStore.shared
        let id = "aac-one-oh-\(UUID().uuidString.prefix(6))"
        let rec = try writeSong(id, store: store, seconds: 6)
        addTeardownBlock { store.delete(id) }
        PartsCompactJob.automatic.store(true, ordering: .relaxed)
        defer { PartsCompactJob.automatic.store(false, ordering: .relaxed) }

        let m = AppModel()
        Self.keepAlive.append(m)
        await m.libraryReady()
        m.library = [rec]
        let parts = PartsCompactJob.convertible(rec)
        try XCTSkipIf(parts.isEmpty, "this Simulator has the cleaner model: the song isn't finished")
        m.select(rec)
        try await waitUntil { m.song?.id == id && m.loadingSongID == nil }
        let lossless = await export(m)
        XCTAssertTrue(m.loadedFormatGains.values.allSatisfy { $0 == 1 })

        // It converts while open (the engine keeps the samples it read).
        m.ensurePartsCompact()
        try await waitUntil { m.compactJob == nil }
        let folder = store.folder(id)
        for name in parts { XCTAssertTrue(SongStore.isAAC(folder.appendingPathComponent(name)), name) }
        XCTAssertFalse(SongStore.isAAC(store.originalURL(id)), "the kept original stays as it is")
        XCTAssertFalse(SongStore.isAAC(store.stemURL(id, .drums)), "Drums waits for the kit")
        XCTAssertEqual(m.compactVisited[id], parts)
        XCTAssertEqual(try store.readAudio(store.originalURL(id)).frameCount, 6 * 44_100)

        // Reloaded in place at a pause (as after a pass), then opened again after another song: from the AAC parts.
        m.forceTrackReload = true
        m.performTrackReload()
        try await waitUntil { m.formatGain(.vocals) == 2 }
        let reloaded = await export(m)
        XCTAssertEqual(Self.levelDifference(StereoAudio(left: reloaded.left, right: reloaded.right, sampleRate: 44_100),
                                            StereoAudio(left: lossless.left, right: lossless.right, sampleRate: 44_100)), 0, accuracy: 0.2)
        let otherID = "aac-other-\(UUID().uuidString.prefix(6))"
        let other = try Self.record(otherID, stems: [.vocals, .bass], seconds: 2)
        try FileManager.default.createDirectory(at: store.folder(otherID), withIntermediateDirectories: true)
        for k in other.stems { try store.writeStem(Self.music(seconds: 2), to: store.stemURL(otherID, k)) }
        try store.save(other)
        addTeardownBlock { store.delete(otherID) }
        m.library = [rec, other]
        m.select(other)
        try await waitUntil { m.song?.id == otherID && m.loadingSongID == nil }
        try await waitUntil { m.compactJob == nil }
        m.select(rec)
        try await waitUntil { m.song?.id == id && m.loadingSongID == nil }
        XCTAssertEqual(m.screen, .mixer)
        for k in m.loadedTracks where k != .drums { XCTAssertEqual(m.formatGain(k), 2, "\(k) is doubled in the mixer") }
        XCTAssertEqual(m.formatGain(.drums), 1)
        let compact = await export(m)
        XCTAssertEqual(compact.left.count, lossless.left.count, "the same length")
        let diff = Self.levelDifference(StereoAudio(left: compact.left, right: compact.right, sampleRate: 44_100),
                                        StereoAudio(left: lossless.left, right: lossless.right, sampleRate: 44_100))
        XCTAssertEqual(diff, 0, accuracy: 0.2, "the same level")
        XCTAssertGreaterThan(Self.snr(compact.left, lossless.left), 15, "the same audio")
    }

    /// An import that ends without opening a song (failed, cancelled) lets the Library's conversion start again
    /// (review mac-core#5); while it is under way, nothing starts.
    func testTheConversionStartsAgainAfterAnImportThatOpensNoSong() async throws {
        let store = SongStore.shared
        let id = "aac-after-import-\(UUID().uuidString.prefix(6))"
        let rec = try writeSong(id, store: store)
        addTeardownBlock { store.delete(id) }
        let m = AppModel()
        Self.keepAlive.append(m)
        await m.libraryReady()
        // Turned on only now: the launch's own start (after the Library loads) has come and gone.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(m.compactJob)
        PartsCompactJob.automatic.store(true, ordering: .relaxed)
        defer { PartsCompactJob.automatic.store(false, ordering: .relaxed) }
        m.library = [rec]
        let parts = PartsCompactJob.convertible(rec)
        try XCTSkipIf(parts.isEmpty, "this Mac has the cleaner model: the song isn't finished")
        // A link's download is under way, then fails (as `endLinkDownload` ends it): no song opens.
        m.screen = .analyzing
        m.downloadingFromYouTube = true
        m.ensurePartsCompact()
        XCTAssertNil(m.compactJob, "nothing starts during an import")
        m.downloadingFromYouTube = false
        m.screen = .failed("Can't read this file.")
        try await waitUntil { parts.allSatisfy { SongStore.isAAC(store.folder(id).appendingPathComponent($0)) } }
        try await waitUntil { m.compactJob == nil }
        m.screen = .empty
    }

    func testTheOpenSongGoesFirstThenTheLibraryAndABusySongWaits() async throws {
        let m = AppModel()
        Self.keepAlive.append(m)
        await m.libraryReady()
        func finished(_ id: String) throws -> SongRecord {
            var r = try Self.record(id)
            r.guitarSplit = Self.split(LeadRefineJob.refinedMethod)
            return r
        }
        let a = try finished("order-a"), b = try finished("order-b"), c = try finished("order-c")
        m.library = [a, b, c]
        m.song = b
        defer { m.song = nil; m.library = [] }
        guard m.nextCompactSong() != nil else { throw XCTSkip("this Simulator has the cleaner model: no song is finished") }
        XCTAssertEqual(m.nextCompactSong()?.id, "order-b", "the open song first")
        XCTAssertEqual(m.nextCompactSong()?.parts, PartsCompactJob.convertible(b))
        // A pass working on the open song: the Library goes on, in its order.
        m.pendingRecord = b
        XCTAssertTrue(m.compactMustWait("order-b"))
        XCTAssertEqual(m.nextCompactSong()?.id, "order-a")
        m.pendingRecord = nil
        // Each song once per form: a song whose parts haven't changed since its visit isn't visited again.
        m.compactVisited["order-b"] = PartsCompactJob.convertible(b)
        m.compactVisited["order-a"] = PartsCompactJob.convertible(a)
        XCTAssertEqual(m.nextCompactSong()?.id, "order-c")
        // A Library song's lead refinement makes that song wait.
        m.leadJobSong = "order-c"
        m.leadJob = Task {}
        XCTAssertNil(m.nextCompactSong())
        m.leadJob = nil
        m.leadJobSong = nil
        // Its form changed (the kit split landed): visited again.
        m.song?.drumSplit = Self.kit
        XCTAssertEqual(m.nextCompactSong()?.id, "order-b")
    }

    /// ios-import#1, ios-storage#5: while an import is under way (here its split; a link's download and a file being
    /// fingerprinted count too) the conversion doesn't start, whatever the screen shows; when the import ends
    /// without opening a song, the passes it paused start again.
    func testNothingConvertsDuringAnImportAndItStartsAgainAfter() async throws {
        PartsCompactJob.automatic.store(true, ordering: .relaxed)
        defer { PartsCompactJob.automatic.store(false, ordering: .relaxed) }
        let m = AppModel()
        Self.keepAlive.append(m)
        await m.libraryReady()
        // A finished song with no files: its visit ends at once (nothing to convert) and marks it visited.
        var rec = try Self.record("import-under-way-\(UUID().uuidString.prefix(6))")
        rec.guitarSplit = Self.split(LeadRefineJob.refinedMethod)
        m.library = [rec]
        defer { m.library = []; m.splitRunning = nil; m.downloadingFromYouTube = false }
        guard m.nextCompactSong() != nil else { throw XCTSkip("this Simulator has the cleaner model: no song is finished") }

        m.splitRunning = 1
        XCTAssertTrue(m.importUnderWay)
        XCTAssertEqual(m.screen, .empty, "the screen says nothing: the import itself is what counts")
        m.ensurePartsCompact()
        m.ensureLeadRefine(); m.ensureCleanerParts(); m.ensureDrumSplit()
        XCTAssertNil(m.compactJob, "no conversion beside an import")
        XCTAssertFalse(m.passesRunning)

        // A link's download is under way too.
        m.splitRunning = nil
        m.downloadingFromYouTube = true
        XCTAssertTrue(m.importUnderWay)
        m.ensurePartsCompact()
        XCTAssertNil(m.compactJob)

        // The import ends (it failed or was cancelled): the passes start again by themselves.
        m.downloadingFromYouTube = false
        XCTAssertFalse(m.importUnderWay)
        try await waitUntil { m.compactVisited[rec.id] != nil }
    }

    /// ios-import#3: one import at a time. While one is under way every way in (the sidebar's +, File ▸ Add Song,
    /// a drop, Open with and the Dock all end in `open`, a pasted or dropped link in `openText`) says so and starts
    /// nothing; a file the app downloaded for it goes, a recording and a person's own file never do.
    func testASecondSongIsRefusedWhileOneIsUnderWay() async throws {
        let m = AppModel()
        Self.keepAlive.append(m)
        await m.libraryReady()
        defer { m.splitRunning = nil; m.recordSheet = false }
        let fm = FileManager.default
        try fm.createDirectory(at: ImportStaging.downloadsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: ImportStaging.recordingsDirectory, withIntermediateDirectories: true)
        let staged = ImportStaging.downloadsDirectory.appendingPathComponent("refused-\(UUID().uuidString).wav")
        let take = ImportStaging.recordingsDirectory.appendingPathComponent("refused-\(UUID().uuidString).wav")
        let own = fm.temporaryDirectory.appendingPathComponent("refused-own-\(UUID().uuidString).wav")
        try Data(count: 64).write(to: staged)
        try Data(count: 64).write(to: take)
        try Data(count: 64).write(to: own)
        addTeardownBlock { try? fm.removeItem(at: staged); try? fm.removeItem(at: take); try? fm.removeItem(at: own) }

        m.splitRunning = 1
        m.open(staged)
        XCTAssertEqual(m.toast?.text, "Still splitting another song.")
        XCTAssertFalse(fm.fileExists(atPath: staged.path), "the file downloaded for it goes")
        XCTAssertEqual(m.screen, .empty, "nothing started")
        XCTAssertNil(m.lastImportURL)

        m.toast = nil
        m.open(own)
        XCTAssertEqual(m.toast?.text, "Still splitting another song.")
        XCTAssertTrue(fm.fileExists(atPath: own.path), "a person's own file is never touched")

        m.toast = nil
        XCTAssertTrue(m.openText("https://youtu.be/dQw4w9WgXcQ"), "a link: handled, by saying so")
        XCTAssertEqual(m.toast?.text, "Still splitting another song.")
        XCTAssertFalse(m.downloadingFromYouTube)
        XCTAssertNil(m.lastYouTube)

        m.toast = nil
        m.addSong()
        XCTAssertFalse(m.addSongSheet, "the + and the Add a song sheet")
        XCTAssertEqual(m.toast?.text, "Still splitting another song.")

        XCTAssertTrue(m.refuseAnotherImport(take))
        XCTAssertTrue(fm.fileExists(atPath: take.path), "a recording is never thrown away")

        // While the Record sheet is open nothing else starts, so its take always can.
        m.splitRunning = nil
        m.recordSheet = true
        m.toast = nil
        XCTAssertTrue(m.openText("https://youtu.be/dQw4w9WgXcQ"))
        XCTAssertEqual(m.toast?.text, "Finish recording first.")
        m.recordSheet = false
        XCTAssertFalse(m.refuseAnotherImport(), "nothing under way: a song may start")
    }

    /// ios-import#3: the app's own hand-over of a link's downloaded file to the split is not another song. It goes
    /// on where a person's file at the same moment would be refused, and the passes stay paused across it.
    func testALinksDownloadedFileIsHandedOnNotRefused() async throws {
        let m = AppModel()
        Self.keepAlive.append(m)
        await m.libraryReady()
        let fm = FileManager.default
        try fm.createDirectory(at: ImportStaging.downloadsDirectory, withIntermediateDirectories: true)
        let file = ImportStaging.downloadsDirectory.appendingPathComponent("handover-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        do {
            let out = try AVAudioFile(forWriting: file, settings: format.settings)
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
            buf.frameLength = 44_100
            try out.write(from: buf)
        }
        addTeardownBlock { try? fm.removeItem(at: file) }
        defer { m.cancelImport(); SeparationService.shared.release() }

        m.downloadingFromYouTube = true                       // the link's download is under way
        XCTAssertTrue(m.refuseAnotherImport(), "a person's song now is refused")
        m.toast = nil
        // The download task's end, as `openFileLink` does it: in one turn.
        m.downloadingFromYouTube = false
        m.continueImport(file)
        XCTAssertNil(m.toast, "not refused")
        XCTAssertTrue(m.importUnderWay, "the same import goes on: the file is being fingerprinted")
        XCTAssertTrue(m.refuseAnotherImport(), "and another song is still refused")
        // Cancelled in this same turn, before the fingerprint: no split runs in a unit test.
        m.cancelImport()
        XCTAssertFalse(m.importUnderWay)
    }

    /// ios-import#5: the import waits for the passes it paused to stop before it measures memory, and a cancel ends
    /// the wait.
    func testTheImportWaitsForThePausedPassesToStop() async throws {
        let m = AppModel()
        Self.keepAlive.append(m)
        m.hqJob = Task {}
        defer { m.hqJob = nil }
        let started = ContinuousClock.now
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            m.hqJob = nil
        }
        await m.waitForPassesToStop(stop: { false })
        XCTAssertFalse(m.passesRunning)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(350), "it waited for the pass")

        m.leadJob = Task {}
        defer { m.leadJob = nil }
        let cancelled = ContinuousClock.now
        await m.waitForPassesToStop(stop: { true })
        XCTAssertLessThan(ContinuousClock.now - cancelled, .milliseconds(300), "a cancel doesn't wait")
    }

    func testALibrarySongWaitingForItsRefinementIsTheNextOneRefined() async throws {
        let m = AppModel()
        Self.keepAlive.append(m)
        await m.libraryReady()
        try XCTSkipIf(LeadSeparator.bundledModel() == nil, "no lead model in this build")
        var open = try Self.record("refine-open"), waiting = try Self.record("refine-waiting"), done = try Self.record("refine-done")
        open.guitarSplit = Self.split(LeadRefineJob.stereoMethod)
        waiting.guitarSplit = Self.split(LeadRefineJob.stereoMethod)
        done.guitarSplit = Self.split(LeadRefineJob.refinedMethod)
        m.library = [open, done, waiting]
        m.song = open
        defer { m.song = nil; m.library = []; m.libraryLeadFailed = [] }
        XCTAssertEqual(m.nextLibraryLeadRefine()?.id, "refine-waiting", "not the open song, not a refined one")
        XCTAssertTrue(m.openSongHasWork, "the open song's own refinement goes first")
        m.libraryLeadFailed = ["refine-waiting"]
        XCTAssertNil(m.nextLibraryLeadRefine(), "not started again by itself after it failed")
    }

    // MARK: helpers

    private func export(_ m: AppModel) async -> (left: [Float], right: [Float]) {
        await m.engineGate.acquire()
        defer { Task { await m.engineGate.release() } }
        let settings = PlaybackEngine.ExportSettings(gains: m.exportGains(), rate: 1, semitones: 0)
        var l: [Float] = [], r: [Float] = []
        m.engine.export(settings) { lp, rp, n in
            l.append(contentsOf: UnsafeBufferPointer(start: lp, count: n))
            r.append(contentsOf: UnsafeBufferPointer(start: rp, count: n))
            return true
        }
        return (l, r)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out")
    }

    nonisolated static func levelDifference(_ a: StereoAudio, _ b: StereoAudio) -> Float {
        var ea: Float = 0, eb: Float = 0, fa: Float = 0, fb: Float = 0
        vDSP_svesq(a.left, 1, &ea, vDSP_Length(a.frameCount)); vDSP_svesq(a.right, 1, &fa, vDSP_Length(a.frameCount))
        vDSP_svesq(b.left, 1, &eb, vDSP_Length(b.frameCount)); vDSP_svesq(b.right, 1, &fb, vDSP_Length(b.frameCount))
        return 10 * log10((ea + fa) / max(eb + fb, 1e-20))
    }

    nonisolated static func snr(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        var d = [Float](repeating: 0, count: n)
        vDSP_vsub(a, 1, b, 1, &d, 1, vDSP_Length(n))
        var s: Float = 0, e: Float = 0
        vDSP_svesq(b, 1, &s, vDSP_Length(n)); vDSP_svesq(d, 1, &e, vDSP_Length(n))
        return 10 * log10(s / max(e, 1e-20))
    }
}

/// Lets the first `allow` swaps through.
nonisolated final class SwapCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var left: Int
    init(allow: Int) { left = allow }
    func take() -> Bool { lock.withLock { defer { left -= 1 }; return left > 0 } }
}
