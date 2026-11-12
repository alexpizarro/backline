import Accelerate
import CoreML
import Foundation

/// STFT / iSTFT matching MDX23C's `models/mdx23c_tfc_tdf_v3.py::STFT`, i.e. plain
/// `torch.stft(n_fft, hop, hann_periodic, center=True, pad_mode="reflect", normalized=False)`
/// truncated to `dim_f` bins, and `torch.istft(..., center=True)` after zero-filling the
/// bins above `dim_f`.
///
/// This is deliberately not `DemucsSTFT`: Demucs normalises the transform (1/sqrt(n_fft))
/// and adds its own `_spec` / `_ispec` padding on top of `center=True`. MDX23C does neither.
final class MDXSTFT {
    let nfft: Int
    let hop: Int
    let bins: Int                 // dim_f: bins kept (bins..n_fft/2 are zero on the way back)
    private let log2n: vDSP_Length
    private let fft: FFTSetup
    private let window: [Float]
    private let windowSq: [Float]
    /// 1 / window-square-envelope for the one frame count we use, cached because every
    /// (part, channel) iSTFT of every chunk shares it.
    private let envelopeRecip: [Float]
    private let envelopeFrames: Int

    init(nfft: Int = 2048, hop: Int = 512, bins: Int = 1024, frames: Int) {
        self.nfft = nfft
        self.hop = hop
        self.bins = bins
        self.log2n = vDSP_Length(log2(Double(nfft)))
        self.fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        var w = [Float](repeating: 0, count: nfft)
        for i in 0..<nfft { w[i] = 0.5 - 0.5 * cos(2 * .pi * Float(i) / Float(nfft)) }  // periodic hann
        self.window = w
        var wsq = [Float](repeating: 0, count: nfft)
        vDSP_vsq(w, 1, &wsq, 1, vDSP_Length(nfft))
        self.windowSq = wsq
        // torch.istft divides by the window-square sum over exactly the frames present,
        // so the taper at the very edges is reproduced rather than assumed constant.
        let olaLen = (frames - 1) * hop + nfft
        var env = [Float](repeating: 0, count: olaLen)
        env.withUnsafeMutableBufferPointer { e in
            for f in 0..<frames {
                vDSP_vadd(e.baseAddress! + f * hop, 1, wsq, 1, e.baseAddress! + f * hop, 1, vDSP_Length(nfft))
            }
        }
        for i in 0..<olaLen { env[i] = env[i] > 1e-11 ? 1 / env[i] : 0 }
        self.envelopeRecip = env
        self.envelopeFrames = frames
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    /// Frames `torch.stft(center: true)` produces for `length` samples.
    static func frames(for length: Int, hop: Int) -> Int { length / hop + 1 }

    /// Samples `torch.istft(center: true, length: nil)` returns for `frames` frames.
    static func length(forFrames frames: Int, hop: Int) -> Int { hop * (frames - 1) }

    /// Complex-as-channels spectrogram of one channel, `bins` kept.
    /// Writes `re` / `im` as [bins][frames] planes (frames fastest), matching the Core ML input.
    func forward(_ x: UnsafePointer<Float>, count length: Int,
                 re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>) {
        let T = Self.frames(for: length, hop: hop)
        let half = nfft / 2
        // center=True: reflect-pad n_fft/2 on both sides.
        let padded = DemucsSTFT.reflectPad(x, count: length, left: half, right: half)
        var frame = [Float](repeating: 0, count: nfft)
        var sr = [Float](repeating: 0, count: half)
        var si = [Float](repeating: 0, count: half)
        // vDSP_fft_zrip's packed-real forward returns 2x the true DFT; normalized=False
        // means no further scaling.
        let scale: Float = 0.5
        padded.withUnsafeBufferPointer { src in
            for t in 0..<T {
                vDSP_vmul(src.baseAddress! + t * hop, 1, window, 1, &frame, 1, vDSP_Length(nfft))
                sr.withUnsafeMutableBufferPointer { srp in
                    si.withUnsafeMutableBufferPointer { sip in
                        var split = DSPSplitComplex(realp: srp.baseAddress!, imagp: sip.baseAddress!)
                        frame.withUnsafeBufferPointer { fp in
                            fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                            }
                        }
                        vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    }
                }
                // Bin 0 is DC (real); vDSP hides Nyquist in si[0], which bin < dim_f never reads.
                re[t] = sr[0] * scale
                im[t] = 0
                for k in 1..<bins {
                    re[k * T + t] = sr[k] * scale
                    im[k * T + t] = si[k] * scale
                }
            }
        }
    }

