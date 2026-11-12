import Accelerate
import BacklineKit
import Foundation
import Synchronization

/// Where Core ML models live: inside the app, or in Application Support/Backline/Models (models too big
/// to ship in the download are fetched there once).
nonisolated enum ModelStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backline/Models", isDirectory: true)
    }

    /// A compiled model (`<name>.mlmodelc`), or nil if this Mac doesn't have it yet.
    static func url(_ name: String) -> URL? {
        if let b = Bundle.main.url(forResource: name, withExtension: "mlmodelc") { return b }
        let u = directory.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
        var isDir: ObjCBool = false
        // A downloaded model counts only once its install finished: the `<name>.sha256` marker is written
        // last, so a folder without it is half-copied or half-unpacked and loading it would fail.
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue,
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(name).sha256").path) else { return nil }
        return u
    }
}

/// Splits a song's drums part into kick, snare, hats (hi-hat + cymbals) and toms (toms + the rest)
/// with MDX23C DrumSep on the GPU. Runs in the background after the song opens; the four parts are
/// written beside drums.caf and always add back to it exactly.
nonisolated enum DrumSplitJob {
    static let method = "mdx23c-drumsep-5"
    /// Overlap 2 is about 1.7× faster than the reference 4 and differs from it by only 21 to 35 dB.
    static let overlap = 2

    /// Where the song's unfinished kit split keeps its finished audio, so it carries on when it next runs. Keyed by
    /// the song, the drums part it reads (its file and its storage gain: the cleaner pass writes another) and the
    /// model: anything else and the split starts from zero.
    static func checkpoint(for rec: SongRecord, store: SongStore, modelURL: URL) -> SeparationCheckpoint {
        let drums = PassCheckpoints.identity(of: store.stemURL(rec.id, .drums))
        let scale = (rec.storageScale[StemKind.drums.rawValue] ?? 1).bitPattern
        let model = PassCheckpoints.downloadedModel(DrumSeparator.modelName, url: modelURL)
        return SeparationCheckpoint(directory: PassCheckpoints.directory(.kit, rec.id),
                                    key: "\(method)|overlap \(overlap)|\(rec.id)|\(drums)|\(scale)|\(model)|cpu")
    }

    static func run(rec: SongRecord, store: SongStore, modelURL: URL,
                    progress: @escaping @Sendable (Double) -> Void,
                    isCancelled: @Sendable () -> Bool) throws -> DrumSplit {
        // Before the drums are read: their file is part of the key.
        let kept = checkpoint(for: rec, store: store, modelURL: modelURL)
        var drums = try store.readAudio(store.stemURL(rec.id, .drums))
        // drums.caf holds the part times its storage gain: undo it for the model.
        var undo = 1 / max(rec.storageScale[StemKind.drums.rawValue] ?? 1, 1e-6)
        if undo != 1 {
            vDSP_vsmul(drums.left, 1, &undo, &drums.left, 1, vDSP_Length(drums.frameCount))
            vDSP_vsmul(drums.right, 1, &undo, &drums.right, 1, vDSP_Length(drums.frameCount))
        }

        let separator = try DrumSeparator(modelURL: modelURL, overlap: overlap)
        // Ten channels (five parts, stereo) over the drums with the split's border either side.
        let room = PassCheckpoints.ifRoom(kept, bytes: PassCheckpoints.bytes(channels: 10, frames: drums.frameCount + 2 * DrumSeparator.chunk))
        let parts = try separator.separate(drums, checkpoint: room, progress: { progress(0.95 * $0) }, isCancelled: isCancelled)
        func sum(_ a: String, _ b: String) throws -> StereoAudio {
            guard var x = parts[a], let y = parts[b] else { throw CocoaError(.coderValueNotFound) }
            vDSP_vadd(x.left, 1, y.left, 1, &x.left, 1, vDSP_Length(x.frameCount))
            vDSP_vadd(x.right, 1, y.right, 1, &x.right, 1, vDSP_Length(x.frameCount))
            return x
        }
        guard let kick = parts["kick"], let snare = parts["snare"] else { throw CocoaError(.coderValueNotFound) }
        let out: [StemKind: StereoAudio] = [.kick: kick, .snare: snare,
                                            .hats: try sum("hh", "cymbals"), .toms: try sum("toms", DrumSeparator.restKey)]
        if isCancelled() { throw CancellationError() }
        // The four parts are written at once, each scaled as it is written (F7).
        let kit = StemKind.drumParts
        let written = Mutex<[Int: Result<(peaks: [Float], scale: Float, energy: Float), Error>]>([:])
        DispatchQueue.concurrentPerform(iterations: kit.count) { i in
            let k = kit[i], a = out[k]!
            let r = Result { () throws -> (peaks: [Float], scale: Float, energy: Float) in
                let (p, s) = try ImportPipeline.writeScaled(a, to: store.stemURL(rec.id, k), store: store)
                var l: Float = 0, r: Float = 0
                vDSP_measqv(a.left, 1, &l, vDSP_Length(a.frameCount))
                vDSP_measqv(a.right, 1, &r, vDSP_Length(a.frameCount))
                return (p, s, (l + r) / 2)
            }
            written.withLock { $0[i] = r }
        }
        var peaks: [String: [Float]] = [:], scales: [String: Float] = [:], energy: [String: Float] = [:]
        let results = written.withLock { $0 }
        for (i, k) in kit.enumerated() {
            guard let r = results[i] else { throw CocoaError(.fileWriteUnknown) }
            let w = try r.get()
            peaks[k.rawValue] = w.peaks
            scales[k.rawValue] = w.scale
            energy[k.rawValue] = w.energy
        }
        // The parts are written: nothing is left to carry on from.
        kept.discard()
        progress(1)
        return DrumSplit(method: method, peaks: peaks, scales: scales, energy: energy)
    }
}

