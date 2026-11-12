import BacklineKit
import Foundation
import SwiftUI

/// D20 (d, e): after a crash or a forced quit, the app says what happened and nothing is lost. The journal
/// (`WorkJournal`) says what the last run was in the middle of; this is what the Library and the Player offer.
/// Ported from iOS `App/AppModel+Recovery.swift`. The Mac opens a file the person picked where it is, so its
/// journal entry keeps the file's path and a bookmark instead of a staged copy.
extension AppModel {
    // MARK: Imports

    /// The journal entry for an import about to start: the file (kept if the run ends), what the Library shows
    /// meanwhile, the overrides a link set, and the song's length once read.
    func noteImportStarted(url: URL, id: String) {
        var entry: WorkJournal.ImportEntry
        if let staged = WorkJournal.relativePath(url) {
            entry = .init(id: id, staged: staged, title: importTitle)
        } else {
            // The person's own file: its path, and a bookmark that opens it again from the next run when the
            // sandbox gives one (the file is open for reading now, from the panel or the drop).
            let bookmark = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                 includingResourceValuesForKeys: nil, relativeTo: nil)
            entry = .init(id: id, staged: "", title: importTitle, external: url.path, bookmark: bookmark)
        }
        entry.titleOverride = importTitleOverride
        entry.artist = importArtistOverride
        entry.source = importSourceOverride
        let journal = WorkJournal.shared
        journal.beginImport(entry, artwork: importArtworkOverride)
        unfinishedImports.removeAll { $0.id == id }
        Task.detached(priority: .utility) {
            if let seconds = await AudioDecoder.duration(of: url) { journal.noteImport(id, seconds: seconds) }
        }
    }

    /// The device word in what the Library says.
    static var deviceName: String { "Mac" }

    /// The line under an unfinished import's title. On the Mac `endedForMemory` is never set (a Mac isn't
    /// closed for memory the way an iPhone is), so it is always the first sentence. Clicking the song, or Try
    /// again, carries on from where its split stopped (R3), so the line says so.
    static func unfinishedLine(_ u: WorkJournal.Unfinished, device: String = deviceName) -> String {
        u.endedForMemory ? "This song is too long for this \(device)."
            : "Backline closed while it was splitting this song. Click to carry on."
    }

    /// Try again is offered unless the song is past this Mac's longest.
    static func mayTryAgain(_ u: WorkJournal.Unfinished, limit: Double = DeviceLimits.maxSongSeconds) -> Bool {
        guard u.endedForMemory, let seconds = u.entry.seconds else { return true }
        return seconds <= limit + 1
    }

    /// The file to split again: Backline's own, or the person's through its bookmark (security-scoped, so the
    /// sandbox lets this run read it) or its path.
    static func retryURL(_ entry: WorkJournal.ImportEntry) -> URL? {
        if !entry.staged.isEmpty {
            let url = WorkJournal.fileURL(entry)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        if let bookmark = entry.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil,
                                  bookmarkDataIsStale: &stale) {
                return url
            }
        }
        guard let path = entry.external, FileManager.default.isReadableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Try again, or a click on the song, on an unfinished import: the kept file is split again, with the title,
    /// artist, picture and source a link gave it, carrying on from what the split had done (its checkpoint, by the
    /// file's content id). Nothing is downloaded again and no part already split is split again.
    func retryUnfinished(_ u: WorkJournal.Unfinished) {
        guard !resetting, !refuseAnotherImport() else { return }
        guard let url = Self.retryURL(u.entry) else {
            removeUnfinished(u)
            showToast(Toast(text: "That file is gone. Add the song again.", isError: true))
            return
        }
        AppLog.note("journal: import \(u.id): trying again")
        importTitleOverride = u.entry.titleOverride
        importArtistOverride = u.entry.artist
        importSourceOverride = u.entry.source
        importArtworkOverride = u.entry.hasArtwork ? WorkJournal.shared.artwork(u.id) : nil
        importTitle = u.entry.title
        WorkJournal.shared.forgetUnfinished(u.id)
        unfinishedImports.removeAll { $0.id == u.id }
        open(url)
    }

    /// Remove on an unfinished import: Backline's own kept file and the half-written folder go (a file the
    /// person picked is never deleted).
    func removeUnfinished(_ u: WorkJournal.Unfinished) {
        AppLog.note("journal: import \(u.id): removed")
        if !u.entry.staged.isEmpty { ImportStaging.discard(WorkJournal.fileURL(u.entry)) }
        // What its split had done goes too (R3).
        PassCheckpoints.discard(.importSplit, u.id)
        // Only a folder without a record: a song of the same file added since stays.
        if !FileManager.default.fileExists(atPath: store.recordURL(u.id).path) { store.delete(u.id) }
        WorkJournal.shared.forgetUnfinished(u.id)
        unfinishedImports.removeAll { $0.id == u.id }
    }

    // MARK: Passes

    /// The open song's held-back passes, read again (after a song opens and after a pass ends).
    func refreshHeldBack() {
        let new = song.map { WorkJournal.shared.heldBack(id: $0.id) } ?? []
        if new != heldBackPasses { heldBackPasses = new }
    }

    /// A pass of `rec` ended. Not after a reset: the journal is new by then.
    func notePassEnded(_ pass: WorkJournal.Pass, _ rec: SongRecord, _ outcome: WorkJournal.Outcome) {
        WorkJournal.shared.endPass(pass, id: rec.id, outcome)
        if outcome == .failed {
            let n = WorkJournal.shared.failures(pass, id: rec.id)
            AppLog.note("\(pass.logName) \(rec.id): failure \(n) of \(WorkJournal.failureLimit)"
                        + (n >= WorkJournal.failureLimit ? "; not started again by itself" : ""))
        }
        refreshHeldBack()
    }

    /// Try again on the open song's held-back passes: their failures are forgotten and they start as usual.
    func retryHeldBack() {
        guard let rec = song else { return }
        for pass in heldBackPasses { WorkJournal.shared.forgetFailures(pass, id: rec.id) }
        AppLog.note("journal: \(rec.id): trying \(heldBackPasses.map(\.logName).joined(separator: ", ")) again")
        if heldBackPasses.contains(.leadRefine), leadRefineFailedFor == rec.id { leadRefineFailedFor = nil }
        if heldBackPasses.contains(.kitSplit), drumSplitFailedFor == rec.id { drumSplitFailedFor = nil }
        refreshHeldBack()
        ensureLeadRefine()
        ensureCleanerParts()
        ensureDrumSplit()
    }
}