    /// Inverse of `forward`: bins above `bins` are treated as zero, as MDX23C's `f_pad` does.
    func inverse(re: UnsafePointer<Float>, im: UnsafePointer<Float>, frames T: Int,
                 out: UnsafeMutablePointer<Float>) {
        precondition(T == envelopeFrames, "MDXSTFT caches the envelope for \(envelopeFrames) frames")
        let half = nfft / 2
        let olaLen = (T - 1) * hop + nfft
        var ola = [Float](repeating: 0, count: olaLen)
        var sr = [Float](repeating: 0, count: half)
        var si = [Float](repeating: 0, count: half)
        var frame = [Float](repeating: 0, count: nfft)
        // Feeding true (1x) DFT values to vDSP's packed inverse yields n_fft * x.
        var invScale = 1 / Float(nfft)
        ola.withUnsafeMutableBufferPointer { o in
            for t in 0..<T {
                sr[0] = re[t]
                si[0] = 0                       // Nyquist: zero, as in MDX23C's inverse
                for k in 1..<half {
                    sr[k] = k < bins ? re[k * T + t] : 0
                    si[k] = k < bins ? im[k * T + t] : 0
                }
                sr.withUnsafeMutableBufferPointer { srp in
                    si.withUnsafeMutableBufferPointer { sip in
                        var split = DSPSplitComplex(realp: srp.baseAddress!, imagp: sip.baseAddress!)
                        vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                        frame.withUnsafeMutableBufferPointer { fp in
                            fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                                vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
                            }
                        }
                    }
                }
                vDSP_vsmul(frame, 1, &invScale, &frame, 1, vDSP_Length(nfft))
                vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(nfft))
                vDSP_vadd(o.baseAddress! + t * hop, 1, frame, 1, o.baseAddress! + t * hop, 1, vDSP_Length(nfft))
            }
        }
        // center=True trims n_fft/2 from each end; divide by the window-square envelope.
        let n = Self.length(forFrames: T, hop: hop)
        ola.withUnsafeBufferPointer { o in
            envelopeRecip.withUnsafeBufferPointer { e in
                vDSP_vmul(o.baseAddress! + half, 1, e.baseAddress! + half, 1, out, 1, vDSP_Length(n))
            }
        }
    }
}

/// On-device drum-kit separation: MDX23C DrumSep (5 parts, by jarredou) as a Core ML core on
/// the GPU with the STFT / iSTFT in Swift (vDSP), and MSST's `demix` "generic" chunking
/// (11.876 s chunks, 4x overlap, linear cross-fade at the chunk edges, reflect-padded borders).
///
/// Shaped like `LeadSeparator`: hand it a drums stem, get the kit pieces back.
public final class DrumSeparator: @unchecked Sendable {
    /// Output order of the Core ML `freq` tensor.
    public static let parts = ["kick", "snare", "toms", "hh", "cymbals"]
    /// Key added alongside `parts` so the pieces stay additive: input minus the sum of the parts.
    public static let restKey = "rest"
    public static let modelName = "DrumSepMDX23C"

    public static let chunk = 523_776            // config audio.chunk_size (11.876 s at 44.1 kHz)
    public static let nfft = 2048
    public static let hop = 512
    public static let dimF = 1024
    /// config inference.num_overlap. Every sample is separated this many times and the
    /// estimates averaged, so runtime is linear in it.
    public static let numOverlap = 4
    public static let sampleRate = 44_100.0

    static let frames = MDXSTFT.frames(for: chunk, hop: hop)   // 1024
    static let fade = chunk / 10                               // 52_377

    /// How many times each sample is separated and averaged. 4 reproduces the upstream
    /// reference; lower trades a little quality for proportionally less time. Values below
    /// 2 are rejected: at overlap 1 consecutive chunks only meet inside the fade, so the
    /// accumulated weight falls to zero at every chunk boundary.
    public let overlap: Int
    private var step: Int { Self.chunk / overlap }
    private var border: Int { Self.chunk - Self.chunk / overlap }

    /// A chunk whose drums average below this mean square (-70 dBFS, both channels) is not sent to the model:
    /// its parts are zero there and the chunk's weight still counts, so `rest` takes whatever is left and the
    /// pieces still add up to the drums exactly (split F10). Drumless intros, breaks and outros are skipped.
    /// The quietest chunk of drums in the fixtures sits far above it (see DrumSeparatorTests).
    public static let silentMeanSquare: Float = 1e-7
    /// Weights at or below this count as none when the parts are divided by them.
    static let weightFloor: Float = 1e-6
    let skipBelow: Float

