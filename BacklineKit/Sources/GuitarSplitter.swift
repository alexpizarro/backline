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

    /// Splits `guitar` (44.1 kHz stereo). Always returns both parts; check `shouldSplit` before showing them.
    public static func split(_ guitar: StereoAudio, params p: Params = Params()) -> Result {
        let n = guitar.frameCount
        let N = p.nfft, hop = p.hop, bins = N / 2 + 1, half = N / 2
        let sr = Float(guitar.sampleRate)
        let pad = N / 2
        let frames = Int((Double(n + 2 * pad - N) / Double(hop)).rounded(.up)) + 1
        let total = (frames - 1) * hop + N
        let log2n = vDSP_Length(log2(Double(N)))
        let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        let window = (0..<N).map { 0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(N)) }

        // Zero-padded channels.
        func padded(_ x: [Float]) -> [Float] {
            var out = [Float](repeating: 0, count: total)
            x.withUnsafeBufferPointer { src in out.withUnsafeMutableBufferPointer { ($0.baseAddress! + pad).update(from: src.baseAddress!, count: n) } }
            return out
        }
        let xl = padded(guitar.left), xr = padded(guitar.right)

        // Forward STFT of both channels, bins 0…N/2 (Nyquist included), stored frame-major.
        var reL = [Float](repeating: 0, count: frames * bins), imL = reL, reR = reL, imR = reL
        func forward(_ x: [Float], _ re: inout [Float], _ im: inout [Float]) {
            x.withUnsafeBufferPointer { src in
                re.withUnsafeMutableBufferPointer { reOut in
                    im.withUnsafeMutableBufferPointer { imOut in
                        let reBase = reOut.baseAddress!, imBase = imOut.baseAddress!
                        DispatchQueue.concurrentPerform(iterations: 8) { w in
                            var frame = [Float](repeating: 0, count: N)
                            var sr_ = [Float](repeating: 0, count: half), si = [Float](repeating: 0, count: half)
                            var t = w
                            while t < frames {
                                vDSP_vmul(src.baseAddress! + t * hop, 1, window, 1, &frame, 1, vDSP_Length(N))
                                sr_.withUnsafeMutableBufferPointer { rp in
                                    si.withUnsafeMutableBufferPointer { ip in
                                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                                        frame.withUnsafeBufferPointer { fp in
                                            fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                                                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                                            }
                                        }
                                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                                        let r = reBase + t * bins, i = imBase + t * bins
                                        // zrip is 2× the DFT; the mask is scale-invariant but keep true scale.
                                        r[0] = rp[0] * 0.5; i[0] = 0
                                        r[half] = ip[0] * 0.5; i[half] = 0
                                        for k in 1..<half { r[k] = rp[k] * 0.5; i[k] = ip[k] * 0.5 }
                                    }
                                }
                                t += 8
                            }
                        }
                    }
                }
            }
        }
        forward(xl, &reL, &imL)
        forward(xr, &reR, &imR)

        // Covariance terms, smoothed along time with a centred box (edge-renormalised).
        let count = frames * bins
        var PLL = [Float](repeating: 0, count: count), PRR = PLL, C = PLL
        vDSP_vsq(reL, 1, &PLL, 1, vDSP_Length(count)); vDSP_vma(imL, 1, imL, 1, PLL, 1, &PLL, 1, vDSP_Length(count))
        vDSP_vsq(reR, 1, &PRR, 1, vDSP_Length(count)); vDSP_vma(imR, 1, imR, 1, PRR, 1, &PRR, 1, vDSP_Length(count))
        // Re(XL · conj XR) = reL·reR + imL·imR
        vDSP_vmul(reL, 1, reR, 1, &C, 1, vDSP_Length(count)); vDSP_vma(imL, 1, imR, 1, C, 1, &C, 1, vDSP_Length(count))
        boxTime(&PLL, frames: frames, bins: bins, size: p.smoothT)
        boxTime(&PRR, frames: frames, bins: bins, size: p.smoothT)
        boxTime(&C, frames: frames, bins: bins, size: p.smoothT)

        // Coherent-centre Wiener masks.
        let eps: Float = 1e-12
        var sc = [Float](repeating: 0, count: count)
        var zero: Float = 0
        vDSP_vthres(C, 1, &zero, &sc, 1, vDSP_Length(count))       // max(C, 0)
        // ML = s / (s + max(PLL − s, 0) + ε), likewise for R.
        func centreMask(_ P: [Float]) -> [Float] {
            var w = [Float](repeating: 0, count: count)
            vDSP_vsub(sc, 1, P, 1, &w, 1, vDSP_Length(count))          // P − s
            var z: Float = 0
            vDSP_vthres(w, 1, &z, &w, 1, vDSP_Length(count))            // max(·, 0)
            vDSP_vadd(w, 1, sc, 1, &w, 1, vDSP_Length(count))           // + s
            var e = eps
            vDSP_vsadd(w, 1, &e, &w, 1, vDSP_Length(count))             // + ε
            var m = [Float](repeating: 0, count: count)
            vDSP_vdiv(w, 1, sc, 1, &m, 1, vDSP_Length(count))           // s / (…)
            return m
        }
        var ML = centreMask(PLL), MR = centreMask(PRR)

        // Register prior.
        var prior = [Float](repeating: 0, count: bins)
        for k in 0..<bins {
            let f = max(Float(k) * sr / Float(N), 1)
            var u = (log(f) - log(p.fLo)) / (log(p.fHi) - log(p.fLo))
            u = min(1, max(0, u))
            prior[k] = u * u * (3 - 2 * u)
        }

        // Per-frame gate from broadband coherence in the lead band.
        let kLo = Int((p.gateLo * Float(N) / sr).rounded(.up)), kHi = min(bins, Int(p.gateHi * Float(N) / sr))
        var coh = [Float](repeating: 0, count: frames), eb = coh
        for t in 0..<frames {
            var e: Float = 0, s: Float = 0
            let o = t * bins
            for k in kLo..<kHi { e += 0.5 * (PLL[o + k] + PRR[o + k]); s += sc[o + k] }
            eb[t] = e; coh[t] = s / (e + eps)
        }
        let ebMax = eb.max() ?? 0
        let activeCoh = zip(coh, eb).filter { $0.1 > ebMax * 1e-4 }.map(\.0).sorted()
        let base: Float = activeCoh.count > 10 ? percentile(activeCoh, p.gateBasePct) : 0
        var gate = coh.map { min(1, max(0, ($0 - base - p.gateMargin) / p.gateWidth)) }
        boxTime(&gate, frames: frames, bins: 1, size: p.gateSmooth)
        gate = gate.map { p.gateFloor + (1 - p.gateFloor) * $0 }

        ML.withUnsafeMutableBufferPointer { ml in
            MR.withUnsafeMutableBufferPointer { mr in
                for t in 0..<frames {
                    let o = t * bins
                    var g = gate[t]
                    vDSP_vmul(ml.baseAddress! + o, 1, prior, 1, ml.baseAddress! + o, 1, vDSP_Length(bins))
                    vDSP_vsmul(ml.baseAddress! + o, 1, &g, ml.baseAddress! + o, 1, vDSP_Length(bins))
                    vDSP_vmul(mr.baseAddress! + o, 1, prior, 1, mr.baseAddress! + o, 1, vDSP_Length(bins))
                    vDSP_vsmul(mr.baseAddress! + o, 1, &g, mr.baseAddress! + o, 1, vDSP_Length(bins))
                }
            }
        }
        boxTime(&ML, frames: frames, bins: bins, size: p.maskSmoothT)
        boxTime(&MR, frames: frames, bins: bins, size: p.maskSmoothT)
        boxFreq(&ML, frames: frames, bins: bins, size: p.maskSmoothF)
        boxFreq(&MR, frames: frames, bins: bins, size: p.maskSmoothF)
        var lo = p.floor, hi = 1 - p.floor
        vDSP_vclip(ML, 1, &lo, &hi, &ML, 1, vDSP_Length(count))
        vDSP_vclip(MR, 1, &lo, &hi, &MR, 1, vDSP_Length(count))

        // Masked inverse STFT (Hann synthesis, Σw² normalisation) → lead; rhythm = guitar − lead.
        func inverse(_ re: [Float], _ im: [Float], _ M: [Float]) -> [Float] {
            var out = [Float](repeating: 0, count: total), norm = out
            var sr_ = [Float](repeating: 0, count: half), si = sr_, frame = [Float](repeating: 0, count: N)
            var wsq = [Float](repeating: 0, count: N)
            vDSP_vsq(window, 1, &wsq, 1, vDSP_Length(N))
            let invN = 1 / Float(N)
            for t in 0..<frames {
                let o = t * bins
                sr_[0] = re[o] * M[o]
                si[0] = re[o + half] * M[o + half]           // pack Nyquist into imag[0]
                for k in 1..<half { sr_[k] = re[o + k] * M[o + k]; si[k] = im[o + k] * M[o + k] }
                sr_.withUnsafeMutableBufferPointer { rp in
                    si.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                        frame.withUnsafeMutableBufferPointer { fp in
                            fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                                vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
                            }
                        }
                    }
                }
                // zrip inverse of a true-scale (half-packed) spectrum gives N × x; ×1/N restores it.
                var s = invN
                vDSP_vsmul(frame, 1, &s, &frame, 1, vDSP_Length(N))
                vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(N))
                out.withUnsafeMutableBufferPointer { op in
                    vDSP_vadd(op.baseAddress! + t * hop, 1, frame, 1, op.baseAddress! + t * hop, 1, vDSP_Length(N))
                }
                norm.withUnsafeMutableBufferPointer { np in
                    vDSP_vadd(np.baseAddress! + t * hop, 1, wsq, 1, np.baseAddress! + t * hop, 1, vDSP_Length(N))
                }
            }
            var y = [Float](repeating: 0, count: n)
            for j in 0..<n { y[j] = out[pad + j] / max(norm[pad + j], 1e-3) }
            return y
        }
        let leadL = inverse(reL, imL, ML), leadR = inverse(reR, imR, MR)
        var rhyL = [Float](repeating: 0, count: n), rhyR = rhyL
        vDSP_vsub(leadL, 1, guitar.left, 1, &rhyL, 1, vDSP_Length(n))
        vDSP_vsub(leadR, 1, guitar.right, 1, &rhyR, 1, vDSP_Length(n))
        let lead = StereoAudio(left: leadL, right: leadR, sampleRate: guitar.sampleRate)
        let rhythm = StereoAudio(left: rhyL, right: rhyR, sampleRate: guitar.sampleRate)

        // Confidence: stereo width × how much the lead share varies over time.
        var sScF: Float = 0, sL: Float = 0, sR: Float = 0
        vDSP_sve(sc, 1, &sScF, vDSP_Length(count))
        vDSP_sve(PLL, 1, &sL, vDSP_Length(count))
        vDSP_sve(PRR, 1, &sR, vDSP_Length(count))
        let width = 1 - Double(sScF) / (0.5 * Double(sL + sR) + 1e-12)
        let block = Int(2 * guitar.sampleRate)
        let nb = n / block
        var eg = [Double](repeating: 0, count: nb), el = eg
        for b in 0..<nb {
            var a: Float = 0, c: Float = 0, d: Float = 0, e: Float = 0
            vDSP_svesq(guitar.left.withUnsafeBufferPointer { $0.baseAddress! + b * block }, 1, &a, vDSP_Length(block))
            vDSP_svesq(guitar.right.withUnsafeBufferPointer { $0.baseAddress! + b * block }, 1, &c, vDSP_Length(block))
            vDSP_svesq(leadL.withUnsafeBufferPointer { $0.baseAddress! + b * block }, 1, &d, vDSP_Length(block))
            vDSP_svesq(leadR.withUnsafeBufferPointer { $0.baseAddress! + b * block }, 1, &e, vDSP_Length(block))
            eg[b] = Double(a + c); el[b] = Double(d + e)
        }
        let egMax = eg.max() ?? 0
        let shares = zip(el, eg).filter { $0.1 > egMax * 1e-4 }.map { $0.0 / ($0.1 + 1e-12) }.sorted()
        let dyn = shares.count > 3 ? percentile(shares, 90) - percentile(shares, 10) : 0
        let c1 = min(1, max(0, (width - 0.25) / 0.30))
        let c2 = min(1, max(0, (dyn - 0.05) / 0.15))
        let conf = c1 * c2
        return Result(lead: lead, rhythm: rhythm, confidence: conf, width: width, leadDynamics: dyn,
                      shouldSplit: width >= p.minWidth)
    }

    // MARK: helpers

    /// Centred moving average along time (frame axis) with edge renormalisation; in place.
    /// Running sum over whole frame rows with vDSP (fast in Debug and Release).
    static func boxTime(_ a: inout [Float], frames: Int, bins: Int, size: Int) {
        guard size > 1, frames > 0 else { return }
        let h = size / 2
        let src = a
        var acc = [Float](repeating: 0, count: bins)
        let nb = vDSP_Length(bins)
        src.withUnsafeBufferPointer { s in
            a.withUnsafeMutableBufferPointer { d in
                let sp = s.baseAddress!, dp = d.baseAddress!
                // Initial window [0, h] for frame 0.
                for t in 0...min(h, frames - 1) { vDSP_vadd(acc, 1, sp + t * bins, 1, &acc, 1, nb) }
                var lo = 0, hi = min(h, frames - 1)          // inclusive window bounds
                for t in 0..<frames {
                    let wantLo = max(0, t - h), wantHi = min(frames - 1, t + h)
                    while hi < wantHi { hi += 1; vDSP_vadd(acc, 1, sp + hi * bins, 1, &acc, 1, nb) }
                    while lo < wantLo { vDSP_vsub(sp + lo * bins, 1, acc, 1, &acc, 1, nb); lo += 1 }
                    var inv = 1 / Float(hi - lo + 1)
                    vDSP_vsmul(acc, 1, &inv, dp + t * bins, 1, nb)
                }
            }
        }
    }

    /// Centred moving average along frequency within each frame; in place.
    static func boxFreq(_ a: inout [Float], frames: Int, bins: Int, size: Int) {
        guard size > 1 else { return }
        let h = size / 2
        let src = a
        // Sum of shifted copies, then divide by the per-bin window length (edge renormalised).
        var counts = [Float](repeating: 0, count: bins)
        for k in 0..<bins { counts[k] = Float(min(bins - 1, k + h) - max(0, k - h) + 1) }
        var invCounts = [Float](repeating: 0, count: bins)
        var one: Float = 1
        vDSP_svdiv(&one, counts, 1, &invCounts, 1, vDSP_Length(bins))
        src.withUnsafeBufferPointer { s in
            a.withUnsafeMutableBufferPointer { d in
                for t in 0..<frames {
                    let sp = s.baseAddress! + t * bins, dp = d.baseAddress! + t * bins
                    dp.update(from: sp, count: bins)
                    for o in 1...h {
                        // bins k receive sp[k-o] (k >= o) and sp[k+o] (k < bins-o)
                        vDSP_vadd(dp + o, 1, sp, 1, dp + o, 1, vDSP_Length(bins - o))
                        vDSP_vadd(dp, 1, sp + o, 1, dp, 1, vDSP_Length(bins - o))
                    }
                    vDSP_vmul(dp, 1, invCounts, 1, dp, 1, vDSP_Length(bins))
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
