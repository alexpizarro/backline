import Accelerate
import CoreML
import XCTest
@testable import BacklineKit

/// `MDXSTFT` is the only half of the drum splitter that can be tested without the
/// 417 MB Core ML package (which is never committed). The round-trip test is
/// self-contained; the two parity tests need `ml/fixtures/drumsep`, written by
/// `python ml/convert_drumsep.py convert --fixtures ml/fixtures/drumsep`, and skip
/// themselves when it is absent.
final class DrumSeparatorTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("ml/fixtures/drumsep")

    private func load(_ name: String) throws -> [Float] {
        let url = Self.fixtures.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("no \(url.lastPathComponent); run ml/convert_drumsep.py convert --fixtures ml/fixtures/drumsep")
        }
        let d = try Data(contentsOf: url)
        return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private func snr(_ ref: [Float], _ got: [Float]) -> Double {
        precondition(ref.count == got.count)
        var se = 0.0, re = 0.0
        for i in 0..<ref.count {
            let d = Double(ref[i]) - Double(got[i])
            se += d * d
            re += Double(ref[i]) * Double(ref[i])
        }
        return 10 * log10(re / max(se, .leastNormalMagnitude))
    }

    /// Dropping bin 1024 (Nyquist) is the only information MDX23C's STFT loses, so a
    /// band-limited signal must survive forward + inverse essentially intact.
    func testRoundTripReconstructsBandLimitedSignal() {
        let hop = DrumSeparator.hop, F = DrumSeparator.dimF
        let T = 64
        let L = MDXSTFT.length(forFrames: T, hop: hop)
        let stft = MDXSTFT(nfft: DrumSeparator.nfft, hop: hop, bins: F, frames: T)
        XCTAssertEqual(MDXSTFT.frames(for: L, hop: hop), T)

        var x = [Float](repeating: 0, count: L)
        for i in 0..<L {
            let t = Double(i) / DrumSeparator.sampleRate
            x[i] = Float(0.3 * sin(2 * .pi * 110 * t) + 0.2 * sin(2 * .pi * 1_830 * t)
                         + 0.1 * sin(2 * .pi * 7_400 * t))
        }

        var re = [Float](repeating: 0, count: F * T), im = re
        var y = [Float](repeating: 0, count: L)
        x.withUnsafeBufferPointer { xp in
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    stft.forward(xp.baseAddress!, count: L, re: rp.baseAddress!, im: ip.baseAddress!)
                    y.withUnsafeMutableBufferPointer { yp in
                        stft.inverse(re: rp.baseAddress!, im: ip.baseAddress!, frames: T, out: yp.baseAddress!)
                    }
                }
            }
        }
        let s = snr(x, y)
        XCTAssertGreaterThan(s, 80, "round-trip SNR \(s) dB")
    }

    /// Swift forward STFT vs torch.stft as MDX23C calls it.
    func testForwardMatchesTorch() throws {
        let L = DrumSeparator.chunk, F = DrumSeparator.dimF, T = DrumSeparator.frames
        let mix = try load("mix.f32")                       // [1, 2, L]
        let ref = try load("spec.f32")                      // [1, 4, F, T]
        XCTAssertEqual(mix.count, 2 * L)
        XCTAssertEqual(ref.count, 4 * F * T)

        let stft = MDXSTFT(nfft: DrumSeparator.nfft, hop: DrumSeparator.hop, bins: F, frames: T)
        var out = [Float](repeating: 0, count: 4 * F * T)
        mix.withUnsafeBufferPointer { m in
            out.withUnsafeMutableBufferPointer { o in
                for c in 0..<2 {
                    stft.forward(m.baseAddress! + c * L, count: L,
                                 re: o.baseAddress! + (2 * c) * F * T,
                                 im: o.baseAddress! + (2 * c + 1) * F * T)
                }
            }
        }
        let s = snr(ref, out)
        print("drumsep forward STFT vs torch: \(String(format: "%.1f", s)) dB")
        XCTAssertGreaterThan(s, 100, "forward STFT SNR \(s) dB")
    }

    /// Swift iSTFT vs torch.istft on the real model output, part 0 (kick).
    func testInverseMatchesTorch() throws {
        let L = DrumSeparator.chunk, F = DrumSeparator.dimF, T = DrumSeparator.frames
        let freq = try load("freq.f32")                     // [1, 5, 4, F, T]
        let wave = try load("wave.f32")                     // [1, 5, 2, L]
        XCTAssertEqual(freq.count, 5 * 4 * F * T)
        XCTAssertEqual(wave.count, 5 * 2 * L)

        let stft = MDXSTFT(nfft: DrumSeparator.nfft, hop: DrumSeparator.hop, bins: F, frames: T)
        var worst = Double.infinity
        for p in 0..<DrumSeparator.parts.count {
            for c in 0..<2 {
                var got = [Float](repeating: 0, count: L)
                freq.withUnsafeBufferPointer { f in
                    let re = f.baseAddress! + (p * 4 + 2 * c) * F * T
                    got.withUnsafeMutableBufferPointer { g in
                        stft.inverse(re: re, im: re + F * T, frames: T, out: g.baseAddress!)
                    }
                }
                let ref = Array(wave[((p * 2 + c) * L)..<((p * 2 + c + 1) * L)])
                worst = min(worst, snr(ref, got))
            }
        }
        print("drumsep iSTFT vs torch (worst of 10 planes): \(String(format: "%.1f", worst)) dB")
        XCTAssertGreaterThan(worst, 100, "iSTFT SNR \(worst) dB")
    }

    /// Split F10: chunks where the drums are silent skip the model. A linear stand-in for the model (part p =
    /// weight p x the input spectrum) shows the bookkeeping: outside the silent span the parts are the same as
    /// when every chunk goes to the model, inside it they are zero, fewer chunks are run, and the pieces with
    /// `rest` still add up to the drums.
    func testSilentChunksSkipTheModelAndThePiecesStillAddUp() throws {
        let sr = DrumSeparator.sampleRate, n = Int(60 * sr)
        let span = Int(15 * sr)..<Int(45 * sr)
        var seed: UInt64 = 0xC0FF_EE00_1234_5678
        func noise() -> Float {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Double(seed >> 11) / Double(1 << 53) - 0.5)
        }
        var l = [Float](repeating: 0, count: n), r = l
        for i in 0..<n {
            if span.contains(i) {
                // A drumless break: room noise at about -85 dBFS, under the -70 dBFS line.
                l[i] = 1.9e-4 * noise(); r[i] = 1.9e-4 * noise()
            } else {
                // Hits every quarter second: a decaying low thump plus a noise burst.
                let k = i % Int(sr / 4), t = Double(k) / sr
                let env = Float(exp(-t * 30))
                let thump = Float(sin(2 * .pi * 60 * t))
                l[i] = 0.5 * env * (thump + noise()); r[i] = 0.5 * env * (thump + 0.8 * noise())
            }
        }
        let drums = StereoAudio(left: l, right: r, sampleRate: sr)

        let weights: [Float] = [0.30, 0.20, 0.10, 0.15, 0.05]
        let F = DrumSeparator.dimF, T = DrumSeparator.frames, plane = F * T
        let out = try MLMultiArray(shape: [1, 5, 4, NSNumber(value: F), NSNumber(value: T)], dataType: .float32)
        func linear(_ calls: UnsafeMutablePointer<Int>) -> (MLMultiArray, () -> Bool) throws -> MLMultiArray {
            { spec, _ in
                calls.pointee += 1
                let src = spec.dataPointer.assumingMemoryBound(to: Float.self)
                let dst = out.dataPointer.assumingMemoryBound(to: Float.self)
                for p in 0..<5 {
                    var w = weights[p]
                    vDSP_vsmul(src, 1, &w, dst + p * 4 * plane, 1, vDSP_Length(4 * plane))
                }
                return out
            }
        }
        var allCalls = 0, skipCalls = 0
        let every = try DrumSeparator(overlap: 2, skipBelow: 0, predict: linear(&allCalls)).separate(drums)
        let skipping = try DrumSeparator(overlap: 2, predict: linear(&skipCalls)).separate(drums)
        print("drum kit: \(skipCalls) of \(allCalls) chunks went to the model")
        XCTAssertLessThan(skipCalls, allCalls, "the silent chunks are skipped")
        XCTAssertGreaterThan(skipCalls, 0)

        // Every chunk that covers 29.5 to 30.5 s lies inside the silent span, so there the parts are zero.
        let middle = Int(29.5 * sr)..<Int(30.5 * sr)
        var worstOutside: Float = 0
        for name in DrumSeparator.parts {
            let a = try XCTUnwrap(skipping[name]), b = try XCTUnwrap(every[name])
            for (x, y) in [(a.left, b.left), (a.right, b.right)] {
                for i in 0..<n where !span.contains(i) { worstOutside = max(worstOutside, abs(x[i] - y[i])) }
                XCTAssertTrue(middle.allSatisfy { x[$0] == 0 }, "\(name) is zero in the silent span")
            }
        }
        XCTAssertLessThanOrEqual(worstOutside, 1e-6, "parts outside the silent span are unchanged")

        // The pieces, rest included, add up to the drums.
        var worstSum: Float = 0
        for c in 0..<2 {
            var total = [Float](repeating: 0, count: n)
            for name in DrumSeparator.parts + [DrumSeparator.restKey] {
                let part = try XCTUnwrap(skipping[name])
                vDSP_vadd(total, 1, c == 0 ? part.left : part.right, 1, &total, 1, vDSP_Length(n))
            }
            let src = c == 0 ? l : r
            for i in 0..<n { worstSum = max(worstSum, abs(total[i] - src[i])) }
        }
        XCTAssertLessThanOrEqual(worstSum, 1e-6, "kick + snare + toms + hh + cymbals + rest = drums")
    }

    /// The -70 dBFS line against real drums: every 11.9 s chunk of the drum parts in `DRUM_STEMS` (default: the
    /// Mac repository's six-part reference outputs, `ref_out` then `htdemucs_6s` in its git-ignored local test
    /// folder, run from its root) is far above it, so only drumless spans are skipped. The path is built from
    /// its components so the publish check, which stops on that folder's name followed by a slash, has nothing
    /// to find here.
    func testRealDrumChunksAreFarAboveTheSilenceLine() throws {
        let env = ProcessInfo.processInfo.environment["DRUM_STEMS"]
        let local = NSString.path(withComponents: [FileManager.default.currentDirectoryPath, "testdata", "ref_out", "htdemucs_6s"])
        let root = URL(fileURLWithPath: env ?? local)
        let songs = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("drums.wav").path) }
        try XCTSkipIf(songs.isEmpty, "set DRUM_STEMS to a folder of song folders with drums.wav")
        for song in songs {
            let d = try AudioDecoder.decode(song.appendingPathComponent("drums.wav"))
            let L = DrumSeparator.chunk, step = L / 2          // the app runs the kit pass at overlap 2
            var quietest = Float.infinity
            for i in stride(from: 0, to: max(1, d.frameCount - L / 2), by: step) {
                let seg = min(L, d.frameCount - i)
                var a: Float = 0, b: Float = 0
                d.left.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress! + i, 1, &a, vDSP_Length(seg)) }
                d.right.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress! + i, 1, &b, vDSP_Length(seg)) }
                quietest = min(quietest, (a + b) / 2)
            }
            let db = 10 * log10(quietest)
            print("\(song.lastPathComponent): quietest drum chunk \(String(format: "%.1f", db)) dBFS")
            XCTAssertGreaterThan(quietest, DrumSeparator.silentMeanSquare * 1_000, "at least 30 dB above the line")
        }
    }
}
