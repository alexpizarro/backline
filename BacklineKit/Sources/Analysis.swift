import Accelerate
import Foundation

/// Song-structure analysis on Apple silicon (Accelerate only, no models):
/// - tempo + beat grid: spectral-flux onset envelope → autocorrelation with a log-Gaussian tempo prior
///   (ported from go-play-in-the-band `analysis.rs`, MIT) → Ellis dynamic-programming beat tracker
/// - bars: downbeat phase chosen where the drum/bass low end is strongest
/// - sections: bar-synchronous chroma + timbre self-similarity → Foote checkerboard novelty (as in MSAF, MIT)
///   → peaks snapped to bars → segments labelled with stem-energy heuristics (Solo, Intro, Outro, …)
/// - key: Krumhansl–Schmuckler on the harmonic stems
public struct SongAnalysis: Codable, Sendable, Equatable {
    public var bpm: Double
    public var beats: [Double]            // seconds
    public var downbeats: [Double]        // seconds (bar starts)
    public var sections: [Section]
    public var key: String?               // e.g. "E minor"
    public var tuningCents: Double?       // deviation from A440

    public struct Section: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID = UUID()
        public var label: String
        public var start: Double
        public var end: Double
        public init(label: String, start: Double, end: Double) {
            self.label = label; self.start = start; self.end = end
        }
    }
}

public enum Analyzer {
    static let frame = 2048
    static let hop = 512

    /// `stems` are keyed by Demucs source name ("drums", "bass", "other", "vocals", "guitar", "piano").
    /// `beatGrid` (from Beat This!) replaces the DSP tempo/beat/downbeat tracker when present.
    public static func analyze(stems: [String: StereoAudio], duration: Double,
                               beatGrid: BeatTracker.Result? = nil) -> SongAnalysis {
        let sr = stems.values.first?.sampleRate ?? 44_100
        // Downmix helpers at 22.05 kHz for speed.
        func mono(_ names: [String]) -> [Float] {
            var acc: [Float]?
            for name in names {
                guard let s = stems[name] else { continue }
                var m = [Float](repeating: 0, count: s.frameCount)
                var h: Float = 0.5
                vDSP_vasm(s.left, 1, s.right, 1, &h, &m, 1, vDSP_Length(s.frameCount))
                if acc == nil { acc = m } else { vDSP_vadd(acc!, 1, m, 1, &acc!, 1, vDSP_Length(m.count)) }
            }
            return decimate2(acc ?? [])
        }
        let fsr = sr / 2
        let full = mono(Array(stems.keys))
        let rhythm = mono(["drums", "bass"])

        let fps = fsr / Double(hop)
        var beats: [Double]
        var bpm: Double
        var downbeats: [Double]
        // Beat This! is the primary grid, but when its beats are irregular (odd meters, skipped
        // beats) and the DSP tracker finds a steady grid, trust the steady one.
        var useGrid = beatGrid.map { $0.beats.count >= 8 } ?? false
        var dspCache: (beats: [Double], bpm: Double)?
        if useGrid, let grid = beatGrid, grid.regularity < 0.8 {
            let env = onsetEnvelope(full.isEmpty ? rhythm : full)
            let tempo = estimateTempo(env: env, fps: fps)
            let b = trackBeats(env: env, fps: fps, bpm: tempo.bpm)
            if let r = refinedBPM(b), BeatTracker.regularity(ofBeats: b) > grid.regularity + 0.1 {
                useGrid = false
                dspCache = (b, r)
            }
        }
        if useGrid, let grid = beatGrid {
            beats = grid.beats
            bpm = grid.bpm
            downbeats = grid.downbeats
            // Beat This! occasionally reports 1–2 beats per bar (odd meters); fall back to our phase pick.
            let perBar = downbeats.count > 1 ? Double(beats.count) / Double(downbeats.count) : 0
            if perBar < 2.5 || perBar > 8 {
                let lowEnv = onsetEnvelope(lowpass(rhythm.isEmpty ? full : rhythm, cutoffHz: 180, sr: fsr))
                downbeats = chooseDownbeats(beats: beats, lowEnv: lowEnv, fps: fps)
            }
        } else if let cached = dspCache {
            beats = cached.beats
            bpm = cached.bpm
            let lowEnv = onsetEnvelope(lowpass(rhythm.isEmpty ? full : rhythm, cutoffHz: 180, sr: fsr))
            downbeats = chooseDownbeats(beats: beats, lowEnv: lowEnv, fps: fps)
        } else {
            let env = onsetEnvelope(full.isEmpty ? rhythm : full)
            let tempo = estimateTempo(env: env, fps: fps)
            beats = trackBeats(env: env, fps: fps, bpm: tempo.bpm)
            if beats.isEmpty && tempo.bpm > 0 {
                let period = 60 / tempo.bpm
                beats = Array(Swift.stride(from: tempo.firstBeat, to: duration, by: period))
            }
            bpm = refinedBPM(beats) ?? tempo.bpm
            // Downbeats: choose the phase (of 4) whose beats carry the most low-frequency onset energy.
            let lowEnv = onsetEnvelope(lowpass(rhythm.isEmpty ? full : rhythm, cutoffHz: 180, sr: fsr))
            downbeats = chooseDownbeats(beats: beats, lowEnv: lowEnv, fps: fps)
        }

        // Per-stem RMS per bar for labelling.
        let barEdges = barGrid(downbeats: downbeats, bpm: bpm, duration: duration)
        let energies = stemEnergies(stems: stems, edges: barEdges, sr: sr)

        // Features per bar: 12 chroma + 12 timbre bands (log-spectral envelope) from the harmonic mix.
        let harmonic = mono(["other", "guitar", "piano", "vocals", "bass"])
        let feats = barFeatures(signal: harmonic.isEmpty ? full : harmonic, edges: barEdges, sr: fsr)
        var boundaries = segmentBoundaries(features: feats, energies: energies)
        boundaries = [0] + boundaries.filter { $0 > 0 && $0 < barEdges.count - 1 } + [barEdges.count - 1]
        let sections = labelSections(boundaries: boundaries, edges: barEdges, energies: energies, features: feats, duration: duration)

        let key = detectKey(harmonic.isEmpty ? full : harmonic, sr: fsr)
        let tuning = estimateTuning(harmonic.isEmpty ? full : harmonic, sr: fsr)
        return SongAnalysis(bpm: (bpm * 10).rounded() / 10, beats: beats, downbeats: downbeats,
                            sections: sections, key: key, tuningCents: tuning)
    }

