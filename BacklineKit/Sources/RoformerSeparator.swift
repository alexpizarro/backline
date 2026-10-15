import Accelerate
import CoreML
import Foundation

/// On-device BS-RoFormer SW (6 stems) separation: Core ML core on the GPU, STFT/iSTFT with vDSP,
/// and the MSST `demix` chunking (13.35 s chunks, 2x overlap, linear fade windows).
///
/// This is the slow, high-quality pass. It mirrors `DemucsSeparator`'s public surface
/// (same `sources` array and order, same input, same `[StereoAudio]` result, same progress
/// callback) so it can be swapped in behind the same call site. Published Multisong SDR:
/// vocals 11.30, bass 14.62, drums 14.11, guitar 9.05, piano 7.83, other 8.71
/// (HTDemucs 6s: vocals 8.05, bass 11.22, drums 10.22).
///
/// The Core ML graph covers everything between the complex STFT and the masked iSTFT:
///   spec  [1, 1151, 4100]      -> out  [1, 6, 1151, 4100]
/// where the trailing axis is `freqBin * 4 + channel * 2 + (re|im)`, matching the
/// `b (f s) t c -> b t (f c)` packing the model was trained with. See ml/convert_roformer.py.
public enum RoformerSeparatorError: LocalizedError {
    case missingOutput
    case unexpectedLayout(String)

    public var errorDescription: String? {
        switch self {
        case .missingOutput: return "The high-quality model returned no output."
        case .unexpectedLayout(let m): return "Unexpected Core ML tensor layout: \(m)"
        }
    }
}

public final class RoformerSeparator: @unchecked Sendable {
    /// Same names and order as `DemucsSeparator.sources`, so results line up when swapped in.
    public static let sources = ["drums", "bass", "other", "vocals", "guitar", "piano"]
    /// The checkpoint's own output order (yaml `training.instruments`).
    public static let modelSources = ["bass", "drums", "other", "vocals", "guitar", "piano"]
    /// `modelSources` index for each entry of `sources`.
    static let remap: [Int] = sources.map { modelSources.firstIndex(of: $0)! }

    /// Core ML pads the innermost dimension for alignment (4100 floats come back with a row
    /// stride of 4112), so the only thing we can assume is row-major with some row pitch.
    /// Returns that pitch, or nil if the tensor is not usable in place.
    static func rowPitch(_ a: MLMultiArray, shape want: [Int]) -> Int? {
        let shape = a.shape.map(\.intValue), strides = a.strides.map(\.intValue)
        guard a.dataType == .float32, shape == want, strides.last == 1 else { return nil }
        let pitch = strides[strides.count - 2]
        guard pitch >= shape[shape.count - 1] else { return nil }
        var expect = pitch
        for i in stride(from: shape.count - 2, through: 1, by: -1) {
            guard strides[i] == expect else { return nil }
            expect *= shape[i]
        }
        return strides[0] == expect ? pitch : nil
    }

    public static let chunk = 588_800            // audio.chunk_size, 13.35 s at 44.1 kHz
    public static let numOverlap = 2             // inference.num_overlap
    public static let nfft = 2048
    public static let hop = 512
    public static let frames = chunk / hop + 1   // 1151, torch.stft(center: true)
    public static let bins = nfft / 2 + 1        // 1025
    public static let flat = bins * 4            // 4100
    public static let sampleRate = 44_100.0

    public struct Progress: Sendable {
        public var fraction: Double              // 0...1 over the model passes
        public var chunk: Int
        public var chunks: Int
        public var secondsRemaining: Double?
    }

    private let model: MLModel
    private let stft: RoformerSTFT

    public init(modelURL: URL, computeUnits: MLComputeUnits = .cpuAndGPU) throws {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        config.allowLowPrecisionAccumulationOnGPU = false
        self.model = try MLModel(contentsOf: modelURL, configuration: config)
        self.stft = RoformerSTFT(nfft: Self.nfft, hop: Self.hop, frames: Self.frames)
    }

    /// Finds the compiled model in `bundle`, or compiles an `.mlpackage` (cached) for CLI/tests.
    public static func locateModel(in bundle: Bundle = .main, packageFallback: URL? = nil) async throws -> URL {
        if let url = bundle.url(forResource: "BSRoformerSW", withExtension: "mlmodelc") { return url }
        guard let pkg = packageFallback else { throw CocoaError(.fileNoSuchFile) }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("BacklineModelCache", isDirectory: true)
        let cache = dir.appendingPathComponent(pkg.deletingPathExtension().lastPathComponent + ".mlmodelc")
        if fm.fileExists(atPath: cache.path) { return cache }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let compiled = try await MLModel.compileModel(at: pkg)
        if compiled.standardizedFileURL == cache.standardizedFileURL { return cache }
        try? fm.removeItem(at: cache)
        try fm.moveItem(at: compiled, to: cache)
        return cache
    }

