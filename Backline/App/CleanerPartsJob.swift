import Accelerate
import BacklineKit
import Foundation

/// The cleaner background pass: BS-RoFormer SW (6 parts, Core ML on the GPU) re-splits the kept original
/// mix after the song has opened on the fast HTDemucs parts. It writes a complete new set of parts in a
/// staging folder and swaps the folder in at the end, so a quit or crash mid-way never mixes old and new
/// files. Lead/rhythm and the drum kit are re-made from the cleaner parts.
nonisolated enum CleanerPartsJob {
    static let method = "bs-roformer-sw"
    static let modelName = "BSRoformerSW"

    /// Where a song's unfinished cleaner pass keeps its finished audio, so reopening the song carries on instead
    /// of starting again. Caches: the system may clear it, which only costs a restart.
    static func checkpointDirectory(_ id: String) -> URL { PassCheckpoints.directory(.cleaner, id) }

    /// Only the open song's cleaner pass ever resumes, so when one starts every other song's checkpoint goes
    /// (storage F5: up to 127 MB per song-minute). That song restarts its pass when it is next opened, as it would
    /// after the system cleared Caches. Returns the ids removed.
    @discardableResult
    static func dropOtherCheckpoints(keeping id: String, root: URL = SongStore.cleanerCheckpoints) -> [String] {
        let fm = FileManager.default
        let others = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0 != id }
        return others.filter { (try? fm.removeItem(at: root.appendingPathComponent($0, isDirectory: true))) != nil }
    }

    /// Same song, same model, same backend: anything else invalidates a kept prefix.
    static func checkpoint(for rec: SongRecord, frames: Int, modelURL: URL) -> SeparationCheckpoint {
        let marker = ModelStore.directory.appendingPathComponent("\(modelName).sha256")
        let model = (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? modelURL.lastPathComponent
        // The Mac keeps the GPU (the iOS key says "cpu" because iOS forces .cpuOnly on this model).
        return SeparationCheckpoint(directory: checkpointDirectory(rec.id), key: "\(method)|1|\(rec.id)|\(frames)|\(model)|gpu")
    }

    /// What splits the original into the six parts (RoformerSeparator.sources order). Tests stand in for it.
    typealias Separate = @Sendable (StereoAudio, SeparationCheckpoint, @escaping @Sendable (Double) -> Void,
                                    @escaping @Sendable () -> Bool) throws -> [StereoAudio]

    /// The song's record with the new parts (its settings as they were when the job started).
    static func run(rec: SongRecord, store: SongStore, modelURL: URL,
                    progress: @escaping @Sendable (Double) -> Void,
                    isCancelled: @escaping @Sendable () -> Bool) async throws -> SongRecord {
        try await run(rec: rec, store: store, modelURL: modelURL, separate: { audio, kept, report, cancelled in
            let separator = try RoformerSeparator(modelURL: modelURL)
            // Loading the model can take a minute: a reset or a new import may have come meanwhile.
            if cancelled() { throw CancellationError() }
            return try separator.separate(audio, checkpoint: kept, progress: { report($0.fraction) }, isCancelled: cancelled)
        }, progress: progress, isCancelled: isCancelled)
    }

    static func run(rec: SongRecord, store: SongStore, modelURL: URL, separate: Separate,
                    progress: @escaping @Sendable (Double) -> Void,
                    isCancelled: @escaping @Sendable () -> Bool) async throws -> SongRecord {
        // The kept original: the source file the song came from (D18), decoded as the import decoded it, or
        // original.caf with its storage gain undone.
        let audio = try store.readOriginal(rec)
        if isCancelled() { throw CancellationError() }
        let kept = checkpoint(for: rec, frames: audio.frameCount, modelURL: modelURL)
        let raw = try separate(audio, kept, { progress(0.88 * $0) }, isCancelled)
        if isCancelled() { throw CancellationError() }
        // The parts move into `byName` and from there into `process`, which drops each one it no longer needs:
        // nothing here keeps a second reference, as in the import (one would make every change in `process` a
        // whole-song copy, and keep all six parts alive to the end of this function).
        var byName: [String: StereoAudio] = [:]
        for (name, s) in zip(RoformerSeparator.sources, consume raw) { byName[name] = s }

        let fm = FileManager.default
        let staging = store.staging
        let stage = staging.folder(rec.id)
        try? fm.removeItem(at: stage)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        let processed = try await ImportPipeline.process(consume byName, id: rec.id, store: staging, original: audio,
                                                         isCancelled: isCancelled)
        if isCancelled() { try? fm.removeItem(at: stage); throw CancellationError() }
        // The original mix (original.caf or the kept source) and the artwork come along (hard links, so
        // nothing is copied).
        let originalName = rec.originalFile.flatMap { SongStore.isSourceName($0) ? $0 : nil } ?? "original.caf"
        for name in [originalName, "artwork"] {
            let src = store.folder(rec.id).appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = stage.appendingPathComponent(name)
            if (try? fm.linkItem(at: src, to: dst)) == nil { try fm.copyItem(at: src, to: dst) }
        }
        var new = rec
        new.stems = processed.order
        new.peaks = processed.peaks
        new.storageScale = processed.scales
        new.guitarSplit = processed.guitarSplit
        new.levels = processed.levels
        new.instruments = processed.instruments
        new.drumSplit = nil                                // the kit is re-made from the cleaner drums
        new.separator = method
        try staging.save(new)
        progress(0.97)

        // Swap the folders. The song may have been deleted meanwhile: then just drop the new parts.
        let live = store.folder(rec.id)
        guard fm.fileExists(atPath: live.path) else {
            try? fm.removeItem(at: stage)
            kept.discard()
            throw CancellationError()
        }
        let old = staging.root.appendingPathComponent(rec.id + "-old", isDirectory: true)
        try? fm.removeItem(at: old)
        try fm.moveItem(at: live, to: old)
        do {
            try fm.moveItem(at: stage, to: live)
        } catch {
            try? fm.moveItem(at: old, to: live)
            throw error
        }
        try? fm.removeItem(at: old)
        kept.discard()
        progress(1)
        return new
    }
}

