import Accelerate
import AppKit
import BacklineKit
import Foundation

/// A simple async mutex: only one engine reallocation / export at a time, without blocking threads.
actor EngineGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

/// Loads the Beat This! model once (nil if unavailable, so analysis falls back to DSP).
nonisolated final class BeatService: @unchecked Sendable {
    static let shared = BeatService()
    private let lock = NSLock()
    private var cached: BeatTracker?
    private var failed = false

    func tracker() async -> BeatTracker? {
        if let t = lock.withLock({ cached }) { return t }
        if lock.withLock({ failed }) { return nil }
        guard let url = try? await BeatTracker.locateModel(in: .main), let t = try? BeatTracker(modelURL: url) else {
            lock.withLock { failed = true }
            return nil
        }
        lock.withLock { if cached == nil { cached = t } }
        return lock.withLock { cached }
    }
}

/// Loads the Core ML separator once and keeps it warm.
nonisolated final class SeparationService: @unchecked Sendable {
    static let shared = SeparationService()
    private let lock = NSLock()
    private var cached: DemucsSeparator?

    func separator() async throws -> DemucsSeparator {
        if let s = lock.withLock({ cached }) { return s }
        let url = try await DemucsSeparator.locateModel(in: .main)
        let s = try DemucsSeparator(modelURL: url)
        lock.withLock { if cached == nil { cached = s } }
        return lock.withLock { cached! }
    }

    /// Compiles GPU kernels in the background so the first import is fast.
    func warmUp() {
        Task.detached(priority: .utility) {
            guard let s = try? await self.separator() else { return }
            s.warmUp()
        }
    }
}

nonisolated struct ImportProgress: Sendable {
    var phase: Int          // 0 reading · 1 vocals · 2 drums & bass · 3 guitars · 4 keys & other · 5 finishing
    var fraction: Double
    var secondsRemaining: Double?
}

