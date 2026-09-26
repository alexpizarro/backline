import Accelerate
import CoreML
import Foundation

/// On-device HTDemucs (6 sources) separation: Core ML core on the GPU, STFT/iSTFT with vDSP,
/// and Demucs' `apply_model` chunking (7.8 s segments, 25 % overlap, triangular overlap-add).
public final class DemucsSeparator: @unchecked Sendable {
    public static let sources = ["drums", "bass", "other", "vocals", "guitar", "piano"]
    public static let segment = 343_980          // 7.8 s at 44.1 kHz
    public static let sampleRate = 44_100.0

    public struct Progress: Sendable {
        public var fraction: Double              // 0...1 over the model passes
        public var chunk: Int
        public var chunks: Int
        public var secondsRemaining: Double?
    }

    private let model: MLModel
    private let stft = DemucsSTFT()

    public init(modelURL: URL, computeUnits: MLComputeUnits = .cpuAndGPU) throws {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        config.allowLowPrecisionAccumulationOnGPU = false
        self.model = try MLModel(contentsOf: modelURL, configuration: config)
    }

    /// Finds the compiled model in `bundle`, or compiles an `.mlpackage` (cached) for CLI/tests.
    public static func locateModel(in bundle: Bundle = .main, packageFallback: URL? = nil) async throws -> URL {
        if let url = bundle.url(forResource: "HTDemucs6s", withExtension: "mlmodelc") { return url }
        guard let pkg = packageFallback else { throw CocoaError(.fileNoSuchFile) }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("BacklineModelCache", isDirectory: true)
        let cache = dir.appendingPathComponent("HTDemucs6s.mlmodelc")
        if fm.fileExists(atPath: cache.path) { return cache }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let compiled = try await MLModel.compileModel(at: pkg)
        if compiled.standardizedFileURL == cache.standardizedFileURL { return cache }
        try? fm.removeItem(at: cache)
        try fm.moveItem(at: compiled, to: cache)
        return cache
    }

    /// Runs one silent segment so GPU kernels are compiled before the user's first import.
    public func warmUp() {
        guard let mix = try? MLMultiArray(shape: [1, 2, NSNumber(value: Self.segment)], dataType: .float32),
              let spec = try? MLMultiArray(shape: [1, 4, NSNumber(value: stft.bins),
                                                   NSNumber(value: stft.frames(for: Self.segment))], dataType: .float32),
              let input = try? MLDictionaryFeatureProvider(dictionary: ["mix": MLFeatureValue(multiArray: mix),
                                                                        "spec": MLFeatureValue(multiArray: spec)])
        else { return }
        _ = try? model.prediction(from: input)
    }

