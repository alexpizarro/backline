import Accelerate
import BacklineKit
import Foundation

/// D2: a song is playable after the six-part pass and the stereo guitar split. The lead guitar model then
/// refines Lead and Rhythm from the stored files, one chunk at a time and only while nothing is playing (it holds
/// its place between chunks; a Mac keeps working while the window is behind another, so there is no foreground
/// wait as on iOS). The better parts replace the stereo ones by rename,
/// and the engine loads them at the next pause. The rows never change when it lands: a refined split that would
/// be dropped, or that would change a row, is thrown away and the stereo split stays.
nonisolated enum LeadRefineJob {
    /// The split made in the import, by stereo position alone.
    static let stereoMethod = "stereo-go-v1"
    /// Stereo split blended 50/50 with the lead guitar model (what 1.0 made in the import).
    static let refinedMethod = "stereo+ml-go-v1"
    /// The model ran, but its split would have been dropped or would have changed the rows: the stereo split
    /// stays, and the song is not refined again.
    static let keptStereoMethod = "stereo-go-v1-kept"

    /// True for a song still waiting for its refinement: its split is the import's stereo one and the app has
    /// the model. A quit mid-way leaves it pending, so it resumes on the next open with no schema change.
    static func isPending(_ rec: SongRecord, modelBundled: Bool = LeadSeparator.bundledModel() != nil) -> Bool {
        modelBundled && rec.guitarSplit?.method == stereoMethod && rec.stems.contains(.guitar)
    }

    /// Where a refined part is written before it is renamed over the live one.
    static func tempURL(_ live: URL) -> URL {
        live.deletingPathExtension().appendingPathExtension("refine.caf")
    }

    /// The refined split, written next to the live files under temporary names.
    struct Refined: Sendable {
        var split: GuitarSplit
        /// `leadGuitar`, `rhythmGuitar` and, when the lead was also taken out of Other, `otherSplit`.
        var levels: [String: PartLevel]
        var leadShares: InstrumentShares?
        /// Temporary file → the live file it replaces.
        var files: [(temp: URL, live: URL)]
    }

    /// Reads a stored part with its 16-bit storage gain undone.
    static func read(_ url: URL, gain: Float, store: SongStore) throws -> StereoAudio {
        var a = try store.readAudio(url)
        var undo = 1 / max(gain, 1e-6)
        if undo != 1 {
            vDSP_vsmul(a.left, 1, &undo, &a.left, 1, vDSP_Length(a.frameCount))
            vDSP_vsmul(a.right, 1, &undo, &a.right, 1, vDSP_Length(a.frameCount))
        }
        return a
    }

    /// Where the song's unfinished refinement keeps the model's finished lead, so it carries on when it next runs.
    /// Keyed by the song, the parts the model reads (guitar and, when the lead is taken out of it too, Other: their
    /// files and storage gains), the app's build (the model is inside it) and where it runs: anything else and the
    /// model's pass starts from zero.
    static func checkpoint(for rec: SongRecord, store: SongStore, frames: Int,
                           computeUnits: String = SeparationCompute.preferred == .cpuOnly ? "cpu" : "gpu") -> SeparationCheckpoint {
        func part(_ k: StemKind) -> String {
            "\(PassCheckpoints.identity(of: store.stemURL(rec.id, k)))x\((rec.storageScale[k.rawValue] ?? 1).bitPattern)"
        }
        let other = rec.guitarSplit?.otherAdjusted == true && rec.stems.contains(.other) ? part(.other) : "-"
        return SeparationCheckpoint(directory: PassCheckpoints.directory(.lead, rec.id),
                                    key: "lead|1|\(rec.id)|\(part(.guitar))|\(other)|\(frames)|\(PassCheckpoints.build)|\(computeUnits)")
    }

    /// Refines the song's stored stereo split with the lead model (F1). Nil when the refined split would be
    /// dropped (`keepSplit`): the stereo split then stays. Throws `CancellationError` when stopped; the model's
    /// pass then keeps its checkpoint and carries on from it next time.
    static func run(rec: SongRecord, store: SongStore, modelURL: URL,
                    progress: @escaping @Sendable (Double) -> Void = { _ in },
                    isCancelled: @escaping @Sendable () -> Bool) throws -> Refined? {
        guard let old = rec.guitarSplit, rec.stems.contains(.guitar) else { throw CocoaError(.coderValueNotFound) }
        let id = rec.id
        func gain(_ k: StemKind) -> Float { rec.storageScale[k.rawValue] ?? 1 }
        // Before the parts are read: their files are part of the key.
        let kept = checkpoint(for: rec, store: store, frames: Int(rec.duration * 44_100))
        let g = try read(store.stemURL(id, .guitar), gain: gain(.guitar), store: store)
        let o: StereoAudio? = old.otherAdjusted && rec.stems.contains(.other)
            ? try read(store.stemURL(id, .other), gain: gain(.other), store: store) : nil
        let stereoLead = try read(store.stemURL(id, .leadGuitar), gain: old.leadScale, store: store)
        // Every part is added sample by sample to the guitar: one of another length (a damaged or cut file) would
        // be read or written past its end, so it ends the pass as a failure instead (D20 f).
        func sameLength(_ a: StereoAudio) throws -> StereoAudio {
            guard a.frameCount == g.frameCount, a.left.count == a.right.count else { throw CocoaError(.fileReadCorruptFile) }
            return a
        }
        _ = try sameLength(stereoLead)
        if let o { _ = try sameLength(o) }
        // The whole song, for the parts' levels: the stored parts add up to the six raw parts' sum.
        var mix = g
        if let o { ImportPipeline.add(o, into: &mix) }
        for k in rec.stems where k != .guitar && k != .other {
            ImportPipeline.add(try sameLength(read(store.stemURL(id, k), gain: gain(k), store: store)), into: &mix)
        }
        if o == nil, rec.stems.contains(.other) {
            ImportPipeline.add(try sameLength(read(store.stemURL(id, .other), gain: gain(.other), store: store)), into: &mix)
        }
        let mixFrames = PartPresence.frames(mix)
        mix = StereoAudio(left: [], right: [], sampleRate: mix.sampleRate)
        if isCancelled() { throw CancellationError() }

        var src = g
        if let o { ImportPipeline.add(o, into: &src) }
        ImportPipeline.leadModelLoads.increment()
        let model = try LeadSeparator(modelURL: modelURL)
        let room = PassCheckpoints.ifRoom(kept, bytes: PassCheckpoints.bytes(channels: 2, frames: src.frameCount))
        let mlLead = try model.lead(of: src, checkpoint: room, progress: progress, isCancelled: isCancelled)
        if isCancelled() { throw CancellationError() }
        // The model's part is done: what is left takes seconds, so nothing more is kept for it.
        kept.discard()
        let lead = ImportPipeline.blend(stereoLead: stereoLead, mlLead: mlLead)
        let (rhythm, otherAdjusted) = ImportPipeline.takeLeadOut(lead, guitar: g, other: o, src: src)

        func level(_ a: StereoAudio) -> PartLevel { PartPresence.level(part: PartPresence.frames(a), mix: mixFrames) }
        let leadLevel = level(lead), rhythmLevel = level(rhythm)
        guard ImportPipeline.keepSplit(lead: leadLevel, rhythm: rhythmLevel) else { return nil }
        var levels = [StemKind.leadGuitar.rawValue: leadLevel, StemKind.rhythmGuitar.rawValue: rhythmLevel]
        if let oa = otherAdjusted { levels[ImportPipeline.otherSplitKey] = level(oa) }
        let shares = InstrumentListener.shares(
            of: lead, active: PartPresence.activeFrames(part: PartPresence.frames(lead), mix: mixFrames))
        if isCancelled() { throw CancellationError() }

        // Written beside the live files; renamed over them only once the app has checked the rows.
        var files: [(temp: URL, live: URL)] = []
        func write(_ a: StereoAudio, _ live: URL) throws -> ([Float], Float) {
            let temp = tempURL(live)
            try? FileManager.default.removeItem(at: temp)
            files.append((temp, live))
            return try ImportPipeline.writeScaled(a, to: temp, store: store)
        }
        do {
            let (lp, ls) = try write(lead, store.stemURL(id, .leadGuitar))
            let (rp, rs) = try write(rhythm, store.stemURL(id, .rhythmGuitar))
            var op: [Float] = [], os: Float = 1
            if let oa = otherAdjusted { (op, os) = try write(oa, store.otherSplitURL(id)) }
            let split = GuitarSplit(method: refinedMethod, confidence: max(old.confidence, 0.5),
                                    leadPeaks: lp, rhythmPeaks: rp, leadScale: ls, rhythmScale: rs,
                                    otherAdjusted: otherAdjusted != nil, otherPeaks: op, otherScale: os)
            return Refined(split: split, levels: levels, leadShares: shares, files: files)
        } catch {
            discard(files)
            throw error
        }
    }

    /// The song's record with the refined split in place of the stereo one.
    static func applied(_ r: Refined, to rec: SongRecord) -> SongRecord {
        var new = rec
        new.guitarSplit = r.split
        var levels = new.levels ?? [:]
        for (k, l) in r.levels { levels[k] = l }
        new.levels = levels
        var inst = new.instruments ?? [:]
        inst["lead"] = r.leadShares
        new.instruments = inst
        return new
    }

    /// The record that says the model was tried and the stereo split kept.
    static func keptStereo(_ rec: SongRecord) -> SongRecord {
        var new = rec
        new.guitarSplit?.method = keptStereoMethod
        return new
    }

    /// Renames each temporary file over its live one (atomic per file).
    static func install(_ files: [(temp: URL, live: URL)]) throws {
        for f in files where rename(f.temp.path, f.live.path) != 0 {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// The journal's record of a swap: the refined split and the file names, all in the song's folder.
    static func swapEntry(_ r: Refined, id: String) -> WorkJournal.LeadSwap {
        WorkJournal.LeadSwap(id: id, split: r.split, levels: r.levels, leadShares: r.leadShares,
                             files: Dictionary(r.files.map { ($0.temp.lastPathComponent, $0.live.lastPathComponent) },
                                               uniquingKeysWith: { a, _ in a }))
    }

    static func discard(_ files: [(temp: URL, live: URL)]) {
        for f in files { try? FileManager.default.removeItem(at: f.temp) }
    }
}

extension AppModel {
    /// True while the open song waits for its lead refinement (and it hasn't failed this session).
    var leadRefinePending: Bool {
        guard let rec = song else { return false }
        return LeadRefineJob.isPending(rec) && leadRefineFailedFor != rec.id
            && !WorkJournal.shared.isHeldBack(.leadRefine, id: rec.id)
    }

    /// True when every mode would show the same rows for `b` as for `a` (D2: rows don't change when the
    /// refined split lands).
    static func sameRows(_ a: SongRecord, _ b: SongRecord, placement: [String: Bool]) -> Bool {
        for open in [false, true] {
            for mode in [PracticeMode.play, .beats] {
                if rows(for: mode, style: nil, song: a, musicOpen: open, placement: placement)
                    != rows(for: mode, style: nil, song: b, musicOpen: open, placement: placement) { return false }
            }
            for style in DanceStyle.allCases {
                if rows(for: .dance, style: style, song: a, musicOpen: open, placement: placement)
                    != rows(for: .dance, style: style, song: b, musicOpen: open, placement: placement) { return false }
            }
        }
        return true
    }

    /// Starts the lead refinement for the open song if it is pending. It goes before the cleaner pass, and before
    /// the kit split except when the screen shows kit parts (`kitGoesFirst`); it never runs beside either.
    func ensureLeadRefine() {
        // Nothing starts beside an import, whatever asks (ios-import#1); its end starts it.
        guard !resetting, !importUnderWay else { return }
        // A Library song's refinement gives way to the open song's work; it carries on later.
        if leadJob != nil, let other = leadJobSong, other != song?.id, openSongHasWork { leadCancel?.value = true; return }
        // When the screen shows kit parts the kit split goes first; the refinement follows it.
        if kitGoesFirst { ensureDrumSplit(); return }
        guard let rec = song, leadRefinePending, leadJob == nil, hqJob == nil, drumJob == nil, pendingRecord == nil,
              !isRoomRefused(.leadRefine, rec.id), let modelURL = LeadSeparator.bundledModel() else { return }
        startLeadRefine(rec, modelURL: modelURL, library: false)
    }

    /// True while the open song has a pass to run (its own work goes before a Library song's refinement).
    var openSongHasWork: Bool {
        song != nil && (leadRefinePending || cleanerPartsPending || kitGoesFirst)
    }

    /// D19 (3): while nothing is playing, a Library song (not the open one) that still waits for its lead
    /// refinement gets it, so it can be finished and its parts converted. Never beside another pass, never while
    /// the open song has work of its own, never during an import; one song at a time, most recently opened first.
    /// (A Mac keeps working while its window is behind another, so unlike iOS this doesn't wait for the front.)
    func ensureLibraryLeadRefine() {
        guard !resetting, libraryLoaded, !isPlaying, !importUnderWay,
              PartsCompactJob.automatic.load(ordering: .relaxed) else { return }
        guard leadJob == nil, hqJob == nil, drumJob == nil, pendingRecord == nil, !openSongHasWork,
              MemoryBudget.mayStartPass, let modelURL = LeadSeparator.bundledModel(), let rec = nextLibraryLeadRefine()
        else { return }
        startLeadRefine(rec, modelURL: modelURL, library: true)
    }

    /// The Library song whose refinement goes next: not the open song, still waiting, not failed this session,
    /// and not held back by the journal after two failures (D20 d).
    func nextLibraryLeadRefine() -> SongRecord? {
        library.first {
            $0.id != song?.id && LeadRefineJob.isPending($0) && !libraryLeadFailed.contains($0.id)
                && !WorkJournal.shared.isHeldBack(.leadRefine, id: $0.id) && !isRoomRefused(.leadRefine, $0.id)
        }
    }

    /// Runs the refinement of `rec`: the open song's, or a Library song's (`library`).
    private func startLeadRefine(_ rec: SongRecord, modelURL: URL, library: Bool) {
        let store = self.store, engine = self.engine
        let cancel = CancelBox()
        leadCancel = cancel
        leadJobSong = rec.id
        let epoch = ResetBackline.epoch
        let started = Date()
        let peak = MemoryPeak()
        // Beside this song's, only the two other refinement checkpoints written last stay.
        PassCheckpoints.dropOthers(.lead, keeping: [rec.id], newest: PassCheckpoints.kept)
        let resuming = FileManager.default.fileExists(atPath: PassCheckpoints.directory(.lead, rec.id).path)
        AppLog.note("lead refine \(rec.id): started\(library ? " (a Library song)" : "")\(resuming ? ", carrying on from its checkpoint" : "")")
        // Written before the work (D20 d): a run that ends during it counts as a failure at the next launch,
        // for a Library song's refinement as for the open song's.
        WorkJournal.shared.beginPass(.leadRefine, id: rec.id)
        leadJob = Task { [weak self] in
            // A thread of its own (the job blocks between chunks while something plays), at user-initiated
            // priority: the model runs on the GPU and only while nothing plays.
            let result: Result<LeadRefineJob.Refined?, Error> = await withCheckedContinuation { c in
                DispatchQueue.global(qos: .userInitiated).async {
                    c.resume(returning: Result {
                        // Room for the whole pass first, and for what it still makes before each chunk (D20 c).
                        try MemoryBudget.requireRoom(for: .leadRefine, seconds: rec.duration)
                        return try LeadRefineJob.run(rec: rec, store: store, modelURL: modelURL, isCancelled: {
                            peak.sample()
                            #if DEBUG
                            DebugExit.at("lead-refine")
                            #endif
                            // Chunks run only while nothing is playing; the job keeps its place meanwhile. Each
                            // asks for room as it goes ahead.
                            while true {
                                if cancel.value || !ResetBackline.isCurrent(epoch) { return true }
                                if !engine.status.playing {
                                    return !MemoryBudget.roomForNextChunk(of: .leadRefine, seconds: rec.duration)
                                }
                                Thread.sleep(forTimeInterval: 0.2)
                            }
                        })
                    })
                }
            }
            guard let self, ResetBackline.isCurrent(epoch) else {
                if case .success(let r?) = result { LeadRefineJob.discard(r.files) }
                Self.dropAfterReset(id: rec.id, url: nil)
                return
            }
            peak.sample()
            let seconds = Int(Date().timeIntervalSince(started))
            switch result {
            case .failure(let error):
                self.leadJob = nil
                self.leadCancel = nil
                self.leadJobSong = nil
                if error is CancellationError || error is MemoryBudget.Short {
                    // Paused for an import, a reset or memory: it picks up again the next time the song opens
                    // (after a memory stop, also once memory has had a minute to come back). Stopped for the kit
                    // split: the kit starts now, and the refinement follows it.
                    let refused = (error as? MemoryBudget.Short)?.refusedAtStart == true
                    AppLog.note("lead refine \(rec.id): \(refused ? "no room to start" : "stopped after \(seconds) s")")
                    self.notePassEnded(.leadRefine, rec, .stopped)
                    if refused {
                        // Not tried again until the song is next opened or the app next comes to the front; the
                        // Library goes on to its next song (ios-import#4).
                        self.noteRoomRefused(.leadRefine, rec.id)
                        if library { self.ensureLibraryLeadRefine() }
                    }
                    if self.leadStoppedForKit {
                        self.leadStoppedForKit = false
                        self.ensureDrumSplit()
                    } else if library, !self.importUnderWay {
                        // It gave way to the open song: that song's work goes now.
                        self.ensureLeadRefine()
                        self.ensureCleanerParts()
                        self.ensureDrumSplit()
                    }
                    return
                }
                AppLog.note("lead refine \(rec.id): failed after \(seconds) s (\(error.localizedDescription)), \(peak.note)")
                // What it kept may be the cause: the next try starts from zero.
                PassCheckpoints.discard(.lead, rec.id)
                if library { self.libraryLeadFailed.insert(rec.id) } else { self.leadRefineFailedFor = rec.id }
                self.notePassEnded(.leadRefine, rec, .failed)
            case .success(let refined):
                // No engine reload or export may read the parts while they are swapped.
                await self.engineGate.acquire()
                self.landLeadRefine(rec: rec, refined: refined, store: store)
                await self.engineGate.release()
                self.leadJob = nil
                self.leadCancel = nil
                self.leadJobSong = nil
                self.notePassEnded(.leadRefine, rec, .done)
                AppLog.note("lead refine \(rec.id): done after \(seconds) s, \(peak.note)")
            }
            self.ensureDrumSplit()
            self.ensureCleanerParts()
            // The song's guitar parts may now become AAC (D19), and the next Library song may be refined.
            self.ensurePartsCompact()
            self.ensureLibraryLeadRefine()
        }
    }

    /// Puts the refined split in place (or keeps the stereo one) for the open song or a library song.
    private func landLeadRefine(rec: SongRecord, refined: LeadRefineJob.Refined?, store: SongStore) {
        let open = song?.id == rec.id
        guard let base = open ? song : library.first(where: { $0.id == rec.id }),
              FileManager.default.fileExists(atPath: store.recordURL(rec.id).path) else {
            if let refined { LeadRefineJob.discard(refined.files) }
            return
        }
        let placement = open ? settings.partPlacement : base.settings.partPlacement
        var new: SongRecord
        var swapped = false
        if let refined, case let candidate = LeadRefineJob.applied(refined, to: base),
           Self.sameRows(base, candidate, placement: placement) {
            // Restart-safe (D20 d): the journal names the swap before the first rename and is cleared once the
            // record says "refined". A run that ends in between is finished at the next launch from the journal,
            // so the refined files are never taken for the stereo ones and refined again.
            WorkJournal.shared.beginLeadSwap(LeadRefineJob.swapEntry(refined, id: rec.id))
            if (try? LeadRefineJob.install(refined.files)) == nil {
                // A file that couldn't be renamed now is renamed at the next launch (the journal keeps the swap).
                AppLog.note("lead refine \(rec.id): not every file renamed; finished at the next launch")
            } else {
                swapped = true
            }
            #if DEBUG
            DebugExit.at("lead-swap")
            #endif
            new = candidate
            AppLog.note("lead refine \(rec.id): refined parts in")
        } else {
            if let refined { LeadRefineJob.discard(refined.files) }
            new = LeadRefineJob.keptStereo(base)
            AppLog.note("lead refine \(rec.id): stereo split kept")
        }
        if open {
            // The engine keeps the old parts until the next pause, then loads the new ones.
            new.settings = settings
            pendingRecord = new
            if let i = library.firstIndex(where: { $0.id == rec.id }) { library[i] = new }
            // On disk before the journal lets go of the swap.
            persistCurrent(synchronously: true)
            forceTrackReload = true
            reloadTracksWhenIdle()
        } else if let i = library.firstIndex(where: { $0.id == rec.id }) {
            library[i] = new
            try? store.save(new)
        }
        if swapped { WorkJournal.shared.endLeadSwap(rec.id) }
    }
}
