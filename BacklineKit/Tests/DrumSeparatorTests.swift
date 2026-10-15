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
}
