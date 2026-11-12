import Accelerate
import AVFoundation
import XCTest
@testable import BacklineKit

final class AudioDecoderTests: XCTestCase {
    /// A damaged file once crashed the app: `AVAudioFile` raised an Objective-C exception from `framePosition`
    /// (Swift cannot catch those) instead of returning an error. 40 KB of noise named `.mp3` reproduces it.
    func testRandomBytesThrowInsteadOfCrashing() throws {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        var bytes = [UInt8](repeating: 0, count: 40_960)
        for i in bytes.indices {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes[i] = UInt8(truncatingIfNeeded: seed >> 33)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("damaged-\(UUID().uuidString).mp3")
        try Data(bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try AudioDecoder.decode(url)) { error in
            XCTAssertTrue(error is AudioDecodeError, "a damaged file is reported as a read error, got \(error)")
        }
    }

    /// The crash itself: an Objective-C exception inside a guarded call becomes a Swift error. Random bytes only
    /// raise on some systems (the iOS Simulator did, this Mac does not), so the guard is tested directly too.
    func testAnObjectiveCExceptionBecomesAnError() {
        XCTAssertThrowsError(try AudioDecoder.guarded { () -> Int in
            NSException(name: .rangeException, reason: "framePosition on a damaged file", userInfo: nil).raise()
            return 0
        }) { XCTAssertTrue($0 is AudioDecodeError) }
        XCTAssertEqual(try AudioDecoder.guarded { 42 }, 42)
    }

    /// A video with no sound track says so, rather than "can't open this file type" (R05).
    func testAVideoWithoutSoundSaysSo() {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/video-no-audio.mp4")
        XCTAssertThrowsError(try AudioDecoder.decode(url)) { error in
            XCTAssertEqual((error as? AudioDecodeError)?.errorDescription, "Couldn't read the audio: there is no sound in this file")
        }
    }

    /// F6, then ios-split-safety: a 48 kHz file is resampled with the fastest setting that keeps the whole band.
    /// Wave 1's normal converter was 13 times faster than mastering at max but dropped everything above about
    /// 17 kHz; the shipped one (mastering at low quality) is about 6 times faster on a real song and differs from
    /// mastering at max by a signal more than 140 dB under the music up to 20 kHz. The fixture has harmonics up to
    /// 20 kHz; the check is 90 dB up to 20 kHz, and at least 2.5 times faster (best of three, so a busy machine
    /// doesn't decide the ratio; this fixture measures 6 to 9 times).
    func testA48kFileResamplesFastAndTheSameUpTo20kHz() throws {
        let url = try Self.write48kFixture(seconds: 30, top: 20_000)
        defer { try? FileManager.default.removeItem(at: url) }

        func timed(_ r: AudioDecoder.Resampler) throws -> (StereoAudio, Double) {
            var best = Double.infinity
            var audio: StereoAudio?
            for _ in 0..<3 {
                let t = Date()
                audio = try AudioDecoder.decode(url, sampleRate: 44_100, resampler: r, progress: nil)
                best = min(best, Date().timeIntervalSince(t))
            }
            return (audio!, best)
        }
        let (fast, fastTime) = try timed(.fast)
        let (slow, slowTime) = try timed(.mastering)
        XCTAssertEqual(fast.frameCount, slow.frameCount)
        XCTAssertEqual(Double(fast.frameCount), 30 * 44_100, accuracy: 2)

        var signal = 0.0, diff = 0.0, signal16 = 0.0, diff16 = 0.0
        for (a, b) in [(fast.left, slow.left), (fast.right, slow.right)] {
            let d = zip(a, b).map { $0 - $1 }
            signal += Self.energy(b, below: 20_000, sampleRate: 44_100).low
            diff += Self.energy(d, below: 20_000, sampleRate: 44_100).low
            signal16 += Self.energy(b, below: 16_000, sampleRate: 44_100).low
            diff16 += Self.energy(d, below: 16_000, sampleRate: 44_100).low
        }
        let below20 = 10 * log10(signal / max(diff, .leastNormalMagnitude))
        let below16 = 10 * log10(signal16 / max(diff16, .leastNormalMagnitude))
        print(String(format: "48 kHz decode of 30 s: shipped %.3f s, mastering %.3f s (%.1fx); difference %.1f dB below the music up to 20 kHz, %.1f dB up to 16 kHz",
                     fastTime, slowTime, slowTime / fastTime, below20, below16))
        XCTAssertGreaterThan(below20, 90, "difference up to 20 kHz: \(below20) dB under the music")
        XCTAssertGreaterThan(below16, 90, "difference up to 16 kHz: \(below16) dB under the music")
        XCTAssertGreaterThan(slowTime / fastTime, 2.5, "shipped \(fastTime) s against mastering \(slowTime) s")
    }

    /// The normal converter (wave 1's choice) loses the top of the band: this is why it isn't shipped.
    func testTheNormalConverterLosesTheTopOfTheBand() throws {
        let url = try Self.write48kFixture(seconds: 10, top: 20_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let normal = AudioDecoder.Resampler(algorithm: AVSampleRateConverterAlgorithm_Normal, quality: AVAudioQuality.high.rawValue)
        let a = try AudioDecoder.decode(url, sampleRate: 44_100, resampler: normal, progress: nil)
        let b = try AudioDecoder.decode(url, sampleRate: 44_100, resampler: .mastering, progress: nil)
        let d = zip(a.left, b.left).map { $0 - $1 }
        let below20 = 10 * log10(Self.energy(b.left, below: 20_000, sampleRate: 44_100).low
                                 / max(Self.energy(d, below: 20_000, sampleRate: 44_100).low, .leastNormalMagnitude))
        XCTAssertLessThan(below20, 90, "the fixture has music above 17 kHz that the normal converter drops")
    }

    /// Energy of `x` over all frequencies and below `hz`, from 4096-point Hann-windowed blocks.
    static func energy(_ x: [Float], below hz: Double, sampleRate: Double) -> (all: Double, low: Double) {
        let n = 4096, half = n / 2, log2n = vDSP_Length(12)
        let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let cutoff = Int(hz / sampleRate * Double(n))
        var frame = [Float](repeating: 0, count: n), re = [Float](repeating: 0, count: half), im = re, mag = re
        var all = 0.0, low = 0.0
        var start = 0
        while start + n <= x.count {
            x.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + start, 1, window, 1, &frame, 1, vDSP_Length(n)) }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    split.imagp[0] = 0          // Nyquist, left out
                    vDSP_zvmags(&split, 1, &mag, 1, vDSP_Length(half))
                }
            }
            for k in 1..<half {
                all += Double(mag[k])
                if k < cutoff { low += Double(mag[k]) }
            }
            start += n
        }
        return (all, low)
    }

    /// Music-like stereo at 48 kHz: plucked notes with harmonics up to 16 kHz (as in a real recording, which
    /// has almost nothing above that), each note panned somewhere else, written as 32-bit float WAV.
    static func write48kFixture(seconds: Int, top: Double = 16_000) throws -> URL {
        let sr = 48_000.0, n = seconds * 48_000
        var left = [Float](repeating: 0, count: n), right = left
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func rand() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let noteLength = Int(sr / 4), ring = 2 * noteLength
        // The decay envelope is shared by every note.
        let envelope = (0..<ring).map { Float(exp(-Double($0) / (sr * 0.3))) }
        var phase = [Float](repeating: 0, count: ring), tone = phase
        for start in stride(from: 0, to: n, by: noteLength) {
            let f0 = 82.4 * pow(2, Double(Int(rand() * 36)) / 12)
            let pan = Float(rand())
            let count = min(ring, n - start)
            var note = [Float](repeating: 0, count: count)
            for h in 1...(top > 16_000 ? 40 : 24) where f0 * Double(h) < top {
                var a: Float = 0, step = Float(2 * Double.pi * f0 * Double(h) / sr)
                vDSP_vramp(&a, &step, &phase, 1, vDSP_Length(count))
                var c = Int32(count)
                vvsinf(&tone, phase, &c)
                var amp = Float(0.25 / Double(h))
                vDSP_vsma(tone, 1, &amp, note, 1, &note, 1, vDSP_Length(count))
            }
            vDSP_vmul(note, 1, envelope, 1, &note, 1, vDSP_Length(count))
            for i in 0..<count {
                left[start + i] += note[i] * (1 - pan)
                right[start + i] += note[i] * pan
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fixture48k-\(UUID().uuidString).wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 2, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        left.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: n) }
        right.withUnsafeBufferPointer { buf.floatChannelData![1].update(from: $0.baseAddress!, count: n) }
        try file.write(from: buf)
        return url
    }
}
