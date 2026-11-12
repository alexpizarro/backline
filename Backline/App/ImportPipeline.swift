import Accelerate
import BacklineKit
import CoreML
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

/// Loads the Beat This! model once (nil if unavailable, so analysis falls back to DSP). On the CPU: it runs
/// while the six-part split has the GPU (F9).
nonisolated final class BeatService: @unchecked Sendable {
    static let shared = BeatService()
    private let lock = NSLock()
    private var cached: BeatTracker?
    private var failed = false

    func tracker() async -> BeatTracker? {
        if let t = lock.withLock({ cached }) { return t }
        if lock.withLock({ failed }) { return nil }
        guard let url = try? await BeatTracker.locateModel(in: .main),
              let t = try? BeatTracker(modelURL: url, computeUnits: .cpuOnly) else {
            lock.withLock { failed = true }
            return nil
        }
        lock.withLock { if cached == nil { cached = t } }
        return lock.withLock { cached }
    }
}

/// The Core ML six-part separator, held only around an import's split (F5, UIP-04): loaded when an import
/// starts (while the file is copied or the link downloads) and released as soon as the split returns, so
/// playback, the lead refinement, the kit split and the cleaner pass never sit beside it.
/// Where the six-part model runs after a split failed its add-up check on the GPU (ios-split-safety). The CPU is
/// remembered with the build and the date, not for ever: a new build, or 14 days on the same build, tries the GPU
/// once more; a second failure on the same build keeps the CPU for the rest of that build. A GPU split that adds
/// up forgets the failure.
nonisolated struct CPUFallback: Codable, Equatable, Sendable {
    /// The build (`CFBundleVersion`) the GPU last failed on.
    var build: String
    /// When it last failed.
    var date: Date
    /// GPU failures on that build.
    var failures: Int

    static let key = "separationCPUFallback"
    /// 1.0's flag: the CPU for ever. Read once and replaced.
    static let legacyKey = "separationOnCPU"
    static let retryAfter: TimeInterval = 14 * 24 * 3600

    static var currentBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?" }

    /// Whether to use the CPU now, and why (for the log).
    static func decide(_ state: CPUFallback?, build: String, now: Date) -> (cpu: Bool, reason: String) {
        guard let state else { return (false, "GPU") }
        if state.build != build { return (false, "GPU again: a new build since it failed on build \(state.build)") }
        if state.failures >= 2 { return (true, "CPU: the GPU failed twice on build \(build)") }
        if now.timeIntervalSince(state.date) >= retryAfter { return (false, "GPU again: 14 days since it failed") }
        return (true, "CPU: the GPU failed on \(state.date.formatted(date: .abbreviated, time: .omitted))")
    }

    /// The state after another GPU failure.
    static func failed(_ state: CPUFallback?, build: String, now: Date) -> CPUFallback {
        CPUFallback(build: build, date: now, failures: state?.build == build ? state!.failures + 1 : 1)
    }

    static func load(_ defaults: UserDefaults = .standard) -> CPUFallback? {
        if let data = defaults.data(forKey: key), let s = try? JSONDecoder().decode(CPUFallback.self, from: data) { return s }
        // A device that 1.0 moved to the CPU for good: treat it as a failure on an older build, so the GPU is tried again.
        if defaults.bool(forKey: legacyKey) { return CPUFallback(build: "1.0", date: .distantPast, failures: 1) }
        return nil
    }

    static func save(_ state: CPUFallback?, _ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: legacyKey)
        if let state, let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

nonisolated final class SeparationService: @unchecked Sendable {
    static let shared = SeparationService()
    /// A separator loaded for an import that never reaches the split (a download that failed, say) goes after this.
    static let unclaimedLifetime: Duration = .seconds(180)
    private let lock = NSLock()
    private var loading: Task<DemucsSeparator, Error>?
    private var generation = 0
    private var claimed = false

    private static func load() async throws -> DemucsSeparator {
        let url = try await DemucsSeparator.locateModel(in: .main)
        var units = SeparationCompute.preferred
        if units != .cpuOnly {
            let state = CPUFallback.load()
            let (cpu, reason) = CPUFallback.decide(state, build: CPUFallback.currentBuild, now: Date())
            if state != nil { AppLog.note("separator: \(reason)") }
            if cpu { units = .cpuOnly }
        }
        return try DemucsSeparator(modelURL: url, computeUnits: units)
    }

    /// True while a separator is loaded or loading.
    var isHeld: Bool { lock.withLock { loading != nil } }

    /// The separator for a split: the one `prepare` started loading, or a new one.
    func separator() async throws -> DemucsSeparator {
        let task = lock.withLock { () -> Task<DemucsSeparator, Error> in
            claimed = true
            if let t = loading { return t }
            let t = Task.detached(priority: .userInitiated) { try await Self.load() }
            loading = t
            return t
        }
        do {
            return try await task.value
        } catch {
            lock.withLock { if loading == task { loading = nil } }
            throw error
        }
    }

    /// An import is starting: load the model while the file is staged or the link downloads.
    func prepare() {
        let gen = lock.withLock { () -> Int? in
            guard loading == nil else { return nil }
            generation += 1
            claimed = false
            // User-initiated: the split waits for it within seconds (under load, utility took 8 s in the Simulator).
            loading = Task.detached(priority: .userInitiated) { try await Self.load() }
            return generation
        }
        guard let gen else { return }
        AppLog.note("separator: loading for an import")
        Task.detached { [self] in
            try? await Task.sleep(for: Self.unclaimedLifetime)
            let dropped = lock.withLock { () -> Bool in
                guard generation == gen, !claimed, loading != nil else { return false }
                loading = nil
                return true
            }
            if dropped { AppLog.note("separator: released (no import used it)") }
        }
    }

    /// A CPU separator for a second opinion on a split whose parts didn't add up on the GPU.
    func cpuSeparator() async throws -> DemucsSeparator {
        let url = try await DemucsSeparator.locateModel(in: .main)
        let s = try DemucsSeparator(modelURL: url, computeUnits: .cpuOnly)
        lock.withLock { loading = Task { s } }
        return s
    }

    /// The GPU's parts didn't add up and the CPU's did: remember it with the build and the date (`CPUFallback`).
    func recordGPUFailure() {
        let state = CPUFallback.failed(CPUFallback.load(), build: CPUFallback.currentBuild, now: Date())
        CPUFallback.save(state)
        AppLog.note("separator: the GPU's parts didn't add up (failure \(state.failures) on build \(state.build)); the CPU from now")
    }

    /// The split is done (or a reset): the model and its GPU buffers go; the next import loads it again.
    func release() {
        lock.withLock {
            loading = nil
            generation += 1
        }
    }

    /// Reset: the next split loads the separator afresh (and on the GPU again).
    func forget() { release() }
}

/// Counts something across threads (tests read it).
nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func increment() { lock.withLock { n += 1 } }
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
        let t0 = Date()
        // Every step's time goes to the app's own log (Release too), so a slow step on a phone shows up.
        func mark(_ what: String) {
            let at = String(format: "%.1f", Date().timeIntervalSince(t0))
            AppLog.note("import \(id): \(what) at \(at) s")
            if ProcessInfo.processInfo.environment["BL_DEBUG"] != nil { print("[import] \(what) at \(at) s") }
        }
        AppLog.note("import \(id): started")
        // The import's memory peak goes to the app log too (split F4): sampled at every progress report and
        // cancellation check the steps already make, written however the import ends.
        let peak = MemoryPeak()
        defer { peak.sample(); AppLog.note("import \(id): \(peak.note) (most since launch \(MemoryBudget.lifetimePeakMegabytes) MB)") }
        let reportProgress = progress, checkCancelled = isCancelled
        let progress: @Sendable (ImportProgress) -> Void = { peak.sample(); reportProgress($0) }
        let isCancelled: @Sendable () -> Bool = { peak.sample(); return checkCancelled() }
        let meta = await TrackMetadata.load(from: url)
        // Longer than this Mac can split (R04): say so before spending minutes on it. The Mac keeps its memory
        // tiers; the free-memory checks before each stage are iOS only (macOS sets no per-app limit to ask).
        if let seconds = await AudioDecoder.duration(of: url), seconds > DeviceLimits.maxSongSeconds + 1 {
            throw DeviceLimits.TooLong()
        }
        let audio = try AudioDecoder.decode(url) { p in
            progress(.init(phase: 0, fraction: 0.005 + 0.045 * p, secondsRemaining: nil))
        }
        mark("decoded (\(Int(audio.duration)) s of audio)")
        // Again with the real length (a file can say less than it holds).
        if audio.duration > DeviceLimits.maxSongSeconds + 1 { throw DeviceLimits.TooLong() }
        if isCancelled() { throw CancellationError() }
        // Beat This! needs only the decoded song. It starts now, but its model runs whole before the six-part
        // pass's first chunk or after its last, never beside it (`PredictionGate`, ios-split-safety).
        let beatTask = Task.detached(priority: .userInitiated) { () -> BeatTracker.Result? in
            guard let tracker = await BeatService.shared.tracker() else { return nil }
            return try? PredictionGate.shared.shared(isCancelled: isCancelled) { try tracker.track(audio) }
        }
        let raw: [StereoAudio]
        do {
            raw = try await separate(audio, id: id, progress: progress, isCancelled: isCancelled, mark: mark)
        } catch {
            beatTask.cancel()
            throw error
        }
        // From here on the steps' length varies too much by device for an honest estimate: the percent
        // moves with each step and no time is shown (copy deck: nothing until an estimate exists).
        progress(.init(phase: 5, fraction: 0.9, secondsRemaining: nil))

        // The parts move into `byName` and from there into `process`, which drops each one it no longer needs:
        // nothing here keeps a second reference (one would make every change in `process` a whole-song copy).
        var byName: [String: StereoAudio] = [:]
        for (name, s) in zip(DemucsSeparator.sources, consume raw) { byName[name] = s }

        // Beat This! (Core ML) on the original mix gives the beat grid; DSP analysis does the rest.
        let grid = await beatTask.value
        mark("beats")
        progress(.init(phase: 5, fraction: 0.92, secondsRemaining: nil))
        let analysis = Analyzer.analyze(stems: byName, duration: audio.duration, beatGrid: grid ?? nil)
        mark("analysed")
        progress(.init(phase: 5, fraction: 0.94, secondsRemaining: nil))

        if isCancelled() { throw CancellationError() }
        let folder = store.folder(id)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The lead guitar model is not run here (D2, F1): the stereo split makes the song playable, and
        // `LeadRefineJob` refines Lead and Rhythm from the files once the song is open. The original mix is
        // kept so a cleaner model can split the real audio later (D8): a lossy source file is kept as it is
        // (D18); otherwise original.caf is written with the parts (F7).
        let keep = await KeptOriginal.plan(for: url)
        let processed = try await process(consume byName, id: id, store: store, original: audio,
                                          writeOriginal: keep == .writeLossless,
                                          useLeadModel: false, isCancelled: isCancelled)
        if isCancelled() { throw CancellationError() }
        mark("processed (stereo guitar split + parts\(keep == .writeLossless ? " and original" : "") written)")
        var originalScale = processed.originalScale
        let originalFile = await KeptOriginal.keep(url, plan: keep, decoded: audio, in: folder)
        if keep != .writeLossless, originalFile == nil {
            // The source couldn't be kept as it is: the lossless original, as before 1.1.
            originalScale = try writeScaled(audio, to: store.originalURL(id), store: store).1
        }
        mark("original kept as \(originalFile ?? "original.caf")")
        progress(.init(phase: 5, fraction: 0.99, secondsRemaining: nil))

        if let art = meta.artwork { try? art.write(to: store.artworkURL(id)) }
        let title = meta.title ?? ImportStaging.displayName(for: url)
        let now = Date()
        let rec = SongRecord(id: id, title: title, artist: meta.artist, duration: audio.duration,
                             sourceName: url.lastPathComponent, addedAt: now, lastOpened: now,
                             stems: processed.order, analysis: analysis, peaks: processed.peaks,
                             storageScale: processed.scales, hasArtwork: meta.artwork != nil, settings: SongSettings(),
                             guitarSplit: processed.guitarSplit)
        if isCancelled() { throw CancellationError() }
        var saved = rec
        saved.levels = processed.levels
        saved.instruments = processed.instruments
        saved.originalScale = originalScale
        saved.originalFile = originalFile
        try store.save(saved)
        progress(.init(phase: 5, fraction: 1, secondsRemaining: 0))
        // No parts in memory are handed on (storage F8): the song opens from the files just written, as a
        // reopened song does, so the import's arrays are freed here.
        return (saved, [:])
    }

    /// Where an import's six-part split keeps what it has done, so an import the app was closed during carries on
    /// (R3). Keyed by the staged file's content id (`id`), its length, the model (inside the app: its build) and
    /// where it runs: a split on the CPU after the GPU's parts didn't add up starts its own.
    static func splitCheckpoint(id: String, frames: Int, units: MLComputeUnits) -> SeparationCheckpoint {
        SeparationCheckpoint(directory: PassCheckpoints.directory(.importSplit, id),
                             key: "htdemucs6s|1|\(id)|\(frames)|\(PassCheckpoints.build)|\(units == .cpuOnly ? "cpu" : "gpu \(units.rawValue)")")
    }

    /// The six-part split. The separator is held only here and released as soon as the split returns (F5).
    private static func separate(_ audio: StereoAudio, id: String, progress: @escaping @Sendable (ImportProgress) -> Void,
                                 isCancelled: @escaping @Sendable () -> Bool,
                                 mark: (String) -> Void) async throws -> [StereoAudio] {
        defer { SeparationService.shared.release() }
        // Optional, so the GPU's model can go before a second opinion on the CPU (ios-import#2).
        var sep: DemucsSeparator? = try await SeparationService.shared.separator()
        let firstUnits = sep!.computeUnits
        mark("separator loaded")
        let finishing = 0.3 + audio.duration / 400     // rough: analysis + encode
        let report: @Sendable (DemucsSeparator.Progress) -> Void = { p in
            let phase = 1 + min(3, Int(p.fraction * 4))
            progress(.init(phase: phase, fraction: 0.05 + 0.85 * p.fraction,
                           secondsRemaining: (p.secondsRemaining ?? 0) + finishing))
        }
        var units = firstUnits
        let kept = splitCheckpoint(id: id, frames: audio.frameCount, units: firstUnits)
        if FileManager.default.fileExists(atPath: kept.directory.path) { mark("carrying on from its checkpoint") }
        // Twelve channels (six parts, stereo) and the weights.
        let room = PassCheckpoints.ifRoom(kept, bytes: PassCheckpoints.bytes(channels: 13, frames: audio.frameCount))
        var raw = try sep!.separate(audio, checkpoint: room, progress: report, isCancelled: isCancelled)
        if isCancelled() { throw CancellationError() }
        // The parts must add back up to the song. A GPU that gets the model wrong (the iOS Simulator's does), or a
        // split spoiled by another prediction beside it, gives parts that don't; then split again on the CPU. Only
        // when the CPU's parts add up differently is the GPU to blame: some songs add up the same way on both
        // (Take the Lead: power 3.5, correlation 0.71 on either), and then the device keeps its GPU.
        var gpuBlamed = false
        if units != .cpuOnly {
            let gpuFit = DemucsSeparator.reconstruction(of: raw, song: audio)
            if !DemucsSeparator.passes(gpuFit) {
                mark(String(format: "parts don't add up on the GPU (power %.2f, correlation %.2f); splitting on the CPU",
                            gpuFit.power, gpuFit.correlation))
                // Only the GPU's fit figures are kept: its six parts and its model go before the CPU pass loads its
                // own (ios-import#2). A failure isn't recorded before the CPU has answered: the song may be the cause.
                // (The Mac's import measures no memory: macOS sets no per-app limit, `MemoryBudget`.)
                let cpuRaw = try await secondOpinion(freeFirst: {
                    raw = []
                    sep = nil
                    SeparationService.shared.release()
                }, split: {
                    // Its own checkpoint (the GPU's is replaced: its parts didn't add up).
                    try await SeparationService.shared.cpuSeparator().separate(
                        audio, checkpoint: room.map { _ in splitCheckpoint(id: id, frames: audio.frameCount, units: .cpuOnly) },
                        progress: report, isCancelled: isCancelled)
                })
                if isCancelled() { throw CancellationError() }
                let cpuFit = DemucsSeparator.reconstruction(of: cpuRaw, song: audio)
                raw = cpuRaw
                units = .cpuOnly
                if DemucsSeparator.agree(gpuFit, cpuFit) {
                    mark("the CPU's parts add up the same way: the song, not the GPU")
                } else {
                    gpuBlamed = true
                    SeparationService.shared.recordGPUFailure()
                }
            }
        }
        if !gpuBlamed, firstUnits != .cpuOnly, CPUFallback.load() != nil {
            // The GPU was tried again and its parts add up (or add up as the CPU's do): it stays the GPU.
            CPUFallback.save(nil)
            AppLog.note("separator: the GPU's parts add up again; the GPU from now")
        }
        mark("separated on \(units == .cpuOnly ? "CPU" : "GPU")")
        return raw
    }

    /// The CPU's second opinion on a split whose parts didn't add up on the GPU (ios-import#2), in this order: what
    /// the first pass holds goes (`freeFirst`: its six parts and its model), then `split`. iOS asks for room between
    /// the two; a Mac has no per-app memory limit to ask about.
    static func secondOpinion(freeFirst: () -> Void,
                              split: () async throws -> [StereoAudio]) async throws -> [StereoAudio] {
        freeFirst()
        return try await split()
    }

    /// The parts after separation, written to the song's folder.
    struct Processed: Sendable {
        var order: [StemKind]
        var peaks: [String: [Float]]
        var scales: [String: Float]
        var guitarSplit: GuitarSplit?
        /// Each part's level against the whole song (U05), stored on the record.
        var levels: [String: PartLevel]
        /// What the sound classifier hears in the song, the guitar and the lead (U06).
        var instruments: [String: InstrumentShares]
        /// The original mix's storage gain, when it was written (`writeOriginal`).
        var originalScale: Float?
    }

    /// How many times the lead guitar model was loaded (tests: never for a guitar that stays one part).
    static let leadModelLoads = Counter()

    /// `a += b`, sample by sample, both channels.
    static func add(_ b: StereoAudio, into a: inout StereoAudio) {
        vDSP_vadd(a.left, 1, b.left, 1, &a.left, 1, vDSP_Length(b.frameCount))
        vDSP_vadd(a.right, 1, b.right, 1, &a.right, 1, vDSP_Length(b.frameCount))
    }

    /// The ML lead blended 50/50 with the stereo split's (scored best on the ground truth: backing SDR 12.6 vs
    /// 12.2 dB).
    static func blend(stereoLead: StereoAudio, mlLead: StereoAudio) -> StereoAudio {
        var lead = stereoLead
        var half: Float = 0.5
        vDSP_vasm(lead.left, 1, mlLead.left, 1, &half, &lead.left, 1, vDSP_Length(lead.frameCount))
        vDSP_vasm(lead.right, 1, mlLead.right, 1, &half, &lead.right, 1, vDSP_Length(lead.frameCount))
        return lead
    }

    /// Takes the lead out of the guitar and Other (`src` = guitar + other):
    ///   rhythm = guitar − lead·g_share      other' = other − lead·o_share
    /// where the shares split the lead between the two in proportion to their energy, so
    /// lead + rhythm + other' == guitar + other exactly and removing Lead removes all of it.
    /// Without an Other part, rhythm = guitar − lead.
    static func takeLeadOut(_ lead: StereoAudio, guitar g: StereoAudio, other: StereoAudio?,
                            src: StereoAudio) -> (rhythm: StereoAudio, other: StereoAudio?) {
        guard var other else {
            var rhythm = src
            vDSP_vsub(lead.left, 1, src.left, 1, &rhythm.left, 1, vDSP_Length(src.frameCount))
            vDSP_vsub(lead.right, 1, src.right, 1, &rhythm.right, 1, vDSP_Length(src.frameCount))
            return (rhythm, nil)
        }
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
                rhythm.left[i] = g.left[i] - lead.left[i] * gs
                rhythm.right[i] = g.right[i] - lead.right[i] * gs
                other.left[i] -= lead.left[i] * (1 - gs)
                other.right[i] -= lead.right[i] * (1 - gs)
            }
        }
        return (rhythm, other)
    }

    /// Everything after the separator, shared by the first split and the cleaner background pass:
    /// fold near-silent stems into Other, split lead and rhythm guitar, and write the parts.
    /// `original`: the song as decoded, for what the classifier hears in the whole song (the parts' sum is
    /// close to it, but on a short song one 3 s window decides the guitar, so the real song is the one to hear).
    /// `writeOriginal`: also write `original` as the song's original.caf, in the same write group as the parts.
    /// `useLeadModel`: blend in the lead guitar model (the cleaner pass); the import leaves it to `LeadRefineJob`.
    ///
    /// Memory (D20): it owns the parts it is given, folds in place, never holds the whole mix when the original
    /// is there, and the stereo split streams; at its worst it holds the original, the parts, the lead, the
    /// rhythm and Other with the lead taken out (about 10 song copies, against 1.0's 23).
    static func process(_ byName: consuming [String: StereoAudio], id: String, store: SongStore, original: StereoAudio? = nil,
                        writeOriginal: Bool = false, useLeadModel: Bool = true,
                        leadProgress: @escaping @Sendable (Double) -> Void = { _ in },
                        isCancelled: @escaping @Sendable () -> Bool) async throws -> Processed {
        // Fold near-silent stems (bleed) into Other so the mixer only shows instruments that are really there.
        func rms(_ a: StereoAudio) -> Float {
            var l: Float = 0, r: Float = 0
            vDSP_rmsqv(a.left, 1, &l, vDSP_Length(a.frameCount))
            vDSP_rmsqv(a.right, 1, &r, vDSP_Length(a.frameCount))
            return (l + r) / 2
        }
        var kinds: [StemKind: StereoAudio] = [:]
        // The loop takes `byName` over (it is consumed), so `kinds` holds the only reference to each part.
        for (name, s) in byName { if let k = StemKind(demucsSource: name) { kinds[k] = s } }
        // Every part's level against the whole song (the sum of all parts before anything is folded): the
        // models always output every part, so a song without guitar still gets a guitar of bleed (U05).
        // The sum is made half a second at a time; it is kept whole only when there is no original to hear.
        let mixFrames = Self.mixFrames(Array(kinds.values))
        let mixAudio: StereoAudio? = original == nil ? Self.sum(Array(kinds.values)) : nil
        func level(_ a: StereoAudio) -> PartLevel { PartPresence.level(part: PartPresence.frames(a), mix: mixFrames) }
        var levels: [String: PartLevel] = [:]
        for (k, s) in kinds { levels[k.rawValue] = level(s) }
        let loudest = kinds.values.map(rms).max() ?? 1
        // Folding takes the parts out of `kinds` first, so Other is added to in place, not copied.
        for k in [StemKind.vocals, .keys, .bass, .drums] {
            guard let s = kinds[k], kinds[.other] != nil, rms(s) < foldThreshold * loudest else { continue }
            let folded = kinds.removeValue(forKey: k)!
            var other = kinds.removeValue(forKey: .other)!
            add(folded, into: &other)
            kinds[.other] = other
        }
        // A guitar is folded only when it is silent; a quiet one stays its own part (the rows can hide it,
        // and that can be undone).
        if kinds[.guitar] != nil, let l = levels[StemKind.guitar.rawValue], l.share < PartPresence.silentShare,
           kinds[.other] != nil {
            let g = kinds.removeValue(forKey: .guitar)!
            var other = kinds.removeValue(forKey: .other)!
            add(g, into: &other)
            kinds[.other] = other
        }
        if let o = kinds[.other] { levels[StemKind.other.rawValue] = level(o) }

        // What Apple's sound classifier hears (U06): the whole song and the guitar start now, beside the
        // guitar split (F9); the lead's comes after it.
        let tHear = Date()
        let heardMix = original ?? mixAudio!
        async let mixShares = InstrumentListener.shares(of: heardMix)
        let guitarForHearing = kinds[.guitar]
        async let guitarShares: InstrumentShares? = guitarForHearing.flatMap { g in
            InstrumentListener.shares(of: g, active: PartPresence.activeFrames(part: PartPresence.frames(g), mix: mixFrames))
        }

        // Lead / rhythm split (stereo position) on guitar + other: htdemucs sometimes files the lead
        // guitar under "other", so the split runs on both and the lead is taken out of both (`takeLeadOut`).
        // Measured on 6 real multitracks: backing SDR 12.2 dB (vs 11.7 guitar-only, 7.1 all-guitar).
        var split: GuitarSplitter.Result?
        var otherAdjusted: StereoAudio?
        var usedML = false
        // Only a guitar that is really there is split into lead and rhythm.
        if let g = kinds[.guitar], Self.mayTrySplit(guitar: levels[StemKind.guitar.rawValue]) {
            var src = g
            let o = kinds[.other]
            if let o { add(o, into: &src) }
            let tSplit = Date()
            // The rhythm is made below by taking the lead out of guitar and Other: the split leaves its own out.
            var r = GuitarSplitter.split(src, withRhythm: false)
            AppLog.note("process \(id): stereo split \(String(format: "%.1f", Date().timeIntervalSince(tSplit))) s")
            // The stereo analysis decides whether to split: a near-mono guitar stays one part, and then the
            // lead model isn't run at all (F2).
            if r.shouldSplit {
                let tLead = Date()
                if useLeadModel, let url = LeadSeparator.bundledModel() {
                    leadModelLoads.increment()
                    if let ml = try? LeadSeparator(modelURL: url),
                       let mlLead = try? ml.lead(of: src, progress: leadProgress, isCancelled: isCancelled) {
                        r = GuitarSplitter.Result(lead: blend(stereoLead: r.lead, mlLead: mlLead), rhythm: r.rhythm,
                                                  confidence: max(r.confidence, 0.5), width: r.width,
                                                  leadDynamics: r.leadDynamics, shouldSplit: true)
                        usedML = true
                    }
                }
                AppLog.note("process \(id): lead model \(usedML ? "used" : "not used") \(String(format: "%.1f", Date().timeIntervalSince(tLead))) s")
                // guitar + other goes before the lead is taken out (without Other it is the guitar itself).
                src = g
                let (rhythm, adjusted) = takeLeadOut(r.lead, guitar: g, other: o, src: src)
                otherAdjusted = adjusted
                split = GuitarSplitter.Result(lead: r.lead, rhythm: rhythm, confidence: r.confidence,
                                              width: r.width, leadDynamics: r.leadDynamics, shouldSplit: true)
            } else {
                AppLog.note("process \(id): lead model not used (guitar stays one part)")
            }
        }

        // A split where either half is barely there (a riff from Other, say) is dropped: one Guitar part.
        if let s = split {
            let lead = level(s.lead), rhythm = level(s.rhythm)
            if !Self.keepSplit(lead: lead, rhythm: rhythm) {
                split = nil
                otherAdjusted = nil
            } else {
                levels[StemKind.leadGuitar.rawValue] = lead
                levels[StemKind.rhythmGuitar.rawValue] = rhythm
                if let oa = otherAdjusted { levels[Self.otherSplitKey] = level(oa) }
            }
        }

        // The guitar and the lead only where they play: the rows use it to name the guitar honestly.
        let tLeadHeard = Date()
        var instruments: [String: InstrumentShares] = [:]
        if let s = split {
            instruments["lead"] = InstrumentListener.shares(
                of: s.lead, active: PartPresence.activeFrames(part: PartPresence.frames(s.lead), mix: mixFrames))
        }
        instruments["mix"] = await mixShares
        if kinds[.guitar] != nil { instruments[StemKind.guitar.rawValue] = await guitarShares }

        // Mix and guitar ran beside the split: what is left to wait for after it is the classifier's cost here.
        AppLog.note("process \(id): classifier \(String(format: "%.1f", Date().timeIntervalSince(tLeadHeard))) s after the split")
        if ProcessInfo.processInfo.environment["BL_DEBUG"] != nil {
            print("[import] instruments \(String(format: "%.2f", Date().timeIntervalSince(tHear))) s \(instruments.mapValues { "g \($0.guitar) k \($0.keys)" })")
        }
        if isCancelled() { throw CancellationError() }
        let tWrite = Date()

        let order = StemKind.displayOrder.filter { kinds[$0] != nil }

        // Every part (and the original mix) in one parallel group, each scaled as it is written (F7).
        enum File: Hashable, Sendable { case part(StemKind), otherSplit, original }
        var files: [(File, StereoAudio, URL)] = order.map { (.part($0), kinds[$0]!, store.stemURL(id, $0)) }
        if let split {
            files.append((.part(.leadGuitar), split.lead, store.stemURL(id, .leadGuitar)))
            files.append((.part(.rhythmGuitar), split.rhythm, store.stemURL(id, .rhythmGuitar)))
            if let oa = otherAdjusted { files.append((.otherSplit, oa, store.otherSplitURL(id))) }
        }
        if writeOriginal, let original { files.append((.original, original, store.originalURL(id))) }
        let written = try await withThrowingTaskGroup(of: (File, [Float], Float).self) { group in
            for (key, audio, url) in files {
                group.addTask {
                    let (p, s) = try writeScaled(audio, to: url, store: store)
                    return (key, p, s)
                }
            }
            var out: [File: ([Float], Float)] = [:]
            for try await (key, p, s) in group { out[key] = (p, s) }
            return out
        }
        var peaks: [String: [Float]] = [:]
        var scales: [String: Float] = [:]
        for k in order {
            peaks[k.rawValue] = written[.part(k)]?.0
            scales[k.rawValue] = written[.part(k)]?.1
        }

        var guitarSplit: GuitarSplit?
        if let split, let l = written[.part(.leadGuitar)], let r = written[.part(.rhythmGuitar)] {
            let (op, os) = written[.otherSplit] ?? ([], 1)
            guitarSplit = GuitarSplit(method: usedML ? LeadRefineJob.refinedMethod : LeadRefineJob.stereoMethod,
                                      confidence: split.confidence,
                                      leadPeaks: l.0, rhythmPeaks: r.0, leadScale: l.1, rhythmScale: r.1,
                                      otherAdjusted: otherAdjusted != nil, otherPeaks: op, otherScale: os)
        }

        AppLog.note("process \(id): parts written \(String(format: "%.1f", Date().timeIntervalSince(tWrite))) s")
        return Processed(order: order, peaks: peaks, scales: scales, guitarSplit: guitarSplit, levels: levels,
                         instruments: instruments, originalScale: written[.original]?.1)
    }

    /// The whole song's per-frame mean squares (`PartPresence.frames` of the parts' sum), adding the parts half
    /// a second at a time instead of holding their sum: the same additions in the same order.
    static func mixFrames(_ parts: [StereoAudio]) -> [Float] {
        guard let first = parts.first else { return [] }
        let n = first.frameCount, f = PartPresence.frame
        var l = [Float](repeating: 0, count: f), r = l
        var out: [Float] = []
        out.reserveCapacity(n / f + 1)
        for s in stride(from: 0, to: n, by: f) {
            let c = min(f, n - s)
            guard c >= f / 4 else { break }                 // only the last frame can be short
            l.withUnsafeMutableBufferPointer { lb in
                r.withUnsafeMutableBufferPointer { rb in
                    let lp = lb.baseAddress!, rp = rb.baseAddress!, len = vDSP_Length(c)
                    first.left.withUnsafeBufferPointer { lp.update(from: $0.baseAddress! + s, count: c) }
                    first.right.withUnsafeBufferPointer { rp.update(from: $0.baseAddress! + s, count: c) }
                    for p in parts.dropFirst() {
                        p.left.withUnsafeBufferPointer { vDSP_vadd(lp, 1, $0.baseAddress! + s, 1, lp, 1, len) }
                        p.right.withUnsafeBufferPointer { vDSP_vadd(rp, 1, $0.baseAddress! + s, 1, rp, 1, len) }
                    }
                }
            }
            var ml: Float = 0, mr: Float = 0
            vDSP_measqv(l, 1, &ml, vDSP_Length(c))
            vDSP_measqv(r, 1, &mr, vDSP_Length(c))
            out.append((ml + mr) / 2)
        }
        return out
    }

    /// The parts' sum, sample by sample.
    static func sum(_ parts: [StereoAudio]) -> StereoAudio {
        var mix = parts[0]
        for s in parts.dropFirst() { add(s, into: &mix) }
        return mix
    }

    /// A guitar is split into lead and rhythm only when it is really there (the stereo analysis then still
    /// has to find it wide enough).
    static func mayTrySplit(guitar: PartLevel?) -> Bool { guitar.map(PartPresence.isPresent) ?? true }

    /// A split is kept only when both halves are really playing; otherwise it is one Guitar part.
    static func keepSplit(lead: PartLevel, rhythm: PartLevel) -> Bool {
        lead.active >= PartPresence.splitHalfActive && rhythm.active >= PartPresence.splitHalfActive
    }

    /// The `levels` key of Other with the lead taken out (what the Other row plays while split).
    static let otherSplitKey = "otherSplit"


    /// Writes a stem at 16-bit with headroom scaling (applied while writing, no copy); returns its peaks and
    /// the storage gain.
    static func writeScaled(_ s: StereoAudio, to url: URL, store: SongStore) throws -> ([Float], Float) {
        let peaks = Peaks.compute(s)
        let peak = max(peaks.max() ?? 0, 1e-9)
        // 16-bit storage with headroom: scale so the part peaks at −0.1 dBFS, undo on load.
        let scale: Float = peak > 0.988 ? 0.988 / peak : 1
        try store.writeStem(s, to: url, gain: scale)
        return (peaks, scale)
    }
}