/// A row on screen: one name, one switch and one fader for one or more engine tracks.
struct MixRow: Identifiable, Equatable {
    let kind: StemKind
    let leaves: [StemKind]
    /// Probably not in this song (U05): listed under "More parts". It still plays and stays controllable.
    var quiet = false
    var id: StemKind { kind }
}

extension AppModel {
    /// Rows for the open song in the current mode. Play shows the drums as one part even when split;
    /// Beats shows the kit; Dance shows bongó / güira / bombo for bachata.
    var rows: [MixRow] {
        song.map { Self.rows(for: mode, style: settings.danceStyle, song: $0, musicOpen: settings.musicOpen,
                             placement: settings.partPlacement) } ?? []
    }

    /// The rows that make up the main list: every row that is really in the song (U05).
    var mainStems: [StemKind] { rows.filter { !$0.quiet }.map(\.kind) }

    /// Moves a part between the main list and "More parts" for this song (beats the level gate).
    func placePart(_ k: StemKind, main: Bool) { updateSettings { $0.partPlacement[k.rawValue] = main } }

    /// The parts that make up Beats' "Music" row.
    static func musicLeaves(_ song: SongRecord) -> [StemKind] {
        song.mixStems.filter { [.leadGuitar, .rhythmGuitar, .guitar, .keys, .other].contains($0) }
    }

    static func rows(for mode: PracticeMode, style: DanceStyle?, song: SongRecord, musicOpen: Bool = false,
                     placement: [String: Bool] = [:]) -> [MixRow] {
        placeByPresence(baseRows(for: mode, style: style, song: song, musicOpen: musicOpen), song: song, placement: placement)
    }

    /// Main-list rows first, then the quiet ones (U05). A song measured before levels existed, or a part the
    /// person placed by hand, keeps its place; Beats' closed Music row always stays.
    static func placeByPresence(_ rows: [MixRow], song: SongRecord, placement: [String: Bool]) -> [MixRow] {
        let (named, guitarUnsure) = nameGuitars(rows, song: song)
        let marked = named.map { r -> MixRow in
            var r = r
            if let main = placement[r.kind.rawValue] {
                r.quiet = !main
            } else if !(r.kind == .other && r.leaves.count > 1) {
                r.quiet = !r.leaves.contains { leafPresent($0, song: song) }
                    || (guitarUnsure && [.guitar, .leadGuitar, .rhythmGuitar].contains(r.kind))
            }
            return r
        }
        return marked.filter { !$0.quiet } + marked.filter(\.quiet)
    }

