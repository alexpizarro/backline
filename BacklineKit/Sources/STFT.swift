import Accelerate
import Foundation

/// STFT / iSTFT matching Demucs' `spectro` / `ispectro` wrappers
/// (`torch.stft(n_fft, hop, hann, normalized=True, center=True, pad_mode="reflect")`)
/// and HTDemucs' `_spec` / `_ispec` re-padding, implemented with vDSP.
public final class DemucsSTFT {
    public let nfft: Int
    public let hop: Int
    public let bins: Int          // nfft / 2 (Nyquist bin dropped, as in Demucs)
    private let log2n: vDSP_Length
    private let fft: FFTSetup
    private let window: [Float]
    private let norm: Float       // 1 / sqrt(nfft) for normalized=True

    public init(nfft: Int = 4096) {
        self.nfft = nfft
        self.hop = nfft / 4
        self.bins = nfft / 2
        self.log2n = vDSP_Length(log2(Double(nfft)))
        self.fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        // torch.hann_window is periodic.
        var w = [Float](repeating: 0, count: nfft)
        for i in 0..<nfft { w[i] = 0.5 - 0.5 * cos(2 * .pi * Float(i) / Float(nfft)) }
        self.window = w
        self.norm = 1 / sqrt(Float(nfft))
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    /// Number of frames `_spec` produces for a signal of `length` samples.
    public func frames(for length: Int) -> Int { Int((Double(length) / Double(hop)).rounded(.up)) }

    /// Reflect-pad (numpy/torch "reflect": edge sample not repeated).
    public static func reflectPad(_ x: UnsafePointer<Float>, count n: Int, left: Int, right: Int) -> [Float] {
        var out = [Float](repeating: 0, count: n + left + right)
        out.withUnsafeMutableBufferPointer { o in
            for i in 0..<left { o[i] = x[left - i] }
            (o.baseAddress! + left).update(from: x, count: n)
            for i in 0..<right { o[left + n + i] = x[n - 2 - i] }
        }
        return out
    }

    /// Complex-as-channels spectrogram of one channel.
    /// Writes `re` and `im` planes, each laid out [bins][frames] (row-major, frames fastest).
    public func forward(_ x: UnsafePointer<Float>, count length: Int,
                        re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>) {
        let hl = hop
        let le = frames(for: length)
        let pad = hl / 2 * 3
        // HTDemucs `_spec` pad, then torch center pad (nfft/2 each side, reflect).
        let p1 = Self.reflectPad(x, count: length, left: pad, right: pad + le * hl - length)
        let p2 = p1.withUnsafeBufferPointer { Self.reflectPad($0.baseAddress!, count: p1.count, left: nfft / 2, right: nfft / 2) }
        let T = le
        let half = nfft / 2
        var frame = [Float](repeating: 0, count: nfft)
        var sr = [Float](repeating: 0, count: half)
        var si = [Float](repeating: 0, count: half)
        p2.withUnsafeBufferPointer { src in
            for t in 0..<T {
                // torch frame index = t + 2 (first two frames and last frames dropped)
                let start = (t + 2) * hl
                vDSP_vmul(src.baseAddress! + start, 1, window, 1, &frame, 1, vDSP_Length(nfft))
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
                // vDSP packs DC in re[0] and Nyquist in im[0]; output is 2x the true DFT.
                // We keep bins 0..<half (Nyquist dropped). torch.stft uses e^{-i...}: same sign as vDSP.
                let scale = 0.5 * norm
                re[t] = sr[0] * scale
                im[t] = 0
                for k in 1..<half {
                    re[k * T + t] = sr[k] * scale
                    im[k * T + t] = si[k] * scale
                }
            }
        }
    }

    /// Inverse of `forward` for a spectrogram with `frames` frames; returns `length` samples.
    /// `re`/`im` are [bins][frames] planes.
    public func inverse(re: UnsafePointer<Float>, im: UnsafePointer<Float>, frames T: Int,
                        length: Int, out: UnsafeMutablePointer<Float>) {
        let hl = hop
        let half = nfft / 2
        let pad = hl / 2 * 3
        let le = hl * Int((Double(length) / Double(hl)).rounded(.up)) + 2 * pad
        // `_ispec` pads 2 zero frames on each side (and a zero Nyquist bin).
        let totalFrames = T + 4
        // torch.istft(center=True, length=le): OLA buffer of (frames-1)*hop + nfft, trim nfft/2 from start.
        let olaLen = (totalFrames - 1) * hl + nfft
        var ola = [Float](repeating: 0, count: olaLen)
        var wsum = [Float](repeating: 0, count: olaLen)
        var sr = [Float](repeating: 0, count: half)
        var si = [Float](repeating: 0, count: half)
        var frame = [Float](repeating: 0, count: nfft)
        var wsq = [Float](repeating: 0, count: nfft)
        vDSP_vsq(window, 1, &wsq, 1, vDSP_Length(nfft))
        // Inverse scale: undo normalized (x sqrt(nfft)), vDSP inverse gives nfft * x, packed-real forward gave 2x.
        let invScale = sqrt(Float(nfft)) / Float(nfft)
        for f in 0..<totalFrames {
            let t = f - 2
            let start = f * hl
            if t >= 0 && t < T {
                sr[0] = re[t]
                si[0] = 0      // Nyquist bin is zero
                for k in 1..<half {
                    sr[k] = re[k * T + t]
                    si[k] = im[k * T + t]
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
                // real DC-only (re[0]) needs x2 because zrip inverse treats packed DC as 2*DC? handled by invScale on all bins
                var s = invScale
                vDSP_vsmul(frame, 1, &s, &frame, 1, vDSP_Length(nfft))
                vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(nfft))
                ola.withUnsafeMutableBufferPointer { o in
                    vDSP_vadd(o.baseAddress! + start, 1, frame, 1, o.baseAddress! + start, 1, vDSP_Length(nfft))
                }
            }
            wsum.withUnsafeMutableBufferPointer { w in
                vDSP_vadd(w.baseAddress! + start, 1, wsq, 1, w.baseAddress! + start, 1, vDSP_Length(nfft))
            }
        }
        // istft output (after center trim) index j corresponds to ola[j + nfft/2]; then `_ispec` keeps [pad, pad+length).
        let base = nfft / 2 + pad
        precondition(base + length <= olaLen && le >= pad + length)
        for j in 0..<length {
            let w = wsum[base + j]
            out[j] = w > 1e-11 ? ola[base + j] / w : 0
        }
    }
}
