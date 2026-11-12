import Accelerate
import Foundation

/// Lead vs rhythm guitar split of a stereo guitar stem by stereo position (no ML).
///
/// Metal/rock convention: rhythm guitars are double/quad-tracked and panned hard left/right, so they are
/// decorrelated between channels; a lead or solo is usually one take panned centre, so it is coherent.
/// Per STFT bin the smoothed 2×2 channel covariance is modelled as a coherent centre source plus
/// independent left/right beds ("coherent-centre Wiener" mask), refined by a register prior (palm-muted
/// low end → rhythm) and a per-frame gate that opens only while a centred part is actually playing.
/// rhythm = guitar − lead in the time domain, so lead + rhythm reconstructs the stem exactly.
///
/// Port of `ml/guitar_split_proto.py` (same defaults).
public enum GuitarSplitter {
    public struct Params: Sendable {
        public var nfft = 4096
        public var hop = 1024
        public var smoothT = 15            // covariance smoothing, frames (~350 ms)
        public var fLo: Float = 120        // register prior: lead weight 0 below …
        public var fHi: Float = 450        // … 1 above (smoothstep on log f)
        public var gateLo: Float = 300, gateHi: Float = 5000
        public var gateMargin: Float = 0.06, gateWidth: Float = 0.12
        public var gateBasePct: Float = 20, gateSmooth = 21, gateFloor: Float = 0.15
        public var maskSmoothT = 3, maskSmoothF = 3
        public var floor: Float = 0.02
        /// Below this the split is still offered (it beat whole-guitar removal on every song of the
        /// ground-truth set, including low-confidence ones) but flagged as approximate. Only a near-mono
        /// guitar stem, where the split degenerates into a crossover filter, is left unsplit.
        public var minWidth = 0.12
        /// Tests: the width's sums taken element by element in double precision (the exact figure).
        var exactSums = false
        public init() {}
    }

    public struct Result: Sendable {
        public var lead: StereoAudio
        public var rhythm: StereoAudio
        public var confidence: Double
        public var width: Double           // share of guitar energy that is not coherent-centre
        public var leadDynamics: Double    // p90 − p10 of the per-2 s lead share
        public var shouldSplit: Bool

        public init(lead: StereoAudio, rhythm: StereoAudio, confidence: Double, width: Double,
                    leadDynamics: Double, shouldSplit: Bool) {
            self.lead = lead; self.rhythm = rhythm; self.confidence = confidence
            self.width = width; self.leadDynamics = leadDynamics; self.shouldSplit = shouldSplit
        }
    }

