import CoreML
import XCTest
@testable import BacklineKit

/// Self-contained checks on the BS-RoFormer front/back end. These pin the three things that
/// silently destroy a converted model: the forward scaling (vDSP's packed real FFT returns twice
/// the DFT), the DC / Nyquist packing (vDSP hides Nyquist in `imagp[0]`, torch keeps bin 1024),
/// and the `f * 4 + channel * 2 + (re|im)` interleave the Core ML graph expects.
/// Numerical agreement with torch.stft / torch.istft itself is checked in ml/convert_roformer.py.
final class RoformerSTFTTests: XCTestCase {
    let nfft = 2048, hop = 512, frames = 9
    var length: Int { (frames - 1) * hop }
    var flat: Int { (nfft / 2 + 1) * 4 }

    func signal(_ n: Int, seed: UInt64 = 12_345) -> [Float] {
        var s = seed
        return (0..<n).map { _ in
            s = s &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int32(truncatingIfNeeded: s >> 33)) / Float(Int32.max) * 0.3
        }
    }

    func hann(_ n: Int) -> [Double] {
        (0..<n).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n)) }
    }

    /// torch/numpy "reflect": the edge sample is not repeated.
    func reflect(_ x: [Float], pad: Int) -> [Double] {
        var out = [Double](repeating: 0, count: x.count + 2 * pad)
        for i in 0..<pad { out[i] = Double(x[pad - i]) }
        for i in 0..<x.count { out[pad + i] = Double(x[i]) }
        for i in 0..<pad { out[pad + x.count + i] = Double(x[x.count - 2 - i]) }
        return out
    }

    func testForwardMatchesNaiveDFT() {
        let stft = RoformerSTFT(nfft: nfft, hop: hop, frames: frames)
        let x = signal(length)
        var spec = [Float](repeating: 0, count: frames * flat)
        x.withUnsafeBufferPointer { s in
            spec.withUnsafeMutableBufferPointer { d in
                stft.forward(s.baseAddress!, channel: 0, into: d.baseAddress!, rowStride: flat)
            }
        }
        let padded = reflect(x, pad: nfft / 2)
        let w = hann(nfft)
        var worst = 0.0, scale = 0.0
        for t in [0, 1, 4, frames - 1] {
            for f in [0, 1, 7, 513, 1023, 1024] {
                var re = 0.0, im = 0.0
                for n in 0..<nfft {
                    let a = -2 * Double.pi * Double(f) * Double(n) / Double(nfft)
                    let v = padded[t * hop + n] * w[n]
                    re += v * cos(a)
                    im += v * sin(a)
                }
                let gotRe = Double(spec[t * flat + f * 4]), gotIm = Double(spec[t * flat + f * 4 + 1])
                worst = max(worst, max(abs(gotRe - re), abs(gotIm - (f == 0 || f == nfft / 2 ? 0 : im))))
                scale = max(scale, max(abs(re), abs(im)))
                if f == 0 || f == nfft / 2 { XCTAssertEqual(gotIm, 0, "bin \(f) must be real") }
            }
        }
        print("forward vs naive DFT: worst \(worst), scale \(scale), rel \(worst / scale)")
        XCTAssertLessThan(worst / scale, 2e-5)
    }

    func testRoundTripReconstructs() {
        let stft = RoformerSTFT(nfft: nfft, hop: hop, frames: frames)
        let x = signal(length, seed: 99)
        var spec = [Float](repeating: 0, count: frames * flat)
        x.withUnsafeBufferPointer { s in
            spec.withUnsafeMutableBufferPointer { d in
                stft.forward(s.baseAddress!, channel: 1, into: d.baseAddress!, rowStride: flat)
            }
        }
        var ola = [Float](repeating: 0, count: stft.olaLength)
        spec.withUnsafeBufferPointer { s in
            ola.withUnsafeMutableBufferPointer { o in
                stft.inverse(s.baseAddress! + 2, rowStride: flat, into: o.baseAddress!)   // channel 1 plane
                stft.applyWindowSum(o.baseAddress! + stft.trim, count: length)
            }
        }
        var err: Double = 0, sig: Double = 0
        for i in 0..<length {
            let d = Double(ola[stft.trim + i]) - Double(x[i])
            err += d * d
            sig += Double(x[i]) * Double(x[i])
        }
        let snr = 10 * log10(sig / err)
        print("stft -> istft round trip SNR \(snr) dB")
        XCTAssertGreaterThan(snr, 100)
    }

    func testChannelsAreIndependent() {
        let stft = RoformerSTFT(nfft: nfft, hop: hop, frames: frames)
        let a = signal(length, seed: 1), b = signal(length, seed: 2)
        var spec = [Float](repeating: 0, count: frames * flat)
        spec.withUnsafeMutableBufferPointer { d in
            a.withUnsafeBufferPointer { s in stft.forward(s.baseAddress!, channel: 0, into: d.baseAddress!, rowStride: flat) }
            b.withUnsafeBufferPointer { s in stft.forward(s.baseAddress!, channel: 1, into: d.baseAddress!, rowStride: flat) }
        }
        for (c, src) in [a, b].enumerated() {
            var ola = [Float](repeating: 0, count: stft.olaLength)
            spec.withUnsafeBufferPointer { s in
                ola.withUnsafeMutableBufferPointer { o in
                    stft.inverse(s.baseAddress! + c * 2, rowStride: flat, into: o.baseAddress!)
                    stft.applyWindowSum(o.baseAddress! + stft.trim, count: length)
                }
            }
            var err: Double = 0, sig: Double = 0
            for i in 0..<length {
                let d = Double(ola[stft.trim + i]) - Double(src[i])
                err += d * d
                sig += Double(src[i]) * Double(src[i])
            }
            XCTAssertGreaterThan(10 * log10(sig / err), 100, "channel \(c) leaked")
        }
    }

    /// A tone exactly on a bin should land in that bin with amplitude sum(window)/2 = nfft/4,
    /// which is the single clearest check that the 0.5 packed-FFT factor is right.
    func testOnBinToneAmplitude() {
        let stft = RoformerSTFT(nfft: nfft, hop: hop, frames: frames)
        let k = 64
        let x = (0..<length).map { Float(cos(2 * Double.pi * Double(k) * Double($0) / Double(nfft))) }
        var spec = [Float](repeating: 0, count: frames * flat)
        x.withUnsafeBufferPointer { s in
            spec.withUnsafeMutableBufferPointer { d in
                stft.forward(s.baseAddress!, channel: 0, into: d.baseAddress!, rowStride: flat)
            }
        }
        let t = 4
        let re = spec[t * flat + k * 4], im = spec[t * flat + k * 4 + 1]
        let mag = (re * re + im * im).squareRoot()
        print("on-bin tone magnitude \(mag), expected \(Float(nfft) / 4)")
        XCTAssertEqual(mag, Float(nfft) / 4, accuracy: Float(nfft) / 4 * 1e-3)
        // neighbouring bins of an on-bin tone are ~0 for a periodic hann only two bins out
        let far = spec[t * flat + (k + 4) * 4]
        XCTAssertLessThan(abs(far), Float(nfft) / 4 * 1e-3)
    }

    /// Core ML hands back the 4100-wide output with a row pitch of 4112, so every read and write
    /// has to go through the tensor's own stride, not `bins * 4`.
    func testPaddedRowStrideRoundTrips() {
        let stft = RoformerSTFT(nfft: nfft, hop: hop, frames: frames)
        let pitch = flat + 12
        let x = signal(length, seed: 7)
        var spec = [Float](repeating: .nan, count: frames * pitch)
        x.withUnsafeBufferPointer { s in
            spec.withUnsafeMutableBufferPointer { d in
                stft.forward(s.baseAddress!, channel: 0, into: d.baseAddress!, rowStride: pitch)
                // channel 1 left as NaN: it must not be read back by the channel 0 inverse
                for t in 0..<self.frames { for i in 0..<self.flat where i % 2 == 1 && (i % 4) == 3 { d[t * pitch + i] = 0 } }
            }
        }
        var ola = [Float](repeating: 0, count: stft.olaLength)
        spec.withUnsafeBufferPointer { s in
            ola.withUnsafeMutableBufferPointer { o in
                stft.inverse(s.baseAddress!, rowStride: pitch, into: o.baseAddress!)
                stft.applyWindowSum(o.baseAddress! + stft.trim, count: length)
            }
        }
        var err: Double = 0, sig: Double = 0
        for i in 0..<length {
            let d = Double(ola[stft.trim + i]) - Double(x[i])
            err += d * d
            sig += Double(x[i]) * Double(x[i])
        }
        XCTAssertGreaterThan(10 * log10(sig / err), 100)
    }

    func testRowPitchAcceptsPaddedCoreMLLayout() throws {
        let a = try MLMultiArray(shape: [1, 6, 4, 5], dataType: .float32)
        XCTAssertEqual(RoformerSeparator.rowPitch(a, shape: [1, 6, 4, 5]), a.strides[2].intValue)
        XCTAssertNil(RoformerSeparator.rowPitch(a, shape: [1, 6, 4, 6]))
        let wrongType = try MLMultiArray(shape: [1, 6, 4, 5], dataType: .double)
        XCTAssertNil(RoformerSeparator.rowPitch(wrongType, shape: [1, 6, 4, 5]))
    }

    func testStemRemapIsConsistent() {
        XCTAssertEqual(RoformerSeparator.sources, DemucsSeparator.sources)
        XCTAssertEqual(Set(RoformerSeparator.modelSources), Set(RoformerSeparator.sources))
        for (i, name) in RoformerSeparator.sources.enumerated() {
            XCTAssertEqual(RoformerSeparator.modelSources[RoformerSeparator.remap[i]], name)
        }
        XCTAssertEqual(RoformerSeparator.frames, 1151)
        XCTAssertEqual(RoformerSeparator.flat, 4100)
    }
}
