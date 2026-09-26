import XCTest
@testable import BacklineKit

final class STFTTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("ml/fixtures")

    func load(_ name: String) throws -> [Float] {
        let d = try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
        return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    func testForwardMatchesTorch() throws {
        let L = 343_980, F = 2048, T = 336
        let mix = try load("mix.f32")
        let ref = try load("spec.f32")         // [4][F][T] : L.re, L.im, R.re, R.im
        let stft = DemucsSTFT()
        XCTAssertEqual(stft.frames(for: L), T)
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
        var maxErr: Float = 0, maxRef: Float = 0
        for i in 0..<out.count { maxErr = max(maxErr, abs(out[i] - ref[i])); maxRef = max(maxRef, abs(ref[i])) }
        print("forward max abs err", maxErr, "max ref", maxRef)
        XCTAssertLessThan(maxErr / maxRef, 1e-4)
    }

    func testInverseMatchesTorch() throws {
        let L = 343_980, F = 2048, T = 336, S = 6
        let freq = try load("freq.f32")        // [S][4][F][T]
        let ref = try load("ispec.f32")        // [S][2][L]
        let stft = DemucsSTFT()
        var out = [Float](repeating: 0, count: S * 2 * L)
        freq.withUnsafeBufferPointer { fr in
            out.withUnsafeMutableBufferPointer { o in
                for s in 0..<S {
                    for c in 0..<2 {
                        let base = fr.baseAddress! + (s * 4 + 2 * c) * F * T
                        stft.inverse(re: base, im: base + F * T, frames: T, length: L,
                                     out: o.baseAddress! + (s * 2 + c) * L)
                    }
                }
            }
        }
        var maxErr: Float = 0, maxRef: Float = 0
        for i in 0..<out.count { maxErr = max(maxErr, abs(out[i] - ref[i])); maxRef = max(maxRef, abs(ref[i])) }
        print("inverse max abs err", maxErr, "max ref", maxRef)
        XCTAssertLessThan(maxErr / maxRef, 1e-4)
    }
}