    /// Separates `audio` (44.1 kHz stereo). Returns planar stereo per source, in `sources` order.
    public func separate(_ audio: StereoAudio,
                         progress: @escaping @Sendable (Progress) -> Void = { _ in },
                         isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> [StereoAudio] {
        let n = audio.frameCount
        let L = Self.segment
        let S = Self.sources.count
        let F = stft.bins
        let T = stft.frames(for: L)

        // Whole-track normalisation (demucs.api / separate.py).
        var mono = [Float](repeating: 0, count: n)
        var half: Float = 0.5
        vDSP_vasm(audio.left, 1, audio.right, 1, &half, &mono, 1, vDSP_Length(n))
        var mean: Float = 0, std: Float = 0
        vDSP_normalize(mono, 1, nil, 1, &mean, &std, vDSP_Length(n))
        // vDSP_normalize gives population std; torch.std is unbiased. Negligible at this size.
        std = std * sqrt(Float(n) / Float(max(1, n - 1))) + 1e-8
        mono = []

        let normL = Self.affine(audio.left, scale: 1 / std, offset: -mean / std)
        let normR = Self.affine(audio.right, scale: 1 / std, offset: -mean / std)

        // Output accumulators: [source][channel] planes, plus the overlap weight sum.
        var out = [[Float]](repeating: [Float](repeating: 0, count: n), count: S * 2)
        var sumWeight = [Float](repeating: 0, count: n)

        let stride = Int(0.75 * Double(L))
        let offsets = Array(Swift.stride(from: 0, to: n, by: stride))
        var weight = [Float](repeating: 0, count: L)
        for i in 0..<(L / 2) { weight[i] = Float(i + 1) }
        for i in 0..<(L - L / 2) { weight[L / 2 + i] = Float(L - L / 2 - i) }
        let wmax = Float(L / 2)
        for i in 0..<L { weight[i] /= wmax }

        let mixArr = try MLMultiArray(shape: [1, 2, NSNumber(value: L)], dataType: .float32)
        let specArr = try MLMultiArray(shape: [1, 4, NSNumber(value: F), NSNumber(value: T)], dataType: .float32)
        var chunkOut = [[Float]](repeating: [Float](repeating: 0, count: L), count: S * 2)

        let start = Date()
        for (ci, offset) in offsets.enumerated() {
            if isCancelled() { throw CancellationError() }
            let chunkLen = min(L, n - offset)
            // TensorChunk.padded(L): centre the chunk, fill with real neighbouring audio where available.
            let delta = L - chunkLen
            let padStart = offset - delta / 2
            let mixPtr = mixArr.dataPointer.assumingMemoryBound(to: Float.self)
            for (c, src) in [normL, normR].enumerated() {
                let dst = mixPtr + c * L
                src.withUnsafeBufferPointer { s in
                    for i in 0..<L {
                        let j = padStart + i
                        dst[i] = (j >= 0 && j < n) ? s[j] : 0
                    }
                }
            }
            // Complex-as-channels spectrogram: L.re, L.im, R.re, R.im.
            let specPtr = specArr.dataPointer.assumingMemoryBound(to: Float.self)
            DispatchQueue.concurrentPerform(iterations: 2) { c in
                stft.forward(mixPtr + c * L, count: L,
                             re: specPtr + (2 * c) * F * T, im: specPtr + (2 * c + 1) * F * T)
            }

            let input = try MLDictionaryFeatureProvider(dictionary: [
                "mix": MLFeatureValue(multiArray: mixArr),
                "spec": MLFeatureValue(multiArray: specArr),
            ])
            let result = try model.prediction(from: input)
            guard let freq = result.featureValue(for: "freq")?.multiArrayValue,
                  let time = result.featureValue(for: "time")?.multiArrayValue else {
                throw CocoaError(.coderValueNotFound)
            }
            let freqPlanes = Self.contiguous(freq, planes: S * 4, planeSize: F * T)
            let timePlanes = Self.contiguous(time, planes: S * 2, planeSize: L)

            // iSTFT of each (source, channel) in parallel, plus the time branch.
            chunkOut.withUnsafeMutableBufferPointer { co in
                let coBase = co.baseAddress!
                freqPlanes.withUnsafeBufferPointer { fp in
                    timePlanes.withUnsafeBufferPointer { tp in
                        DispatchQueue.concurrentPerform(iterations: S * 2) { k in
                            let s = k / 2, c = k % 2
                            let re = fp.baseAddress! + (s * 4 + 2 * c) * F * T
                            coBase[k].withUnsafeMutableBufferPointer { dst in
                                stft.inverse(re: re, im: re + F * T, frames: T, length: L, out: dst.baseAddress!)
                                vDSP_vadd(dst.baseAddress!, 1, tp.baseAddress! + k * L, 1, dst.baseAddress!, 1, vDSP_Length(L))
                            }
                        }
                    }
                }
            }

            // center_trim to chunkLen, weight, accumulate.
            let trim = delta / 2
            for k in 0..<(S * 2) {
                chunkOut[k].withUnsafeBufferPointer { src in
                    out[k].withUnsafeMutableBufferPointer { dst in
                        weight.withUnsafeBufferPointer { w in
                            vDSP_vma(src.baseAddress! + trim, 1, w.baseAddress!, 1,
                                     dst.baseAddress! + offset, 1, dst.baseAddress! + offset, 1, vDSP_Length(chunkLen))
                        }
                    }
                }
            }
            sumWeight.withUnsafeMutableBufferPointer { sw in
                vDSP_vadd(sw.baseAddress! + offset, 1, weight, 1, sw.baseAddress! + offset, 1, vDSP_Length(chunkLen))
            }

            let elapsed = Date().timeIntervalSince(start)
            let done = ci + 1
            progress(Progress(fraction: Double(done) / Double(offsets.count), chunk: done, chunks: offsets.count,
                              secondsRemaining: elapsed / Double(done) * Double(offsets.count - done)))
        }

        // Normalise by weights and undo the input normalisation.
        var results: [StereoAudio] = []
        var inv = [Float](repeating: 0, count: n)
        var one: Float = 1
        vDSP_svdiv(&one, sumWeight, 1, &inv, 1, vDSP_Length(n))
        for s in 0..<S {
            var chans: [[Float]] = []
            for c in 0..<2 {
                var x = out[s * 2 + c]
                vDSP_vmul(x, 1, inv, 1, &x, 1, vDSP_Length(n))
                x = Self.affine(x, scale: std, offset: mean)
                chans.append(x)
                out[s * 2 + c] = []
            }
            results.append(StereoAudio(left: chans[0], right: chans[1], sampleRate: audio.sampleRate))
        }
        return results
    }

    static func affine(_ x: [Float], scale: Float, offset: Float) -> [Float] {
        var r = [Float](repeating: 0, count: x.count)
        var s = scale, o = offset
        vDSP_vsmsa(x, 1, &s, &o, &r, 1, vDSP_Length(x.count))
        return r
    }

    /// Copies an MLMultiArray whose trailing dimension may be padded into a dense [planes][planeSize] buffer.
    public static func contiguous(_ a: MLMultiArray, planes: Int, planeSize: Int) -> [Float] {
        let shape = a.shape.map(\.intValue)
        let strides = a.strides.map(\.intValue)
        let last = shape.last!
        var dense = [Float](repeating: 0, count: planes * planeSize)
        let isDense = strides.last == 1 && zip(shape.indices.dropLast(), shape.indices.dropFirst())
            .allSatisfy { strides[$0] == strides[$1] * shape[$1] }
        a.withUnsafeBufferPointer(ofType: Float.self) { src in
            if isDense {
                dense.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: src.baseAddress!, count: planes * planeSize) }
                return
            }
            // General case: iterate rows of the last dimension.
            let rows = planes * planeSize / last
            var idx = [Int](repeating: 0, count: shape.count - 1)
            dense.withUnsafeMutableBufferPointer { d in
                for r in 0..<rows {
                    var off = 0
                    for (i, v) in idx.enumerated() { off += v * strides[i] }
                    (d.baseAddress! + r * last).update(from: src.baseAddress! + off, count: last)
                    var i = idx.count - 1
                    while i >= 0 {
                        idx[i] += 1
                        if idx[i] < shape[i] { break }
                        idx[i] = 0
                        i -= 1
                    }
                }
            }
        }
        return dense
    }
}
