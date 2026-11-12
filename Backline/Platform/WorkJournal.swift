import BacklineKit
import Foundation
import Synchronization

/// D20 (d, e): what the app is in the middle of, written before the work starts and cleared when it ends, in
/// `Application Support/Backline/Journal/work.json`. Ported from iOS `Platform/WorkJournal.swift`. An entry still
/// there at the next launch means the last run ended during that work (a crash, or the app was forced to quit),
/// and the launch says so:
///
/// - an import: the file is kept and the Library shows the song as not finished, with Try again and Remove
///   (`Unfinished`). A Mac doesn't close an app for holding too much memory the way an iPhone does (it swaps), so
///   unlike iOS an unfinished import is never taken for "too long for this Mac": that is said only when the import
///   itself reports it (`DeviceLimits.TooLong`, on the failure screen), and the Mac's length tiers are not lowered.
///   The Mac opens a file the person picked where it is (no Imports copy, unlike iOS), so for such a file the
///   journal keeps its path and a security-scoped bookmark instead of a staged copy; Backline's own recordings and
///   downloads are named by their place in `Application Support/Backline`, as on iOS.
/// - a pass (the lead refinement, the kit split, the cleaner pass) that ended while the app was running normally:
///   one more failure for that song. After two, it isn't started again by itself; the Player offers Try again.
///   A Mac keeps working while its window is behind another, so "in front" here means "not quitting": a pass
///   that ends because the person quit Backline (`applicationWillTerminate`) is not its failure.
/// - the lead refinement's swap: the refined files were being renamed over the stereo ones. It is finished from
///   the journal (the renames that hadn't happened, then the record), so a song never holds refined parts under
///   a record that says they are the stereo ones (which would refine them again).
///
/// Nothing in it names a song beyond its id and the title the Library shows; it is deleted by Reset with the
/// rest of `Application Support/Backline`.
nonisolated final class WorkJournal: Sendable {
    static let shared = WorkJournal(folder: BacklineFolders.support.appendingPathComponent("Journal", isDirectory: true))

    /// The background passes a song can fail in.
    enum Pass: String, Codable, CaseIterable, Sendable {
        case leadRefine, kitSplit, cleaner

        /// For the app's log.
        var logName: String {
            switch self {
            case .leadRefine: "lead refine"
            case .kitSplit: "kit split"
            case .cleaner: "cleaner"
            }
        }
    }

    /// How a pass ended.
    enum Outcome: Sendable {
        /// It finished (or decided there was nothing to do): its failures are forgotten.
        case done
        /// Stopped by the app (an import, a song switch, Reset, memory): not a failure, it starts again later.
        case stopped
        /// It failed: one more failure for that song.
        case failed
    }

    /// After this many failures (a crash during it counts) a pass isn't started again by itself.
    static let failureLimit = 2

    /// An import in progress.
    struct ImportEntry: Codable, Equatable, Sendable {
        var id: String
        /// Backline's own file (a recording or a download), relative to `Application Support/Backline` (the
        /// container's path can change); empty for a file the person picked (`external`).
        var staged: String
        /// What the Library shows while it isn't finished.
        var title: String
        /// The title and artist the song keeps whatever its file says (a link's or a recording's).
        var titleOverride: String?
        var artist: String?
        /// The song's `sourceName` when it came from a link (so it is found again as that link).
        var source: String?
        /// The picture a link brought, kept beside the journal while the import isn't finished.
        var hasArtwork = false
        /// How far it got (`ImportProgress.phase`: 0 reading, 1 to 4 splitting, 5 finishing).
        var stage = 0
        /// The song's length, once read.
        var seconds: Double?
        var started = Date()
        /// Mac: the person's own file, opened where it is (its path, and a bookmark that opens it again from a
        /// new run of the sandboxed app when the system gives one).
        var external: String?
        var bookmark: Data?

        init(id: String, staged: String, title: String, titleOverride: String? = nil, artist: String? = nil,
             source: String? = nil, stage: Int = 0, seconds: Double? = nil, external: String? = nil, bookmark: Data? = nil) {
            self.id = id; self.staged = staged; self.title = title; self.titleOverride = titleOverride
            self.artist = artist; self.source = source; self.stage = stage; self.seconds = seconds
            self.external = external; self.bookmark = bookmark
        }
    }

    /// An import a previous run didn't finish.
    struct Unfinished: Codable, Equatable, Identifiable, Sendable {
        var entry: ImportEntry
        /// The run was stopped for memory while splitting. Always false on the Mac (see the type's note); kept so
        /// the record and the Library row read as on iOS.
        var endedForMemory: Bool
        var id: String { entry.id }
    }

    /// The lead refinement's swap, written just before the renames.
    struct LeadSwap: Codable, Equatable, Sendable {
        var id: String
        var split: GuitarSplit
        var levels: [String: PartLevel]
        var leadShares: InstrumentShares?
        /// Temporary file name → the live file name it replaces, both in the song's folder.
        var files: [String: String]
    }

    struct PassEntry: Codable, Equatable, Sendable {
        var pass: Pass
        var id: String
    }

    struct State: Codable, Equatable, Sendable {
        var running: ImportEntry?
        var passes: [PassEntry] = []
        var leadSwap: LeadSwap?
        /// Backline was running normally (not quitting) when this was last written.
        var inFront = false
        var unfinished: [Unfinished] = []
        /// Failures per pass and song (`key`).
        var failures: [String: Int] = [:]

        static func key(_ pass: Pass, _ id: String) -> String { pass.rawValue + " " + id }
    }

    let folder: URL
    var url: URL { folder.appendingPathComponent("work.json") }
    private let state: Mutex<State>
    /// The journal was there but couldn't be read (damaged, or written by a build that knows more): it was moved
    /// aside to `work.json.bad`, and this run deletes no staged file, since which ones it named isn't known
    /// (release review ios-storage#4).
    let unreadable: Bool

    init(folder: URL) {
        self.folder = folder
        let url = folder.appendingPathComponent("work.json")
        let fm = FileManager.default
        let saved = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        unreadable = saved == nil && fm.fileExists(atPath: url.path)
        if unreadable {
            let aside = folder.appendingPathComponent("work.json.bad")
            try? fm.removeItem(at: aside)
            let moved = (try? fm.moveItem(at: url, to: aside)) != nil
            AppLog.note("journal: work.json couldn't be read; \(moved ? "moved aside to work.json.bad" : "not moved") "
                        + "and no staged file is deleted at this launch")
        }
        state = Mutex(saved ?? State())
    }

    /// The state as it is now (tests, the launch).
    var snapshot: State { state.withLock { $0 } }

    /// Changes the state and writes it at once (a small file, written atomically).
    private func change(write: Bool = true, _ body: (inout State) -> Void) {
        let new = state.withLock { s -> State? in
            let old = s
            body(&s)
            return s == old ? nil : s
        }
        guard write, let new else { return }
        save(new)
    }

    private func save(_ s: State) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(s) else { return }
        do { try data.write(to: url, options: .atomic) } catch { AppLog.note("journal: not written (\(error.localizedDescription))") }
    }

    // MARK: Being in front

    /// Mac: true from launch, false once the person quits (`applicationWillTerminate`). Written when an import or
    /// a pass is running, since that is what the next launch reads it for.
    func setInFront(_ inFront: Bool) {
        let busy = state.withLock { s -> Bool in
            s.inFront = inFront
            return s.running != nil || !s.passes.isEmpty
        }
        if busy { save(snapshot) }
    }

    // MARK: Imports

    /// Where an import's file is noted from when it is Backline's own (Downloads or Recordings); nil for a file
    /// the person picked.
    static func relativePath(_ url: URL, base: URL = BacklineFolders.support) -> String? {
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        let b = base.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return p.hasPrefix(b) ? String(p.dropFirst(b.count)) : nil
    }

    /// The file an entry names: Backline's own under `base`, or the person's where it is.
    static func fileURL(_ entry: ImportEntry, base: URL = BacklineFolders.support) -> URL {
        if let external = entry.external, entry.staged.isEmpty { return URL(fileURLWithPath: external) }
        return base.appendingPathComponent(entry.staged)
    }

    /// An import starts. `artwork` is a link's picture, kept until the import ends.
    func beginImport(_ entry: ImportEntry, artwork: Data?) {
        var entry = entry
        if let artwork {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            entry.hasArtwork = (try? artwork.write(to: artworkURL(entry.id), options: .atomic)) != nil
        }
        change { s in
            s.running = entry
            // Trying an unfinished one again: it is the running import now.
            s.unfinished.removeAll { $0.id == entry.id }
        }
    }

    /// The import reached a new step (from the progress reports, on any thread): written only when it moves on.
    func noteImport(_ id: String, stage: Int) {
        change { s in
            guard s.running?.id == id, let old = s.running?.stage, stage > old else { return }
            s.running?.stage = stage
        }
    }

    /// The song's length, once read.
    func noteImport(_ id: String, seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        change { s in
            guard s.running?.id == id else { return }
            s.running?.seconds = seconds
        }
    }

    /// The song's own name, once its file was read (the Library shows it if the import isn't finished).
    func noteImport(_ id: String, title: String) {
        change { s in
            guard s.running?.id == id, !title.isEmpty else { return }
            s.running?.title = title
        }
    }

    /// The import ended, whichever way: nothing is left in progress.
    func endImport(_ id: String) {
        change { s in
            guard s.running?.id == id else { return }
            s.running = nil
        }
        try? FileManager.default.removeItem(at: artworkURL(id))
    }

    /// A link's picture for an unfinished import.
    func artworkURL(_ id: String) -> URL { folder.appendingPathComponent("\(id).artwork") }
    func artwork(_ id: String) -> Data? { try? Data(contentsOf: artworkURL(id)) }

    var unfinished: [Unfinished] { snapshot.unfinished }

    /// Try again or Remove on an unfinished import: it leaves the list (Try again makes it the running import).
    func forgetUnfinished(_ id: String, keepArtwork: Bool = false) {
        change { s in s.unfinished.removeAll { $0.id == id } }
        if !keepArtwork { try? FileManager.default.removeItem(at: artworkURL(id)) }
    }

    // MARK: Passes

    func beginPass(_ pass: Pass, id: String) {
        change { s in
            s.passes.removeAll { $0 == PassEntry(pass: pass, id: id) }
            s.passes.append(PassEntry(pass: pass, id: id))
        }
    }

    func endPass(_ pass: Pass, id: String, _ outcome: Outcome) {
        change { s in
            s.passes.removeAll { $0 == PassEntry(pass: pass, id: id) }
            let key = State.key(pass, id)
            switch outcome {
            case .done: s.failures[key] = nil
            case .stopped: break
            case .failed: s.failures[key, default: 0] += 1
            }
        }
    }

    func failures(_ pass: Pass, id: String) -> Int { snapshot.failures[State.key(pass, id)] ?? 0 }

    /// True when the pass failed twice on this song: it waits for Try again.
    func isHeldBack(_ pass: Pass, id: String) -> Bool { failures(pass, id: id) >= Self.failureLimit }

    /// The passes held back for a song.
    func heldBack(id: String) -> [Pass] { Pass.allCases.filter { isHeldBack($0, id: id) } }

    /// Try again on a held-back pass: its failures are forgotten, so it starts as a new one would.
    func forgetFailures(_ pass: Pass, id: String) {
        change { s in s.failures[State.key(pass, id)] = nil }
    }

    /// A song that left the Library takes its counts with it.
    func forgetSong(_ id: String) {
        change { s in
            for p in Pass.allCases { s.failures[State.key(p, id)] = nil }
            s.unfinished.removeAll { $0.id == id }
        }
        try? FileManager.default.removeItem(at: artworkURL(id))
    }

    // MARK: The lead refinement's swap

    /// Written just before the renames; `endLeadSwap` after the record is saved.
    func beginLeadSwap(_ swap: LeadSwap) { change { $0.leadSwap = swap } }

    func endLeadSwap(_ id: String) {
        change { s in if s.leadSwap?.id == id { s.leadSwap = nil } }
    }

    // MARK: Reset

    /// Reset (the file went with `Application Support/Backline`): nothing in memory either, and no file a late
    /// write may have made since.
    func forget() {
        change(write: false) { $0 = State() }
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Launch

    /// What the launch found.
    struct Recovery: Equatable, Sendable {
        /// Imports the last run didn't finish (with what earlier launches kept).
        var unfinished: [Unfinished] = []
        /// Backline's own files to keep (absolute paths): recordings the microphone's cleanup must leave.
        var keepFiles: Set<String> = []
        /// Song folders to keep from the sweep.
        var keepSongs: Set<String> = []
        /// Passes the last run ended during.
        var interruptedPasses: [PassEntry] = []
        /// A lead refinement swap finished from the journal.
        var finishedLeadSwap: String?
        /// `*.refine.caf` files removed.
        var removedRefineFiles = 0
        /// The journal couldn't be read: `ImportStaging.cleanUpDownloads` keeps every download at this launch.
        var journalUnreadable = false
    }

    /// True while an unfinished import's file can still be split again: Backline's own file is there, or the
    /// person's file is there or has a bookmark (whether the sandbox still lets it be read is found out on Try
    /// again, which says so if not).
    static func fileIsKept(_ entry: ImportEntry, base: URL = BacklineFolders.support) -> Bool {
        if entry.staged.isEmpty { return entry.bookmark != nil || entry.external.map { FileManager.default.fileExists(atPath: $0) } == true }
        return FileManager.default.fileExists(atPath: base.appendingPathComponent(entry.staged).path)
    }

    /// At launch, before the sweep and before anything starts: reads what the last run left in progress and
    /// turns it into what this run offers. Interrupted cleaner swaps are put back first (they are the song).
    @discardableResult
    func recoverAtLaunch(store: SongStore, base: URL = BacklineFolders.support) -> Recovery {
        store.recoverInterruptedSwaps()
        var out = Recovery(journalUnreadable: unreadable)
        var s = snapshot
        let fm = FileManager.default

        if let swap = s.leadSwap {
            Self.finishLeadSwap(swap, store: store)
            out.finishedLeadSwap = swap.id
            AppLog.note("journal: lead refine \(swap.id): the swap was interrupted; finished from the journal")
            s.leadSwap = nil
            // Its pass got to the end: done, not failed.
            s.passes.removeAll { $0 == PassEntry(pass: .leadRefine, id: swap.id) }
            s.failures[State.key(.leadRefine, swap.id)] = nil
        }
        out.removedRefineFiles = Self.sweepRefineFiles(store: store)

        if let running = s.running {
            if fm.fileExists(atPath: store.recordURL(running.id).path) {
                // Its record was written: the song is in the Library, only the clearing of the entry was missed.
                AppLog.note("journal: import \(running.id): finished before the last run ended")
            } else if Self.fileIsKept(running, base: base) {
                // A Mac isn't closed for memory the way an iPhone is: never "too long" from this alone.
                s.unfinished.removeAll { $0.id == running.id }
                s.unfinished.insert(Unfinished(entry: running, endedForMemory: false), at: 0)
                AppLog.note("journal: import \(running.id): the last run ended during it (step \(running.stage)); kept to try again")
            } else {
                AppLog.note("journal: import \(running.id): the last run ended during it; its file is gone")
            }
            s.running = nil
        }
        // An unfinished import whose file went can't be tried again.
        s.unfinished.removeAll { !Self.fileIsKept($0.entry, base: base) }

        // A pass that ended because the person quit is not the pass failing; one that ended while the app was
        // running normally (a crash, a forced quit) is.
        for p in s.passes {
            let key = State.key(p.pass, p.id)
            guard s.inFront else {
                AppLog.note("journal: \(p.pass.logName) \(p.id): the last run ended during it, quitting (not counted)")
                continue
            }
            let n = (s.failures[key] ?? 0) + 1
            s.failures[key] = n
            AppLog.note("journal: \(p.pass.logName) \(p.id): the last run ended during it (failure \(n) of \(Self.failureLimit))")
        }
        out.interruptedPasses = s.passes
        s.passes = []
        s.inFront = false

        state.withLock { $0 = s }
        save(s)
        out.unfinished = s.unfinished
        out.keepFiles = Set(s.unfinished.filter { !$0.entry.staged.isEmpty }
            .map { base.appendingPathComponent($0.entry.staged).standardizedFileURL.path })
        out.keepSongs = Set(s.unfinished.map(\.id))
        return out
    }

    /// Finishes an interrupted lead refinement swap: each temporary file still there is renamed over its live
    /// one (it was complete before the journal named it), then the record gets the refined split. A song that
    /// is gone, or whose record no longer has a stereo split, only loses the temporary files.
    static func finishLeadSwap(_ swap: LeadSwap, store: SongStore) {
        let fm = FileManager.default
        let folder = store.folder(swap.id)
        let record = store.recordURL(swap.id)
        guard let data = try? Data(contentsOf: record), var rec = try? JSONDecoder().decode(SongRecord.self, from: data),
              rec.guitarSplit != nil else {
            for temp in swap.files.keys where isPlainName(temp) { try? fm.removeItem(at: folder.appendingPathComponent(temp)) }
            return
        }
        for (temp, live) in swap.files where isPlainName(temp) && isPlainName(live) {
            let t = folder.appendingPathComponent(temp)
            if fm.fileExists(atPath: t.path) { _ = rename(t.path, folder.appendingPathComponent(live).path) }
        }
        rec = LeadRefineJob.applied(LeadRefineJob.Refined(split: swap.split, levels: swap.levels, leadShares: swap.leadShares,
                                                          files: []), to: rec)
        try? store.save(rec)
    }

    /// A file name inside a song's folder (never a path out of it).
    static func isPlainName(_ name: String) -> Bool { !name.isEmpty && !name.contains("/") && name != "." && name != ".." }

    /// Removes `*.refine.caf` left in song folders by a lead refinement that stopped while writing (or a swap
    /// that was finished above). Only at launch, before any pass starts.
    @discardableResult
    static func sweepRefineFiles(store: SongStore) -> Int {
        let fm = FileManager.default
        var removed = 0
        for id in (try? fm.contentsOfDirectory(atPath: store.root.path)) ?? [] {
            let folder = store.folder(id)
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".refine.caf") {
                if (try? fm.removeItem(at: folder.appendingPathComponent(name))) != nil { removed += 1 }
            }
        }
        if removed > 0 { AppLog.note("journal: removed \(removed) unfinished lead refinement files") }
        return removed
    }
}

#if DEBUG
/// Tests of what the next launch says (D20 d): `--exit-at <point>` ends the app at that point as a crash would,
/// with no chance to tidy up. `--exit-away` says it was quitting at the time, so a pass isn't counted.
///   import-split   the import's six-part split has started
///   lead-refine    the lead refinement's first chunk
///   lead-swap      the lead refinement's files are renamed, its record not yet saved
nonisolated enum DebugExit {
    static func at(_ point: String) {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--exit-at"), i + 1 < a.count, a[i + 1] == point else { return }
        if a.contains("--exit-away") { WorkJournal.shared.setInFront(false) }
        print("[harness] exiting at \(point)")
        AppLog.note("debug: exiting at \(point)")
        AppLog.flush()
        exit(0)
    }
}
#endif
