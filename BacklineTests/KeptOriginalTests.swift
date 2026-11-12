import AVFoundation
import Accelerate
import BacklineKit
import XCTest
@testable import Backline

/// D18: the kept original is the file the song came from when that file is lossy audio. The gate: decoding the
/// kept source gives, sample for sample, the audio the import split, and the cleaner pass makes the same parts
/// from it as from `original.caf`.
final class KeptOriginalTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    /// 20 s of "Summon the Rawk" by Kevin MacLeod (incompetech.com, CC BY), the Mac's test fixture.
    static let mp3 = root.appendingPathComponent("BacklineTests/Fixtures/SummonTheRawk-20s.mp3")

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("KeptOriginalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// The MP3 fixture as AAC in an `.m4a` (the form downloads and the Music library come in). At 48 kHz the
    /// same samples are labelled 48 kHz, so the import has to resample them.
    private func aacFixture(in dir: URL, sampleRate: Double = 44_100) throws -> URL {
        let audio = try AudioDecoder.decode(Self.mp3)
        let url = dir.appendingPathComponent(sampleRate == 44_100 ? "song.m4a" : "song-\(Int(sampleRate)).m4a")
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(audio.frameCount))!
        buf.frameLength = buf.frameCapacity
        audio.left.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: audio.frameCount) }
        audio.right.withUnsafeBufferPointer { buf.floatChannelData![1].update(from: $0.baseAddress!, count: audio.frameCount) }
        try file.write(from: buf)
        return url
    }

    private func wavFixture(in dir: URL) throws -> URL {
        let audio = try AudioDecoder.decode(Self.mp3)
        let url = dir.appendingPathComponent("song.wav")
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(audio.frameCount))!
        buf.frameLength = buf.frameCapacity
        audio.left.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: audio.frameCount) }
        audio.right.withUnsafeBufferPointer { buf.floatChannelData![1].update(from: $0.baseAddress!, count: audio.frameCount) }
        try file.write(from: buf)
        return url
    }

    /// A short video (a few frames of H.264) carrying `audio`'s AAC track unchanged.
    private func videoFixture(with audioURL: URL, in dir: URL, type: AVFileType, ext: String) async throws -> URL {
        let url = dir.appendingPathComponent("clip.\(ext)")
        let source = AVURLAsset(url: audioURL)
        let track = try await source.loadTracks(withMediaType: .audio)[0]
        let hint = try await track.load(.formatDescriptions).first
        let duration = try await source.load(.duration)
        let reader = try AVAssetReader(asset: source)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(out)
        let writer = try AVAssetWriter(outputURL: url, fileType: type)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 120,
        ])
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 120,
        ])
        let sound = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
        writer.add(video)
        writer.add(sound)
        XCTAssertTrue(reader.startReading())
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        // The two inputs are interleaved: a writer stops taking video that runs ahead of the sound.
        let frames = Int(duration.seconds.rounded(.up))
        var frame = 0, videoDone = false, soundDone = false
        while !videoDone || !soundDone {
            var moved = false
            if !videoDone, video.isReadyForMoreMediaData {
                if frame < frames {
                    var pb: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(pixels.pixelBufferPool), &pb)
                    pixels.append(try XCTUnwrap(pb), withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 1))
                    frame += 1
                } else {
                    video.markAsFinished()
                    videoDone = true
                }
                moved = true
            }
            if !soundDone, sound.isReadyForMoreMediaData {
                if let b = out.copyNextSampleBuffer() { sound.append(b) } else { sound.markAsFinished(); soundDone = true }
                moved = true
            }
            if !moved { try await Task.sleep(for: .milliseconds(2)) }
        }
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(writer.error as Any)")
        return url
    }

    // MARK: What is kept

    func testLossySourcesAreKeptAndLosslessOnesAreNot() async throws {
        let dir = try tempDir()
        let mp3Plan = await KeptOriginal.plan(for: Self.mp3)
        XCTAssertEqual(mp3Plan, .keepFile(ext: "mp3"))
        let aacPlan = await KeptOriginal.plan(for: try aacFixture(in: dir))
        XCTAssertEqual(aacPlan, .keepFile(ext: "m4a"))
        let wavPlan = await KeptOriginal.plan(for: try wavFixture(in: dir))
        XCTAssertEqual(wavPlan, .writeLossless, "uncompressed audio keeps the lossless original.caf")
        // A recording is written as uncompressed CAF.
        let rec = dir.appendingPathComponent("take.caf")
        try FileManager.default.copyItem(at: try wavFixture(in: dir), to: rec)
        let recPlan = await KeptOriginal.plan(for: rec)
        XCTAssertEqual(recPlan, .writeLossless)
        // Named for what it isn't: the codec decides, not the extension.
        let fake = dir.appendingPathComponent("named.mp3")
        try FileManager.default.copyItem(at: try wavFixture(in: dir), to: fake)
        let fakePlan = await KeptOriginal.plan(for: fake)
        XCTAssertEqual(fakePlan, .writeLossless)
    }

    // MARK: The gate: the kept source decodes to the audio the import split

    /// The whole import on a lossy file: the folder has `source.<ext>` (the file's own bytes) and no
    /// original.caf, and decoding the kept source gives the very samples `ImportPipeline.run` decoded.
    private func importKeepsSource(_ source: URL, ext: String) async throws {
        let dir = try tempDir()
        let store = SongStore(root: dir.appendingPathComponent("Songs", isDirectory: true))
        let (rec, _) = try await ImportPipeline.run(url: source, id: "kept", store: store, progress: { _ in }, isCancelled: { false })
        XCTAssertEqual(rec.originalFile, "source.\(ext)")
        XCTAssertNil(rec.originalScale)
        XCTAssertTrue(rec.hasOriginal)
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: store.originalURL("kept").path), "no original.caf beside a kept source")
        let kept = try XCTUnwrap(store.originalURL(rec))
        XCTAssertEqual(kept.lastPathComponent, "source.\(ext)")
        XCTAssertEqual(try Data(contentsOf: kept), try Data(contentsOf: source), "the file itself, unchanged")
        XCTAssertTrue(fm.fileExists(atPath: source.path), "a file the app doesn't own is copied, never moved")

        let split = try AudioDecoder.decode(source)     // what ImportPipeline.run decoded and split
        let back = try store.readOriginal(rec)
        XCTAssertEqual(back.frameCount, split.frameCount, "same length")
        XCTAssertEqual(back.sampleRate, split.sampleRate)
        XCTAssertTrue(back.left == split.left && back.right == split.right, "same samples")
        XCTAssertEqual(rec.duration, split.duration)

        // Reopened from disk it is still there.
        let loaded = try XCTUnwrap(store.loadAll().first { $0.id == "kept" })
        XCTAssertEqual(loaded.originalFile, "source.\(ext)")

        // The folder's size, and what it was with original.caf (written here the way 1.0 wrote it).
        func size(_ url: URL) -> Int { (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0 }
        let files = try fm.contentsOfDirectory(at: store.folder("kept"), includingPropertiesForKeys: nil)
        let total = files.map(size).reduce(0, +)
        let caf = dir.appendingPathComponent("original.caf")
        _ = try ImportPipeline.writeScaled(split, to: caf, store: store)
        print("[kept-original] \(ext): folder \(total) bytes with source.\(ext) (\(size(kept)) bytes); "
              + "with original.caf it was \(total - size(kept) + size(caf)) bytes (original.caf \(size(caf)) bytes)")
        XCTAssertLessThan(size(kept), size(caf), "the kept source is smaller than original.caf")
    }

    func testAnMP3ImportKeepsTheMP3AndItDecodesToTheSplitAudio() async throws {
        try await importKeepsSource(Self.mp3, ext: "mp3")
    }

    func testAnAACImportKeepsTheM4AAndItDecodesToTheSplitAudio() async throws {
        try await importKeepsSource(try aacFixture(in: try tempDir()), ext: "m4a")
    }

    /// A 48 kHz source is resampled by the import; the kept file, decoded again (as the cleaner pass does through
    /// readOriginal), goes through the same resampler and gives the same samples.
    func testA48kHzAACImportKeepsTheM4AAndItDecodesToTheSplitAudio() async throws {
        let source = try aacFixture(in: try tempDir(), sampleRate: 48_000)
        let rate = try AVAudioFile(forReading: source).fileFormat.sampleRate
        XCTAssertEqual(rate, 48_000, "the fixture really is 48 kHz")
        try await importKeepsSource(source, ext: "m4a")
    }

    /// A file the app owns (a download or a recording; the Mac opens a picked file in place) is hard-linked: no second copy on disk, and the staged
    /// name can still be discarded after the import as before.
    func testAnOwnedStagedFileIsLinkedNotCopied() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: ImportStaging.downloadsDirectory, withIntermediateDirectories: true)
        let staged = ImportStaging.downloadsDirectory.appendingPathComponent(UUID().uuidString + "-song.mp3")
        try fm.copyItem(at: Self.mp3, to: staged)
        addTeardownBlock { try? FileManager.default.removeItem(at: staged) }
        let folder = try tempDir().appendingPathComponent("song", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let decoded = try AudioDecoder.decode(staged)
        let name = await KeptOriginal.keep(staged, plan: .keepFile(ext: "mp3"), decoded: decoded, in: folder)
        XCTAssertEqual(name, "source.mp3")
        let kept = folder.appendingPathComponent("source.mp3")
        let ino = { (u: URL) in (try? fm.attributesOfItem(atPath: u.path)[.systemFileNumber] as? Int) ?? -1 }
        // Same volume in the app's container: the same file, not a copy (a tmp folder elsewhere is copied).
        if (try? fm.attributesOfItem(atPath: folder.path)[.systemNumber] as? Int)
            == (try? fm.attributesOfItem(atPath: staged.path)[.systemNumber] as? Int) {
            XCTAssertEqual(ino(kept), ino(staged))
        }
        ImportStaging.discard(staged)
        XCTAssertFalse(fm.fileExists(atPath: staged.path))
        XCTAssertEqual(try Data(contentsOf: kept), try Data(contentsOf: Self.mp3), "the kept source outlives the staged name")
    }

    /// A video's sound is copied out unchanged into `source.m4a` when it decodes to the same samples as the
    /// video did; otherwise nothing is kept here and the import writes original.caf. Either way, a kept file
    /// never decodes to anything but the audio that was split.
    func testAVideoKeepsItsSoundOnlyWhenItDecodesTheSame() async throws {
        let dir = try tempDir()
        let aac = try aacFixture(in: dir)
        var kept = 0
        for (type, ext) in [(AVFileType.mp4, "mp4"), (.mov, "mov")] {
            let video = try await videoFixture(with: aac, in: dir, type: type, ext: ext)
            let plan = await KeptOriginal.plan(for: video)
            XCTAssertEqual(plan, .copyOutVideoSound, ext)
            let folder = dir.appendingPathComponent("song-\(ext)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let split = try AudioDecoder.decode(video)
            let name = await KeptOriginal.keep(video, plan: plan, decoded: split, in: folder)
            let m4a = folder.appendingPathComponent("source.m4a")
            if let name {
                kept += 1
                XCTAssertEqual(name, "source.m4a")
                XCTAssertTrue(KeptOriginal.same(try AudioDecoder.decode(m4a), split), ext)
                XCTAssertLessThan(try Data(contentsOf: m4a).count, try Data(contentsOf: video).count)
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: m4a.path), "nothing half-kept")
            }
            print("[kept-original] \(ext) video: \(name ?? "original.caf")")
        }
        // On macOS (26.2 SDK, this Mac, 12 Nov 2026) neither video's sound is kept: decoding the video gives 624
        // (MP4) and 2,736 (MOV) more frames than decoding its sound copied out unchanged, the MOV also starting
        // earlier (its priming isn't trimmed), so the copy would not be the audio that was split and the import
        // rightly writes original.caf. The iOS Simulator keeps the MP4's. Recorded as a known Mac difference.
        XCTExpectFailure("macOS decodes a video's AAC track to a different length than the same track in an .m4a",
                         strict: false)
        XCTAssertGreaterThan(kept, 0, "an MP4's AAC sound is copied out unchanged")
    }

    // MARK: Readers

    /// Only `source.<ext>` names are followed, and a kept source whose file is gone is forgotten on load.
    func testLoadForgetsAMissingOrUnsafeSourceName() throws {
        let dir = try tempDir()
        let store = SongStore(root: dir.appendingPathComponent("Songs", isDirectory: true))
        var rec = try Self.record(id: "a")
        rec.originalFile = "source.mp3"
        try store.save(rec)
        try FileManager.default.copyItem(at: Self.mp3, to: store.stemURL("a", .vocals))
        rec.id = "b"
        rec.originalFile = "../a/source.mp3"
        try store.save(rec)
        try FileManager.default.copyItem(at: Self.mp3, to: store.stemURL("b", .vocals))
        let loaded = Dictionary(uniqueKeysWithValues: store.loadAll().map { ($0.id, $0) })
        XCTAssertNil(loaded["a"]?.originalFile, "the file isn't there")
        XCTAssertNil(loaded["b"]?.originalFile, "not a name in the song's own folder")
        XCTAssertFalse(SongStore.isSourceName("source."))
        XCTAssertFalse(SongStore.isSourceName("original.caf"))
        XCTAssertTrue(SongStore.isSourceName("source.m4a"))
    }

    static func record(id: String) throws -> SongRecord {
        let data = try Data(contentsOf: root.appendingPathComponent("BacklineKit/Tests/Fixtures/v011_song.json"))
        var rec = try JSONDecoder().decode(SongRecord.self, from: data)
        rec.id = id
        rec.stems = [.vocals]
        rec.guitarSplit = nil
        rec.drumSplit = nil
        return rec
    }

    // MARK: The gate: the cleaner pass reads the kept source

    /// Six stand-in parts made the same way from whatever the cleaner pass reads (no model needed): a song
    /// with a kept source and the same song with original.caf must give the same parts, apart from the
    /// 16-bit rounding of original.caf.
    static let standIn: CleanerPartsJob.Separate = { audio, _, report, _ in
        report(1)
        let shares: [Float] = [0.3, 0.25, 0.15, 0.12, 0.1, 0.08]
        return shares.enumerated().map { i, g in
            var l = audio.left, r = audio.right
            var gl = g, gr = g * (i == 4 ? 0.4 : 1)       // the "guitar" leans left, so the stereo split has work
            vDSP_vsmul(l, 1, &gl, &l, 1, vDSP_Length(l.count))
            vDSP_vsmul(r, 1, &gr, &r, 1, vDSP_Length(r.count))
            return StereoAudio(left: l, right: r, sampleRate: audio.sampleRate)
        }
    }

    func testTheCleanerPassGivesTheSamePartsFromAKeptSourceAsFromOriginalCaf() async throws {
        let dir = try tempDir()
        let store = SongStore(root: dir.appendingPathComponent("Songs", isDirectory: true))
        let fm = FileManager.default
        let song = try AudioDecoder.decode(Self.mp3)

        // Song "src": the MP3 kept as its source. Song "caf": the same audio as original.caf.
        var src = try Self.record(id: "src")
        try fm.createDirectory(at: store.folder("src"), withIntermediateDirectories: true)
        try fm.copyItem(at: Self.mp3, to: store.folder("src").appendingPathComponent("source.mp3"))
        try store.writeStem(song, to: store.stemURL("src", .vocals))
        src.originalFile = "source.mp3"
        try store.save(src)
        var caf = try Self.record(id: "caf")
        try fm.createDirectory(at: store.folder("caf"), withIntermediateDirectories: true)
        try store.writeStem(song, to: store.stemURL("caf", .vocals))
        caf.originalScale = try ImportPipeline.writeScaled(song, to: store.originalURL("caf"), store: store).1
        try store.save(caf)

        // What the cleaner pass reads.
        let fromSource = try store.readOriginal(src)
        XCTAssertTrue(KeptOriginal.same(fromSource, song), "the kept source is the decoded song itself")
        let fromCaf = try store.readOriginal(caf)
        XCTAssertEqual(fromCaf.frameCount, song.frameCount)

        let model = dir.appendingPathComponent("Stand-in.mlmodelc")
        let a = try await CleanerPartsJob.run(rec: src, store: store, modelURL: model, separate: Self.standIn,
                                              progress: { _ in }, isCancelled: { false })
        let b = try await CleanerPartsJob.run(rec: caf, store: store, modelURL: model, separate: Self.standIn,
                                              progress: { _ in }, isCancelled: { false })
        XCTAssertEqual(a.separator, CleanerPartsJob.method)
        XCTAssertEqual(a.originalFile, "source.mp3", "the record still names its kept source")
        XCTAssertNil(a.originalScale)
        XCTAssertTrue(fm.fileExists(atPath: store.folder("src").appendingPathComponent("source.mp3").path),
                      "the kept source came along with the swap")
        XCTAssertFalse(fm.fileExists(atPath: store.originalURL("src").path))
        XCTAssertTrue(fm.fileExists(atPath: store.originalURL("caf").path))
        XCTAssertEqual(try store.readOriginal(a).left, song.left, "still the same song after the swap")

        XCTAssertEqual(a.stems, b.stems, "same parts")
        XCTAssertEqual(a.guitarSplit != nil, b.guitarSplit != nil, "same guitar split")
        var worst = -Float.infinity
        for k in a.stems {
            var pa = try store.readAudio(store.stemURL("src", k))
            var pb = try store.readAudio(store.stemURL("caf", k))
            XCTAssertEqual(pa.frameCount, pb.frameCount, k.rawValue)
            var ua = 1 / (a.storageScale[k.rawValue] ?? 1), ub = 1 / (b.storageScale[k.rawValue] ?? 1)
            vDSP_vsmul(pa.left, 1, &ua, &pa.left, 1, vDSP_Length(pa.frameCount))
            vDSP_vsmul(pb.left, 1, &ub, &pb.left, 1, vDSP_Length(pb.frameCount))
            var power: Float = 0, diff: Float = 0
            vDSP_svesq(pa.left, 1, &power, vDSP_Length(pa.frameCount))
            var d = pa.left
            vDSP_vsub(pb.left, 1, pa.left, 1, &d, 1, vDSP_Length(d.count))
            vDSP_svesq(d, 1, &diff, vDSP_Length(d.count))
            let db = 10 * log10(max(diff, 1e-20) / max(power, 1e-20))
            worst = max(worst, db)
            // 16-bit rounding of original.caf and of each part: far below the music.
            XCTAssertLessThan(db, -70, "\(k.rawValue): difference \(db) dB against the part")
        }
        print("[kept-original] cleaner parts, kept source against original.caf: worst difference \(worst) dB")
    }

    /// A completion handler called twice (as AVFoundation did inside `finishWriting` in a Simulator crash on
    /// 11 November) resumes the wait once, from any thread, instead of crashing.
    func testACompletionCalledTwiceResumesOnce() async {
        for _ in 0..<200 {
            await KeptOriginal.completion { done in
                DispatchQueue.global().async { done() }
                DispatchQueue.global().async { done() }
                done()
            }
        }
        // A completion that comes later, on another queue, still ends the wait.
        let start = Date()
        await KeptOriginal.completion { done in DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { done(); done() } }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.04)
    }
}