    private let model: MLModel?
    /// Runs the model on one `spec` tensor and returns its `freq` tensor.
    private let predict: (MLMultiArray, () -> Bool) throws -> MLMultiArray
    private let stft = MDXSTFT(nfft: nfft, hop: hop, bins: dimF, frames: frames)

    public init(modelURL: URL, computeUnits: MLComputeUnits = .cpuOnly,
                overlap: Int = DrumSeparator.numOverlap) throws {
        precondition(overlap >= 2, "overlap must be >= 2")
        self.overlap = overlap
        // The GPU is left alone on purpose. Measured on an iPhone 15 Pro (20 s of a real song, both
        // backends on the identical chunk): .cpuAndGPU returns stems that correlate only 0.85-0.92 with
        // a Mac reference and whose sum is -14.5 dB from the mix, while .cpuOnly scores 0.94-0.9997 and
        // -35.2 dB. The FP16 mlprogram graph is not numerically sound on the device GPU. CPU is also
        // slightly faster there (37 s vs 43 s), so nothing is given up. Checked by --diag-roformer.
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        config.allowLowPrecisionAccumulationOnGPU = false
        let model = try MLModel(contentsOf: modelURL, configuration: config)
        self.model = model
        self.skipBelow = Self.silentMeanSquare
        self.predict = { spec, isCancelled in
            let result = try DemucsSeparator.predict(model, MLDictionaryFeatureProvider(dictionary: [
                "spec": MLFeatureValue(multiArray: spec),
            ]), isCancelled: isCancelled)
            guard let freq = result.featureValue(for: "freq")?.multiArrayValue else {
                throw CocoaError(.coderValueNotFound)
            }
            return freq
        }
    }

    /// For tests: `predict` stands in for the model; `skipBelow` 0 sends every chunk to it.
    init(overlap: Int, skipBelow: Float = DrumSeparator.silentMeanSquare,
         predict: @escaping (MLMultiArray, () -> Bool) throws -> MLMultiArray) {
        precondition(overlap >= 2, "overlap must be >= 2")
        self.overlap = overlap
        self.model = nil
        self.skipBelow = skipBelow
        self.predict = predict
    }

