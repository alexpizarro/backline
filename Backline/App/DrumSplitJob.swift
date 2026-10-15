import Accelerate
import BacklineKit
import Foundation

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
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) && isDir.boolValue ? u : nil
    }
}

/// Splits a song's drums part into kick, snare, hats (hi-hat + cymbals) and toms (toms + the rest)
/// with MDX23C DrumSep on the GPU. Runs in the background after the song opens; the four parts are
/// written beside drums.caf and always add back to it exactly.
nonisolated enum DrumSplitJob {
    static let method = "mdx23c-drumsep-5"
    /// Overlap 2 is about 1.7× faster than the reference 4 and differs from it by only 21 to 35 dB.
    static let overlap = 2

    static func run(rec: SongRecord, store: SongStore, modelURL: URL,
                    progress: @escaping @Sendable (Double) -> Void,
                    isCancelled: @Sendable () -> Bool) throws -> DrumSplit {
        var drums = try store.readAudio(store.stemURL(rec.id, .drums))
        // drums.caf holds the part times its storage gain: undo it for the model.
        var undo = 1 / max(rec.storageScale[StemKind.drums.rawValue] ?? 1, 1e-6)
        if undo != 1 {
            vDSP_vsmul(drums.left, 1, &undo, &drums.left, 1, vDSP_Length(drums.frameCount))
            vDSP_vsmul(drums.right, 1, &undo, &drums.right, 1, vDSP_Length(drums.frameCount))
        }

        let separator = try DrumSeparator(modelURL: modelURL, overlap: overlap)
        let parts = try separator.separate(drums, progress: { progress(0.95 * $0) }, isCancelled: isCancelled)
        func sum(_ a: String, _ b: String) throws -> StereoAudio {
            guard var x = parts[a], let y = parts[b] else { throw CocoaError(.coderValueNotFound) }
            vDSP_vadd(x.left, 1, y.left, 1, &x.left, 1, vDSP_Length(x.frameCount))
            vDSP_vadd(x.right, 1, y.right, 1, &x.right, 1, vDSP_Length(x.frameCount))
            return x
        }
        guard let kick = parts["kick"], let snare = parts["snare"] else { throw CocoaError(.coderValueNotFound) }
        let out: [StemKind: StereoAudio] = [.kick: kick, .snare: snare,
                                            .hats: try sum("hh", "cymbals"), .toms: try sum("toms", DrumSeparator.restKey)]
        var peaks: [String: [Float]] = [:], scales: [String: Float] = [:], energy: [String: Float] = [:]
        for k in StemKind.drumParts {
            if isCancelled() { throw CancellationError() }
            let a = out[k]!
            let (p, s) = try ImportPipeline.writeScaled(a, to: store.stemURL(rec.id, k), store: store)
            peaks[k.rawValue] = p
            scales[k.rawValue] = s
            var l: Float = 0, r: Float = 0
            vDSP_measqv(a.left, 1, &l, vDSP_Length(a.frameCount))
            vDSP_measqv(a.right, 1, &r, vDSP_Length(a.frameCount))
            energy[k.rawValue] = (l + r) / 2
        }
        progress(1)
        return DrumSplit(method: method, peaks: peaks, scales: scales, energy: energy)
    }
}

/// A row on screen: one name, one switch and one fader for one or more engine tracks.
struct MixRow: Identifiable, Equatable {
    let kind: StemKind
    let leaves: [StemKind]
    var id: StemKind { kind }
}

extension AppModel {
    /// Rows for the open song in the current mode. Play shows the drums as one part even when split;
    /// Beats shows the kit; Dance shows bongó / güira / bombo for bachata.
    var rows: [MixRow] {
        song.map { Self.rows(for: mode, style: settings.danceStyle, song: $0, musicOpen: settings.musicOpen) } ?? []
    }

    /// The parts that make up Beats' "Music" row.
    static func musicLeaves(_ song: SongRecord) -> [StemKind] {
        song.mixStems.filter { [.leadGuitar, .rhythmGuitar, .guitar, .keys, .other].contains($0) }
    }

    static func rows(for mode: PracticeMode, style: DanceStyle?, song: SongRecord, musicOpen: Bool = false) -> [MixRow] {
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
                ? Self.gain(forVolume: settings.volume(k)) * spotlightFactor(k) / max(song.storageGain(leaf), 1e-6) : 0
        }
    }

    // MARK: Background drum split

    /// Splits the open song's drums in the background when the mode needs the kit parts.
    func ensureDrumSplit() {
        // After the cleaner pass (if one is coming), so the kit is split from the cleaner drums.
        guard let rec = song, rec.stems.contains(.drums), rec.drumSplit == nil, drumJob == nil,
              hqJob == nil, pendingRecord == nil, !cleanerPartsPending,
              mode == .beats || (mode == .dance && settings.danceStyle == .bachata),
              let modelURL = ModelStore.url(DrumSeparator.modelName) else { return }
        let store = self.store
        let cancel = CancelBox()
        drumCancel = cancel
        drumSplitProgress = 0
        drumJob = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { [weak self] () -> DrumSplit? in
                try? DrumSplitJob.run(rec: rec, store: store, modelURL: modelURL, progress: { p in
                    Task { @MainActor in self?.drumSplitProgress = p }
                }, isCancelled: { cancel.value })
            }.value
            guard let self else { return }
            self.drumJob = nil
            self.drumCancel = nil
            self.drumSplitProgress = nil
            guard let split = result else { self.ensureCleanerParts(); return }
            if self.song?.id == rec.id {
                self.song?.drumSplit = split
                // A part turned off as "Drums" in Beats stays off as all four kit parts.
                if self.mode == .beats, self.settings.removed.contains(.drums) {
                    self.settings.removed.remove(.drums)
                    self.settings.removed.formUnion(StemKind.drumParts)
                }
                self.persistCurrent()
                self.reloadTracksWhenIdle()
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
            let ok = await Task.detached(priority: .userInitiated) { Self.loadEngine(target, store: store, engine: engine) }.value
            guard generation == self.loadGeneration, self.song?.id == rec.id else { return }
            if ok {
                self.loadedTracks = rec.engineTracks
            } else {
                // Couldn't read the kit parts: forget the split and put the drums part back.
                self.song?.drumSplit = nil
                let fallback = self.song ?? target
                _ = await Task.detached(priority: .userInitiated) { Self.loadEngine(fallback, store: store, engine: engine) }.value
                self.loadedTracks = self.song?.engineTracks ?? []
            }
            engine.commit()
            self.pushAll()
            self.seek(to: at)
            self.ensureDrumSplit()
        }
    }
}
