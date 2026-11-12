import Accelerate
import CoreML
import Foundation

/// On-device HTDemucs (6 sources) separation: Core ML core on the GPU, STFT/iSTFT with vDSP,
/// and Demucs' `apply_model` chunking (7.8 s segments, 25 % overlap, triangular overlap-add).
/// Debug timing that both the GPU loop and the overlapped DSP stage can add to.
final class StageTimer: @unchecked Sendable {
    private let lock = NSLock()
    private var totals: [String: Double] = [:]
    func add(_ stage: String, _ seconds: Double) { lock.withLock { totals[stage, default: 0] += seconds } }
    var summary: String {
        lock.withLock { totals.sorted { $0.key < $1.key }.map { "\($0.key) \(String(format: "%.1f", $0.value)) s" }.joined(separator: ", ") }
    }
}

/// Where the separation models run. The iOS Simulator's Core ML GPU path gets HTDemucs wrong (its six parts
/// add back up to 13 % of the song's power, correlation 0.35, 22 Oct 2026) while the CPU is exact, so the
/// Simulator always uses the CPU. Devices and the Mac use the GPU.
public enum SeparationCompute {
    public static var preferred: MLComputeUnits {
        #if targetEnvironment(simulator)
        return .cpuOnly
        #else
        return .cpuAndGPU
        #endif
    }
}

/// One six-part prediction at a time in the process, whichever instance makes it, and no other Core ML prediction
/// beside it. Measured on the Mac (M3 Max, 11 Nov 2026): a six-part prediction running beside a split, even on
/// another instance, spoiled the split's parts (their power 0.68 to 16 times the song's, sometimes a GPU error)
/// about one time in three. A spoiled split can pass the add-up check, or fail it and move the device to the CPU.
///
/// The six-part pass holds the gate alone from its first chunk to its last (`exclusively`). Every other model's
/// prediction (lead, kit, cleaner, beats) holds it shared (`shared`): those may run beside each other as before,
/// but never beside the six-part pass. A six-part pass that is waiting goes before any new shared holder, so it
/// waits for at most the predictions already running. Not re-entrant: code holding it must not ask again.
public final class PredictionGate: @unchecked Sendable {
    public static let shared = PredictionGate()
    private let condition = NSCondition()
    private var exclusive = false
    private var exclusiveWaiting = 0
    private var sharedHolders = 0
    /// How often a waiting caller asks `isCancelled`.
    private static let poll: TimeInterval = 0.2

    public init() {}

    /// Runs `body` with every Core ML prediction in the process kept away. Throws `CancellationError` when
    /// `isCancelled` says so while waiting.
    public func exclusively<T>(isCancelled: () -> Bool = { false }, _ body: () throws -> T) throws -> T {
        condition.lock()
        exclusiveWaiting += 1
        while exclusive || sharedHolders > 0 {
            condition.unlock()
            if isCancelled() {
                condition.lock()
                exclusiveWaiting -= 1
                condition.broadcast()
                condition.unlock()
                throw CancellationError()
            }
            condition.lock()
            if exclusive || sharedHolders > 0 { condition.wait(until: Date(timeIntervalSinceNow: Self.poll)) }
        }
        exclusiveWaiting -= 1
        exclusive = true
        condition.unlock()
        defer {
            condition.lock()
            exclusive = false
            condition.broadcast()
            condition.unlock()
        }
        return try body()
    }

    /// Runs `body` (another model's prediction) once no six-part pass holds or waits for the gate.
    public func shared<T>(isCancelled: () -> Bool = { false }, _ body: () throws -> T) throws -> T {
        condition.lock()
        while exclusive || exclusiveWaiting > 0 {
            condition.unlock()
            if isCancelled() { throw CancellationError() }
            condition.lock()
            if exclusive || exclusiveWaiting > 0 { condition.wait(until: Date(timeIntervalSinceNow: Self.poll)) }
        }
        sharedHolders += 1
        condition.unlock()
        defer {
            condition.lock()
            sharedHolders -= 1
            condition.broadcast()
            condition.unlock()
        }
        return try body()
    }

    /// For tests and logs: whether a six-part pass holds the gate now.
    public var isHeldExclusively: Bool { condition.withLock { exclusive } }
}