    // MARK: - Signal helpers

    static func decimate2(_ x: [Float]) -> [Float] {
        guard x.count > 16 else { return x }
        // Half-band FIR (31 taps, windowed sinc) then take every 2nd sample.
        let taps = 31
        var h = [Float](repeating: 0, count: taps)
        for i in 0..<taps {
            let n = Float(i - taps / 2)
            let sinc: Float = n == 0 ? 0.5 : sin(.pi * n / 2) / (.pi * n)
            let w = 0.54 - 0.46 * cos(2 * .pi * Float(i) / Float(taps - 1))
            h[i] = sinc * w
        }
        let padded = [Float](repeating: 0, count: taps / 2) + x + [Float](repeating: 0, count: taps)
        let outCount = x.count / 2
        var out = [Float](repeating: 0, count: outCount)
        vDSP_desamp(padded, 2, h, &out, vDSP_Length(outCount), vDSP_Length(taps))
        return out
    }

    static func lowpass(_ x: [Float], cutoffHz: Double, sr: Double) -> [Float] {
        guard !x.isEmpty else { return x }
        // One-pole, applied forward twice (cheap, adequate for an energy envelope).
        let a = Float(exp(-2 * .pi * cutoffHz / sr))
        var y = x
        for _ in 0..<2 {
            var s: Float = 0
            for i in 0..<y.count { s = (1 - a) * y[i] + a * s; y[i] = s }
        }
        return y
    }

    final class FFT {
        let n: Int
        let log2n: vDSP_Length
        let setup: FFTSetup
        let window: [Float]
        init(_ n: Int) {
            self.n = n
            log2n = vDSP_Length(log2(Double(n)))
            setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
            window = (0..<n).map { 0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(n)) }
        }
        deinit { vDSP_destroy_fftsetup(setup) }

