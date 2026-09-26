import Accelerate
import CoreML
import Foundation

/// Beat and downbeat tracking with Beat This! (Foscarin, Schlüter & Widmer, ISMIR 2024; code and
/// weights MIT) running as Core ML on the GPU. The log-mel front end and the "minimal"
/// post-processing are re-implemented with vDSP to match the reference `beat_this` package
/// (validated against `ml/fixtures_beat`).
public final class BeatTracker: @unchecked Sendable {
    public static let sampleRate = 22_050.0
    static let nfft = 1024
    static let hop = 441
    static let mels = 128
    static let chunk = 1500
    static let border = 6
    static let fps = 50.0

    public struct Result: Sendable, Equatable {
        public var beats: [Double]
        public var downbeats: [Double]
        public var bpm: Double
        public var regularity: Double = 1
    }

    private let model: MLModel
    private let fbank: [Float]          // [513][128] row-major
    private let window: [Float]
    private let fft: FFTSetup
    private let log2n: vDSP_Length

    public init(modelURL: URL, computeUnits: MLComputeUnits = .cpuAndGPU) throws {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        config.allowLowPrecisionAccumulationOnGPU = false
        model = try MLModel(contentsOf: modelURL, configuration: config)
        fbank = Self.slaneyMelFilterbank()
        window = (0..<Self.nfft).map { 0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(Self.nfft)) }
        log2n = vDSP_Length(log2(Double(Self.nfft)))
        fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    /// Finds the compiled model in `bundle`, or compiles an `.mlpackage` (cached) for CLI/tests.
    public static func locateModel(in bundle: Bundle = .main, packageFallback: URL? = nil) async throws -> URL {
        if let url = bundle.url(forResource: "BeatThisSmall", withExtension: "mlmodelc") { return url }
        guard let pkg = packageFallback else { throw CocoaError(.fileNoSuchFile) }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("BacklineModelCache", isDirectory: true)
        let cache = dir.appendingPathComponent("BeatThisSmall.mlmodelc")
        if fm.fileExists(atPath: cache.path) { return cache }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let compiled = try await MLModel.compileModel(at: pkg)
        try? fm.removeItem(at: cache)
        try fm.moveItem(at: compiled, to: cache)
        return cache
    }

    // MARK: Front end

    /// Slaney-scale mel filterbank (torchaudio `melscale_fbanks`, norm=None), 30–11000 Hz. [513][128].
    static func slaneyMelFilterbank(sr: Double = sampleRate, nfft: Int = nfft, nMels: Int = mels,
                                    fmin: Double = 30, fmax: Double = 11_000) -> [Float] {
        func hz2mel(_ f: Double) -> Double {
            f >= 1000 ? 15 + log(f / 1000) / (log(6.4) / 27) : f / (200.0 / 3)
        }
        func mel2hz(_ m: Double) -> Double {
            m >= 15 ? 1000 * exp((log(6.4) / 27) * (m - 15)) : m * (200.0 / 3)
        }
        let bins = nfft / 2 + 1
        let allFreqs = (0..<bins).map { Double($0) * (sr / 2) / Double(bins - 1) }
        let mMin = hz2mel(fmin), mMax = hz2mel(fmax)
        let fPts = (0..<(nMels + 2)).map { mel2hz(mMin + (mMax - mMin) * Double($0) / Double(nMels + 1)) }
        var fb = [Float](repeating: 0, count: bins * nMels)
        for b in 0..<bins {
            for m in 0..<nMels {
                let down = -(fPts[m] - allFreqs[b]) / (fPts[m + 1] - fPts[m])
                let up = (fPts[m + 2] - allFreqs[b]) / (fPts[m + 2] - fPts[m + 1])
                fb[b * nMels + m] = Float(max(0, min(down, up)))
            }
        }
        return fb
    }

