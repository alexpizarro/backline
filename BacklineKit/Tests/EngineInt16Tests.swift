import AVFoundation
import CryptoKit
import XCTest
@testable import BacklineKit

/// D3 / storage F2: the engine holds 16-bit samples and converts in the mixer. The gate is that a song read
/// from disk sounds bit for bit as it did with the float engine.
///
/// Two halves make that proof:
/// 1. A part on disk is 16-bit Apple Lossless, and reading it as Float32 gives exactly `Int16 / 32768` for
///    every sample (`testALACFloatReadIsInt16Over32768`). So the float engine held exactly the values a 16-bit
///    engine holds, and the two can only differ in the mixer.
/// 2. The mixer: the digests below were taken from the float engine (`std::vector<float>` storage, before the
///    change) rendering quantised parts through every path that reads the stored song: plain play, the loop
///    splice, gain ramps, seeks under play, time-stretch and pitch with a pitch-locked part, a scrub hold, and
///    export at identity and stretched. The 16-bit engine must give the same bits.
final class EngineInt16Tests: XCTestCase {
    let sr = 44_100.0

    /// Five parts of quantised audio (k / 32768), the way a part read from disk arrives: sines, pseudo-noise,
    /// full-scale extremes and a silent part.
    func makeParts(seconds: Double = 6) -> [StereoAudio] {
        let n = Int(seconds * sr)
        var seed: UInt32 = 0x1234_5678
        func noise() -> Int32 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Int32(Int16(truncatingIfNeeded: seed >> 16))
        }
        func q(_ x: Double) -> Float {
            let k = max(-32768, min(32767, (x * 32768).rounded()))
            return Float(k) / 32768
        }
        var parts: [StereoAudio] = []
        for p in 0..<4 {
            var l = [Float](repeating: 0, count: n), r = [Float](repeating: 0, count: n)
            let f = 110.0 * Double(p + 1)
            for i in 0..<n {
                let t = Double(i) / sr
                let s = 0.35 * sin(2 * .pi * f * t) + 0.1 * sin(2 * .pi * f * 2.7 * t + Double(p))
                l[i] = q(s + Double(noise()) / 32768 * 0.05)
                r[i] = q(0.8 * s - Double(noise()) / 32768 * 0.05)
            }
            // Full scale, both ways, so the conversion's ends are covered.
            for i in stride(from: 1000 + p * 37, to: n, by: 9_973) { l[i] = -1; r[i] = Float(32767) / 32768 }
            parts.append(StereoAudio(left: l, right: r, sampleRate: sr))
        }
        parts.append(StereoAudio(left: [Float](repeating: 0, count: n), right: [Float](repeating: 0, count: n), sampleRate: sr))
        return parts
    }

    func digest(_ blocks: [[Float]]) -> String {
        var h = SHA256()
        for b in blocks { b.withUnsafeBytes { h.update(bufferPointer: $0) } }
        return h.finalize().prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    func render(_ e: PlaybackEngine, blocks: Int, size: Int = 512, into out: inout [[Float]]) {
        for _ in 0..<blocks {
            let r = e.renderForTesting(frames: size)
            out.append(r.left); out.append(r.right)
        }
    }

    func loaded(locked: [Bool] = [false, false, true, false, false]) -> PlaybackEngine {
        let e = PlaybackEngine(drivesOutput: false)
        e.load(stems: makeParts(), pitchLocked: locked)
        return e
    }

    /// Plain play with gain changes (ramps), a seek under play (crossfade), and a pause (fade-out).
    func testPlainPlayIsBitExact() {
        let e = loaded()
        e.setGain(stem: 0, 0.8); e.setGain(stem: 1, 1.6); e.setGain(stem: 3, 0.3)
        var out: [[Float]] = []
        e.play()
        render(e, blocks: 40, into: &out)
        e.setGain(stem: 1, 0); e.setGain(stem: 2, 2.0)
        render(e, blocks: 20, into: &out)
        e.seek(frame: 150_000)
        render(e, blocks: 20, into: &out)
        e.pause()
        render(e, blocks: 4, into: &out)
        XCTAssertEqual(digest(out), Self.golden["plain"])
    }

    /// The loop splice crossfade reads the stored song directly; several passes at identity.
    func testLoopSpliceIsBitExact() {
        let e = loaded()
        e.setLoop(enabled: true, start: 30_000, end: 52_050)
        e.seek(frame: 40_000)
        var out: [[Float]] = []
        e.play()
        render(e, blocks: 200, size: 441, into: &out)
        XCTAssertEqual(digest(out), Self.golden["loop"])
    }

    /// Time-stretch and pitch (one part pitch-locked), a rate change mid-way, a looped trainer and a scrub hold.
    func testStretchedPlayIsBitExact() {
        let e = loaded()
        e.setRate(0.8); e.setSemitones(2)
        var out: [[Float]] = []
        e.seek(frame: 20_000)
        e.play()
        render(e, blocks: 60, into: &out)
        e.setRate(1.3)
        render(e, blocks: 30, into: &out)
        e.setLoop(enabled: true, start: 100_000, end: 140_000)
        e.setTrainer(enabled: true, from: 0.7, step: 0.1, every: 1, to: 1.0)
        e.seek(frame: 100_000)
        render(e, blocks: 200, into: &out)
        e.setHold(true)
        e.seek(frame: 60_000)
        render(e, blocks: 4, into: &out)
        e.seek(frame: 70_000)
        e.setHold(false)
        render(e, blocks: 30, into: &out)
        XCTAssertEqual(digest(out), Self.golden["stretch"])
    }

    /// Export at identity (with gains, one part silent) and stretched over a range.
    func testExportIsBitExact() {
        let e = loaded()
        var out: [[Float]] = []
        e.export(.init(gains: [1, 0.5, 2, 0, 1], rate: 1, semitones: 0, start: 10_000, end: 200_000)) { l, r, n in
            out.append(Array(UnsafeBufferPointer(start: l, count: n))); out.append(Array(UnsafeBufferPointer(start: r, count: n)))
            return true
        }
        XCTAssertEqual(digest(out), Self.golden["export-identity"])
        out = []
        e.export(.init(gains: [1, 1, 0.7, 1.2, 1], rate: 0.85, semitones: -3, start: 44_100, end: 200_000)) { l, r, n in
            out.append(Array(UnsafeBufferPointer(start: l, count: n))); out.append(Array(UnsafeBufferPointer(start: r, count: n)))
            return true
        }
        XCTAssertEqual(digest(out), Self.golden["export-stretched"])
    }

    /// A part written the way `SongStore.writeStem` writes it (16-bit Apple Lossless) reads back as Float32 equal
    /// to its Int16 reading divided by 32768, sample for sample: the float engine never held anything a 16-bit
    /// engine can't.
    func testALACFloatReadIsInt16Over32768() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("EngineInt16Tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("part.caf")
        let part = makeParts(seconds: 2)[0]
        // Unquantised audio too, as the import writes it: the file stores 16 bits whatever goes in.
        let n = part.frameCount
        var raw = [Float](repeating: 0, count: n)
        for j in 0..<n {
            let x = Double(j)
            let a: Double = 0.6 * sin(x * 0.0123)
            let b: Double = 0.3 * sin(x * 0.31)
            raw[j] = Float(a + b)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16,
        ]
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 2, interleaved: false)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            buf.floatChannelData![0].update(from: part.left, count: n)
            buf.floatChannelData![1].update(from: raw, count: n)
            try file.write(from: buf)
        }
        let asFloat = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let fb = AVAudioPCMBuffer(pcmFormat: asFloat.processingFormat, frameCapacity: AVAudioFrameCount(n))!
        try asFloat.read(into: fb)
        let asInt = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
        let ib = AVAudioPCMBuffer(pcmFormat: asInt.processingFormat, frameCapacity: AVAudioFrameCount(n))!
        try asInt.read(into: ib)
        XCTAssertEqual(Int(fb.frameLength), n)
        XCTAssertEqual(Int(ib.frameLength), n)
        var mismatches = 0
        for c in 0..<2 {
            let f = fb.floatChannelData![c], i = ib.int16ChannelData![c]
            for j in 0..<n where f[j] != Float(i[j]) / 32768 { mismatches += 1 }
        }
        XCTAssertEqual(mismatches, 0, "a Float32 read is exactly the Int16 read / 32768")
        // And quantised audio goes through the file unchanged.
        let l = fb.floatChannelData![0]
        XCTAssertEqual((0..<n).filter { l[$0] != part.left[$0] }.count, 0)
    }

    /// Digests of the float engine's output (taken before the 16-bit change, on Apple silicon).
    static let golden: [String: String] = [
        "plain": "0e3622f1334477365f702ad5",
        "loop": "1d915e5590584157185405cd",
        "stretch": "3f49aba2e698bc131b0139c0",
        "export-identity": "e668bf49196d10a2cbf9743a",
        "export-stretched": "e483c6210c12b6651d8bdbdd",
    ]
}