    /// The naming check (U06): a "lead guitar" that doesn't sound like guitar plays with the rhythm as one Guitar
    /// row; a "guitar" that sounds like keys joins the Keys row (or becomes it); a guitar in a song where the
    /// classifier hears none, and that isn't clearly keys, is reported as unsure (it goes under More parts).
    /// Beats' closed Music row is left alone. No stored shares: nothing changes.
    static func nameGuitars(_ rows: [MixRow], song: SongRecord) -> ([MixRow], unsure: Bool) {
        guard let inst = song.instruments else { return (rows, false) }
        var rows = rows
        if !NameCheck.trustLead(inst["lead"]),
           let li = rows.firstIndex(where: { $0.kind == .leadGuitar }), let ri = rows.firstIndex(where: { $0.kind == .rhythmGuitar }) {
            rows[li] = MixRow(kind: .guitar, leaves: rows[li].leaves + rows[ri].leaves)
            rows.remove(at: ri)
        }
        switch NameCheck.guitarFate(mix: inst["mix"], guitarStem: inst[StemKind.guitar.rawValue]) {
        case .keep:
            return (rows, false)
        case .joinKeys:
            guard let gi = rows.firstIndex(where: { $0.kind == .guitar }) else { return (rows, false) }
            let g = rows.remove(at: gi)
            if let ki = rows.firstIndex(where: { $0.kind == .keys }) {
                rows[ki] = MixRow(kind: .keys, leaves: rows[ki].leaves + g.leaves)
            } else {
                rows.insert(MixRow(kind: .keys, leaves: g.leaves), at: min(gi, rows.count))
            }
            return (rows, false)
        case .moreParts:
            return (rows, true)
        }
    }

    /// Whether a track is really in the song, from its stored level (no level: assume it is).
    static func leafPresent(_ leaf: StemKind, song: SongRecord) -> Bool {
        guard let levels = song.levels else { return true }
        let key: String
        switch leaf {
        case .kick, .snare, .hats, .toms: return true       // `kitRows` already drops a silent kit part
        case .other where song.splitActive && song.guitarSplit?.otherAdjusted == true: key = ImportPipeline.otherSplitKey
        default: key = leaf.rawValue
        }
        guard let l = levels[key] else { return true }
        return PartPresence.isPresent(l)
    }

    static func baseRows(for mode: PracticeMode, style: DanceStyle?, song: SongRecord, musicOpen: Bool) -> [MixRow] {
        let drumLeaves: [StemKind] = song.drumSplitActive ? StemKind.drumParts : [.drums]
        let base = song.mixStems
        func single(_ k: StemKind) -> MixRow { MixRow(kind: k, leaves: k == .drums ? drumLeaves : [k]) }
        switch mode {
        case .play:
            return base.map(single)
        case .dance:
            return base.flatMap { k -> [MixRow] in
                guard k == .drums, style == .bachata, song.drumSplitActive else { return [single(k)] }
                return kitRows([MixRow(kind: .snare, leaves: [.snare, .toms]), MixRow(kind: .hats, leaves: [.hats]),
                                MixRow(kind: .kick, leaves: [.kick])], song: song)
            }
        case .beats:
            var rows: [MixRow] = []
            if base.contains(.vocals) { rows.append(single(.vocals)) }
            if base.contains(.drums) {
                rows += song.drumSplitActive
                    ? kitRows([.kick, .snare, .hats, .toms].map { MixRow(kind: $0, leaves: [$0]) }, song: song)
                    : [single(.drums)]
            }
            if base.contains(.bass) { rows.append(single(.bass)) }
            let music = musicLeaves(song)
            if musicOpen && music.count > 1 {
                rows += music.map { MixRow(kind: $0, leaves: [$0]) }
            } else if !music.isEmpty {
                rows.append(MixRow(kind: .other, leaves: music))
            }
            return rows
        }
    }

    /// Drops kit rows that are nearly silent in this song (a bachata with no bass drum, say) and hands
    /// their tracks to the last remaining row, so every track still has a switch and a fader.
    static func kitRows(_ rows: [MixRow], song: SongRecord) -> [MixRow] {
        // Real energy when the split recorded it; older splits fall back to the waveform peaks.
        let measured = song.drumSplit?.energy ?? [:]
        let usePeaks = measured.isEmpty
        let energy: [StemKind: Float] = Dictionary(uniqueKeysWithValues: StemKind.drumParts.map { k in
            (k, usePeaks ? (song.drumSplit?.peaks[k.rawValue] ?? []).reduce(0) { $0 + $1 * $1 } : measured[k.rawValue] ?? 0)
        })
        let total = max(energy.values.reduce(0, +), 1e-12)
        let limit: Float = usePeaks ? 0.03 : 0.01
        let quiet = { (r: MixRow) in r.leaves.reduce(Float(0)) { $0 + (energy[$1] ?? 0) } / total < limit }
        var kept = rows.filter { !quiet($0) }
        guard !kept.isEmpty else { return [MixRow(kind: .drums, leaves: StemKind.drumParts)] }
        let spare = rows.filter(quiet).flatMap(\.leaves)
        if !spare.isEmpty {
            let i = kept.firstIndex { $0.kind == .toms || $0.kind == .snare } ?? kept.count - 1
            kept[i] = MixRow(kind: kept[i].kind, leaves: kept[i].leaves + spare)
        }
        return kept
    }