    /// log1p(1000 · mel(|STFT| / √1024)), frames = 1 + n / 441, layout [frames][128].
    func melSpectrogram(_ x: [Float]) -> [Float] {
        let n = Self.nfft, hop = Self.hop, half = n / 2, bins = half + 1
        let padded = x.withUnsafeBufferPointer { DemucsSTFT.reflectPad($0.baseAddress!, count: x.count, left: half, right: half) }
        let frames = 1 + (padded.count - n) / hop
        var mags = [Float](repeating: 0, count: frames * bins)
        let scale = 0.5 / sqrt(Float(n))            // zrip gives 2× DFT; normalized="frame_length"
        padded.withUnsafeBufferPointer { src in
            mags.withUnsafeMutableBufferPointer { out in
                let outBase = out.baseAddress!
                DispatchQueue.concurrentPerform(iterations: 8) { w in
                    var frame = [Float](repeating: 0, count: n)
                    var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
                    var t = w
                    while t < frames {
                        vDSP_vmul(src.baseAddress! + t * hop, 1, window, 1, &frame, 1, vDSP_Length(n))
                        re.withUnsafeMutableBufferPointer { rp in
                            im.withUnsafeMutableBufferPointer { ip in
                                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                                frame.withUnsafeBufferPointer { fp in
                                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                                    }
                                }
                                vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                                let row = outBase + t * bins
                                row[0] = abs(rp[0]) * scale
                                row[half] = abs(ip[0]) * scale        // Nyquist packed in imag[0]
                                for k in 1..<half { row[k] = hypot(rp[k], ip[k]) * scale }
                            }
                        }
                        t += 8
                    }
                }
            }
        }
        // [frames × 513] · [513 × 128]
        var mel = [Float](repeating: 0, count: frames * Self.mels)
        vDSP_mmul(mags, 1, fbank, 1, &mel, 1, vDSP_Length(frames), vDSP_Length(Self.mels), vDSP_Length(bins))
        var k: Float = 1000
        vDSP_vsmul(mel, 1, &k, &mel, 1, vDSP_Length(mel.count))
        var count = Int32(mel.count)
        vvlog1pf(&mel, mel, &count)
        return mel
    }

    // MARK: Model

    /// One model pass over exactly 1500 frames of mel.
    func predictChunk(_ mel: UnsafePointer<Float>, into input: MLMultiArray) throws -> (beat: [Float], downbeat: [Float]) {
        let T = Self.chunk
        input.dataPointer.assumingMemoryBound(to: Float.self).update(from: mel, count: T * Self.mels)
        let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["mel": MLFeatureValue(multiArray: input)]))
        guard let ob = out.featureValue(for: "beat")?.multiArrayValue,
              let od = out.featureValue(for: "downbeat")?.multiArrayValue else { throw CocoaError(.coderValueNotFound) }
        return (Self.vector(ob, count: T), Self.vector(od, count: T))
    }

    func logits(mel: [Float]) throws -> (beat: [Float], downbeat: [Float]) {
        let L = mel.count / Self.mels
        let T = Self.chunk, B = Self.border, stride = T - 2 * B
        var starts = Array(Swift.stride(from: -B, to: L - B, by: stride))
        if L > stride, !starts.isEmpty { starts[starts.count - 1] = L - (T - B) }
        var beat = [Float](repeating: -1000, count: L)
        var down = [Float](repeating: -1000, count: L)
        let input = try MLMultiArray(shape: [1, NSNumber(value: T), NSNumber(value: Self.mels)], dataType: .float32)
        var chunkMel = [Float](repeating: 0, count: T * Self.mels)
        for s in starts.reversed() {       // earlier chunks win on overlaps
            for i in chunkMel.indices { chunkMel[i] = 0 }
            let a = max(s, 0), b = min(s + T, L)
            if b > a {
                mel.withUnsafeBufferPointer { m in
                    chunkMel.withUnsafeMutableBufferPointer { c in
                        (c.baseAddress! + (a - s) * Self.mels).update(from: m.baseAddress! + a * Self.mels, count: (b - a) * Self.mels)
                    }
                }
            }
            let (bArr, dArr) = try chunkMel.withUnsafeBufferPointer { try predictChunk($0.baseAddress!, into: input) }
            let lo = s + B, hi = min(s + T - B, L)
            guard hi > lo else { continue }
            for i in lo..<hi {
                beat[i] = bArr[B + i - lo]
                down[i] = dArr[B + i - lo]
            }
        }
        return (beat, down)
    }

    /// Reads the last dimension of a [1, N] multi-array honouring its stride (Core ML pads rows).
    static func vector(_ a: MLMultiArray, count n: Int) -> [Float] {
        let stride = a.strides.last?.intValue ?? 1
        var out = [Float](repeating: 0, count: n)
        a.withUnsafeBufferPointer(ofType: Float.self) { src in
            for i in 0..<n { out[i] = src[i * stride] }
        }
        return out
    }

    // MARK: Post-processing

    /// Frames that are the maximum of a ±3-frame window and positive; adjacent peaks merged to their mean. Seconds.
    static func peaks(_ logit: [Float]) -> [Double] {
        let n = logit.count
        var frames: [Int] = []
        for t in 0..<n where logit[t] > 0 {
            var isMax = true
            for d in -3...3 where d != 0 {
                let u = t + d
                if u >= 0 && u < n && logit[u] > logit[t] { isMax = false; break }
            }
            if isMax { frames.append(t) }
        }
        var out: [Double] = []
        var cur: Double?
        var c = 0.0
        for f in frames {
            if let v = cur, Double(f) - v <= 1 {
                c += 1
                cur = v + (Double(f) - v) / c
            } else {
                if let v = cur { out.append(v) }
                cur = Double(f); c = 1
            }
        }
        if let v = cur { out.append(v) }
        return out.map { $0 / fps }
    }

    static func postprocess(beat: [Float], downbeat: [Float]) -> (beats: [Double], downbeats: [Double]) {
        let b = peaks(beat)
        var d = peaks(downbeat)
        if !b.isEmpty {
            d = Array(Set(d.map { t in b.min { abs($0 - t) < abs($1 - t) }! })).sorted()
        }
        return (b, d)
    }

    /// 60 / mean inter-beat interval over intervals within ±15 % of the median.
    public static func bpm(fromBeats b: [Double]) -> Double? {
        guard b.count >= 8 else { return nil }
        let ibi = zip(b.dropFirst(), b).map { $0 - $1 }
        let med = ibi.sorted()[ibi.count / 2]
        let good = ibi.filter { abs($0 / med - 1) < 0.15 }
        guard !good.isEmpty else { return nil }
        return 60 / (good.reduce(0, +) / Double(good.count))
    }

    /// How consistent the beat grid is: share of inter-beat intervals within ±15 % of the median.
    /// Irregular grids (odd meters, half-time/double-time switching) score low.
    public static func regularity(ofBeats b: [Double]) -> Double {
        guard b.count >= 8 else { return 0 }
        let ibi = zip(b.dropFirst(), b).map { $0 - $1 }
        let med = ibi.sorted()[ibi.count / 2]
        return Double(ibi.filter { abs($0 / med - 1) < 0.15 }.count) / Double(ibi.count)
    }

    // MARK: Public

    /// Tracks beats in a 22.05 kHz mono signal.
    public func track(mono22k x: [Float]) throws -> Result? {
        guard x.count > Self.nfft * 4 else { return nil }
        let mel = melSpectrogram(x)
        let (b, d) = try logits(mel: mel)
        let (beats, downbeats) = Self.postprocess(beat: b, downbeat: d)
        guard let bpm = Self.bpm(fromBeats: beats) else { return nil }
        return Result(beats: beats, downbeats: downbeats, bpm: bpm, regularity: Self.regularity(ofBeats: beats))
    }

    /// Tracks beats in 44.1 kHz stereo (averaged to mono, decimated ×2 with the analysis half-band filter).
    public func track(_ audio: StereoAudio) throws -> Result? {
        var mono = [Float](repeating: 0, count: audio.frameCount)
        var h: Float = 0.5
        vDSP_vasm(audio.left, 1, audio.right, 1, &h, &mono, 1, vDSP_Length(audio.frameCount))
        let x = abs(audio.sampleRate - 44_100) < 1 ? Analyzer.decimate2(mono) : mono
        return try track(mono22k: x)
    }
}