extension AppModel {
    /// True while the open song is waiting for (or making) its cleaner parts.
    var cleanerPartsPending: Bool {
        guard let rec = song else { return false }
        return rec.separator == nil && rec.hasOriginal && ModelStore.url(CleanerPartsJob.modelName) != nil
            && !WorkJournal.shared.isHeldBack(.cleaner, id: rec.id)
    }

    /// Starts the cleaner pass for the open song if it hasn't had one.
    func ensureCleanerParts() {
        // Nothing starts beside an import, whatever asks (ios-import#1); its end starts it.
        guard !resetting, !importUnderWay else { return }
        // The lead refinement goes first and never runs beside the cleaner pass (D2).
        if leadJob != nil || leadRefinePending { ensureLeadRefine(); return }
        guard let rec = song, cleanerPartsPending, hqJob == nil, drumJob == nil, pendingRecord == nil, !kitGoesFirst,
              !isRoomRefused(.cleaner, rec.id), let modelURL = ModelStore.url(CleanerPartsJob.modelName) else { return }
        let store = self.store
        let cancel = CancelBox()
        hqCancel = cancel
        hqProgress = 0
        let started = Date()
        let resuming = FileManager.default.fileExists(atPath: CleanerPartsJob.checkpointDirectory(rec.id).path)
        AppLog.note("cleaner \(rec.id): started\(resuming ? ", carrying on from its checkpoint" : "")")
        let epoch = ResetBackline.epoch
        // Written before the work (D20 d): a run that ends during it counts as a failure at the next launch.
        WorkJournal.shared.beginPass(.cleaner, id: rec.id)
        hqJob = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { [weak self] () -> Result<SongRecord, Error> in
                let dropped = CleanerPartsJob.dropOtherCheckpoints(keeping: rec.id)
                if !dropped.isEmpty { AppLog.note("cleaner \(rec.id): removed \(dropped.count) other songs' checkpoints") }
                do {
                    // Room for the whole pass first, and for what it still makes before each chunk (D20 c).
                    try MemoryBudget.requireRoom(for: .cleaner, seconds: rec.duration)
                    return .success(try await CleanerPartsJob.run(rec: rec, store: store, modelURL: modelURL, progress: { p in
                        Task { @MainActor in self?.hqProgress = p }
                    }, isCancelled: {
                        if cancel.value || !ResetBackline.isCurrent(epoch) { return true }
                        // Room for what the pass still makes, asked just before each chunk (D20 c).
                        return !MemoryBudget.roomForNextChunk(of: .cleaner, seconds: rec.duration)
                    }))
                } catch {
                    return .failure(error)
                }
            }.value
            // After a reset this pass changes nothing; what it wrote under its own id goes.
            guard let self, ResetBackline.isCurrent(epoch) else { Self.dropAfterReset(id: rec.id, url: nil); return }
            self.hqJob = nil
            self.hqCancel = nil
            self.hqProgress = nil
            guard case .success(var new) = result else {
                // Stopped (an import, a song switch, memory, the song deleted) starts again later; anything else
                // is a failure, and two on a song keep it from starting by itself (D20 d).
                var stopped = cancel.value
                if case .failure(let error) = result, error is CancellationError || error is MemoryBudget.Short { stopped = true }
                // No room to start: not tried again until the song is next opened or the app next comes to the
                // front (ios-import#4).
                if case .failure(let error) = result, (error as? MemoryBudget.Short)?.refusedAtStart == true {
                    self.noteRoomRefused(.cleaner, rec.id)
                }
                AppLog.note("cleaner \(rec.id): \(stopped ? "stopped" : "failed") after \(Int(Date().timeIntervalSince(started))) s")
                self.notePassEnded(.cleaner, rec, stopped ? .stopped : .failed)
                self.ensureDrumSplit()
                return
            }
            AppLog.note("cleaner \(rec.id): done after \(Int(Date().timeIntervalSince(started))) s")
            self.notePassEnded(.cleaner, rec, .done)
            if self.song?.id == rec.id {
                // Keep what the user changed while it ran. The engine keeps playing the old parts until
                // the next pause, then loads the new ones (reloadTracksWhenIdle).
                new.settings = self.settings
                new.lastOpened = self.song?.lastOpened ?? new.lastOpened
                self.pendingRecord = new
                if let i = self.library.firstIndex(where: { $0.id == rec.id }) { self.library[i] = new }
                self.persistCurrent()
                self.forceTrackReload = true
                self.reloadTracksWhenIdle()
                self.showToast(Toast(text: "Cleaner parts are ready"))
            } else if let i = self.library.firstIndex(where: { $0.id == rec.id }) {
                new.settings = self.library[i].settings
                self.library[i] = new
                try? store.save(new)
                // That was another song: the one open now may be waiting for its turn.
                self.ensureCleanerParts()
                self.ensureDrumSplit()
            }
        }
    }

    /// Stops background work (a new import needs the GPU). It picks up again next time the song opens.
    func pauseBackgroundWork() {
        hqCancel?.value = true
        drumCancel?.value = true
        leadCancel?.value = true
        leadStoppedForKit = false       // an import: the kit doesn't start when the refinement ends
        stopPartsCompact()
    }

    /// Back on the open song after an import was cancelled or failed: carry on with whatever it is waiting for.
    func resumeBackgroundWork() {
        guard !resetting, screen == .mixer, song != nil else { return }
        ensureLeadRefine()
        ensureCleanerParts()
        ensureDrumSplit()
    }
}