    /// The bundled compiled model, if the app ever ships one.
    public static func bundledModel(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: modelName, withExtension: "mlmodelc")
    }

    /// Runs one silent chunk so the Metal kernels are compiled before the first real call.
    public func warmUp() {
        guard let model, let spec = try? MLMultiArray(shape: [1, 4, NSNumber(value: Self.dimF), NSNumber(value: Self.frames)],
                                           dataType: .float32),
              let input = try? MLDictionaryFeatureProvider(dictionary: ["spec": MLFeatureValue(multiArray: spec)])
        else { return }
        _ = try? model.prediction(from: input)
    }

    /// Splits a drums stem (44.1 kHz stereo) into kit pieces.
    ///
    /// Returns one entry per `parts` plus `restKey`, so `sum(result.values) == drums` to
    /// float precision. MDX23C is not mask-constrained, so the five parts alone do not sum
    /// to the input.
    ///
    /// With a `checkpoint`, finished audio is kept on disk as it is made, and a run stopped part-way carries on
    /// where it stopped: it gives the same samples as a run that was never stopped.
    public func separate(_ drums: StereoAudio,
                         checkpoint: SeparationCheckpoint? = nil,
                         progress: ((Double) -> Void)? = nil,
                         isCancelled: () -> Bool = { false }) throws -> [String: StereoAudio] {
        let n = drums.frameCount
        guard n > 0 else { throw CocoaError(.coderValueNotFound) }
        let L = Self.chunk, F = Self.dimF, T = Self.frames
        let P = Self.parts.count
        let step = self.step, fade = Self.fade

        // demix(): reflect-pad the whole track by `border` so chunk-edge artefacts land
        // outside the real audio. Skipped for short inputs, exactly as upstream does.
        let doPad = n > 2 * self.border && self.border > 0
        let border = doPad ? self.border : 0
        var padded: [[Float]] = [drums.left, drums.right].map { ch in
            guard doPad else { return ch }
            return ch.withUnsafeBufferPointer {
                DemucsSTFT.reflectPad($0.baseAddress!, count: n, left: border, right: border)
            }
        }
        let padLen = padded[0].count

        var acc = [[Float]](repeating: [Float](repeating: 0, count: padLen), count: P * 2)
        var counter = [Float](repeating: 0, count: padLen)

        // Fade window; the first chunk keeps a hard start and the last a hard end.
        var baseWindow = [Float](repeating: 1, count: L)
        for i in 0..<fade {
            let v = Float(i) / Float(fade - 1)
            baseWindow[i] = v
            baseWindow[L - fade + i] = 1 - v
        }

        let specArr = try MLMultiArray(shape: [1, 4, NSNumber(value: F), NSNumber(value: T)], dataType: .float32)
        var chunkIn = [Float](repeating: 0, count: 2 * L)
        var wave = [[Float]](repeating: [Float](repeating: 0, count: L), count: P * 2)
        var window = [Float](repeating: 0, count: L)

        let offsets = Array(stride(from: 0, to: padLen, by: step))
        // A run that was stopped kept the final samples below `resumeFrom`: only the chunks that reach past them are
        // computed again, from nothing, and the kept samples are put back over them at the end.
        var writer = CheckpointWriter.open(checkpoint, total: padLen, step: step, channels: P * 2,
                                           scale: .reciprocal(above: Self.weightFloor))
        let resumeFrom = writer?.resumeFrom ?? 0
        let first = CheckpointWriter.firstChunk(offsets, resumeFrom: resumeFrom) { min(L, padLen - $0) }
        // No later chunk reaches below `i + step`: those samples are final and go to the checkpoint.
        func chunkDone(_ ci: Int, _ i: Int) {
            if let w = writer, (try? w.append(upTo: min(i + step, padLen), accumulated: acc, weight: counter)) == nil {
                writer = nil
            }
            progress?(Double(ci + 1) / Double(offsets.count))
        }
        for ci in first..<offsets.count {
            let i = offsets[ci]
            if isCancelled() { throw CancellationError() }
            let seg = min(L, padLen - i)

            window.withUnsafeMutableBufferPointer { w in
                baseWindow.withUnsafeBufferPointer { b in w.baseAddress!.update(from: b.baseAddress!, count: L) }
                if i == 0 { w.baseAddress!.update(repeating: 1, count: fade) }
                else if i + step >= padLen { (w.baseAddress! + L - fade).update(repeating: 1, count: fade) }
            }

            // Silent drums: zeros for every part (nothing added), but the chunk's weight still counts.
            var power: Float = 0
            for c in 0..<2 {
                var ms: Float = 0
                padded[c].withUnsafeBufferPointer { vDSP_measqv($0.baseAddress! + i, 1, &ms, vDSP_Length(seg)) }
                power += ms / 2
            }
            if power < skipBelow {
                counter.withUnsafeMutableBufferPointer { cp in
                    window.withUnsafeBufferPointer { w in
                        vDSP_vadd(cp.baseAddress! + i, 1, w.baseAddress!, 1, cp.baseAddress! + i, 1, vDSP_Length(seg))
                    }
                }
                chunkDone(ci, i)
                continue
            }

            // Chunk, right-padded to L: reflect while more than half the chunk is real audio
            // (upstream's rule), zeros otherwise.
            chunkIn.withUnsafeMutableBufferPointer { dst in
                for c in 0..<2 {
                    let d = dst.baseAddress! + c * L
                    padded[c].withUnsafeBufferPointer { s in d.update(from: s.baseAddress! + i, count: seg) }
                    if seg < L {
                        if seg > L / 2 {
                            // numpy/torch reflect: pad[j] = x[seg - 2 - j]
                            for j in 0..<(L - seg) { d[seg + j] = d[seg - 2 - j] }
                        } else {
                            (d + seg).update(repeating: 0, count: L - seg)
                        }
                    }
                }
            }

            let specPtr = specArr.dataPointer.assumingMemoryBound(to: Float.self)
            chunkIn.withUnsafeBufferPointer { src in
                DispatchQueue.concurrentPerform(iterations: 2) { c in
                    stft.forward(src.baseAddress! + c * L, count: L,
                                 re: specPtr + (2 * c) * F * T, im: specPtr + (2 * c + 1) * F * T)
                }
            }

            let freq = try predict(specArr, isCancelled)

            // iSTFT every (part, channel) in parallel.
            Self.withPlanes(freq, planes: P * 4, planeSize: F * T) { f in
                wave.withUnsafeMutableBufferPointer { ww in
                    let base = ww.baseAddress!
                    DispatchQueue.concurrentPerform(iterations: P * 2) { k in
                        let p = k / 2, c = k % 2
                        let re = f + (p * 4 + 2 * c) * F * T
                        base[k].withUnsafeMutableBufferPointer { d in
                            stft.inverse(re: re, im: re + F * T, frames: T, out: d.baseAddress!)
                        }
                    }
                }
            }

            for k in 0..<(P * 2) {
                wave[k].withUnsafeBufferPointer { src in
                    acc[k].withUnsafeMutableBufferPointer { dst in
                        window.withUnsafeBufferPointer { w in
                            vDSP_vma(src.baseAddress!, 1, w.baseAddress!, 1,
                                     dst.baseAddress! + i, 1, dst.baseAddress! + i, 1, vDSP_Length(seg))
                        }
                    }
                }
            }
            counter.withUnsafeMutableBufferPointer { cp in
                window.withUnsafeBufferPointer { w in
                    vDSP_vadd(cp.baseAddress! + i, 1, w.baseAddress!, 1, cp.baseAddress! + i, 1, vDSP_Length(seg))
                }
            }
            chunkDone(ci, i)
        }
        padded = []
        if let w = writer, w.resumeFrom > 0, (try? w.restorePrefix(into: &acc, weight: &counter)) == nil {
            // The kept samples couldn't be read back after all: the whole split again, from nothing.
            writer = nil
            checkpoint?.discard()
            return try separate(drums, checkpoint: checkpoint, progress: progress, isCancelled: isCancelled)
        }
        writer = nil

        // Normalise by the accumulated weights, then drop the reflect-padded border.
        // A weight of ~0 only happens where the numerator is ~0 too (the very last sample
        // of a single-chunk input), so emitting 0 there avoids a 0/0.
        var inv = [Float](repeating: 0, count: padLen)
        for j in 0..<padLen { inv[j] = counter[j] > Self.weightFloor ? 1 / counter[j] : 0 }

        var out: [String: StereoAudio] = [:]
        var sum = [[Float]](repeating: [Float](repeating: 0, count: n), count: 2)
        for p in 0..<P {
            var chans: [[Float]] = []
            for c in 0..<2 {
                var x = [Float](repeating: 0, count: n)
                acc[p * 2 + c].withUnsafeBufferPointer { a in
                    inv.withUnsafeBufferPointer { iv in
                        x.withUnsafeMutableBufferPointer { d in
                            vDSP_vmul(a.baseAddress! + border, 1, iv.baseAddress! + border, 1,
                                      d.baseAddress!, 1, vDSP_Length(n))
                        }
                    }
                }
                acc[p * 2 + c] = []
                sum[c].withUnsafeMutableBufferPointer { s in
                    vDSP_vadd(s.baseAddress!, 1, x, 1, s.baseAddress!, 1, vDSP_Length(n))
                }
                chans.append(x)
            }
            out[Self.parts[p]] = StereoAudio(left: chans[0], right: chans[1], sampleRate: drums.sampleRate)
        }

        var rest: [[Float]] = []
        for (c, src) in [drums.left, drums.right].enumerated() {
            var r = [Float](repeating: 0, count: n)
            vDSP_vsub(sum[c], 1, src, 1, &r, 1, vDSP_Length(n))   // src - sum
            rest.append(r)
        }
        out[Self.restKey] = StereoAudio(left: rest[0], right: rest[1], sampleRate: drums.sampleRate)
        return out
    }

    /// Calls `body` with a dense [planes][planeSize] Float buffer for `a`, copying only if
    /// Core ML handed back padded strides.
    private static func withPlanes(_ a: MLMultiArray, planes: Int, planeSize: Int,
                                   _ body: (UnsafePointer<Float>) -> Void) {
        let shape = a.shape.map(\.intValue), strides = a.strides.map(\.intValue)
        let dense = strides.last == 1 && zip(shape.indices.dropLast(), shape.indices.dropFirst())
            .allSatisfy { strides[$0] == strides[$1] * shape[$1] }
        if dense {
            a.withUnsafeBufferPointer(ofType: Float.self) { body($0.baseAddress!) }
        } else {
            DemucsSeparator.contiguous(a, planes: planes, planeSize: planeSize)
                .withUnsafeBufferPointer { body($0.baseAddress!) }
        }
    }
}