    /// The row that controls an engine track in the current mode.
    func rowKind(forTrack leaf: StemKind) -> StemKind { rows.first { $0.leaves.contains(leaf) }?.kind ?? leaf }

    /// Waveform peaks for a row (several tracks combine by power).
    func rowPeaks(_ k: StemKind) -> [Float] {
        guard let song else { return [] }
        guard let row = rows.first(where: { $0.kind == k }) else { return song.peaks(for: k) }
        if row.leaves.count == 1 { return song.peaks(for: row.leaves[0]) }
        if row.kind == .drums, let p = song.peaks[StemKind.drums.rawValue], !p.isEmpty { return p }
        let ps = row.leaves.map { song.peaks(for: $0) }.filter { !$0.isEmpty }
        guard let n = ps.map(\.count).max() else { return [] }
        return (0..<n).map { i in sqrt(ps.reduce(0) { $0 + ($1.indices.contains(i) ? $1[i] * $1[i] : 0) }) }
    }

    /// Engine gains in engine-track order for an export: never a removed part, spotlight applied.
    func exportGains() -> [Float] {
        guard let song else { return [] }
        let removed = settings.removed
        return loadedTracks.map { leaf in
            let k = rowKind(forTrack: leaf)
            return (isAudible(k) && !removed.contains(k))
                ? Self.gain(forVolume: settings.volume(k)) * spotlightFactor(k) * formatGain(leaf) / max(song.storageGain(leaf), 1e-6) : 0
        }
    }

    // MARK: Background drum split

    /// True when the screen shows kit parts (Beats, and Dance for bachata, where the güira is the hi-hat part).
    var kitWanted: Bool { mode == .beats || (mode == .dance && settings.danceStyle == .bachata) }

    /// True while the open song should get its kit before the cleaner pass. The cleaner pass takes minutes,
    /// so a dancer would wait that long for the güira; the kit is split from the fast drums first and made
    /// again from the cleaner drums afterwards.
    var kitGoesFirst: Bool {
        guard let rec = song else { return false }
        return kitWanted && rec.drumSplit == nil && rec.stems.contains(.drums) && drumSplitFailedFor != rec.id
            && !WorkJournal.shared.isHeldBack(.kitSplit, id: rec.id) && !isRoomRefused(.kitSplit, rec.id)
            && ModelStore.url(DrumSeparator.modelName) != nil
    }

    /// True when no new parts wait for the next pause, or only ones that leave the drums as they are (the lead
    /// refinement's): the kit split reads drums.caf with the open record's gain, so a cleaner record must land first.
    func pendingRecordKeepsDrums(_ rec: SongRecord) -> Bool {
        guard let p = pendingRecord, p.id == rec.id else { return pendingRecord == nil }
        let key = StemKind.drums.rawValue
        return p.separator == rec.separator && p.stems.contains(.drums) && p.storageScale[key] == rec.storageScale[key]
    }