    /// Runs one silent chunk so GPU kernels are compiled before the first real chunk.
    public func warmUp() {
        guard let spec = try? MLMultiArray(shape: [1, NSNumber(value: Self.frames), NSNumber(value: Self.flat)],
                                           dataType: .float32),
              let input = try? MLDictionaryFeatureProvider(dictionary: ["spec": MLFeatureValue(multiArray: spec)])
        else { return }
        autoreleasepool { _ = try? model.prediction(from: input) }
    }

    /// Separates `audio` (44.1 kHz stereo). Returns planar stereo per source, in `sources` order.
    public func separate(_ audio: StereoAudio,
                         progress: @escaping @Sendable (Progress) -> Void = { _ in },
                         isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> [StereoAudio] {
        let n0 = audio.frameCount
        guard n0 > 0 else { throw CocoaError(.coderValueNotFound) }
        let L = Self.chunk
        let S = Self.sources.count
        let T = Self.frames
        let F = Self.flat
        let step = L / Self.numOverlap
        let border = L - step
        let fade = L / 10

        // demix(): reflect-pad the whole track so the first and last chunks see real audio.
        let padded = n0 > 2 * border && border > 0
        let n = padded ? n0 + 2 * border : n0
        var mix = [[Float]](repeating: [], count: 2)
        for (c, src) in [audio.left, audio.right].enumerated() {
            mix[c] = padded
                ? src.withUnsafeBufferPointer { DemucsSTFT.reflectPad($0.baseAddress!, count: n0, left: border, right: border) }
                : src
        }

        // demix() windowing_array: linear fade in/out, flat 1 in between.
        var baseWindow = [Float](repeating: 1, count: L)
        for i in 0..<fade {
            let v = Float(i) / Float(fade - 1)
            baseWindow[L - fade + i] = 1 - v
            baseWindow[i] = v
        }

        var out = [[Float]](repeating: [Float](repeating: 0, count: n), count: S * 2)
        var counter = [Float](repeating: 0, count: n)

        let specArr = try MLMultiArray(shape: [1, NSNumber(value: T), NSNumber(value: F)], dataType: .float32)
        guard let specPitch = Self.rowPitch(specArr, shape: [1, T, F]) else {
            throw RoformerSeparatorError.unexpectedLayout("input strides \(specArr.strides)")
        }
        var part = [[Float]](repeating: [Float](repeating: 0, count: L), count: 2)
        var scratch = [[Float]](repeating: [Float](repeating: 0, count: stft.olaLength), count: S * 2)
        var window = [Float](repeating: 0, count: L)

        let chunks = (n + step - 1) / step
        let start = Date()
        var ci = 0
        var offset = 0
        while offset < n {
            if isCancelled() { throw CancellationError() }
            let clen = Swift.min(L, n - offset)
            // Pad the tail chunk up to L: reflect while there is enough audio, else zeros.
            for c in 0..<2 {
                part[c].withUnsafeMutableBufferPointer { dst in
                    mix[c].withUnsafeBufferPointer { src in
                        dst.baseAddress!.update(from: src.baseAddress! + offset, count: clen)
                        if clen < L {
                            if clen > L / 2 {
                                for i in 0..<(L - clen) { dst[clen + i] = src[offset + clen - 2 - i] }
                            } else {
                                for i in clen..<L { dst[i] = 0 }
                            }
                        }
                    }
                }
            }

            let specPtr = specArr.dataPointer.assumingMemoryBound(to: Float.self)
            DispatchQueue.concurrentPerform(iterations: 2) { c in
                part[c].withUnsafeBufferPointer { src in
                    stft.forward(src.baseAddress!, channel: c, into: specPtr, rowStride: specPitch)
                }
            }

            try autoreleasepool {
                let input = try MLDictionaryFeatureProvider(dictionary: ["spec": MLFeatureValue(multiArray: specArr)])
                let result = try model.prediction(from: input)
                guard let outArr = result.featureValue(for: "out")?.multiArrayValue else {
                    throw RoformerSeparatorError.missingOutput
                }
                // The iSTFT reads this tensor in place (113 MB a chunk), so it has to be
                // row-major float32 in [1, stem, frame, bin*4 + chan*2 + (re|im)] order.
                guard let pitch = Self.rowPitch(outArr, shape: [1, S, T, F]) else {
                    throw RoformerSeparatorError.unexpectedLayout(
                        "out shape \(outArr.shape) strides \(outArr.strides) dataType \(outArr.dataType.rawValue)")
                }

                // demix(): no fade-in on the first chunk, no fade-out on the last.
                window.withUnsafeMutableBufferPointer { w in
                    baseWindow.withUnsafeBufferPointer { b in w.baseAddress!.update(from: b.baseAddress!, count: L) }
                    if offset == 0 {
                        for i in 0..<fade { w[i] = 1 }
                    } else if offset + step >= n {
                        for i in 0..<fade { w[L - fade + i] = 1 }
                    }
                }

                outArr.withUnsafeBufferPointer(ofType: Float.self) { modelOut in
                    let base = modelOut.baseAddress!
                    let off = offset
                    scratch.withUnsafeMutableBufferPointer { sc in
                        let scBase = sc.baseAddress!
                        out.withUnsafeMutableBufferPointer { acc in
                            let accBase = acc.baseAddress!
                            window.withUnsafeBufferPointer { w in
                                DispatchQueue.concurrentPerform(iterations: S * 2) { k in
                                    let s = Self.remap[k / 2], c = k % 2
                                    let plane = base + s * T * pitch + c * 2
                                    scBase[k].withUnsafeMutableBufferPointer { ola in
                                        self.stft.inverse(plane, rowStride: pitch, into: ola.baseAddress!)
                                        // ola now holds the un-normalised overlap-add; scale, window, accumulate.
                                        let y = ola.baseAddress! + self.stft.trim
                                        self.stft.applyWindowSum(y, count: clen)
                                        accBase[k].withUnsafeMutableBufferPointer { dst in
                                            vDSP_vma(y, 1, w.baseAddress!, 1, dst.baseAddress! + off, 1,
                                                     dst.baseAddress! + off, 1, vDSP_Length(clen))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            counter.withUnsafeMutableBufferPointer { cp in
                vDSP_vadd(cp.baseAddress! + offset, 1, window, 1, cp.baseAddress! + offset, 1, vDSP_Length(clen))
            }

            offset += step
            ci += 1
            let elapsed = Date().timeIntervalSince(start)
            progress(Progress(fraction: Double(ci) / Double(chunks), chunk: ci, chunks: chunks,
                              secondsRemaining: elapsed / Double(ci) * Double(Swift.max(0, chunks - ci))))
        }

        // result / counter, then drop the reflect padding.
        var inv = [Float](repeating: 0, count: n)
        for i in 0..<n { inv[i] = counter[i] > 0 ? 1 / counter[i] : 0 }
        let trim = padded ? border : 0
        var results: [StereoAudio] = []
        results.reserveCapacity(S)
        for s in 0..<S {
            var chans: [[Float]] = []
            for c in 0..<2 {
                var x = [Float](repeating: 0, count: n0)
                out[s * 2 + c].withUnsafeBufferPointer { src in
                    inv.withUnsafeBufferPointer { iv in
                        vDSP_vmul(src.baseAddress! + trim, 1, iv.baseAddress! + trim, 1, &x, 1, vDSP_Length(n0))
                    }
                }
                chans.append(x)
                out[s * 2 + c] = []
            }
            results.append(StereoAudio(left: chans[0], right: chans[1], sampleRate: audio.sampleRate))
        }
        return results
    }
}

/// STFT / iSTFT matching `torch.stft(2048, 512, hann(2048), center=True, pad_mode="reflect",
/// normalized=False)` and `torch.istft(..., length=chunk)`, implemented with vDSP and writing
/// straight into / reading straight out of the Core ML tensor layout
/// (trailing axis `freqBin * 4 + channel * 2 + (re|im)`).
final class RoformerSTFT: @unchecked Sendable {
    let nfft: Int
    let hop: Int
    let frames: Int
    let bins: Int                  // nfft / 2 + 1, Nyquist kept
    let length: Int                // samples the forward consumes / the inverse produces
    let olaLength: Int             // (frames - 1) * hop + nfft
    let trim: Int                  // istft(center: true) drops nfft / 2 from the front
    private let half: Int          // nfft / 2
    private let log2n: vDSP_Length
    private let fft: FFTSetup
    private let window: [Float]
    private let invWindowSum: [Float]   // 1 / overlap-added window^2, zero where unusable

    init(nfft: Int, hop: Int, frames: Int) {
        self.nfft = nfft
        self.hop = hop
        self.frames = frames
        self.bins = nfft / 2 + 1
        self.half = nfft / 2
        self.length = (frames - 1) * hop
        self.olaLength = (frames - 1) * hop + nfft
        self.trim = nfft / 2
        self.log2n = vDSP_Length(log2(Double(nfft)).rounded())
        self.fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        // torch.hann_window is periodic.
        var w = [Float](repeating: 0, count: nfft)
        for i in 0..<nfft { w[i] = 0.5 - 0.5 * cos(2 * .pi * Float(i) / Float(nfft)) }
        self.window = w
        // torch.istft divides the overlap-add by the overlap-added squared window.
        var wsum = [Float](repeating: 0, count: olaLength)
        for f in 0..<frames {
            for i in 0..<nfft { wsum[f * hop + i] += w[i] * w[i] }
        }
        self.invWindowSum = wsum.map { $0 > 1e-11 ? 1 / $0 : 0 }
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    /// numpy/torch "reflect" pad of one channel, then the framed forward transform.
    /// Writes bins 0...1024 of `channel` into `dst` at `t * rowStride + f * 4 + channel * 2 + c`
    /// (`rowStride` is the tensor's row pitch, which Core ML may pad above `bins * 4`).
    func forward(_ x: UnsafePointer<Float>, channel: Int, into dst: UnsafeMutablePointer<Float>,
                 rowStride: Int) {
        let padded = Self.reflect(x, count: length, pad: half)
        var frame = [Float](repeating: 0, count: nfft)
        var re = [Float](repeating: 0, count: half)
        var im = [Float](repeating: 0, count: half)
        var scale: Float = 0.5      // vDSP's packed real forward returns twice the DFT
        padded.withUnsafeBufferPointer { src in
            for t in 0..<frames {
                vDSP_vmul(src.baseAddress! + t * hop, 1, window, 1, &frame, 1, vDSP_Length(nfft))
                re.withUnsafeMutableBufferPointer { rp in
                    im.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        frame.withUnsafeBufferPointer { fp in
                            fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                            }
                        }
                        vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        // Packed layout: realp[0] = DC, imagp[0] = Nyquist, both purely real.
                        // Scatter into the model's (f * 4 + channel * 2 + c) layout, halving as we go.
                        let row = dst + t * rowStride + channel * 2
                        vDSP_vsmul(rp.baseAddress!, 1, &scale, row, 4, vDSP_Length(half))             // re, bins 0..<1024
                        vDSP_vsmul(ip.baseAddress! + 1, 1, &scale, row + 5, 4, vDSP_Length(half - 1)) // im, bins 1..<1024
                        row[1] = 0                                                        // DC has no imaginary part
                        row[half * 4] = ip.baseAddress![0] * scale                        // Nyquist, real
                        row[half * 4 + 1] = 0
                    }
                }
            }
        }
    }

    /// Inverse of `forward` for one (stem, channel) plane of the model output.
    /// `src` points at `out[stem][0][channel * 2]`; bin f of frame t is `src[t * rowStride + f * 4]`.
    /// Writes the raw overlap-add (not yet divided by the window sum) into `ola`, length `olaLength`.
    func inverse(_ src: UnsafePointer<Float>, rowStride: Int, into ola: UnsafeMutablePointer<Float>) {
        vDSP_vclr(ola, 1, vDSP_Length(olaLength))
        var re = [Float](repeating: 0, count: half)
        var im = [Float](repeating: 0, count: half)
        var frame = [Float](repeating: 0, count: nfft)
        // Undo vDSP's unnormalised inverse; torch's irfft carries the 1/nfft.
        var scale = 1 / Float(nfft)
        for t in 0..<frames {
            let row = src + t * rowStride
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    row.withMemoryRebound(to: DSPComplex.self, capacity: half * 2) {
                        vDSP_ctoz($0, 4, &split, 1, vDSP_Length(half))
                    }
                    // irfft treats the signal as Hermitian: DC and Nyquist are real, and the
                    // imaginary part the mask put on them is discarded. Pack Nyquist into imagp[0].
                    ip.baseAddress![0] = row[half * 4]
                    vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                    frame.withUnsafeMutableBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
                        }
                    }
                    vDSP_vsmul(frame, 1, &scale, &frame, 1, vDSP_Length(nfft))
                    vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(nfft))
                    vDSP_vadd(ola + t * hop, 1, frame, 1, ola + t * hop, 1, vDSP_Length(nfft))
                }
            }
        }
    }

    /// Divides `count` samples of a trimmed `inverse` result by the overlap-added squared window.
    func applyWindowSum(_ y: UnsafeMutablePointer<Float>, count: Int) {
        invWindowSum.withUnsafeBufferPointer { iw in
            vDSP_vmul(y, 1, iw.baseAddress! + trim, 1, y, 1, vDSP_Length(count))
        }
    }

    /// numpy/torch "reflect": the edge sample is not repeated.
    static func reflect(_ x: UnsafePointer<Float>, count n: Int, pad: Int) -> [Float] {
        var out = [Float](repeating: 0, count: n + 2 * pad)
        out.withUnsafeMutableBufferPointer { o in
            for i in 0..<pad { o[i] = x[pad - i] }
            (o.baseAddress! + pad).update(from: x, count: n)
            for i in 0..<pad { o[pad + n + i] = x[n - 2 - i] }
        }
        return out
    }
}