nonisolated enum ImportPipeline {
    /// Stems quieter than this (RMS relative to the loudest stem) are folded into "Other".
    static let foldThreshold: Float = 0.06

    static func run(url: URL, id: String, store: SongStore,
                    progress: @escaping @Sendable (ImportProgress) -> Void,
                    isCancelled: @escaping @Sendable () -> Bool) async throws -> (SongRecord, [StemKind: StereoAudio]) {
        progress(.init(phase: 0, fraction: 0.005, secondsRemaining: nil))
        let meta = await TrackMetadata.load(from: url)
        let audio = try AudioDecoder.decode(url) { p in
            progress(.init(phase: 0, fraction: 0.005 + 0.045 * p, secondsRemaining: nil))
        }
        if isCancelled() { throw CancellationError() }
        let sep = try await SeparationService.shared.separator()
        let finishing = 0.4 + audio.duration / 240     // rough: encode + analysis
        let raw = try sep.separate(audio, progress: { p in
            let phase = 1 + min(3, Int(p.fraction * 4))
            progress(.init(phase: phase, fraction: 0.05 + 0.85 * p.fraction,
                           secondsRemaining: (p.secondsRemaining ?? 0) + finishing))
        }, isCancelled: isCancelled)
        if isCancelled() { throw CancellationError() }
        progress(.init(phase: 5, fraction: 0.9, secondsRemaining: finishing))

        var byName: [String: StereoAudio] = [:]
        for (name, s) in zip(DemucsSeparator.sources, raw) { byName[name] = s }

        // Beat This! (Core ML) on the original mix gives the beat grid; DSP analysis does the rest.
        let grid = try? await BeatService.shared.tracker()?.track(audio)
        let analysis = Analyzer.analyze(stems: byName, duration: audio.duration, beatGrid: grid ?? nil)

        // Fold near-silent stems (bleed) into Other so the mixer only shows instruments that are really there.
        func rms(_ a: StereoAudio) -> Float {
            var l: Float = 0, r: Float = 0
            vDSP_rmsqv(a.left, 1, &l, vDSP_Length(a.frameCount))
            vDSP_rmsqv(a.right, 1, &r, vDSP_Length(a.frameCount))
            return (l + r) / 2
        }
        var kinds: [StemKind: StereoAudio] = [:]
        for (name, s) in byName { if let k = StemKind(demucsSource: name) { kinds[k] = s } }
        let loudest = kinds.values.map(rms).max() ?? 1
        for k in [StemKind.vocals, .keys, .bass, .drums] {
            guard let s = kinds[k], var other = kinds[.other], rms(s) < foldThreshold * loudest else { continue }
            vDSP_vadd(other.left, 1, s.left, 1, &other.left, 1, vDSP_Length(s.frameCount))
            vDSP_vadd(other.right, 1, s.right, 1, &other.right, 1, vDSP_Length(s.frameCount))
            kinds[.other] = other
            kinds[k] = nil
        }

        // Lead / rhythm split (stereo position) on guitar + other: htdemucs sometimes files the lead
        // guitar under "other", so the split runs on both and the lead is taken out of both.
        //   lead   = centred part of (guitar + other)
        //   rhythm = guitar − lead·g_share      other' = other − lead·o_share
        // where the shares split the lead between the stems in proportion to their energy, so
        // lead + rhythm + other' == guitar + other exactly and removing Lead removes all of it.
        // Measured on 6 real multitracks: backing SDR 12.2 dB (vs 11.7 guitar-only, 7.1 all-guitar).
        var split: GuitarSplitter.Result?
        var otherAdjusted: StereoAudio?
        var usedML = false
        if let g = kinds[.guitar] {
            var src = g
            let o = kinds[.other]
            if let o {
                vDSP_vadd(src.left, 1, o.left, 1, &src.left, 1, vDSP_Length(src.frameCount))
                vDSP_vadd(src.right, 1, o.right, 1, &src.right, 1, vDSP_Length(src.frameCount))
            }
            var r = GuitarSplitter.split(src)
            // ML lead model, blended 50/50 with the stereo split (scored best on the ground truth: backing
            // SDR 12.6 vs 12.2 dB).
            if let url = LeadSeparator.bundledModel(), let ml = try? LeadSeparator(modelURL: url),
               let mlLead = try? ml.lead(of: src, isCancelled: isCancelled) {
                var lead = r.lead
                var half: Float = 0.5
                vDSP_vasm(lead.left, 1, mlLead.left, 1, &half, &lead.left, 1, vDSP_Length(lead.frameCount))
                vDSP_vasm(lead.right, 1, mlLead.right, 1, &half, &lead.right, 1, vDSP_Length(lead.frameCount))
                var rhythm = src
                vDSP_vsub(lead.left, 1, src.left, 1, &rhythm.left, 1, vDSP_Length(src.frameCount))
                vDSP_vsub(lead.right, 1, src.right, 1, &rhythm.right, 1, vDSP_Length(src.frameCount))
                r = GuitarSplitter.Result(lead: lead, rhythm: rhythm, confidence: max(r.confidence, 0.5),
                                          width: r.width, leadDynamics: r.leadDynamics,
                                          shouldSplit: true)
                usedML = true
            }
            if r.shouldSplit {
                if var other = o {
                    // Per-sample-block energy share of guitar vs other, smoothed, decides where the lead came from.
                    let n = g.frameCount, block = 2048
                    var rhythm = g
                    for b in stride(from: 0, to: n, by: block) {
                        let m = min(block, n - b)
                        var eg: Float = 0, eo: Float = 0, t: Float = 0
                        g.left.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + b, 1, &eg, vDSP_Length(m)) }
                        g.right.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + b, 1, &t, vDSP_Length(m)) }; eg += t
                        other.left.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + b, 1, &eo, vDSP_Length(m)) }
                        other.right.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + b, 1, &t, vDSP_Length(m)) }; eo += t
                        let gs = eg + eo > 1e-12 ? eg / (eg + eo) : 1
                        for i in b..<(b + m) {
                            rhythm.left[i] = g.left[i] - r.lead.left[i] * gs
                            rhythm.right[i] = g.right[i] - r.lead.right[i] * gs
                            other.left[i] -= r.lead.left[i] * (1 - gs)
                            other.right[i] -= r.lead.right[i] * (1 - gs)
                        }
                    }
                    otherAdjusted = other
                    split = GuitarSplitter.Result(lead: r.lead, rhythm: rhythm, confidence: r.confidence,
                                                  width: r.width, leadDynamics: r.leadDynamics, shouldSplit: true)
                } else {
                    split = r
                }
            }
        }


        let order = StemKind.displayOrder.filter { kinds[$0] != nil }
        let stems = order.map { kinds[$0]! }

        // Peaks (shared scale) and lossless stem files, written in parallel.
        let folder = store.folder(id)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let results = try await withThrowingTaskGroup(of: (StemKind, [Float], Float).self) { group in
            for (k, s) in zip(order, stems) {
                group.addTask {
                    let peaks = Peaks.compute(s)
                    let peak = max(peaks.max() ?? 0, 1e-9)
                    // 16-bit storage with headroom: scale so the stem peaks at −0.1 dBFS, undo on load.
                    let scale: Float = peak > 0.988 ? 0.988 / peak : 1
                    var stored = s
                    if scale != 1 {
                        var sc = scale
                        vDSP_vsmul(s.left, 1, &sc, &stored.left, 1, vDSP_Length(s.frameCount))
                        vDSP_vsmul(s.right, 1, &sc, &stored.right, 1, vDSP_Length(s.frameCount))
                    }
                    try store.writeStem(stored, to: store.stemURL(id, k))
                    return (k, peaks, scale)
                }
            }
            var out: [(StemKind, [Float], Float)] = []
            for try await r in group { out.append(r) }
            return out
        }
        var peaks: [String: [Float]] = [:]
        var scales: [String: Float] = [:]
        for (k, p, sc) in results { peaks[k.rawValue] = p; scales[k.rawValue] = sc }

        var guitarSplit: GuitarSplit?
        var all: [StemKind: StereoAudio] = kinds
        if let split {
            let (lp, ls) = try writeScaled(split.lead, to: store.stemURL(id, .leadGuitar), store: store)
            let (rp, rs) = try writeScaled(split.rhythm, to: store.stemURL(id, .rhythmGuitar), store: store)
            var op: [Float] = [], os: Float = 1
            if let oa = otherAdjusted {
                (op, os) = try writeScaled(oa, to: store.otherSplitURL(id), store: store)
                all[.other] = oa          // the engine loads the split view first
            }
            guitarSplit = GuitarSplit(method: usedML ? "stereo+ml-go-v1" : "stereo-go-v1", confidence: split.confidence,
                                      leadPeaks: lp, rhythmPeaks: rp, leadScale: ls, rhythmScale: rs,
                                      otherAdjusted: otherAdjusted != nil, otherPeaks: op, otherScale: os)
            all[.leadGuitar] = split.lead
            all[.rhythmGuitar] = split.rhythm
        }

        if let art = meta.artwork { try? art.write(to: store.artworkURL(id)) }
        let title = meta.title ?? url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
        let now = Date()
        let rec = SongRecord(id: id, title: title, artist: meta.artist, duration: audio.duration,
                             sourceName: url.lastPathComponent, addedAt: now, lastOpened: now,
                             stems: order, analysis: analysis, peaks: peaks, storageScale: scales,
                             hasArtwork: meta.artwork != nil, settings: SongSettings(), guitarSplit: guitarSplit)
        try store.save(rec)
        progress(.init(phase: 5, fraction: 1, secondsRemaining: 0))
        _ = stems
        return (rec, all)
    }

    /// Writes a stem at 16-bit with headroom scaling; returns its peaks and the storage gain.
    static func writeScaled(_ s: StereoAudio, to url: URL, store: SongStore) throws -> ([Float], Float) {
        let peaks = Peaks.compute(s)
        let peak = max(peaks.max() ?? 0, 1e-9)
        let scale: Float = peak > 0.988 ? 0.988 / peak : 1
        var stored = s
        if scale != 1 {
            var sc = scale
            vDSP_vsmul(s.left, 1, &sc, &stored.left, 1, vDSP_Length(s.frameCount))
            vDSP_vsmul(s.right, 1, &sc, &stored.right, 1, vDSP_Length(s.frameCount))
        }
        try store.writeStem(stored, to: url)
        return (peaks, scale)
    }
}