    /// Splits `guitar` (44.1 kHz stereo). Returns the lead and, unless `withRhythm` is false, the rhythm
    /// (guitar − lead); check `shouldSplit` before showing them. A caller that makes its own rhythm (the import
    /// takes the lead out of guitar and Other) passes false and gets an empty `rhythm`, one song copy fewer.
    ///
    /// Streams (split F3): the gate's base is a percentile over the whole song, so the song is read twice,
    /// frame by frame. Pass 1 takes the spectra, smooths the channel covariances through a ring of rows and
    /// keeps only each frame's gate inputs and the width sums. Pass 2 takes the spectra again, rebuilds the
    /// smoothed covariances, makes each frame's masks and adds the masked inverse straight into the lead. Beside
    /// its input and outputs it holds a few hundred frames of spectra (about 10 MB), where the whole-song planes
    /// held 9 to 13 song copies. Every frame goes through the same arithmetic in the same order as the
    /// whole-array version did; only the width's sums are taken a row at a time.
    public static func split(_ guitar: StereoAudio, params p: Params = Params(), withRhythm: Bool = true) -> Result {
        let n = guitar.frameCount
        let N = p.nfft, hop = p.hop, bins = N / 2 + 1, half = N / 2
        let sr = Float(guitar.sampleRate)
        let pad = N / 2
        let frames = Int((Double(n + 2 * pad - N) / Double(hop)).rounded(.up)) + 1
        let nb = vDSP_Length(bins)
        let eps: Float = 1e-12
        let stft = Spectra(size: N, hop: hop, pad: pad)
        // Frames whose spectra are taken at once (in parallel); the rest of the work goes a frame at a time.
        let block = 128
        let hT = RowBox.half(p.smoothT), hM = RowBox.half(p.maskSmoothT)

        // Raw covariance rows of one frame: PLL = |XL|², PRR = |XR|², C = Re(XL · conj XR). The second term is
        // a fused multiply-add, as `vDSP_vma` computes it over a whole song (over one row it mostly doesn't).
        func covariance(_ s: Spectra.Rows, _ pll: UnsafeMutablePointer<Float>, _ prr: UnsafeMutablePointer<Float>,
                        _ c: UnsafeMutablePointer<Float>) {
            for k in 0..<bins {
                pll[k] = (s.reL[k] * s.reL[k]).addingProduct(s.imL[k], s.imL[k])
                prr[k] = (s.reR[k] * s.reR[k]).addingProduct(s.imR[k], s.imR[k])
                c[k] = (s.reL[k] * s.reR[k]).addingProduct(s.imL[k], s.imR[k])
            }
        }

        // Pass 1: per frame, the gate's coherence and energy in the lead band; over the song, the width's sums.
        let kLo = Int((p.gateLo * Float(N) / sr).rounded(.up)), kHi = min(bins, Int(p.gateHi * Float(N) / sr))
        var coh = [Float](repeating: 0, count: frames), eb = coh
        var sumS = 0.0, sumL = 0.0, sumR = 0.0
        do {
            let store = Spectra.Store(bins: bins, capacity: block)
            var boxL = RowBox(bins: bins, frames: frames, size: p.smoothT)
            var boxR = boxL, boxC = boxL
            let raw = Row(bins: bins, count: 3), smooth = Row(bins: bins, count: 3)
            let (rl, rr, rc) = (raw.at(0), raw.at(1), raw.at(2))
            let (sl, sr_, sc) = (smooth.at(0), smooth.at(1), smooth.at(2))
            var b0 = 0
            while b0 < frames {
                let b1 = min(frames, b0 + block)
                stft.forward(guitar, frames: b0..<b1, into: store)
                for t in b0..<b1 {
                    covariance(store.rows(t), rl, rr, rc)
                    boxL.push(rl); boxR.push(rr); boxC.push(rc)
                    while let e = boxL.emit(into: sl) {
                        _ = boxR.emit(into: sr_); _ = boxC.emit(into: sc)
                        var zero: Float = 0
                        vDSP_vthres(sc, 1, &zero, sc, 1, nb)                 // s = max(C, 0)
                        var en: Float = 0, s: Float = 0
                        for k in kLo..<kHi { en += 0.5 * (sl[k] + sr_[k]); s += sc[k] }
                        eb[e] = en; coh[e] = s / (en + eps)
                        if p.exactSums {
                            for k in 0..<bins { sumS += Double(sc[k]); sumL += Double(sl[k]); sumR += Double(sr_[k]) }
                        } else {
                            // A row in single precision, the song in double: within 1e-7 of the exact width on
                            // real stems (one single-precision sum over the whole song was 1e-5 off).
                            var x: Float = 0
                            vDSP_sve(sc, 1, &x, nb); sumS += Double(x)
                            vDSP_sve(sl, 1, &x, nb); sumL += Double(x)
                            vDSP_sve(sr_, 1, &x, nb); sumR += Double(x)
                        }
                    }
                }
                b0 = b1
            }
            withExtendedLifetime((raw, smooth)) {}
        }

        // Register prior.
        var prior = [Float](repeating: 0, count: bins)
        for k in 0..<bins {
            let f = max(Float(k) * sr / Float(N), 1)
            var u = (log(f) - log(p.fLo)) / (log(p.fHi) - log(p.fLo))
            u = min(1, max(0, u))
            prior[k] = u * u * (3 - 2 * u)
        }

        // Per-frame gate from broadband coherence in the lead band.
        let ebMax = eb.max() ?? 0
        let activeCoh = zip(coh, eb).filter { $0.1 > ebMax * 1e-4 }.map(\.0).sorted()
        let base: Float = activeCoh.count > 10 ? percentile(activeCoh, p.gateBasePct) : 0
        var gate = coh.map { min(1, max(0, ($0 - base - p.gateMargin) / p.gateWidth)) }
        boxTime(&gate, frames: frames, bins: 1, size: p.gateSmooth)
        gate = gate.map { p.gateFloor + (1 - p.gateFloor) * $0 }
        coh = []; eb = []

        // Pass 2: coherent-centre Wiener masks, gated and smoothed, and the masked inverse STFT (Hann synthesis,
        // Σw² normalisation) added into the lead as each frame's mask is ready.
        var leadL = [Float](repeating: 0, count: n), leadR = leadL
        do {
            // A frame's spectra are needed until its mask is out of both smoothing windows and its block of
            // inverse transforms has run.
            let store = Spectra.Store(bins: bins, capacity: 2 * block + hT + hM + 1)
            var boxL = RowBox(bins: bins, frames: frames, size: p.smoothT)
            var boxR = boxL, boxC = boxL
            var maskL = RowBox(bins: bins, frames: frames, size: p.maskSmoothT), maskR = maskL
            let rows = Row(bins: bins, count: 8)
            let (rl, rr, rc) = (rows.at(0), rows.at(1), rows.at(2))
            let (ml, mr, sc) = (rows.at(3), rows.at(4), rows.at(5))
            let (outL, outR) = (rows.at(6), rows.at(7))
            let freq = FreqBox(bins: bins, size: p.maskSmoothF)
            var lo = p.floor, hi = 1 - p.floor
            let synth = Synthesis(stft: stft, frames: frames, length: n, block: block)
            let finished = prior.withUnsafeBufferPointer { pr -> Bool in
                let prior = pr.baseAddress!
                var b0 = 0
                while b0 < frames {
                    let b1 = min(frames, b0 + block)
                    stft.forward(guitar, frames: b0..<b1, into: store)
                    for t in b0..<b1 {
                        covariance(store.rows(t), rl, rr, rc)
                        boxL.push(rl); boxR.push(rr); boxC.push(rc)
                        while let e = boxL.emit(into: ml) {
                            _ = boxR.emit(into: mr); _ = boxC.emit(into: sc)
                            var zero: Float = 0
                            vDSP_vthres(sc, 1, &zero, sc, 1, nb)
                            // ML = s / (s + max(PLL − s, 0) + ε), likewise for R, in place: P becomes its mask.
                            for w in [ml, mr] {
                                vDSP_vsub(sc, 1, w, 1, w, 1, nb)                       // P − s
                                var z: Float = 0
                                vDSP_vthres(w, 1, &z, w, 1, nb)                        // max(·, 0)
                                vDSP_vadd(w, 1, sc, 1, w, 1, nb)                       // + s
                                var ep = eps
                                vDSP_vsadd(w, 1, &ep, w, 1, nb)                        // + ε
                                vDSP_vdiv(w, 1, sc, 1, w, 1, nb)                       // s / (…)
                                var g = gate[e]
                                vDSP_vmul(w, 1, prior, 1, w, 1, nb)
                                vDSP_vsmul(w, 1, &g, w, 1, nb)
                            }
                            maskL.push(ml); maskR.push(mr)
                            while let f = maskL.emit(into: outL) {
                                _ = maskR.emit(into: outR)
                                freq.apply(outL); freq.apply(outR)
                                vDSP_vclip(outL, 1, &lo, &hi, outL, 1, nb)
                                vDSP_vclip(outR, 1, &lo, &hi, outR, 1, nb)
                                synth.queue(frame: f, maskL: outL, maskR: outR, spectra: store, left: &leadL, right: &leadR)
                            }
                        }
                    }
                    b0 = b1
                }
                synth.flush(spectra: store, left: &leadL, right: &leadR)
                return synth.done
            }
            precondition(finished, "every frame was synthesised")
            withExtendedLifetime(rows) {}
        }
        var rhyL: [Float] = [], rhyR: [Float] = []
        if withRhythm {
            rhyL = [Float](repeating: 0, count: n); rhyR = rhyL
            vDSP_vsub(leadL, 1, guitar.left, 1, &rhyL, 1, vDSP_Length(n))
            vDSP_vsub(leadR, 1, guitar.right, 1, &rhyR, 1, vDSP_Length(n))
        }

        // Confidence: stereo width × how much the lead share varies over time.
        let width = 1 - sumS / (0.5 * (sumL + sumR) + 1e-12)
        let block2s = Int(2 * guitar.sampleRate)
        let nblocks = n / block2s
        var eg = [Double](repeating: 0, count: nblocks), el = eg
        for b in 0..<nblocks {
            var a: Float = 0, c: Float = 0, d: Float = 0, e: Float = 0
            vDSP_svesq(guitar.left.withUnsafeBufferPointer { $0.baseAddress! + b * block2s }, 1, &a, vDSP_Length(block2s))
            vDSP_svesq(guitar.right.withUnsafeBufferPointer { $0.baseAddress! + b * block2s }, 1, &c, vDSP_Length(block2s))
            vDSP_svesq(leadL.withUnsafeBufferPointer { $0.baseAddress! + b * block2s }, 1, &d, vDSP_Length(block2s))
            vDSP_svesq(leadR.withUnsafeBufferPointer { $0.baseAddress! + b * block2s }, 1, &e, vDSP_Length(block2s))
            eg[b] = Double(a + c); el[b] = Double(d + e)
        }
        let egMax = eg.max() ?? 0
        let shares = zip(el, eg).filter { $0.1 > egMax * 1e-4 }.map { $0.0 / ($0.1 + 1e-12) }.sorted()
        let dyn = shares.count > 3 ? percentile(shares, 90) - percentile(shares, 10) : 0
        let c1 = min(1, max(0, (width - 0.25) / 0.30))
        let c2 = min(1, max(0, (dyn - 0.05) / 0.15))
        let conf = c1 * c2
        let lead = StereoAudio(left: leadL, right: leadR, sampleRate: guitar.sampleRate)
        let rhythm = StereoAudio(left: rhyL, right: rhyR, sampleRate: guitar.sampleRate)
        return Result(lead: lead, rhythm: rhythm, confidence: conf, width: width, leadDynamics: dyn,
                      shouldSplit: width >= p.minWidth)
    }