/// A checkpoint writer handed to the six-part pass's post queue (which alone uses it while the pass runs).
private final class KeptChunks: @unchecked Sendable {
    var writer: CheckpointWriter?
    init(_ writer: CheckpointWriter?) { self.writer = writer }
}

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

    public let computeUnits: MLComputeUnits

    public init(modelURL: URL, computeUnits: MLComputeUnits = SeparationCompute.preferred) throws {
        self.computeUnits = computeUnits
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
        _ = try? PredictionGate.shared.exclusively { try model.prediction(from: input) }
    }

    /// Separates `audio` (44.1 kHz stereo). Returns planar stereo per source, in `sources` order. The whole pass
    /// holds `PredictionGate` alone: no other six-part pass or Core ML prediction runs beside it.
    ///
    /// With a `checkpoint`, what the pass has added up is kept on disk as it goes, and a run stopped part-way
    /// carries on where it stopped: it gives the same samples as a run that was never stopped (on the same compute
    /// units).
    public func separate(_ audio: StereoAudio,
                         checkpoint: SeparationCheckpoint? = nil,
                         progress: @escaping @Sendable (Progress) -> Void = { _ in },
                         isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> [StereoAudio] {
        try PredictionGate.shared.exclusively(isCancelled: isCancelled) {
            try separateHoldingGate(audio, checkpoint: checkpoint, progress: progress, isCancelled: isCancelled)
        }
    }

    /// The pass itself, for a caller that holds the gate (tests reach it to spoil a split on purpose).
    func separateHoldingGate(_ audio: StereoAudio, checkpoint: SeparationCheckpoint? = nil,
                             progress: @escaping @Sendable (Progress) -> Void,
                             isCancelled: @escaping @Sendable () -> Bool) throws -> [StereoAudio] {
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
        // Each chunk is normalised as it is fed to the model (below), not the whole song up front: one song copy
        // less, with the very same numbers (the same `vDSP_vsmsa` on the same samples).
        var normScale = 1 / std, normOffset = -mean / std

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
        var chunkOut = (0..<(S * 2)).map { _ in [Float](repeating: 0, count: L) }

        // A run that was stopped kept what it had added up below `resumeFrom` (no later chunk reaches there): only
        // the chunks that reach past it are computed again, from nothing, and the kept sums are put back at the end.
        // The writer is used on the post queue only, after each chunk is added in.
        let kept = KeptChunks(CheckpointWriter.open(checkpoint, total: n, step: stride, channels: S * 2, scale: .raw))
        let resumeFrom = kept.writer?.resumeFrom ?? 0
        let first = CheckpointWriter.firstChunk(offsets, resumeFrom: resumeFrom) { min(L, n - $0) }

        let start = Date()
        let post = DispatchQueue(label: "backline.demucs.post", qos: .userInitiated)
        let inflight = DispatchSemaphore(value: 1)
        let noPipeline = ProcessInfo.processInfo.environment["BL_NOPIPE"] != nil
        let group = DispatchGroup()
        let timing = StageTimer()
        // Defers run last-in first-out: the timing line prints after the post queue has drained.
        defer {
            if ProcessInfo.processInfo.environment["BL_DEBUG"] != nil {
                print("[demucs] \(offsets.count) chunks, total \(String(format: "%.1f", Date().timeIntervalSince(start))) s, \(timing.summary)")
            }
        }
        defer { group.wait() }
        for (ci, offset) in offsets.enumerated() where ci >= first {
            if isCancelled() { group.wait(); throw CancellationError() }
            let chunkLen = min(L, n - offset)
            // TensorChunk.padded(L): centre the chunk, fill with real neighbouring audio where available.
            let delta = L - chunkLen
            let padStart = offset - delta / 2
            let mixPtr = mixArr.dataPointer.assumingMemoryBound(to: Float.self)
            // The song's samples where it has them, normalised; silence (0, not normalised) beyond its ends.
            let first = max(0, -padStart), end = min(L, n - padStart)
            for (c, src) in [audio.left, audio.right].enumerated() {
                let dst = mixPtr + c * L
                dst.update(repeating: 0, count: L)
                guard end > first else { continue }
                src.withUnsafeBufferPointer { s in
                    vDSP_vsmsa(s.baseAddress! + padStart + first, 1, &normScale, &normOffset,
                               dst + first, 1, vDSP_Length(end - first))
                }
            }
            // Complex-as-channels spectrogram: L.re, L.im, R.re, R.im.
            let specPtr = specArr.dataPointer.assumingMemoryBound(to: Float.self)
            let tFwd = Date()
            DispatchQueue.concurrentPerform(iterations: 2) { c in
                stft.forward(mixPtr + c * L, count: L,
                             re: specPtr + (2 * c) * F * T, im: specPtr + (2 * c + 1) * F * T)
            }
            timing.add("fwd STFT", Date().timeIntervalSince(tFwd))

            let input = try MLDictionaryFeatureProvider(dictionary: [
                "mix": MLFeatureValue(multiArray: mixArr),
                "spec": MLFeatureValue(multiArray: specArr),
            ])
            let tPredict = Date()
            let result = try Self.predictHoldingGate(model, input, isCancelled: isCancelled)
            timing.add("Core ML", Date().timeIntervalSince(tPredict))
            guard let freq = result.featureValue(for: "freq")?.multiArrayValue,
                  let time = result.featureValue(for: "time")?.multiArrayValue else {
                throw CocoaError(.coderValueNotFound)
            }
            // The back half (copy-out, inverse STFT, overlap-add) runs on the CPU while the GPU already works on
            // the next chunk. At most one chunk's results wait here, so memory stays bounded.
            inflight.wait()
            let run: (DispatchGroup, @escaping () -> Void) -> Void = noPipeline
                ? { g, work in post.sync { g.enter(); work(); g.leave() } }
                : { g, work in post.async(group: g, execute: work) }
            run(group) {
                let tContig = Date()
                let freqPlanes = Self.contiguous(freq, planes: S * 4, planeSize: F * T)
                let timePlanes = Self.contiguous(time, planes: S * 2, planeSize: L)
                timing.add("contiguous", Date().timeIntervalSince(tContig))
                let tInv = Date()

                // iSTFT of each (source, channel) in parallel, plus the time branch.
                chunkOut.withUnsafeMutableBufferPointer { co in
                    let coBase = co.baseAddress!
                    freqPlanes.withUnsafeBufferPointer { fp in
                        timePlanes.withUnsafeBufferPointer { tp in
                            DispatchQueue.concurrentPerform(iterations: S * 2) { k in
                                let s = k / 2, c = k % 2
                                let re = fp.baseAddress! + (s * 4 + 2 * c) * F * T
                                coBase[k].withUnsafeMutableBufferPointer { dst in
                                    self.stft.inverse(re: re, im: re + F * T, frames: T, length: L, out: dst.baseAddress!)
                                    vDSP_vadd(dst.baseAddress!, 1, tp.baseAddress! + k * L, 1, dst.baseAddress!, 1, vDSP_Length(L))
                                }
                            }
                        }
                    }
                }

                timing.add("iSTFT", Date().timeIntervalSince(tInv))
                let tAcc = Date()
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
                // No later chunk reaches below `offset + stride`: those sums are final and go to the checkpoint.
                if let w = kept.writer,
                   (try? w.append(upTo: min(offset + stride, n), accumulated: out, weight: sumWeight)) == nil {
                    kept.writer = nil
                }

                timing.add("accumulate", Date().timeIntervalSince(tAcc))
                let elapsed = Date().timeIntervalSince(start)
                let done = ci + 1
                progress(Progress(fraction: Double(done) / Double(offsets.count), chunk: done, chunks: offsets.count,
                                  secondsRemaining: elapsed / Double(done - first) * Double(offsets.count - done)))
                inflight.signal()
            }
        }
        group.wait()
        if let w = kept.writer, w.resumeFrom > 0, (try? w.restorePrefix(into: &out, weight: &sumWeight)) == nil {
            // The kept sums couldn't be read back after all: the whole split again, from nothing.
            kept.writer = nil
            checkpoint?.discard()
            out = []
            sumWeight = []
            return try separateHoldingGate(audio, checkpoint: checkpoint, progress: progress, isCancelled: isCancelled)
        }
        kept.writer = nil

        // Normalise by weights and undo the input normalisation, each part in place. The song's offset from zero
        // (its mean) is shared out, a sixth to each part, so the parts still add up to the song: Demucs adds the
        // whole mean back to every part, which gives their sum six times the song's offset. A song mastered off
        // centre ("Take the Lead", mean 0.062) then failed the add-up check on every backend (power 3.55,
        // correlation 0.714; 0.93 and 0.989 with the offset shared out), and each of its parts carried the
        // whole offset into the mixer. For a song centred on zero the difference is below hearing.
        // its accumulator is taken out
        // of `out` (so it is the only owner and nothing is copied) and becomes the part. The weights' reciprocal
        // is written over the weights.
        var results: [StereoAudio] = []
        var one: Float = 1
        sumWeight.withUnsafeMutableBufferPointer { sw in
            vDSP_svdiv(&one, sw.baseAddress!, 1, sw.baseAddress!, 1, vDSP_Length(n))
        }
        let inv = sumWeight
        var outScale = std, outOffset = mean / Float(S)
        for s in 0..<S {
            var chans: [[Float]] = []
            for c in 0..<2 {
                var x: [Float] = []
                swap(&x, &out[s * 2 + c])
                x.withUnsafeMutableBufferPointer { xp in
                    let p = xp.baseAddress!
                    vDSP_vmul(p, 1, inv, 1, p, 1, vDSP_Length(n))
                    vDSP_vsmsa(p, 1, &outScale, &outOffset, p, 1, vDSP_Length(n))
                }
                chans.append(x)
            }
            results.append(StereoAudio(left: chans[0], right: chans[1], sampleRate: audio.sampleRate))
        }
        return results
    }

    /// One Core ML call of another model (lead, kit, cleaner), never beside a six-part pass (`PredictionGate`).
    /// If it fails while the app was in the background (the GPU is not available there), wait for the foreground
    /// (`isCancelled` blocks on the foreground gate) and try again.
    static func predict(_ model: MLModel, _ input: MLFeatureProvider, isCancelled: @Sendable () -> Bool) throws -> MLFeatureProvider {
        try PredictionGate.shared.shared(isCancelled: isCancelled) {
            try predictHoldingGate(model, input, isCancelled: isCancelled)
        }
    }

    /// The same call for a caller that already holds `PredictionGate` (the six-part pass).
    static func predictHoldingGate(_ model: MLModel, _ input: MLFeatureProvider, isCancelled: @Sendable () -> Bool) throws -> MLFeatureProvider {
        var attempts = 0
        while true {
            do { return try model.prediction(from: input) } catch {
                attempts += 1
                if isCancelled() { throw CancellationError() }
                if attempts >= 3 { throw error }
            }
        }
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

extension DemucsSeparator {
    /// How well the parts add back up to the song: the power of their sum over the song's, and the
    /// correlation of the sum with the song (both channels). A healthy split is close to 1 and 1.
    public static func reconstruction(of parts: [StereoAudio], song: StereoAudio) -> (power: Float, correlation: Float) {
        let n = min(song.frameCount, parts.map(\.frameCount).min() ?? 0)
        guard n > 0 else { return (0, 0) }
        var sumPower: Float = 0, songPower: Float = 0, dot: Float = 0
        for (whole, pick) in [(song.left, \StereoAudio.left), (song.right, \StereoAudio.right)] {
            var sum = [Float](repeating: 0, count: n)
            for p in parts { vDSP_vadd(sum, 1, p[keyPath: pick], 1, &sum, 1, vDSP_Length(n)) }
            var a: Float = 0, b: Float = 0, c: Float = 0
            vDSP_svesq(sum, 1, &a, vDSP_Length(n))
            vDSP_svesq(whole, 1, &b, vDSP_Length(n))
            vDSP_dotpr(sum, 1, whole, 1, &c, vDSP_Length(n))
            sumPower += a; songPower += b; dot += c
        }
        guard songPower > 1e-9, sumPower > 1e-9 else { return (sumPower > 1e-9 ? .infinity : 0, 0) }
        return (sumPower / songPower, dot / (sumPower * songPower).squareRoot())
    }

    /// The add-up check's bounds. Measured on ten real songs (ios-split-safety, 11 Nov 2026, this Mac, CPU and
    /// GPU alike): a clean split's power is 0.947 to 0.992 of the song's and its correlation 0.988 to 0.9998, except
    /// one song that added up at 3.55 and 0.714 on both until the song's offset from zero was shared out
    /// among the parts instead of added to each (see `separateHoldingGate`); `agree` still covers such a song. The Mac's spoiled splits ran from 0.68 to 16
    /// times the power. The bounds keep a margin of about 1 dB of power below and above the clean ones.
    public static let powerRange: ClosedRange<Float> = 0.8...1.25
    public static let minimumCorrelation: Float = 0.95

    /// True when a split's figures (`reconstruction`) are a clean split's.
    public static func passes(_ r: (power: Float, correlation: Float)) -> Bool {
        powerRange.contains(r.power) && r.correlation >= minimumCorrelation
    }

    /// True when the parts plausibly are the song.
    public static func reconstructs(_ parts: [StereoAudio], song: StereoAudio) -> Bool {
        passes(reconstruction(of: parts, song: song))
    }

    /// True when two splits of one song add up the same way (within 2 % of the power and 0.01 of correlation):
    /// then a split that fails the check does so because of the song, not the backend that made it.
    public static func agree(_ a: (power: Float, correlation: Float), _ b: (power: Float, correlation: Float)) -> Bool {
        guard a.power.isFinite, b.power.isFinite else { return false }
        return abs(a.power - b.power) <= 0.02 * max(a.power, b.power) && abs(a.correlation - b.correlation) <= 0.01
    }
}
