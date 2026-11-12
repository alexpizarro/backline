import BacklineKit
import Darwin
import Foundation
import Synchronization

/// D19: a song's parts are lossless until its splitting work is done, then AAC at about 192 kbps (the AAC part
/// format in docs/release-1.1-everywhere.md, the same on all three apps). A part is converted only when no pass
/// will read it again; the new file keeps the lossless one's name and is renamed over it once it has passed the
/// check, so a song is always complete in one format or the other, part by part, and the record never changes.
/// The loader tells the two apart from the file's own data format (`SongStore.formatGain`). The kept original
/// (`original.caf` or `source.<ext>`) is never converted (D18). Ported from iOS `App/PartsCompactJob.swift`; the
/// Mac runs it whether or not its window is in front (as its passes do), and has no live storage figure to refresh
/// (Settings measures when it opens).
nonisolated enum PartsCompactJob {
    /// Where a part is written before it is renamed over the live one.
    static func tempURL(_ live: URL) -> URL {
        live.deletingPathExtension().appendingPathExtension("compact.caf")
    }

    /// The song's note of parts that were tried and are not worth converting (the check failed): file name to
    /// the lossless file's size then. A part whose file has changed since (a new kit split) is tried again.
    static let keptName = "lossless-kept.json"

    /// Whether the app starts the conversion, and a Library song's lead refinement, by itself. Off while unit
    /// tests run in the app (their songs share the Library folder with the test host); a test turns it on. Off
    /// too for a picture run (`--no-library-work`, which scripts/readme-shots.sh passes): the pictures don't need
    /// it, and the songs there are copies.
    static let automatic = Atomic<Bool>(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
                                        && !CommandLine.arguments.contains("--no-library-work"))

    // MARK: The rule

    /// The part files (names in the song's folder) that no pass will read again, so they may become AAC.
    ///
    /// Nothing while the song still has splitting work to do: the cleaner pass (when its model is installed and
    /// the song keeps an original) writes every part anew and the kit again; the lead refinement reads Guitar,
    /// Other and the stereo Lead, and every other part for the song's levels. After that: every part, except
    /// that Drums waits for the kit (a song whose kit was never split keeps lossless Drums, so a later kit split
    /// still has them); the kit parts once they exist; Lead, Rhythm and Other with the lead taken out with the
    /// guitar split. A song from 1.0 says "stereo+ml-go-v1", so its refinement is already done.
    static func convertible(_ rec: SongRecord, cleanerInstalled: Bool, leadModelBundled: Bool) -> [String] {
        let cleanerDone = rec.separator != nil || !rec.hasOriginal || !cleanerInstalled
        let leadDone = !LeadRefineJob.isPending(rec, modelBundled: leadModelBundled)
        guard cleanerDone, leadDone else { return [] }
        var names: [StemKind] = rec.stems.filter { $0 != .drums || rec.drumSplit != nil }
        if rec.guitarSplit != nil, rec.stems.contains(.guitar) { names += [.leadGuitar, .rhythmGuitar] }
        if rec.drumSplitActive { names += StemKind.drumParts }
        var files = names.map { "\(SongRecord.fileStem($0)).caf" }
        if rec.guitarSplit?.otherAdjusted == true, rec.stems.contains(.guitar) { files.append("other-split.caf") }
        return files
    }

    /// `convertible` with what this Mac has: the cleaner model downloaded, the lead model in the app.
    static func convertible(_ rec: SongRecord) -> [String] {
        convertible(rec, cleanerInstalled: ModelStore.url(CleanerPartsJob.modelName) != nil,
                    leadModelBundled: LeadSeparator.bundledModel() != nil)
    }

    // MARK: One song

    /// A file's identity: the same inode, size and modification time means nothing has written it since.
    struct Identity: Equatable, Sendable {
        var inode: UInt64, size: Int64, modified: Double
        init?(_ url: URL) {
            var st = Darwin.stat()
            guard stat(url.path, &st) == 0 else { return nil }
            inode = UInt64(st.st_ino)
            size = Int64(st.st_size)
            modified = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        }
    }

    /// How a song's visit ended.
    enum Outcome: Equatable, Sendable {
        /// Every part it was given is AAC, kept lossless on purpose, unreadable, or gone.
        case finished
        /// Stopped (an import, a reset, or memory): it is visited again later.
        case stopped
    }

    /// What one visit did, for the log and the tests.
    struct Report: Equatable, Sendable {
        var outcome: Outcome = .finished
        var converted: [String] = []
        var kept: [String] = []
        /// Parts whose lossless file couldn't be read: skipped, left as they are.
        var unreadable: [String] = []
        var bytesBefore: Int64 = 0, bytesAfter: Int64 = 0
    }

    /// Converts the song's `parts` (file names from `convertible`) one at a time. For each lossless part: write
    /// the AAC file beside it, check it, and hand it to `swap`, which renames it over the live file if the song
    /// still allows it (the app's say: the engine gate, the rule on the record as it is now, and the live file
    /// unchanged). A part that fails the check stays lossless and is noted so it isn't tried again. `mayGoOn` is
    /// asked before each part (memory), `stop` between chunks.
    static func compact(id: String, parts: [String], store: SongStore,
                        stop: @escaping @Sendable () -> Bool,
                        mayGoOn: @escaping @Sendable () -> Bool,
                        swap: @Sendable (_ name: String, _ temp: URL, _ live: URL, _ was: Identity) async -> Bool) async -> Report {
        var report = Report()
        let folder = store.folder(id)
        let fm = FileManager.default
        // What an interrupted visit left: never the live files, only the temporary ones.
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".compact.caf") {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
        var kept = readKept(folder)
        for name in parts {
            let live = folder.appendingPathComponent(name)
            guard let was = Identity(live), !SongStore.isAAC(live) else { continue }
            if kept[name] == was.size { continue }
            if stop() || !mayGoOn() { report.outcome = .stopped; return report }
            let temp = tempURL(live)
            // The encoder and the check block for seconds: on a background-priority thread of their own, not the
            // tasks' shared pool.
            let made: Result<SongStore.AACCheck, Error> = await withCheckedContinuation { c in
                DispatchQueue.global(qos: .background).async {
                    c.resume(returning: Result {
                        try store.writeAACPart(from: live, to: temp, stop: stop)
                        return try store.checkAACPart(source: live, candidate: temp, stop: stop)
                    })
                }
            }
            let check: SongStore.AACCheck
            switch made {
            case .success(let c):
                check = c
            case .failure(let error as SongStore.PartUnreadable):
                // The lossless part can't be read: it would fail the same way every time. It stays as it is, and
                // the song's other parts and the songs after it go on; the visit ends `.finished`, so the song
                // isn't visited again this session (ios-storage#1).
                try? fm.removeItem(at: temp)
                AppLog.note("AAC parts \(id): \(name) can't be read (\(error.underlying.localizedDescription)); skipped")
                report.unreadable.append(name)
                continue
            case .failure(let error):
                // Stopped, or the file couldn't be written (a full disk, the song deleted meanwhile): the part
                // stays as it is and is tried again on a later visit.
                try? fm.removeItem(at: temp)
                if !(error is CancellationError) {
                    AppLog.note("AAC parts \(id): \(name) couldn't be written (\(error.localizedDescription))")
                }
                report.outcome = .stopped
                return report
            }
            guard check.passes else {
                try? fm.removeItem(at: temp)
                AppLog.note("AAC parts \(id): \(name) kept lossless (frames \(check.frames)/\(check.sourceFrames), "
                            + "lag \(check.lag.map(String.init) ?? "none"), correlation \(String(format: "%.3f", check.correlation)), "
                            + "\(check.bytes)/\(check.sourceBytes) bytes, \(String(format: "%.1f", check.snr)) dB)")
                kept[name] = was.size
                writeKept(kept, folder)
                report.kept.append(name)
                continue
            }
            if stop() { try? fm.removeItem(at: temp); report.outcome = .stopped; return report }
            if await swap(name, temp, live, was) {
                report.converted.append(name)
                report.bytesBefore += check.sourceBytes
                report.bytesAfter += check.bytes
            } else {
                try? fm.removeItem(at: temp)
                report.outcome = .stopped
                return report
            }
        }
        return report
    }

    /// The rename itself, once the app has said yes: the live file must still be the one that was converted.
    /// Atomic: the part is either the lossless file or the AAC one, never neither.
    static func install(temp: URL, live: URL, was: Identity) -> Bool {
        guard Identity(live) == was, rename(temp.path, live.path) == 0 else { return false }
        return true
    }

    static func readKept(_ folder: URL) -> [String: Int64] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(keptName)) else { return [:] }
        return (try? JSONDecoder().decode([String: Int64].self, from: data)) ?? [:]
    }

    static func writeKept(_ kept: [String: Int64], _ folder: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try? enc.encode(kept).write(to: folder.appendingPathComponent(keptName), options: .atomic)
    }
}