    // MARK: streaming parts

    /// A few rows of `bins` floats in one allocation, handed out as pointers.
    final class Row {
        private let storage: UnsafeMutablePointer<Float>
        private let bins: Int
        init(bins: Int, count: Int) {
            self.bins = bins
            storage = .allocate(capacity: bins * count)
            storage.initialize(repeating: 0, count: bins * count)
        }
        deinit { storage.deallocate() }
        func at(_ i: Int) -> UnsafeMutablePointer<Float> { storage + i * bins }
    }

    /// The forward STFT of both channels, a block of frames at a time, with the zero padding made on the fly.
    final class Spectra: @unchecked Sendable {
        let size: Int, hop: Int, pad: Int, half: Int, bins: Int
        let log2n: vDSP_Length
        let setup: FFTSetup
        let window: [Float]
        /// Σw² of the window, for the synthesis' normalisation.
        let windowSquared: [Float]

        init(size: Int, hop: Int, pad: Int) {
            self.size = size; self.hop = hop; self.pad = pad
            half = size / 2; bins = size / 2 + 1
            log2n = vDSP_Length(log2(Double(size)))
            setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
            window = (0..<size).map { 0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(size)) }
            var wsq = [Float](repeating: 0, count: size)
            vDSP_vsq(window, 1, &wsq, 1, vDSP_Length(size))
            windowSquared = wsq
        }
        deinit { vDSP_destroy_fftsetup(setup) }