    /// Splits the open song's drums in the background when the mode needs the kit parts.
    func ensureDrumSplit() {
        // Nothing starts beside an import, whatever asks (ios-import#1); its end starts it.
        guard !resetting, !importUnderWay else { return }
        if kitGoesFirst {
            // The screen shows kit parts (Beats, or Dance for bachata): the kit doesn't wait for the lead
            // refinement, which only runs while nothing plays, so a dancer who never pauses still gets the güira.
            // The two never run side by side: a refinement under way stops (it starts again after the kit).
            if let cancel = leadCancel, leadJob != nil {
                if !cancel.value { AppLog.note("lead refine \(song?.id ?? "?"): stopped for the kit split") }
                leadStoppedForKit = true
                cancel.value = true
                return          // its end starts the kit
            }
            // The same for a cleaner pass under way (it takes minutes): it stops, keeping its
            // checkpoint, its end starts the kit, and it carries on from where it stopped after the kit.
            if let cancel = hqCancel, hqJob != nil {
                if !cancel.value { AppLog.note("cleaner \(song?.id ?? "?"): stopped for the kit split") }
                cancel.value = true
                return          // its end starts the kit
            }
        } else if leadJob != nil || leadRefinePending {
            // In other modes the lead refinement goes first and never runs beside the kit split (D2).
            ensureLeadRefine()
            return
        }
        guard let rec = song, rec.stems.contains(.drums), rec.drumSplit == nil, drumJob == nil,
              hqJob == nil, pendingRecordKeepsDrums(rec), kitWanted, !WorkJournal.shared.isHeldBack(.kitSplit, id: rec.id),
              !isRoomRefused(.kitSplit, rec.id), let modelURL = ModelStore.url(DrumSeparator.modelName) else { return }
        let store = self.store
        let cancel = CancelBox()
        drumCancel = cancel
        drumSplitProgress = 0
        // Beside this song's, only the two other kit checkpoints written last stay (each is hundreds of MB).
        let dropped = PassCheckpoints.dropOthers(.kit, keeping: [rec.id], newest: PassCheckpoints.kept)
        if !dropped.isEmpty { AppLog.note("kit split \(rec.id): removed \(dropped.count) other songs' checkpoints") }
        let resuming = FileManager.default.fileExists(atPath: PassCheckpoints.directory(.kit, rec.id).path)
        AppLog.note("kit split \(rec.id): started\(isPlaying ? " while playing" : "")\(resuming ? ", carrying on from its checkpoint" : "")")
        let epoch = ResetBackline.epoch
        let started = Date()
        // Written before the work (D20 d): a run that ends during it counts as a failure at the next launch.
        WorkJournal.shared.beginPass(.kitSplit, id: rec.id)
        drumJob = Task { [weak self] in
            // K3: utility, which iOS now uses while the kit parts are on screen. The Mac ran the kit split at utility
            // already (.background throttles disk reads hard on macOS), and it only starts while `kitWanted` is
            // true. Playback never waits for it: the engine mixes on Core Audio's real-time thread from parts
            // already in memory.
            let (result, refused) = await Task.detached(priority: .utility) { [weak self] () -> (DrumSplit?, Bool) in
                // Room for the whole pass first, and for what it still makes before each chunk (D20 c).
                do {
                    try MemoryBudget.requireRoom(for: .kitSplit, seconds: rec.duration)
                } catch {
                    return (nil, (error as? MemoryBudget.Short)?.refusedAtStart == true)
                }
                return (try? DrumSplitJob.run(rec: rec, store: store, modelURL: modelURL, progress: { p in
                    Task { @MainActor in self?.drumSplitProgress = p }
                }, isCancelled: {
                    if cancel.value || !ResetBackline.isCurrent(epoch) { return true }
                    // Room for what the pass still makes, asked just before each chunk (D20 c).
                    return !MemoryBudget.roomForNextChunk(of: .kitSplit, seconds: rec.duration)
                }), false)
            }.value
            guard let self, ResetBackline.isCurrent(epoch) else { Self.dropAfterReset(id: rec.id, url: nil); return }
            self.drumJob = nil
            self.drumCancel = nil
            self.drumSplitProgress = nil
            AppLog.note("kit split \(rec.id): \(result == nil ? (refused ? "no room to start" : "stopped") : "done") after \(Int(Date().timeIntervalSince(started))) s")
            #if DEBUG
            print("[harness] kit split \(result == nil ? "stopped" : "done") in \(Int(Date().timeIntervalSince(started))) s")
            #endif
            guard let split = result else {
                // No room to start is not a failure either, and not a memory stop: not tried again until the song
                // is next opened or the app next comes to the front, and the passes after it go on (ios-import#4).
                if refused {
                    self.notePassEnded(.kitSplit, rec, .stopped)
                    self.noteRoomRefused(.kitSplit, rec.id)
                    if self.song?.id == rec.id { self.extraPartsKitSplitEnded(ok: false) }
                    self.ensureLeadRefine()
                    self.ensureCleanerParts()
                    return
                }
                // Stopped for memory is not a failure: the row keeps its place and the split starts again
                // once memory has come back (D20 c).
                guard MemoryBudget.mayStartPass else { self.notePassEnded(.kitSplit, rec, .stopped); return }
                // The extra parts row was holding its place for this split: it goes, and the toast says
                // only what really arrived (V01).
                if self.song?.id == rec.id { self.extraPartsKitSplitEnded(ok: false) }
                // Stopped (an import, say) is not failed: nothing starts now, and the kit is tried again when the
                // song is next open (with the kit still first in Beats and bachata).
                if cancel.value { self.notePassEnded(.kitSplit, rec, .stopped); return }
                // A failure: what it kept may be the cause, so the next try starts from zero.
                PassCheckpoints.discard(.kit, rec.id)
                // Not again this session: the cleaner pass stops waiting for it.
                self.drumSplitFailedFor = rec.id
                self.notePassEnded(.kitSplit, rec, .failed)
                self.ensureCleanerParts()
                return
            }
            self.notePassEnded(.kitSplit, rec, .done)
            if self.song?.id == rec.id {
                self.song?.drumSplit = split
                // A refined guitar waiting for the next pause carries the kit too, or the reload would drop it.
                if self.pendingRecord?.id == rec.id { self.pendingRecord?.drumSplit = split }
                // A part turned off as "Drums" in Beats stays off as all four kit parts.
                if self.mode == .beats, self.settings.removed.contains(.drums) {
                    self.settings.removed.remove(.drums)
                    self.settings.removed.formUnion(StemKind.drumParts)
                }
                self.persistCurrent()
                self.extraPartsKitSplitEnded(ok: true)
                self.reloadTracksWhenIdle()
                // The kit came from the fast drums: the cleaner pass is next, and the kit is made again after it.
                self.ensureCleanerParts()
            } else if let i = self.library.firstIndex(where: { $0.id == rec.id }) {
                self.library[i].drumSplit = split
                try? store.save(self.library[i])
                self.ensureCleanerParts()
                self.ensureDrumSplit()
            }
        }
    }