        /// Magnitude spectrum (n/2 bins) of x[start..<start+n] (zero padded).
        func magnitudes(_ x: UnsafeBufferPointer<Float>, start: Int, into mag: inout [Float]) {
            var buf = [Float](repeating: 0, count: n)
            let avail = max(0, min(n, x.count - start))
            if avail > 0 { vDSP_vmul(x.baseAddress! + start, 1, window, 1, &buf, 1, vDSP_Length(avail)) }
            var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
            re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                buf.withUnsafeBufferPointer { bp in
                    bp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2)) }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                ip[0] = 0
                vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(n / 2))
            } }
            var s: Float = 0.5
            vDSP_vsmul(mag, 1, &s, &mag, 1, vDSP_Length(n / 2))
        }
    }

    /// Spectral-flux onset strength with local-mean removal (one value per hop).
    static func onsetEnvelope(_ x: [Float]) -> [Float] {
        guard x.count > frame else { return [] }
        let fft = FFT(frame)
        let frames = (x.count - frame) / hop + 1
        let bins = frame / 2
        var env = [Float](repeating: 0, count: frames)
        // Each frame is independent given the previous log-magnitude, so compute log-mags in parallel.
        var logMags = [Float](repeating: 0, count: frames * bins)
        x.withUnsafeBufferPointer { xp in
            logMags.withUnsafeMutableBufferPointer { lm in
                let base = lm.baseAddress!
                DispatchQueue.concurrentPerform(iterations: 8) { worker in
                    var mag = [Float](repeating: 0, count: bins)
                    var t = worker
                    while t < frames {
                        fft.magnitudes(xp, start: t * hop, into: &mag)
                        var k: Float = 100
                        vDSP_vsmul(mag, 1, &k, &mag, 1, vDSP_Length(bins))
                        var one: Float = 1
                        vDSP_vsadd(mag, 1, &one, &mag, 1, vDSP_Length(bins))
                        var nb = Int32(bins)
                        vvlogf(base + t * bins, mag, &nb)
                        t += 8
                    }
                }
            }
        }
        var diff = [Float](repeating: 0, count: bins)
        for t in 1..<frames {
            logMags.withUnsafeBufferPointer { lm in
                vDSP_vsub(lm.baseAddress! + (t - 1) * bins, 1, lm.baseAddress! + t * bins, 1, &diff, 1, vDSP_Length(bins))
            }
            var zero: Float = 0
            vDSP_vthres(diff, 1, &zero, &diff, 1, vDSP_Length(bins))
            var s: Float = 0
            vDSP_sve(diff, 1, &s, vDSP_Length(bins))
            env[t] = s
        }
        // Remove local mean (~0.5 s each side) and half-wave rectify.
        let half = 21
        var prefix = [Double](repeating: 0, count: frames + 1)
        for i in 0..<frames { prefix[i + 1] = prefix[i] + Double(env[i]) }
        var out = [Float](repeating: 0, count: frames)
        for t in 0..<frames {
            let lo = max(0, t - half), hi = min(frames, t + half + 1)
            let mean = Float((prefix[hi] - prefix[lo]) / Double(hi - lo))
            out[t] = max(0, env[t] - mean)
        }
        // Normalise.
        var sd: Float = 0, mean: Float = 0
        vDSP_normalize(out, 1, nil, 1, &mean, &sd, vDSP_Length(frames))
        if sd > 0 { var s = 1 / sd; vDSP_vsmul(out, 1, &s, &out, 1, vDSP_Length(frames)) }
        return out
    }

    /// Tempo by autocorrelation with a log-Gaussian prior around 120 BPM; returns BPM and first-beat time.
    static func estimateTempo(env: [Float], fps: Double) -> (bpm: Double, firstBeat: Double) {
        let lo = Int(fps * 60 / 200), hi = Int(fps * 60 / 60) + 1
        guard env.count > hi * 3 else { return (0, 0) }
        var scores = [Float](repeating: 0, count: hi + 2)
        env.withUnsafeBufferPointer { e in
            for lag in max(1, lo - 1)...(hi + 1) {
                var s: Float = 0
                vDSP_dotpr(e.baseAddress! + lag, 1, e.baseAddress!, 1, &s, vDSP_Length(env.count - lag))
                scores[lag] = s / Float(env.count - lag)
            }
        }
        // Harmonic enhancement: reward lags whose double also correlates (helps octave errors).
        var best = (lag: lo, score: -Float.greatestFiniteMagnitude)
        for lag in lo...hi {
            let bpm = 60 * fps / Double(lag)
            let prior = Float(exp(-0.5 * pow(log2(bpm / 120) / 0.9, 2)))
            let dbl = 2 * lag < scores.count ? scores[2 * lag] : 0
            let s = (scores[lag] + 0.5 * dbl) * prior
            if s > best.score { best = (lag, s) }
        }
        guard best.score > 0 else { return (0, 0) }
        let a = scores[best.lag - 1], b = scores[best.lag], c = scores[best.lag + 1]
        let denom = a - 2 * b + c
        let period = Double(best.lag) + (abs(denom) > 1e-12 ? Double(0.5 * (a - c) / denom) : 0)
        // Beat phase: comb that collects the most onset strength.
        var phase = (o: 0, s: -Float.greatestFiniteMagnitude)
        for o in 0..<Int(period.rounded(.up)) {
            var s: Float = 0
            var k = 0.0
            while Int(Double(o) + k * period) < env.count { s += env[Int(Double(o) + k * period)]; k += 1 }
            if s > phase.s { phase = (o, s) }
        }
        return (60 * fps / period, Double(phase.o) / fps)
    }

    /// Ellis (2007) dynamic-programming beat tracker (as in librosa.beat).
    static func trackBeats(env: [Float], fps: Double, bpm: Double, tightness: Double = 100) -> [Double] {
        guard bpm > 0, env.count > 16 else { return [] }
        let period = 60 * fps / bpm
        // Local score: onset envelope smoothed by a Gaussian of width period/32.
        let w = Int(period)
        var kernel = [Float](repeating: 0, count: 2 * w + 1)
        for i in -w...w { kernel[i + w] = Float(exp(-0.5 * pow(Double(i) * 32 / period, 2))) }
        let padded = [Float](repeating: 0, count: w) + env + [Float](repeating: 0, count: w)
        var local = [Float](repeating: 0, count: env.count)
        vDSP_conv(padded, 1, kernel, 1, &local, 1, vDSP_Length(env.count), vDSP_Length(kernel.count))

        let n = env.count
        var cum = [Float](repeating: 0, count: n)
        var back = [Int](repeating: -1, count: n)
        let lo = Int((period / 2).rounded()), hi = Int((2 * period).rounded())
        var txcost = [Float](repeating: 0, count: hi - lo + 1)
        for (j, d) in (lo...hi).enumerated() {
            txcost[j] = Float(-tightness * pow(log(Double(d) / period), 2))
        }
        var firstBeat = true
        let thresh = 0.01 * (local.max() ?? 0)
        for i in 0..<n {
            var bestScore: Float = -.greatestFiniteMagnitude, bestIdx = -1
            if i - lo >= 0 {
                for (j, d) in (lo...hi).enumerated() where i - d >= 0 {
                    let s = cum[i - d] + txcost[j]
                    if s > bestScore { bestScore = s; bestIdx = i - d }
                }
            }
            cum[i] = local[i] + (bestIdx >= 0 ? bestScore : 0)
            if firstBeat && local[i] < thresh { back[i] = -1 } else { back[i] = bestIdx; firstBeat = false }
        }
        // Last beat: highest local maximum of cumulative score above half the median of maxima.
        var maxima: [Int] = []
        for i in 1..<(n - 1) where cum[i] > cum[i - 1] && cum[i] >= cum[i + 1] { maxima.append(i) }
        guard !maxima.isEmpty else { return [] }
        let vals = maxima.map { cum[$0] }.sorted()
        let med = vals[vals.count / 2]
        var last = maxima.last!
        for m in maxima.reversed() where cum[m] >= 0.5 * med { last = m; break }
        var beats: [Int] = []
        var i = last
        while i >= 0 { beats.append(i); i = back[i] }
        beats.reverse()
        // Trim weak beats at the edges.
        let strong = beats.map { local[$0] }
        let mean = strong.reduce(0, +) / Float(max(1, strong.count))
        while let f = beats.first, local[f] < 0.2 * mean { beats.removeFirst() }
        while let l = beats.last, local[l] < 0.2 * mean { beats.removeLast() }
        // Onset envelope frame t is centred at sample t*hop + frame/2 of the analysis signal.
        let offset = Double(frame) / 2 / (fps * Double(hop))
        var times = beats.map { Double($0) / fps + offset - 0.5 / fps }
        // Extrapolate the grid back to the start (weak pickup beats are trimmed above).
        if times.count >= 2 {
            let p = 60 / bpm
            while let f = times.first, f - p > -0.08 { times.insert(max(0, f - p), at: 0) }
        }
        return times
    }

    static func refinedBPM(_ beats: [Double]) -> Double? {
        guard beats.count > 8 else { return nil }
        var ibis = zip(beats.dropFirst(), beats).map { $0 - $1 }.sorted()
        ibis = Array(ibis[(ibis.count / 5)..<(ibis.count * 4 / 5)])
        let mean = ibis.reduce(0, +) / Double(ibis.count)
        return mean > 0 ? 60 / mean : nil
    }

    static func chooseDownbeats(beats: [Double], lowEnv: [Float], fps: Double) -> [Double] {
        guard beats.count >= 8 else { return beats }
        func strength(_ t: Double) -> Float {
            let i = Int((t * fps).rounded())
            let lo = max(0, i - 2), hi = min(lowEnv.count - 1, i + 2)
            guard lo <= hi else { return 0 }
            return lowEnv[lo...hi].max() ?? 0
        }
        var best = (phase: 0, score: -Float.greatestFiniteMagnitude)
        for p in 0..<4 {
            var s: Float = 0, c = 0
            var i = p
            while i < beats.count { s += strength(beats[i]); c += 1; i += 4 }
            // Beats 1 and 3 both carry kick; prefer the phase whose next-by-two is weaker on average.
            let avg = s / Float(max(1, c))
            if avg > best.score { best = (p, avg) }
        }
        var out: [Double] = []
        var i = best.phase
        while i < beats.count { out.append(beats[i]); i += 4 }
        // Extend one bar back to cover pickup/intro before the first detected downbeat.
        if let first = out.first, out.count > 1 {
            let bar = out[1] - out[0]
            var t = first - bar
            while t > -bar * 0.25 { out.insert(max(0, t), at: 0); t -= bar }
        }
        return out
    }

    /// Bar edges in seconds from 0 to duration. Falls back to 4/4 at the tempo if no downbeats.
    static func barGrid(downbeats: [Double], bpm: Double, duration: Double) -> [Double] {
        var edges: [Double] = []
        if downbeats.count >= 2 {
            edges = downbeats.filter { $0 < duration }
            let bar = (edges.last! - edges.first!) / Double(edges.count - 1)
            if edges.first! > 0.05 { edges.insert(0, at: 0) }
            var t = edges.last! + bar
            while t < duration - bar * 0.3 { edges.append(t); t += bar }
        } else {
            let bar = bpm > 0 ? 240 / bpm : 8
            edges = Array(Swift.stride(from: 0, to: duration, by: bar))
        }
        if edges.last! < duration { edges.append(duration) } else { edges[edges.count - 1] = duration }
        return edges
    }

    /// RMS per stem per bar.
    static func stemEnergies(stems: [String: StereoAudio], edges: [Double], sr: Double) -> [String: [Float]] {
        var out: [String: [Float]] = [:]
        for (name, s) in stems {
            var e = [Float](repeating: 0, count: edges.count - 1)
            s.left.withUnsafeBufferPointer { l in
                s.right.withUnsafeBufferPointer { r in
                    for b in 0..<(edges.count - 1) {
                        let a = min(s.frameCount, Int(edges[b] * sr)), z = min(s.frameCount, Int(edges[b + 1] * sr))
                        guard z > a else { continue }
                        var ml: Float = 0, mr: Float = 0
                        vDSP_measqv(l.baseAddress! + a, 1, &ml, vDSP_Length(z - a))
                        vDSP_measqv(r.baseAddress! + a, 1, &mr, vDSP_Length(z - a))
                        e[b] = sqrt((ml + mr) / 2)
                    }
                }
            }
            out[name] = e
        }
        return out
    }

    /// Per-bar feature vectors: L2-normalised chroma (12) ⊕ normalised log band energies (12).
    static func barFeatures(signal: [Float], edges: [Double], sr: Double) -> [[Float]] {
        let n = 4096
        let fft = FFT(n)
        let bins = n / 2
        // Bin → pitch class, bin → band (log-spaced 60 Hz..10 kHz).
        var pc = [Int](repeating: -1, count: bins)
        var band = [Int](repeating: -1, count: bins)
        for b in 1..<bins {
            let f = Double(b) * sr / Double(n)
            if f >= 60 && f <= 2500 { pc[b] = Int((12 * log2(f / 261.63)).rounded()).mod(12) }
            if f >= 60 && f <= 10_000 { band[b] = min(11, Int(12 * log2(f / 60) / log2(10_000 / 60))) }
        }
        var feats = [[Float]](repeating: [Float](repeating: 0, count: 24), count: edges.count - 1)
        signal.withUnsafeBufferPointer { x in
            DispatchQueue.concurrentPerform(iterations: edges.count - 1) { b in
                var mag = [Float](repeating: 0, count: bins)
                var chroma = [Float](repeating: 0, count: 12)
                var bands = [Float](repeating: 0, count: 12)
                let a = Int(edges[b] * sr), z = min(x.count, Int(edges[b + 1] * sr))
                var start = a
                var frames = 0
                while start + n / 2 < z {
                    fft.magnitudes(x, start: start, into: &mag)
                    for k in 1..<bins {
                        let p = mag[k] * mag[k]
                        if pc[k] >= 0 { chroma[pc[k]] += p }
                        if band[k] >= 0 { bands[band[k]] += p }
                    }
                    frames += 1
                    start += n
                }
                guard frames > 0 else { return }
                chroma = chroma.map { sqrt($0) }
                let cn = sqrt(chroma.reduce(0) { $0 + $1 * $1 })
                if cn > 0 { chroma = chroma.map { $0 / cn } }
                bands = bands.map { log(1 + $0 / Float(frames)) }
                let bm = bands.reduce(0, +) / 12
                bands = bands.map { $0 - bm }
                let bn = sqrt(bands.reduce(0) { $0 + $1 * $1 })
                if bn > 0 { bands = bands.map { $0 / bn } }
                feats[b] = chroma + bands
            }
        }
        return feats
    }

    /// Foote novelty on the bar-level self-similarity matrix, plus stem-energy change novelty.
    /// Returns boundary indices into bars (a boundary at i means a section starts at bar i).
    static func segmentBoundaries(features: [[Float]], energies: [String: [Float]]) -> [Int] {
        let n = features.count
        guard n >= 8 else { return [] }
        // Stem-activity vector per bar (vocals/guitar/drums/bass/keys/other levels, log-compressed).
        let order = ["vocals", "guitar", "drums", "bass", "piano", "other"]
        var act = [[Float]](repeating: [Float](repeating: 0, count: order.count), count: n)
        for (j, name) in order.enumerated() {
            guard let e = energies[name], e.count == n else { continue }
            let peak = max(1e-6, e.max() ?? 1)
            for i in 0..<n { act[i][j] = log(1 + 20 * e[i] / peak) / log(21) }
        }
        let feats: [[Float]] = (0..<n).map { features[$0] + act[$0].map { $0 * 0.8 } }
        let d = feats[0].count
        // Cosine similarity matrix via BLAS (vDSP_mmul).
        var flat = [Float](repeating: 0, count: n * d)
        for i in 0..<n {
            let v = feats[i]
            let norm = max(1e-9, sqrt(v.reduce(0) { $0 + $1 * $1 }))
            for k in 0..<d { flat[i * d + k] = v[k] / norm }
        }
        var ssm = [Float](repeating: 0, count: n * n)
        var flatT = [Float](repeating: 0, count: n * d)
        vDSP_mtrans(flat, 1, &flatT, 1, vDSP_Length(d), vDSP_Length(n))
        vDSP_mmul(flat, 1, flatT, 1, &ssm, 1, vDSP_Length(n), vDSP_Length(n), vDSP_Length(d))

        // Gaussian-tapered checkerboard kernel, half-width 4 bars (a typical phrase). Near the edges only
        // the in-range part of the kernel is used and the score is normalised by its weight, so the song
        // start/end don't produce spurious peaks.
        let L = min(4, n / 4)
        var novelty = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var s: Float = 0, wsum: Float = 0
            for a in -L..<L {
                for b in -L..<L {
                    let x = i + a, y = i + b
                    guard x >= 0, y >= 0, x < n, y < n else { continue }
                    let sign: Float = ((a < 0) == (b < 0)) ? 1 : -1
                    let g = exp(-Float(pow(Double(a) + 0.5, 2) + pow(Double(b) + 0.5, 2)) / (Float(L * L)))
                    s += sign * g * ssm[x * n + y]
                    wsum += g
                }
            }
            // Only a full two-sided window can see a change.
            let twoSided = i - L >= 0 && i + L <= n
            novelty[i] = twoSided && wsum > 0 ? max(0, s / wsum) : 0
        }
        if ProcessInfo.processInfo.environment["BL_DEBUG"] != nil {
            print("novelty", novelty.map { String(format: "%.3f", $0) }.joined(separator: " "))
        }
        // Peak-pick: local maxima (±2 bars) above median + 1.0 × MAD, at least 4 bars apart,
        // strongest first; target roughly one section per 8–16 bars.
        let interior = Array(novelty[L..<max(L + 1, n - L)])
        let sorted = interior.sorted()
        let med = sorted[sorted.count / 2]
        let mad = interior.map { abs($0 - med) }.sorted()[sorted.count / 2]
        let thresh = med + 1.0 * mad
        var peaks: [(Int, Float)] = []
        for i in L..<(n - L) where novelty[i] > thresh && novelty[i] == novelty[max(0, i - 2)...min(n - 1, i + 2)].max() {
            peaks.append((i, novelty[i]))
        }
        // Sections are musical phrases: at least 8 bars apart, about one per 10 bars overall.
        let maxBoundaries = max(2, n / 10)
        var chosen: [Int] = []
        for (i, _) in peaks.sorted(by: { $0.1 > $1.1 }) {
            if chosen.count >= maxBoundaries { break }
            if chosen.allSatisfy({ abs($0 - i) >= 8 }) && i >= 4 && n - i >= 4 { chosen.append(i) }
        }
        return chosen.sorted()
    }

    /// Names segments: repetition letters by feature similarity, then musical labels via stem heuristics.
    static func labelSections(boundaries: [Int], edges: [Double], energies: [String: [Float]],
                              features: [[Float]], duration: Double) -> [SongAnalysis.Section] {
        let segs = zip(boundaries.dropLast(), boundaries.dropFirst()).map { ($0, $1) }.filter { $1 > $0 }
        guard !segs.isEmpty else { return [SongAnalysis.Section(label: "Song", start: 0, end: duration)] }
        func mean(_ name: String, _ s: (Int, Int)) -> Float {
            guard let e = energies[name], s.1 <= e.count, s.1 > s.0 else { return 0 }
            return e[s.0..<s.1].reduce(0, +) / Float(s.1 - s.0)
        }
        func median(_ name: String) -> Float {
            guard let e = energies[name], !e.isEmpty else { return 0 }
            let s = e.sorted(); return s[s.count / 2]
        }
        func peak(_ name: String) -> Float { max(1e-6, energies[name]?.max() ?? 1e-6) }
        let total = (0..<(edges.count - 1)).map { b in
            ["drums", "bass", "other", "vocals", "guitar", "piano"].reduce(Float(0)) { $0 + (energies[$1]?[b] ?? 0) }
        }
        let totalPeak = max(1e-6, total.max() ?? 1)

        var labels = [String](repeating: "", count: segs.count)
        let vocalPeak = peak("vocals"), vocalMed = median("vocals")
        let hasVocals = vocalPeak > 0.02 && vocalMed > 0.004
        // Guitar share of the mix per segment vs. the song's typical share.
        func share(_ s: (Int, Int)) -> Float {
            let t = s.1 > s.0 ? total[s.0..<s.1].reduce(0, +) / Float(s.1 - s.0) : 0
            return t > 0 ? mean("guitar", s) / t : 0
        }
        let shares = segs.map(share)
        let medShare = shares.sorted()[shares.count / 2]
        var soloScore = [Float](repeating: 0, count: segs.count)
        let guitarMed = max(median("guitar"), 1e-6)
        // Only call something a guitar solo when guitar is a real part of this mix.
        let guitarMatters = (shares.max() ?? 0) >= 0.08
        for (k, s) in segs.enumerated() {
            let v = mean("vocals", s)
            let loud = s.1 > s.0 ? total[s.0..<s.1].reduce(0, +) / Float(s.1 - s.0) / totalPeak : 0
            let isFirst = k == 0, isLast = k == segs.count - 1
            let bars = s.1 - s.0
            let lift = mean("guitar", s) / guitarMed
            if guitarMatters && !isFirst && !isLast && bars >= 4 && loud > 0.45 {
                if hasVocals {
                    // Vocals drop out while guitar steps up.
                    if v < 0.35 * max(vocalMed, 1e-6) && lift > 1.15 { soloScore[k] = lift }
                } else if lift > 1.3 {
                    soloScore[k] = lift
                }
            }
            if isFirst && (v < 0.3 * vocalPeak || loud < 0.5) && bars <= 12 {
                labels[k] = "Intro"
            } else if isLast && (v < 0.3 * vocalPeak || loud < 0.5) && bars <= 16 {
                labels[k] = "Outro"
            }
        }
        if ProcessInfo.processInfo.environment["BL_DEBUG"] != nil {
            for (k, sg) in segs.enumerated() {
                let loud = total[sg.0..<sg.1].reduce(0, +) / Float(sg.1 - sg.0) / totalPeak
                print(String(format: "seg %5.1f-%5.1f  gtr %.4f (med %.4f) share %.2f (med %.2f) voc %.4f loud %.2f other %.4f", edges[sg.0], edges[sg.1], mean("guitar", sg), median("guitar"), shares[k], medShare, mean("vocals", sg), loud, mean("other", sg)))
            }
        }
        // With vocals every qualifying gap is a solo; in instrumentals only the standout one or two.
        let soloCandidates = soloScore.indices.filter { soloScore[$0] > 0 && labels[$0].isEmpty }
        let maxSolos = hasVocals ? soloCandidates.count : 1
        for k in soloCandidates.sorted(by: { soloScore[$0] > soloScore[$1] }).prefix(maxSolos) { labels[k] = "Solo" }
        // Remaining: cluster by mean feature similarity; the loudest recurring cluster → "Chorus",
        // the first other recurring cluster → "Verse", non-recurring → "Bridge"/"Section".
        let rest = labels.indices.filter { labels[$0].isEmpty }
        func meanFeat(_ s: (Int, Int)) -> [Float] {
            var m = [Float](repeating: 0, count: features[0].count)
            for b in s.0..<s.1 { for i in m.indices { m[i] += features[b][i] } }
            let norm = max(1e-9, sqrt(m.reduce(0) { $0 + $1 * $1 }))
            return m.map { $0 / norm }
        }
        var cluster = [Int](repeating: -1, count: segs.count)
        var reps: [[Float]] = []
        for k in rest {
            let f = meanFeat(segs[k])
            var best = (-1, Float(0))
            for (c, r) in reps.enumerated() {
                let sim = zip(f, r).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                if sim > best.1 { best = (c, sim) }
            }
            if best.0 >= 0 && best.1 > 0.92 { cluster[k] = best.0 } else { cluster[k] = reps.count; reps.append(f) }
        }
        var clusterLoud: [Int: Float] = [:], clusterCount: [Int: Int] = [:]
        for k in rest {
            let s = segs[k]
            let loud = total[s.0..<s.1].reduce(0, +) / Float(s.1 - s.0)
            clusterLoud[cluster[k], default: 0] += loud
            clusterCount[cluster[k], default: 0] += 1
        }
        let recurring = clusterCount.filter { $0.value >= 2 }.map(\.key)
        let chorus = recurring.max { (clusterLoud[$0]! / Float(clusterCount[$0]!)) < (clusterLoud[$1]! / Float(clusterCount[$1]!)) }
        var verse: Int?
        for k in rest where recurring.contains(cluster[k]) && cluster[k] != chorus { verse = cluster[k]; break }
        for k in rest {
            if cluster[k] == chorus && hasVocals { labels[k] = "Chorus" }
            else if cluster[k] == verse && hasVocals { labels[k] = "Verse" }
            else if hasVocals && recurring.isEmpty == false && clusterCount[cluster[k]] == 1 && k > 0 && k < segs.count - 1 { labels[k] = "Bridge" }
            else { labels[k] = "" }
        }
        // Number repeated names ("Verse 1", "Verse 2"); generic fallback "Part A/B/…".
        var counts: [String: Int] = [:]
        for l in labels where !l.isEmpty { counts[l, default: 0] += 1 }
        var seen: [String: Int] = [:]
        var generic = 0
        var result: [SongAnalysis.Section] = []
        for (k, s) in segs.enumerated() {
            var name = labels[k]
            if name.isEmpty {
                generic += 1
                name = "Section \(generic)"
            } else if (counts[name] ?? 0) > 1 && (name == "Verse" || name == "Solo") {
                seen[name, default: 0] += 1
                name += " \(seen[name]!)"
            }
            result.append(SongAnalysis.Section(label: name, start: edges[s.0], end: min(duration, edges[s.1])))
        }
        return mergeAdjacent(result, rawLabels: labels)
    }

    /// Merges consecutive segments that share a musical label (e.g. two Solo halves) and renumbers.
    static func mergeAdjacent(_ secs: [SongAnalysis.Section], rawLabels: [String]) -> [SongAnalysis.Section] {
        guard secs.count == rawLabels.count, !secs.isEmpty else { return secs }
        var merged: [(String, Double, Double)] = []
        for (i, s) in secs.enumerated() {
            let base = rawLabels[i]
            if !base.isEmpty, let last = merged.last, last.0 == base {
                merged[merged.count - 1].2 = s.end
            } else {
                merged.append((base, s.start, s.end))
            }
        }
        var counts: [String: Int] = [:]
        for m in merged where !m.0.isEmpty { counts[m.0, default: 0] += 1 }
        var seen: [String: Int] = [:]
        var generic = 0
        return merged.map { m in
            var name = m.0
            if name.isEmpty { generic += 1; name = "Section \(generic)" }
            else if (counts[name] ?? 0) > 1 && name != "Chorus" && name != "Intro" && name != "Outro" {
                seen[name, default: 0] += 1; name += " \(seen[name]!)"
            }
            return SongAnalysis.Section(label: name, start: m.1, end: m.2)
        }
    }

    // MARK: - Key & tuning

    static let major: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minor: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
    static let noteNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

    static func detectKey(_ x: [Float], sr: Double) -> String? {
        let n = 8192
        guard x.count > n * 4 else { return nil }
        let fft = FFT(n)
        var chroma = [Float](repeating: 0, count: 12)
        var mag = [Float](repeating: 0, count: n / 2)
        x.withUnsafeBufferPointer { xp in
            var start = 0
            while start + n < xp.count {
                fft.magnitudes(xp, start: start, into: &mag)
                for b in 1..<(n / 2) {
                    let f = Double(b) * sr / Double(n)
                    guard f >= 65 && f <= 2000 else { continue }
                    let pc = Int((12 * log2(f / 261.63)).rounded()).mod(12)
                    chroma[pc] += mag[b] * mag[b]
                }
                start += n * 2
            }
        }
        guard chroma.reduce(0, +) > 1e-9 else { return nil }
        chroma = chroma.map { sqrt($0) }
        func corr(_ a: [Float], _ b: [Float], _ shift: Int) -> Float {
            let ma = a.reduce(0, +) / 12, mb = b.reduce(0, +) / 12
            var n: Float = 0, da: Float = 0, db: Float = 0
            for i in 0..<12 { let x = a[(i + shift) % 12] - ma, y = b[i] - mb; n += x * y; da += x * x; db += y * y }
            return da * db > 0 ? n / sqrt(da * db) : 0
        }
        var best = (name: "", r: -Float.greatestFiniteMagnitude)
        for k in 0..<12 {
            let rM = corr(chroma, major, k), rm = corr(chroma, minor, k)
            if rM > best.r { best = ("\(noteNames[k]) major", rM) }
            if rm > best.r { best = ("\(noteNames[k]) minor", rm) }
        }
        return best.name
    }

    /// Deviation from A440 in cents (−50…50), from a histogram of spectral-peak offsets (librosa-style).
    static func estimateTuning(_ x: [Float], sr: Double) -> Double? {
        let n = 8192
        guard x.count > n * 4 else { return nil }
        let fft = FFT(n)
        var mag = [Float](repeating: 0, count: n / 2)
        var hist = [Float](repeating: 0, count: 100)
        x.withUnsafeBufferPointer { xp in
            var start = 0
            while start + n < xp.count {
                fft.magnitudes(xp, start: start, into: &mag)
                let thr = (mag.max() ?? 0) * 0.1
                for b in 2..<(n / 2 - 1) where mag[b] > thr && mag[b] > mag[b - 1] && mag[b] >= mag[b + 1] {
                    let a = mag[b - 1], c = mag[b], d = mag[b + 1]
                    let den = a - 2 * c + d
                    let delta = abs(den) > 1e-12 ? 0.5 * (a - d) / den : 0
                    let f = (Double(b) + Double(delta)) * sr / Double(n)
                    guard f >= 80 && f <= 2000 else { continue }
                    let midi = 69 + 12 * log2(f / 440)
                    let dev = midi - midi.rounded()          // −0.5…0.5
                    let bin = min(99, max(0, Int((dev + 0.5) * 100)))
                    hist[bin] += c
                }
                start += n * 2
            }
        }
        guard let peakIdx = hist.indices.max(by: { hist[$0] < hist[$1] }), hist[peakIdx] > 0 else { return nil }
        return (Double(peakIdx) + 0.5) - 50
    }
}

extension Int {
    func mod(_ m: Int) -> Int { let r = self % m; return r < 0 ? r + m : r }
}