        /// One frame's four spectrum rows.
        struct Rows {
            let reL: UnsafeMutablePointer<Float>, imL: UnsafeMutablePointer<Float>
            let reR: UnsafeMutablePointer<Float>, imR: UnsafeMutablePointer<Float>
        }

        /// Spectra of `capacity` frames, frame t in slot t % capacity.
        final class Store: @unchecked Sendable {
            let bins: Int, capacity: Int
            private let memory: UnsafeMutablePointer<Float>
            init(bins: Int, capacity: Int) {
                self.bins = bins; self.capacity = capacity
                memory = .allocate(capacity: 4 * bins * capacity)
                memory.initialize(repeating: 0, count: 4 * bins * capacity)
            }
            deinit { memory.deallocate() }
            /// Channel 0 is left, 1 is right.
            func re(_ t: Int, _ c: Int) -> UnsafeMutablePointer<Float> { memory + ((2 * c) * capacity + t % capacity) * bins }
            func im(_ t: Int, _ c: Int) -> UnsafeMutablePointer<Float> { memory + ((2 * c + 1) * capacity + t % capacity) * bins }
            func rows(_ t: Int) -> Rows { Rows(reL: re(t, 0), imL: im(t, 0), reR: re(t, 1), imR: im(t, 1)) }
        }

