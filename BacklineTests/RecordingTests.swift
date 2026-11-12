import AVFoundation
import BacklineKit
import CoreMedia
import XCTest
@testable import Backline

/// Pure logic behind Record from a microphone: level maths, the take heuristics, and the streaming writer /
/// trimmer driven with synthetic audio (including 16-bit 48 kHz `CMSampleBuffer`s).
///
/// Ported from backline-ios `BacklineTests/RecordingTests.swift`. Left out: the broadcast status file, the
/// Darwin notification and the share extension's links (iOS only: the Mac records another app with a
/// process tap and has no share extension).
final class RecordingTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("RecordingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: Level maths

    func testDecibelConversion() {
        XCTAssertEqual(AudioLevel.db(fromLinear: 1), 0, accuracy: 1e-4)
        XCTAssertEqual(AudioLevel.db(fromLinear: 0.5), -6.0206, accuracy: 1e-3)
        XCTAssertEqual(AudioLevel.db(fromLinear: 0), AudioLevel.floorDB)
        XCTAssertEqual(AudioLevel.db(fromLinear: 1e-9), AudioLevel.floorDB)
        XCTAssertEqual(AudioLevel.linear(fromDB: -20), 0.1, accuracy: 1e-5)
    }

    func testPeakAndRMSOfSine() {
        let n = 44_100
        let samples = (0..<n).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / 44_100)) }
        let (peak, rms) = samples.withUnsafeBufferPointer { AudioLevel.peakAndRMS($0.baseAddress!, count: n) }
        XCTAssertEqual(peak, 0.5, accuracy: 1e-3)
        XCTAssertEqual(rms, Float(0.5 / 2.0.squareRoot()), accuracy: 1e-3)
        XCTAssertEqual(AudioLevel.peakAndRMS(channels: [], frames: 10).peak, 0)
    }

    func testMeterFractionIsLinearInDecibels() {
        XCTAssertEqual(AudioLevel.meterFraction(db: 0), 1, accuracy: 1e-6)
        XCTAssertEqual(AudioLevel.meterFraction(db: -60), 0, accuracy: 1e-6)
        XCTAssertEqual(AudioLevel.meterFraction(db: -30), 0.5, accuracy: 1e-6)
        XCTAssertEqual(AudioLevel.meterFraction(db: -120), 0)
        XCTAssertEqual(AudioLevel.meterFraction(db: 6), 1)
        XCTAssertEqual(AudioLevel.meterFraction(db: .nan), 0)
    }

    func testMeterBallisticsRiseFastFallSlowAndHold() {
        var m = MeterBallistics()
        var t = 1.0
        // 100 ms toward full scale: almost there.
        for _ in 0..<6 { t += 1 / 60; m.advance(toward: 1, dt: 1 / 60, now: t) }
        XCTAssertGreaterThan(m.value, 0.9)
        XCTAssertEqual(m.hold, m.value, accuracy: 1e-6)
        // 100 ms of silence: still clearly above half (slow release), and the hold marker has not moved.
        let held = m.hold
        for _ in 0..<6 { t += 1 / 60; m.advance(toward: 0, dt: 1 / 60, now: t) }
        XCTAssertGreaterThan(m.value, 0.5)
        XCTAssertEqual(m.hold, held, accuracy: 1e-6)
        // After the hold time the marker falls and the meter reaches the floor.
        for _ in 0..<600 { t += 1 / 60; m.advance(toward: 0, dt: 1 / 60, now: t) }
        XCTAssertLessThan(m.value, 0.01)
        XCTAssertLessThan(m.hold, 0.05)
    }

    func testLevelHistoryKeepsNewestLastAndClamps() {
        var h = LevelHistory(capacity: 3)
        h.append(0.2); h.append(0.4); h.append(2); h.append(-1)
        XCTAssertEqual(h.values, [0.4, 1, 0])
        h.clear()
        XCTAssertEqual(h.values, [0, 0, 0])
    }

    // MARK: Heuristics

    private func stats(seconds: Double, first: Double? = nil, last: Double? = nil, loudest: Float = -20,
                       everNonZero: Bool = true, buffers: Int = 10) -> RecordingStats {
        var s = RecordingStats()
        s.framesWritten = Int(seconds * 44_100)
        s.firstSoundFrame = first.map { Int($0 * 44_100) }
        s.lastSoundFrame = last.map { Int($0 * 44_100) }
        s.loudestPeakDB = loudest
        s.everNonZero = everNonZero
        s.buffersReceived = buffers
        return s
    }

    func testQualityStates() {
        XCTAssertEqual(RecordingHeuristics.quality(stats(seconds: 3)), .waitingForSound)
        XCTAssertEqual(RecordingHeuristics.quality(stats(seconds: 9, loudest: -70)), .tooQuiet)
        XCTAssertEqual(RecordingHeuristics.quality(stats(seconds: 6, everNonZero: false)), .silent)
        // A broadcast that has delivered nothing at all is just waiting for the user to press play.
        XCTAssertEqual(RecordingHeuristics.quality(stats(seconds: 30, everNonZero: false, buffers: 0)), .waitingForSound)
        XCTAssertEqual(RecordingHeuristics.quality(stats(seconds: 20, first: 2, last: 19, loudest: -10)), .good)
        XCTAssertEqual(RecordingHeuristics.quality(stats(seconds: 20, first: 2, last: 19, loudest: -30)), .faint)
        XCTAssertEqual(RecordingHeuristics.quality(stats(seconds: 5, first: 1, last: 4, loudest: -30)), .good)
    }

    func testTrimRange() throws {
        let range = try XCTUnwrap(RecordingHeuristics.trimRange(stats(seconds: 60, first: 10, last: 50)))
        XCTAssertEqual(range.lowerBound, 10 - RecordingHeuristics.leadSeconds, accuracy: 1e-3)
        XCTAssertEqual(range.upperBound, 50 + RecordingHeuristics.tailSeconds, accuracy: 1e-3)
        // Never past the end of the file or before its start.
        let edge = try XCTUnwrap(RecordingHeuristics.trimRange(stats(seconds: 20, first: 0.1, last: 19.9)))
        XCTAssertEqual(edge.lowerBound, 0, accuracy: 1e-6)
        XCTAssertEqual(edge.upperBound, 20, accuracy: 1e-3)
        // Too short, or nothing heard: no take.
        XCTAssertNil(RecordingHeuristics.trimRange(stats(seconds: 30, first: 10, last: 13)))
        XCTAssertNil(RecordingHeuristics.trimRange(stats(seconds: 30)))
    }

    // MARK: Writer, trimmer (synthetic audio)

    /// A float buffer, non-interleaved: `seconds` of a sine (or silence when `amplitude` is 0).
    private func floatBuffer(rate: Double, channels: Int, seconds: Double, amplitude: Float, frequency: Double = 440) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: AVAudioChannelCount(channels), interleaved: false)!
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<channels {
            let p = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) { p[i] = amplitude * Float(sin(2 * Double.pi * frequency * Double(i) / rate)) }
        }
        return buffer
    }

    /// Writes silence / tone / silence in 100 ms pieces, the way an audio callback would.
    private func writeTake(to url: URL, rate: Double = 48_000, channels: Int = 1, silenceIn: Double, tone: Double, silenceOut: Double) throws -> RecordingStats {
        let writer = try PCMStreamWriter(url: url, soundThresholdDB: RecordingHeuristics.micSoundThresholdDB)
        for (seconds, amp) in [(silenceIn, Float(0)), (tone, Float(0.4)), (silenceOut, Float(0))] {
            var left = seconds
            while left > 1e-6 {
                let piece = min(0.1, left)
                try writer.append(floatBuffer(rate: rate, channels: channels, seconds: piece, amplitude: amp))
                left -= piece
            }
        }
        return writer.finish()
    }

    func testWriterConvertsMonoHardwareAudioToStereo44k() throws {
        let url = tmp.appendingPathComponent("mono48.caf")
        let stats = try writeTake(to: url, rate: 48_000, channels: 1, silenceIn: 2, tone: 3, silenceOut: 1)
        XCTAssertEqual(stats.seconds, 6, accuracy: 0.1)
        XCTAssertEqual(stats.firstSoundAt ?? -1, 2, accuracy: 0.15)
        XCTAssertEqual(stats.lastSoundAt ?? -1, 5, accuracy: 0.15)
        XCTAssertEqual(stats.loudestPeakDB, AudioLevel.db(fromLinear: 0.4), accuracy: 0.6)
        XCTAssertTrue(stats.everNonZero)

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 44_100)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
        XCTAssertEqual(file.length, Int64(stats.framesWritten))
        // Mono became dual mono: both channels carry the tone.
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44_100)!
        file.framePosition = Int64(3 * 44_100)
        try file.read(into: buffer, frameCount: 44_100)
        let l = AudioLevel.peakAndRMS(UnsafePointer(buffer.floatChannelData![0]), count: Int(buffer.frameLength))
        let r = AudioLevel.peakAndRMS(UnsafePointer(buffer.floatChannelData![1]), count: Int(buffer.frameLength))
        XCTAssertEqual(l.peak, 0.4, accuracy: 0.02)
        XCTAssertEqual(r.peak, 0.4, accuracy: 0.02)
    }

    func testWriterTakesFourChannelInterfaceAndUsesTheFirstTwo() throws {
        // A USB interface with four inputs at 48 kHz: channel 1 carries the tone, channel 2 silence.
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Quadraphonic)!
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for ch in 0..<4 {
            for i in 0..<48_000 { buffer.floatChannelData![ch][i] = ch == 0 ? 0.3 * Float(sin(2 * Double.pi * 440 * Double(i) / 48_000)) : 0 }
        }
        let url = tmp.appendingPathComponent("four.caf")
        let writer = try PCMStreamWriter(url: url, soundThresholdDB: -50)
        try writer.append(buffer)
        let stats = writer.finish()
        XCTAssertEqual(stats.seconds, 1, accuracy: 0.02, "the converter's held-back tail is flushed when the file closes")
        XCTAssertEqual(stats.loudestPeakDB, AudioLevel.db(fromLinear: 0.3), accuracy: 0.6)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
        XCTAssertEqual(file.length, Int64(stats.framesWritten))
    }

    func testWriterAcceptsAlready44kStereoWithoutConversion() throws {
        let url = tmp.appendingPathComponent("stereo44.caf")
        let writer = try PCMStreamWriter(url: url, soundThresholdDB: -50)
        try writer.append(floatBuffer(rate: 44_100, channels: 2, seconds: 1, amplitude: 0.25))
        let stats = writer.finish()
        XCTAssertEqual(stats.framesWritten, 44_100)
        XCTAssertEqual(stats.peakDB, AudioLevel.db(fromLinear: 0.25), accuracy: 0.1)
        XCTAssertThrowsError(try writer.append(floatBuffer(rate: 44_100, channels: 2, seconds: 0.1, amplitude: 0.1)), "closed writers refuse audio")
    }

    func testSnapshotPeakHoldResetsOnRead() throws {
        let writer = try PCMStreamWriter(url: tmp.appendingPathComponent("peak.caf"), soundThresholdDB: -50)
        try writer.append(floatBuffer(rate: 44_100, channels: 2, seconds: 0.1, amplitude: 0.5))
        XCTAssertEqual(writer.snapshot(resetPeak: true).peakDB, -6, accuracy: 0.2)
        try writer.append(floatBuffer(rate: 44_100, channels: 2, seconds: 0.1, amplitude: 0.05))
        XCTAssertEqual(writer.snapshot(resetPeak: true).peakDB, -26, accuracy: 0.3, "the loud block must not leak into the next read")
        writer.finish()
    }

    /// A ReplayKit-style sample buffer: 16-bit interleaved stereo.
    private func sampleBuffer(rate: Double, seconds: Double, amplitude: Double, frequency: Double = 440) throws -> CMSampleBuffer {
        let frames = Int(rate * seconds)
        var pcm = [Int16](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let v = Int16(amplitude * 32_767 * sin(2 * Double.pi * frequency * Double(i) / rate))
            pcm[2 * i] = v
            pcm[2 * i + 1] = v
        }
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                                      magicCookie: nil, extensions: nil, formatDescriptionOut: &format), noErr)
        let bytes = pcm.count * MemoryLayout<Int16>.size
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                          customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                          flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block), noErr)
        _ = pcm.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes) }
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: format!,
                                                                            sampleCount: frames, presentationTimeStamp: .zero,
                                                                            packetDescriptions: nil, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    func testWriterTakesReplayKitStyleSampleBuffers() throws {
        let url = tmp.appendingPathComponent("broadcast.caf")
        let writer = try PCMStreamWriter(url: url, soundThresholdDB: RecordingHeuristics.appSoundThresholdDB)
        // 1 s of silence, 2 s of tone, in 21 ms buffers like the real thing (1024 frames at 48 kHz).
        for (seconds, amp) in [(1.0, 0.0), (2.0, 0.5)] {
            var t = 0.0
            while t < seconds - 1e-9 {
                try writer.append(sampleBuffer: sampleBuffer(rate: 48_000, seconds: 1024.0 / 48_000, amplitude: amp))
                t += 1024.0 / 48_000
            }
        }
        let stats = writer.finish()
        XCTAssertEqual(stats.seconds, 3, accuracy: 0.1)
        XCTAssertEqual(stats.firstSoundAt ?? -1, 1, accuracy: 0.1)
        XCTAssertEqual(stats.lastSoundAt ?? -1, 3, accuracy: 0.1)
        XCTAssertEqual(stats.loudestPeakDB, -6, accuracy: 0.5)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 44_100)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
        XCTAssertEqual(Double(file.length) / 44_100, 3, accuracy: 0.1)
    }

    func testTrimCutsSilenceAroundTheSong() throws {
        let url = tmp.appendingPathComponent("take.caf")
        let stats = try writeTake(to: url, silenceIn: 3, tone: 8, silenceOut: 3)
        let range = try XCTUnwrap(RecordingHeuristics.trimRange(stats))
        let trimmed = try RecordingTrimmer.trimSync(url, to: range)
        XCTAssertEqual(trimmed, url, "the take keeps its name")
        XCTAssertEqual((try FileManager.default.contentsOfDirectory(atPath: tmp.path)).filter { $0.hasSuffix(".caf") }, ["take.caf"],
                       "no temporary copy is left behind")
        let file = try AVAudioFile(forReading: trimmed)
        let expected = 8 + RecordingHeuristics.leadSeconds + RecordingHeuristics.tailSeconds
        XCTAssertEqual(Double(file.length) / file.fileFormat.sampleRate, expected, accuracy: 0.3)
        XCTAssertEqual(file.fileFormat.sampleRate, 44_100)
        // The kept audio starts a moment before the tone.
        let hit = try XCTUnwrap(try RecordingTrimmer.scan(trimmed, thresholdDB: -42))
        XCTAssertEqual(hit.first, RecordingHeuristics.leadSeconds, accuracy: 0.2)
    }

    func testTrimOfWholeFileLeavesItAlone() throws {
        let url = tmp.appendingPathComponent("whole.caf")
        let stats = try writeTake(to: url, silenceIn: 0, tone: 6, silenceOut: 0)
        let same = try RecordingTrimmer.trimSync(url, to: 0...stats.seconds + 5)
        XCTAssertEqual(same, url)
        XCTAssertThrowsError(try RecordingTrimmer.trimSync(url, to: 100...200))
    }

    func testScanFindsFirstAndLastSound() throws {
        let url = tmp.appendingPathComponent("scan.caf")
        _ = try writeTake(to: url, silenceIn: 4, tone: 6, silenceOut: 2)
        let hit = try XCTUnwrap(try RecordingTrimmer.scan(url, thresholdDB: -42))
        XCTAssertEqual(hit.first, 4, accuracy: 0.15)
        XCTAssertEqual(hit.last, 10, accuracy: 0.15)
        XCTAssertEqual(hit.duration, 12, accuracy: 0.1)

        let silent = tmp.appendingPathComponent("silent.caf")
        _ = try writeTake(to: silent, silenceIn: 3, tone: 0, silenceOut: 0)
        XCTAssertNil(try RecordingTrimmer.scan(silent, thresholdDB: -42))
    }

    func testPurgeStaleRemovesOnlyOldFilesNotListedAsKept() throws {
        let old = tmp.appendingPathComponent("old.caf"), keep = tmp.appendingPathComponent("keep.caf"), fresh = tmp.appendingPathComponent("fresh.caf")
        for u in [old, keep, fresh] { try Data([1]).write(to: u) }
        let past = Date().addingTimeInterval(-3 * 24 * 3600)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: keep.path)
        RecordingTrimmer.purgeStale(in: tmp, keeping: ["keep.caf"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testNewRecordingNamesAreReadableAndUnique() throws {
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        let url = RecordingTrimmer.newRecordingURL(date: date)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("Recording 20"), url.lastPathComponent)
        XCTAssertEqual(url.pathExtension, "caf")
        XCTAssertTrue(ImportStaging.isOwned(url))
        try FileManager.default.createDirectory(at: ImportStaging.recordingsDirectory, withIntermediateDirectories: true)
        try Data([1]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNotEqual(RecordingTrimmer.newRecordingURL(date: date), url, "a second take in the same second gets its own name")
    }

    private static let backupExclusion = "com.apple.metadata:com_apple_backup_excludeItem"

    /// D5 on the Mac is models only: a take is in Time Machine, and a folder an earlier build kept out goes back in.
    func testRecordingsFolderIsBackedUpOnTheMac() throws {
        let dir = tmp.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var marked = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try marked.setResourceValues(values)
        XCTAssertGreaterThan(getxattr(dir.path, Self.backupExclusion, nil, 0, 0, 0), 0, "marked as an earlier build did")
        try RecordingTrimmer.prepareRecordingsDirectory(dir)
        // The flag on disk (Time Machine reads this attribute), not a cached resource value.
        XCTAssertEqual(getxattr(dir.path, Self.backupExclusion, nil, 0, 0, 0), -1, "the folder is backed up")
    }

    func testAdoptMovesAFileIntoTheAppsRecordingsFolder() throws {
        let src = tmp.appendingPathComponent("from-group.caf")
        try Data([1, 2, 3]).write(to: src)
        let dest = try RecordingTrimmer.adopt(src)
        defer { try? FileManager.default.removeItem(at: dest) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertTrue(ImportStaging.isOwned(dest), "the import pipeline must treat it as ours and delete it after the split")
        XCTAssertEqual(try Data(contentsOf: dest), Data([1, 2, 3]))
    }

    // MARK: Mac inputs

    /// Reading the inputs needs no permission; every one listed can record, once, with the Mac's own input first.
    func testInputListHasOnlyRealInputsWithTheMacsOwnFirst() {
        let list = AudioInputs.list()
        XCTAssertEqual(Set(list.map(\.id)).count, list.count)
        for input in list {
            XCTAssertGreaterThan(input.channels, 0, input.name)
            XCTAssertFalse(input.uid.isEmpty, input.name)
            XCTAssertNotEqual(input.name, "Backline Capture", "Record from an app's private device is never offered")
        }
        if let id = AudioInputs.systemDefaultID, list.contains(where: { $0.id == id }) {
            XCTAssertEqual(list.first?.id, id)
        }
    }

    @MainActor
    func testANewMicRecorderIsIdleAndNamesTakesLikeIOS() {
        let mic = MicRecorder()
        XCTAssertEqual(mic.phase, .idle)
        XCTAssertFalse(mic.isBusy)
        XCTAssertNil(mic.selectedInputID, "it follows the Mac's own input until one is picked")
        XCTAssertTrue(MicRecorder.title(Date(timeIntervalSince1970: 1_760_000_000)).hasPrefix("Recording – "))
        XCTAssertEqual(MicRecorder.privacyURL.scheme, "x-apple.systempreferences")
        XCTAssertTrue(MicRecorder.privacyURL.absoluteString.hasSuffix("Privacy_Microphone"))
    }
}
