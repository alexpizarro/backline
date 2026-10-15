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

    /// The song's record with the new parts (its settings as they were when the job started).
    static func run(rec: SongRecord, store: SongStore, modelURL: URL,
                    progress: @escaping @Sendable (Double) -> Void,
                    isCancelled: @escaping @Sendable () -> Bool) async throws -> SongRecord {
        guard let scale = rec.originalScale else { throw CocoaError(.fileNoSuchFile) }
        var audio = try store.readAudio(store.originalURL(rec.id))
        var undo = 1 / max(scale, 1e-6)
        if undo != 1 {
            vDSP_vsmul(audio.left, 1, &undo, &audio.left, 1, vDSP_Length(audio.frameCount))
            vDSP_vsmul(audio.right, 1, &undo, &audio.right, 1, vDSP_Length(audio.frameCount))
        }
        let separator = try RoformerSeparator(modelURL: modelURL)
        let raw = try separator.separate(audio, progress: { progress(0.88 * $0.fraction) }, isCancelled: isCancelled)
        if isCancelled() { throw CancellationError() }
        var byName: [String: StereoAudio] = [:]
        for (name, s) in zip(RoformerSeparator.sources, raw) { byName[name] = s }

        let fm = FileManager.default
        let staging = store.staging
        let stage = staging.folder(rec.id)
        try? fm.removeItem(at: stage)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        let processed = try await ImportPipeline.process(byName, id: rec.id, store: staging, isCancelled: isCancelled)
        if isCancelled() { try? fm.removeItem(at: stage); throw CancellationError() }
        // The original mix and the artwork come along (hard links, so nothing is copied).
        for name in ["original.caf", "artwork"] {
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
        new.drumSplit = nil                                // the kit is re-made from the cleaner drums
        new.separator = method
        try staging.save(new)
        progress(0.97)

        // Swap the folders. The song may have been deleted meanwhile: then just drop the new parts.
        let live = store.folder(rec.id)
        guard fm.fileExists(atPath: live.path) else { try? fm.removeItem(at: stage); throw CancellationError() }
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
        progress(1)
        return new
    }
}

extension AppModel {
    /// True while the open song is waiting for (or making) its cleaner parts.
    var cleanerPartsPending: Bool {
        guard let rec = song else { return false }
        return rec.separator == nil && rec.originalScale != nil && ModelStore.url(CleanerPartsJob.modelName) != nil
    }

    /// Starts the cleaner pass for the open song if it hasn't had one.
    func ensureCleanerParts() {
        guard let rec = song, cleanerPartsPending, hqJob == nil, drumJob == nil, pendingRecord == nil,
              let modelURL = ModelStore.url(CleanerPartsJob.modelName) else { return }
        let store = self.store
        let cancel = CancelBox()
        hqCancel = cancel
        hqProgress = 0
        hqJob = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { [weak self] () -> SongRecord? in
                try? await CleanerPartsJob.run(rec: rec, store: store, modelURL: modelURL, progress: { p in
                    Task { @MainActor in self?.hqProgress = p }
                }, isCancelled: { cancel.value })
            }.value
            guard let self else { return }
            self.hqJob = nil
            self.hqCancel = nil
            self.hqProgress = nil
            guard var new = result else { self.ensureDrumSplit(); return }
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
    }
}
