import Accelerate
import CoreML
import Foundation

/// ML lead-guitar extractor: a 2-source (lead, rhythm) HTDemucs model converted to Core ML (STFT outside the
/// graph, same `DemucsSTFT` as the 6-source separator). Runs MSST's "demucs" demix: 3 s chunks, 50 % overlap,
/// right-zero-padded chunks, plain averaging, no whole-track normalisation. Its lead estimate is blended
/// 50/50 with the stereo `GuitarSplitter`.
public final class LeadSeparator: @unchecked Sendable {
    public static let segment = 132_300          // 3 s at 44.1 kHz
    public static let step = 66_150              // 50 % overlap
    public static let modelName = "LeadRhythmHTDemucs"

    private let model: MLModel?
    private let stft = DemucsSTFT()

    /// For tests: no model (the pass is given a stand-in for it).
    init() { model = nil }

    public init(modelURL: URL, computeUnits: MLComputeUnits = SeparationCompute.preferred) throws {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        config.allowLowPrecisionAccumulationOnGPU = false
        model = try MLModel(contentsOf: modelURL, configuration: config)
    }

    /// The bundled model (Resources/LeadRhythmHTDemucs.mlmodelc).
    public static func bundledModel(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: modelName, withExtension: "mlmodelc")
    }

    /// Lead estimate for `input` (44.1 kHz stereo). Rhythm is `input − lead`. `progress` gets 0...1 after
    /// each segment: on a phone this can be the longest step of an import.
    ///
    /// With a `checkpoint`, finished audio is kept on disk as it is made, and a run stopped part-way carries on
    /// where it stopped: it gives the same samples as a run that was never stopped.
    public func lead(of input: StereoAudio, checkpoint: SeparationCheckpoint? = nil, progress: (Double) -> Void = { _ in },
                     isCancelled: @Sendable () -> Bool = { false }) throws -> StereoAudio {
        guard let model else { throw CocoaError(.featureUnsupported) }
        return try lead(of: input, checkpoint: checkpoint, progress: progress, isCancelled: isCancelled) { mix, spec in
            let out = try DemucsSeparator.predict(model, MLDictionaryFeatureProvider(dictionary: [
                "mix": MLFeatureValue(multiArray: mix), "spec": MLFeatureValue(multiArray: spec),
            ]), isCancelled: isCancelled)
            guard let freq = out.featureValue(for: "freq")?.multiArrayValue,
                  let time = out.featureValue(for: "time")?.multiArrayValue else { throw CocoaError(.coderValueNotFound) }
            return (freq, time)
        }
    }

    /// The pass with `predict` standing in for the model (tests): it gets the `mix` and `spec` tensors and returns
    /// the `freq` and `time` tensors.
    func lead(of input: StereoAudio, checkpoint: SeparationCheckpoint?, progress: (Double) -> Void,
              isCancelled: @Sendable () -> Bool,
              predict: (MLMultiArray, MLMultiArray) throws -> (freq: MLMultiArray, time: MLMultiArray)) throws -> StereoAudio {
        let n = input.frameCount
        let L = Self.segment, F = stft.bins, T = stft.frames(for: L)
        var acc = [[Float]](repeating: [Float](repeating: 0, count: n), count: 2)
        var count = [Float](repeating: 0, count: n)
        let mixArr = try MLMultiArray(shape: [1, 2, NSNumber(value: L)], dataType: .float32)
        let specArr = try MLMultiArray(shape: [1, 4, NSNumber(value: F), NSNumber(value: T)], dataType: .float32)
        var y = [[Float]](repeating: [Float](repeating: 0, count: L), count: 2)

        // A run that was stopped kept the final samples below `resumeFrom`: only the segments that reach past them
        // are computed again, from nothing, and the kept samples are put back over them at the end.
        let offsets = Array(stride(from: 0, to: n, by: Self.step))
        var writer = CheckpointWriter.open(checkpoint, total: n, step: Self.step, channels: 2, scale: .divide)
        let resumeFrom = writer?.resumeFrom ?? 0
        let first = CheckpointWriter.firstChunk(offsets, resumeFrom: resumeFrom) { min(L, n - $0) }
        for offset in offsets[first...] {
            if isCancelled() { throw CancellationError() }
            progress(Double(offset) / Double(max(n, 1)))
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
            let (freq, time) = try predict(mixArr, specArr)
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
            // No later segment reaches below `offset + step`: those samples are final and go to the checkpoint.
            if let w = writer, (try? w.append(upTo: min(offset + Self.step, n), accumulated: acc, weight: count)) == nil {
                writer = nil
            }
        }
        if let w = writer, w.resumeFrom > 0, (try? w.restorePrefix(into: &acc, weight: &count)) == nil {
            // The kept samples couldn't be read back after all: the whole pass again, from nothing.
            writer = nil
            checkpoint?.discard()
            return try lead(of: input, checkpoint: checkpoint, progress: progress, isCancelled: isCancelled, predict: predict)
        }
        writer = nil
        for c in 0..<2 { vDSP_vdiv(count, 1, acc[c], 1, &acc[c], 1, vDSP_Length(n)) }
        return StereoAudio(left: acc[0], right: acc[1], sampleRate: input.sampleRate)
    }
}