extension AppModel {
    /// True when a pass is working on the song, or new parts wait for the engine: its files are not touched.
    func compactMustWait(_ id: String) -> Bool {
        if leadJob != nil && leadJobSong == id { return true }
        guard song?.id == id else { return false }
        return hqJob != nil || drumJob != nil || pendingRecord?.id == id || loadingSongID == id
    }

    /// The song's record as the app has it now: the open one, or the Library's.
    private func currentRecord(_ id: String) -> SongRecord? {
        song?.id == id ? song : library.first { $0.id == id }
    }

    /// The next song with parts that may become AAC and haven't been looked at in this form: the open song first,
    /// then the Library in its order (most recently opened first).
    func nextCompactSong() -> (id: String, parts: [String])? {
        let candidates = (song.map { [$0] } ?? []) + library.filter { $0.id != song?.id }
        let cleaner = ModelStore.url(CleanerPartsJob.modelName) != nil, lead = LeadSeparator.bundledModel() != nil
        for rec in candidates where !compactMustWait(rec.id) {
            let parts = PartsCompactJob.convertible(rec, cleanerInstalled: cleaner, leadModelBundled: lead)
            guard !parts.isEmpty, compactVisited[rec.id] != parts else { continue }
            return (rec.id, parts)
        }
        return nil
    }

