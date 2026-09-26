import Accelerate
import CoreML
import Foundation

/// Optional ML lead-guitar extractor: a 2-source (lead, rhythm) HTDemucs checkpoint converted to Core ML
/// (STFT outside the graph, same `DemucsSTFT` as the 6-source separator). Runs MSST's "demucs" demix:
/// 3 s chunks, 50 % overlap, right-zero-padded chunks, plain averaging, no whole-track normalisation.
///
/// Used only when a build bundles a model whose licence allows it; otherwise Backline uses the stereo
/// `GuitarSplitter` alone. Users never install models.
public final class LeadSeparator: @unchecked Sendable {
    public static let segment = 132_300          // 3 s at 44.1 kHz
    public static let step = 66_150              // 50 % overlap
    public static let modelName = "LeadRhythmHTDemucs"

    private let model: MLModel
    private let stft = DemucsSTFT()

    public init(modelURL: URL, computeUnits: MLComputeUnits = .cpuAndGPU) throws {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        config.allowLowPrecisionAccumulationOnGPU = false
        model = try MLModel(contentsOf: modelURL, configuration: config)
    }

    /// A lead/rhythm model shipped inside the app bundle, if this build includes one. There is no
    /// user-installed path: people never have to add anything to Backline.
    public static func bundledModel(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: modelName, withExtension: "mlmodelc")
    }

    /// Lead estimate for `input` (44.1 kHz stereo). Rhythm is `input − lead`.
    public func lead(of input: StereoAudio, isCancelled: @Sendable () -> Bool = { false }) throws -> StereoAudio {
        let n = input.frameCount
        let L = Self.segment, F = stft.bins, T = stft.frames(for: L)
        var acc = [[Float]](repeating: [Float](repeating: 0, count: n), count: 2)
        var count = [Float](repeating: 0, count: n)
        let mixArr = try MLMultiArray(shape: [1, 2, NSNumber(value: L)], dataType: .float32)
        let specArr = try MLMultiArray(shape: [1, 4, NSNumber(value: F), NSNumber(value: T)], dataType: .float32)
        var y = [[Float]](repeating: [Float](repeating: 0, count: L), count: 2)

        for offset in stride(from: 0, to: n, by: Self.step) {
            if isCancelled() { throw CancellationError() }
            let seg = min(L, n - offset)
            let mixPtr = mixArr.dataPointer.assumingMemoryBound(to: Float.self)
            for (c, src) in [input.left, input.right].enumerated() {
                let dst = mixPtr + c * L
                src.withUnsafeBufferPointer { dst.update(from: $0.baseAddress! + offset, count: seg) }
                if seg < L { (dst + seg).update(repeating: 0, count: L - seg) }
            }
            let specPtr = specArr.dataPointer.assumingMemoryBound(to: Float.self)
            DispatchQueue.concurrentPerform(iterations: 2) { c in
                stft.forward(mixPtr + c * L, count: L, re: specPtr + (2 * c) * F * T, im: specPtr + (2 * c + 1) * F * T)
            }
            let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "mix": MLFeatureValue(multiArray: mixArr), "spec": MLFeatureValue(multiArray: specArr),
            ]))
            guard let freq = out.featureValue(for: "freq")?.multiArrayValue,
                  let time = out.featureValue(for: "time")?.multiArrayValue else { throw CocoaError(.coderValueNotFound) }
            // Only source 0 (lead) is needed: freq planes 0…3, time planes 0…1.
            let fp = DemucsSeparator.contiguous(freq, planes: 2 * 4, planeSize: F * T)
            let tp = DemucsSeparator.contiguous(time, planes: 2 * 2, planeSize: L)
            fp.withUnsafeBufferPointer { f in
                tp.withUnsafeBufferPointer { t in
                    y.withUnsafeMutableBufferPointer { yy in
                        let yBase = yy.baseAddress!
                        DispatchQueue.concurrentPerform(iterations: 2) { c in
                            let re = f.baseAddress! + (2 * c) * F * T
                            yBase[c].withUnsafeMutableBufferPointer { d in
                                stft.inverse(re: re, im: re + F * T, frames: T, length: L, out: d.baseAddress!)
                                vDSP_vadd(d.baseAddress!, 1, t.baseAddress! + c * L, 1, d.baseAddress!, 1, vDSP_Length(L))
                            }
                        }
                    }
                }
            }
            for c in 0..<2 {
                acc[c].withUnsafeMutableBufferPointer { a in
                    y[c].withUnsafeBufferPointer { v in
                        vDSP_vadd(a.baseAddress! + offset, 1, v.baseAddress!, 1, a.baseAddress! + offset, 1, vDSP_Length(seg))
                    }
                }
            }
            var one: Float = 1
            count.withUnsafeMutableBufferPointer { cp in
                vDSP_vsadd(cp.baseAddress! + offset, 1, &one, cp.baseAddress! + offset, 1, vDSP_Length(seg))
            }
        }
        for c in 0..<2 { vDSP_vdiv(count, 1, acc[c], 1, &acc[c], 1, vDSP_Length(n)) }
        return StereoAudio(left: acc[0], right: acc[1], sampleRate: input.sampleRate)
    }
}