    /// Loads the engine's new tracks (after a split) at the next moment nothing is playing.
    func reloadTracksWhenIdle() {
        pendingTrackReload = true
        if !isPlaying { performTrackReload() }
    }

    func performTrackReload() {
        pendingTrackReload = false
        guard let current = song else { return }
        let hasPending = pendingRecord?.id == current.id
        guard hasPending || current.engineTracks != loadedTracks || forceTrackReload else { return }
        let generation = loadGeneration
        let at = position
        let store = self.store, engine = self.engine
        Task {
            let gate = self.engineGate
            await gate.acquire()
            defer { Task { await gate.release() } }
            guard generation == self.loadGeneration, let open = self.song, open.id == current.id else { return }
            // Started playing while we waited: try again at the next pause (nothing has changed yet).
            guard !self.isPlaying else { self.pendingTrackReload = true; return }
            // New parts from the cleaner pass take over now that nothing is playing.
            var rec = open
            if let p = self.pendingRecord, p.id == open.id {
                rec = p
                rec.settings = self.settings
                rec.lastOpened = open.lastOpened
                self.song = rec
                self.pendingRecord = nil
            }
            self.forceTrackReload = false
            let target = rec
            let (ok, gains) = await Task.detached(priority: .userInitiated) {
                (Self.loadEngine(target, store: store, engine: engine), Self.formatGains(target, store: store))
            }.value
            guard generation == self.loadGeneration, self.song?.id == rec.id else { return }
            if ok {
                self.loadedTracks = rec.engineTracks
                self.loadedFormatGains = gains
            } else {
                // Couldn't read the kit parts: forget the split and put the drums part back.
                AppLog.note("reload \(rec.id): the new parts can't be read; going back to the drums part")
                self.song?.drumSplit = nil
                let fallback = self.song ?? target
                let (back, backGains) = await Task.detached(priority: .userInitiated) {
                    (Self.loadEngine(fallback, store: store, engine: engine), Self.formatGains(fallback, store: store))
                }.value
                guard back else {
                    // D7: nothing readable to play; the song stays, and the failure screen says so.
                    self.showOpenFailure(fallback, .unreadable)
                    return
                }
                self.loadedTracks = self.song?.engineTracks ?? []
                self.loadedFormatGains = backGains
            }
            engine.commit()
            self.pushAll()
            self.seek(to: at)
            self.ensureDrumSplit()
            // After the lead refinement's parts: the cleaner pass may be next.
            self.ensureCleanerParts()
            // New parts in: those no pass will read again become AAC (D19).
            self.ensurePartsCompact()
        }
    }
}