        /// Frames `range` of both channels of `x` into `store`, bins 0…N/2 (Nyquist included), at true scale.
        func forward(_ x: StereoAudio, frames range: Range<Int>, into store: Store) {
            let n = x.frameCount
            let workers = 8
            x.left.withUnsafeBufferPointer { l in
                x.right.withUnsafeBufferPointer { r in
                    let channels = [l.baseAddress, r.baseAddress]
                    DispatchQueue.concurrentPerform(iterations: 2 * workers) { job in
                        let c = job % 2
                        var frame = [Float](repeating: 0, count: size)
                        var sr_ = [Float](repeating: 0, count: half), si = [Float](repeating: 0, count: half)
                        var t = range.lowerBound + job / 2
                        while t < range.upperBound {
                            let start = t * hop - pad                         // input index of the frame's first sample
                            let lo = max(0, -start), hi = min(size, n - start)
                            frame.withUnsafeMutableBufferPointer { f in
                                let fp = f.baseAddress!
                                fp.update(repeating: 0, count: size)
                                if hi > lo, let src = channels[c] { (fp + lo).update(from: src + start + lo, count: hi - lo) }
                                vDSP_vmul(fp, 1, window, 1, fp, 1, vDSP_Length(size))
                            }
                            sr_.withUnsafeMutableBufferPointer { rp in
                                si.withUnsafeMutableBufferPointer { ip in
                                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                                    frame.withUnsafeBufferPointer { fp in
                                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                                        }
                                    }
                                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                                    let re = store.re(t, c), im = store.im(t, c)
                                    // zrip is 2× the DFT; the mask is scale-invariant but keep true scale.
                                    re[0] = rp[0] * 0.5; im[0] = 0
                                    re[half] = ip[0] * 0.5; im[half] = 0
                                    for k in 1..<half { re[k] = rp[k] * 0.5; im[k] = ip[k] * 0.5 }
                                }
                            }
                            t += workers
                        }
                    }
                }
            }
        }
    }

    /// The masked inverse STFT of both channels: masks are queued a frame at a time, a block's inverse
    /// transforms run in parallel, and the frames are overlap-added in order into a window one frame long; each
    /// hop of output is final (and written out) once no later frame reaches it.
    final class Synthesis {
        let stft: Spectra
        let frames: Int, length: Int, block: Int
        private var acc: [[Float]], norm: [Float]
        private var masks: [Float], time: [Float]
        private var queued: [Int] = []
        private var added = 0

        init(stft: Spectra, frames: Int, length: Int, block: Int) {
            self.stft = stft; self.frames = frames; self.length = length; self.block = block
            acc = [[Float](repeating: 0, count: stft.size), [Float](repeating: 0, count: stft.size)]
            norm = [Float](repeating: 0, count: stft.size)
            masks = [Float](repeating: 0, count: 2 * block * stft.bins)
            time = [Float](repeating: 0, count: 2 * block * stft.size)
        }

        var done: Bool { added == frames }

        /// Frame `frame`'s masks (copied); its spectra must stay in `spectra` until the block is flushed.
        func queue(frame: Int, maskL: UnsafePointer<Float>, maskR: UnsafePointer<Float>, spectra: Spectra.Store,
                   left: inout [Float], right: inout [Float]) {
            let i = queued.count, bins = stft.bins
            masks.withUnsafeMutableBufferPointer { m in
                (m.baseAddress! + (2 * i) * bins).update(from: maskL, count: bins)
                (m.baseAddress! + (2 * i + 1) * bins).update(from: maskR, count: bins)
            }
            queued.append(frame)
            if queued.count == block { flush(spectra: spectra, left: &left, right: &right) }
        }

        func flush(spectra: Spectra.Store, left: inout [Float], right: inout [Float]) {
            guard !queued.isEmpty else { return }
            let N = stft.size, half = stft.half, bins = stft.bins
            let setup = stft.setup, log2n = stft.log2n
            let frameList = queued
            masks.withUnsafeBufferPointer { mp in
                time.withUnsafeMutableBufferPointer { tp in
                    let mBase = mp.baseAddress!, tBase = tp.baseAddress!
                    stft.window.withUnsafeBufferPointer { wp in
                        DispatchQueue.concurrentPerform(iterations: 2 * frameList.count) { job in
                            let i = job / 2, c = job % 2
                            let re = UnsafePointer(spectra.re(frameList[i], c)), im = UnsafePointer(spectra.im(frameList[i], c))
                            let M = mBase + job * bins
                            var sr_ = [Float](repeating: 0, count: half), si = sr_
                            sr_[0] = re[0] * M[0]
                            si[0] = re[half] * M[half]                    // pack Nyquist into imag[0]
                            for k in 1..<half { sr_[k] = re[k] * M[k]; si[k] = im[k] * M[k] }
                            let out = tBase + job * N
                            sr_.withUnsafeMutableBufferPointer { rp in
                                si.withUnsafeMutableBufferPointer { ip in
                                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                                    out.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                                        vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
                                    }
                                }
                            }
                            // zrip inverse of a true-scale (half-packed) spectrum gives N × x; ×1/N restores it.
                            var s = 1 / Float(N)
                            vDSP_vsmul(out, 1, &s, out, 1, vDSP_Length(N))
                            vDSP_vmul(out, 1, wp.baseAddress!, 1, out, 1, vDSP_Length(N))
                        }
                    }
                    for i in frameList.indices {
                        overlapAdd(frame: frameList[i], left: tBase + (2 * i) * N, right: tBase + (2 * i + 1) * N,
                                   into: &left, &right)
                    }
                }
            }
            queued.removeAll(keepingCapacity: true)
        }

        private func overlapAdd(frame t: Int, left: UnsafePointer<Float>, right: UnsafePointer<Float>,
                                into outL: inout [Float], _ outR: inout [Float]) {
            precondition(t == added, "frames are added in order")
            added += 1
            let N = stft.size, hop = stft.hop
            // Samples [t·hop, t·hop + ready) of the padded signal are final after this frame.
            let ready = t == frames - 1 ? N : hop
            let base = t * hop - stft.pad
            norm.withUnsafeMutableBufferPointer { w in
                let wp = w.baseAddress!
                stft.windowSquared.withUnsafeBufferPointer { vDSP_vadd(wp, 1, $0.baseAddress!, 1, wp, 1, vDSP_Length(N)) }
                for (c, frame) in [left, right].enumerated() {
                    acc[c].withUnsafeMutableBufferPointer { a in
                        let ap = a.baseAddress!
                        vDSP_vadd(ap, 1, frame, 1, ap, 1, vDSP_Length(N))
                        func write(_ out: UnsafeMutablePointer<Float>) {
                            for i in 0..<ready {
                                let j = base + i
                                if j >= 0, j < length { out[j] = ap[i] / max(wp[i], 1e-3) }
                            }
                        }
                        if c == 0 { outL.withUnsafeMutableBufferPointer { write($0.baseAddress!) } }
                        else { outR.withUnsafeMutableBufferPointer { write($0.baseAddress!) } }
                        if t < frames - 1 {
                            ap.update(from: ap + hop, count: N - hop)
                            (ap + N - hop).update(repeating: 0, count: hop)
                        }
                    }
                }
                if t < frames - 1 {
                    wp.update(from: wp + hop, count: N - hop)
                    (wp + N - hop).update(repeating: 0, count: hop)
                }
            }
        }
    }

    /// Centred moving average along time with edge renormalisation, a row at a time: rows go in in order and
    /// each smoothed row comes out once the rows its window needs are in. Same running sum as `boxTime`, so
    /// the same result; it keeps 2h + 2 rows.
    struct RowBox {
        let bins: Int, frames: Int, h: Int, slots: Int
        private var ring: [Float], acc: [Float]
        private var pushed = 0, next = 0, lo = 0, hi = -1
        private let passThrough: Bool

        static func half(_ size: Int) -> Int { size > 1 ? size / 2 : 0 }

        init(bins: Int, frames: Int, size: Int) {
            self.bins = bins; self.frames = frames
            passThrough = size <= 1
            h = Self.half(size)
            slots = 2 * h + 2
            ring = [Float](repeating: 0, count: slots * bins)
            acc = [Float](repeating: 0, count: bins)
        }

        mutating func push(_ row: UnsafePointer<Float>) {
            let slot = pushed % slots
            ring.withUnsafeMutableBufferPointer { ($0.baseAddress! + slot * bins).update(from: row, count: bins) }
            pushed += 1
        }

        /// Writes the next smoothed row to `out` and returns its frame, or nil until its window is complete.
        mutating func emit(into out: UnsafeMutablePointer<Float>) -> Int? {
            guard next < frames, pushed == frames || next + h < pushed else { return nil }
            let t = next
            next += 1
            let nb = vDSP_Length(bins), slots = slots, bins = bins
            if passThrough {
                ring.withUnsafeBufferPointer { out.update(from: $0.baseAddress! + (t % slots) * bins, count: bins) }
                return t
            }
            let wantLo = max(0, t - h), wantHi = min(frames - 1, t + h)
            var lo = lo, hi = hi
            ring.withUnsafeBufferPointer { r in
                acc.withUnsafeMutableBufferPointer { a in
                    let rp = r.baseAddress!, ap = a.baseAddress!
                    while hi < wantHi { hi += 1; vDSP_vadd(ap, 1, rp + (hi % slots) * bins, 1, ap, 1, nb) }
                    while lo < wantLo { vDSP_vsub(rp + (lo % slots) * bins, 1, ap, 1, ap, 1, nb); lo += 1 }
                    var inv = 1 / Float(hi - lo + 1)
                    vDSP_vsmul(ap, 1, &inv, out, 1, nb)
                }
            }
            self.lo = lo; self.hi = hi
            return t
        }
    }

    /// Centred moving average along frequency within one row, edge renormalised (`boxFreq` for one frame).
    final class FreqBox {
        let bins: Int, h: Int
        private var row: [Float], invCounts: [Float]

        init(bins: Int, size: Int) {
            self.bins = bins
            h = size > 1 ? size / 2 : 0
            row = [Float](repeating: 0, count: bins)
            var counts = [Float](repeating: 0, count: bins)
            for k in 0..<bins { counts[k] = Float(min(bins - 1, k + h) - max(0, k - h) + 1) }
            invCounts = [Float](repeating: 0, count: bins)
            var one: Float = 1
            vDSP_svdiv(&one, counts, 1, &invCounts, 1, vDSP_Length(bins))
        }

        func apply(_ dp: UnsafeMutablePointer<Float>) {
            guard h > 0 else { return }
            let bins = bins, h = h
            row.withUnsafeMutableBufferPointer { s in
                let sp = s.baseAddress!
                sp.update(from: dp, count: bins)
                for o in 1...h {
                    // bins k receive sp[k-o] (k >= o) and sp[k+o] (k < bins-o)
                    vDSP_vadd(dp + o, 1, sp, 1, dp + o, 1, vDSP_Length(bins - o))
                    vDSP_vadd(dp, 1, sp + o, 1, dp, 1, vDSP_Length(bins - o))
                }
            }
            invCounts.withUnsafeBufferPointer { vDSP_vmul(dp, 1, $0.baseAddress!, 1, dp, 1, vDSP_Length(bins)) }
        }
    }

    // MARK: helpers

    /// Centred moving average along time (frame axis) with edge renormalisation; in place.
    /// Running sum over whole frame rows with vDSP (fast in Debug and Release). Row t is overwritten once the
    /// window has moved past it, but the sum still has to subtract its original value h + 1 frames later,
    /// so the last h + 1 original rows are kept in a ring instead of a copy of the whole array.
    static func boxTime(_ a: inout [Float], frames: Int, bins: Int, size: Int) {
        guard size > 1, frames > 0 else { return }
        let h = size / 2
        let slots = h + 1
        var ring = [Float](repeating: 0, count: slots * bins)
        var acc = [Float](repeating: 0, count: bins)
        let nb = vDSP_Length(bins)
        ring.withUnsafeMutableBufferPointer { r in
            a.withUnsafeMutableBufferPointer { d in
                let rp = r.baseAddress!, dp = d.baseAddress!
                // Initial window [0, h] for frame 0.
                for t in 0...min(h, frames - 1) { vDSP_vadd(acc, 1, dp + t * bins, 1, &acc, 1, nb) }
                var lo = 0, hi = min(h, frames - 1)          // inclusive window bounds
                for t in 0..<frames {
                    let wantLo = max(0, t - h), wantHi = min(frames - 1, t + h)
                    // Rows past t are still original in `a`.
                    while hi < wantHi { hi += 1; vDSP_vadd(acc, 1, dp + hi * bins, 1, &acc, 1, nb) }
                    // Rows before t were overwritten; their originals are in the ring.
                    while lo < wantLo { vDSP_vsub(rp + (lo % slots) * bins, 1, acc, 1, &acc, 1, nb); lo += 1 }
                    // Keep row t's original before it is overwritten (lo <= t - h - 1 is subtracted later).
                    (rp + (t % slots) * bins).update(from: dp + t * bins, count: bins)
                    var inv = 1 / Float(hi - lo + 1)
                    vDSP_vsmul(acc, 1, &inv, dp + t * bins, 1, nb)
                }
            }
        }
    }

    /// numpy-style linear-interpolated percentile of a sorted array.
    static func percentile<T: BinaryFloatingPoint>(_ sorted: [T], _ q: T) -> T {
        guard !sorted.isEmpty else { return 0 }
        let pos = q / 100 * T(sorted.count - 1)
        let i = Int(pos), f = pos - T(i)
        return i + 1 < sorted.count ? sorted[i] + f * (sorted[i + 1] - sorted[i]) : sorted[i]
    }
}