    /// Starts the AAC conversion (D19) if it isn't running: at background priority, only while no import runs,
    /// one song at a time; it may run while a song plays (it uses the CPU only).
    func ensurePartsCompact() {
        guard !resetting, compactJob == nil, libraryLoaded, !importUnderWay,
              PartsCompactJob.automatic.load(ordering: .relaxed) else { return }
        guard MemoryBudget.mayStartPass, nextCompactSong() != nil else { return }
        let store = self.store
        let cancel = CancelBox()
        compactCancel = cancel
        let epoch = ResetBackline.epoch
        compactJob = Task { [weak self] in
            var changed = false
            while let next = self?.nextCompactSong(), !cancel.value, ResetBackline.isCurrent(epoch) {
                guard let model = self else { break }
                let started = Date()
                let duration = model.currentRecord(next.id)?.duration ?? 0
                let report = await Task.detached(priority: .background) { [model] in
                    await PartsCompactJob.compact(id: next.id, parts: next.parts, store: store, stop: {
                        cancel.value || !ResetBackline.isCurrent(epoch) || !MemoryBudget.mayStartPass
                    }, mayGoOn: {
                        (try? MemoryBudget.requireRoom(for: .compact, seconds: duration)) != nil
                    }, swap: { name, temp, live, was in
                        await model.installCompacted(id: next.id, name: name, temp: temp, live: live, was: was, epoch: epoch)
                    })
                }.value
                guard ResetBackline.isCurrent(epoch) else { break }
                if !report.converted.isEmpty || !report.kept.isEmpty {
                    let mb = { (b: Int64) in String(format: "%.1f", Double(b) / 1_048_576) }
                    AppLog.note("AAC parts \(next.id): \(report.converted.count) converted (\(mb(report.bytesBefore)) to "
                                + "\(mb(report.bytesAfter)) MB), \(report.kept.count) kept lossless, "
                                + "\(Int(Date().timeIntervalSince(started))) s\(report.outcome == .stopped ? ", stopped" : "")")
                }
                changed = changed || !report.converted.isEmpty
                if report.outcome == .stopped { break }
                model.compactVisited[next.id] = next.parts
            }
            guard let self, ResetBackline.isCurrent(epoch) else { return }
            self.compactJob = nil
            self.compactCancel = nil
            if changed { AppLog.note("AAC parts: this run's songs are done") }
        }
    }

    /// The swap of one part, on the main actor under the engine gate (no load, reload or export reads the song's
    /// files meanwhile): only if no pass works on the song now, the rule still allows the part on the record as it
    /// is now, and the live file is the one that was converted.
    func installCompacted(id: String, name: String, temp: URL, live: URL, was: PartsCompactJob.Identity,
                          epoch: Int) async -> Bool {
        let gate = engineGate
        await gate.acquire()
        defer { Task { await gate.release() } }
        guard ResetBackline.isCurrent(epoch), !compactMustWait(id), let rec = currentRecord(id),
              PartsCompactJob.convertible(rec).contains(name) else { return false }
        return PartsCompactJob.install(temp: temp, live: live, was: was)
    }

    /// Stops the conversion where it is (a part half written is thrown away); it carries on later (an import,
    /// a memory warning).
    func stopPartsCompact() {
        compactCancel?.value = true
    }
}
