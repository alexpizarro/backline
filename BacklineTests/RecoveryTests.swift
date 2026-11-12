import BacklineKit
import XCTest
@testable import Backline

/// D20 (d, e, f), ported from iOS `RecoveryTests` (175feae): what the next launch makes of work a run ended
/// during, the lead refinement's swap made restart-safe, and the words. The Mac's own: a picked file is kept by
/// its path and bookmark (no staged copy), quitting is not a pass's failure, and a Mac isn't closed for memory, so
/// no unfinished import is blamed on its length and the tiers never go down (iOS's learned-limit tests stay iOS's).
final class RecoveryTests: XCTestCase {
    private var dir: URL!
    private var store: SongStore!
    private var base: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("RecoveryTests-\(UUID().uuidString)")
        base = dir.appendingPathComponent("Backline", isDirectory: true)
        store = SongStore(root: base.appendingPathComponent("Songs", isDirectory: true))
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(at: dir!) }
    }

    private func journal() -> WorkJournal { WorkJournal(folder: base.appendingPathComponent("Journal", isDirectory: true)) }

    /// Backline's own file (a link's download), as the link engine leaves it.
    private func staged(_ name: String = "ABC-song.m4a") throws -> URL {
        let u = base.appendingPathComponent("Downloads/\(name)")
        try Data("audio".utf8).write(to: u)
        return u
    }

    private func entry(_ id: String, _ url: URL, seconds: Double? = 552) -> WorkJournal.ImportEntry {
        WorkJournal.ImportEntry(id: id, staged: WorkJournal.relativePath(url, base: base)!, title: "Long Song", titleOverride: nil,
                                artist: nil, source: nil, stage: 2, seconds: seconds)
    }

    // MARK: Imports

    func testAnImportEndedWhileRunningIsKeptWithoutBlamingMemory() throws {
        let file = try staged()
        let j = journal()
        j.setInFront(true)
        j.beginImport(entry("song1", file), artwork: nil)
        // A half-written folder, as an import killed before its record leaves it.
        try FileManager.default.createDirectory(at: store.folder("song1"), withIntermediateDirectories: true)

        // The next launch reads the file the last run left.
        let next = journal()
        let r = next.recoverAtLaunch(store: store, base: base)
        XCTAssertEqual(r.unfinished.map(\.id), ["song1"])
        XCTAssertEqual(r.unfinished.first?.endedForMemory, false, "a Mac isn't closed for memory: never \"too long\"")
        XCTAssertEqual(r.keepFiles, [file.standardizedFileURL.path], "Backline's own file is kept")
        XCTAssertEqual(r.keepSongs, ["song1"], "and its folder from the sweep")
        XCTAssertEqual(DeviceLimits.maxSongSeconds, DeviceLimits.maxSongSeconds(memory: ProcessInfo.processInfo.physicalMemory),
                       "the length tiers stay")
        XCTAssertNil(next.snapshot.running, "nothing is in progress any more")
        XCTAssertEqual(journal().unfinished.map(\.id), ["song1"], "and that is on disk")

        // A third launch still offers it.
        let third = journal().recoverAtLaunch(store: store, base: base)
        XCTAssertEqual(third.unfinished.map(\.id), ["song1"])
    }

    /// The Mac opens a picked file where it is: the journal keeps its path (and a bookmark when the sandbox gives
    /// one), never deletes it, and Try again finds it there.
    @MainActor
    func testAPickedFileIsKeptByItsPathAndNeverDeleted() throws {
        let own = dir.appendingPathComponent("Music/My Song.mp3")
        try FileManager.default.createDirectory(at: own.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: own)
        XCTAssertNil(WorkJournal.relativePath(own, base: base), "not Backline's own file")
        let j = journal()
        j.setInFront(true)
        j.beginImport(WorkJournal.ImportEntry(id: "song1", staged: "", title: "My Song", external: own.path), artwork: nil)
        let r = journal().recoverAtLaunch(store: store, base: base)
        XCTAssertEqual(r.unfinished.map(\.id), ["song1"])
        XCTAssertTrue(r.keepFiles.isEmpty, "nothing of the person's is Backline's to keep or delete")
        XCTAssertEqual(WorkJournal.fileURL(r.unfinished[0].entry, base: base).path, own.path)
        XCTAssertEqual(AppModel.retryURL(r.unfinished[0].entry)?.path, own.path, "Try again opens it where it is")
        // Gone, with no bookmark: it can't be tried again.
        try FileManager.default.removeItem(at: own)
        XCTAssertNil(AppModel.retryURL(r.unfinished[0].entry))
        XCTAssertTrue(journal().recoverAtLaunch(store: store, base: base).unfinished.isEmpty)
    }

    func testAnImportEndedWhileQuittingIsKeptToo() throws {
        let file = try staged()
        let j = journal()
        j.setInFront(true)
        j.beginImport(entry("song1", file), artwork: Data("cover".utf8))
        j.noteImport("song1", stage: 3)
        j.setInFront(false)              // quitting
        let r = journal().recoverAtLaunch(store: store, base: base)
        XCTAssertEqual(r.unfinished.first?.endedForMemory, false)
        XCTAssertEqual(r.unfinished.first?.entry.stage, 3)
        XCTAssertEqual(r.unfinished.first?.entry.hasArtwork, true)
        XCTAssertEqual(journal().artwork("song1"), Data("cover".utf8), "a link's picture is kept for Try again")
    }

    func testAnImportThatEndedNormallyLeavesNothing() throws {
        let file = try staged()
        let j = journal()
        j.setInFront(true)
        j.beginImport(entry("song1", file), artwork: Data("cover".utf8))
        j.endImport("song1")
        let r = journal().recoverAtLaunch(store: store, base: base)
        XCTAssertTrue(r.unfinished.isEmpty)
        XCTAssertTrue(r.keepFiles.isEmpty)
        XCTAssertNil(journal().artwork("song1"))
    }

    func testAnImportWhoseRecordWasWrittenIsNotUnfinished() throws {
        let file = try staged()
        let j = journal()
        j.setInFront(true)
        j.beginImport(entry("song1", file), artwork: nil)
        try FileManager.default.createDirectory(at: store.folder("song1"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: store.recordURL("song1"))
        let r = journal().recoverAtLaunch(store: store, base: base)
        XCTAssertTrue(r.unfinished.isEmpty, "the song is in the Library; only clearing the entry was missed")
    }

    func testAnUnfinishedImportWhoseFileWentIsDropped() throws {
        let file = try staged()
        let j = journal()
        j.beginImport(entry("song1", file), artwork: nil)
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(journal().recoverAtLaunch(store: store, base: base).unfinished.isEmpty)
    }

    func testTryingAgainMakesItTheRunningImportAndRemoveForgetsIt() throws {
        let file = try staged()
        journal().beginImport(entry("song1", file), artwork: nil)
        let j = journal()
        _ = j.recoverAtLaunch(store: store, base: base)
        XCTAssertEqual(j.unfinished.count, 1)
        j.beginImport(entry("song1", file), artwork: nil)
        XCTAssertTrue(j.unfinished.isEmpty, "a running import is not also unfinished")
        XCTAssertEqual(j.snapshot.running?.id, "song1")
        j.endImport("song1")
        let other = try staged("DEF-other.m4a")
        j.beginImport(entry("song2", other), artwork: nil)
        let k = journal()
        _ = k.recoverAtLaunch(store: store, base: base)
        k.forgetUnfinished("song2")
        XCTAssertTrue(journal().unfinished.isEmpty)
    }

    func testTheStepOnlyMovesOnAndOnlyForTheRunningImport() throws {
        let file = try staged()
        let j = journal()
        j.beginImport(entry("song1", file), artwork: nil)
        j.noteImport("song1", stage: 4)
        j.noteImport("song1", stage: 1)
        j.noteImport("other", stage: 5)
        j.noteImport("song1", seconds: .nan)
        j.noteImport("song1", title: "Its Own Name")
        j.noteImport("other", title: "Not This")
        XCTAssertEqual(j.snapshot.running?.stage, 4)
        XCTAssertEqual(j.snapshot.running?.seconds, 552, "a length that isn't a number is not written")
        XCTAssertEqual(j.snapshot.running?.title, "Its Own Name", "the file's own title once read")
    }

    func testTheStagedPathIsRelativeToTheBacklineFolder() {
        let u = base.appendingPathComponent("Downloads/x.m4a")
        XCTAssertEqual(WorkJournal.relativePath(u, base: base), "Downloads/x.m4a")
        XCTAssertNil(WorkJournal.relativePath(URL(fileURLWithPath: "/tmp/elsewhere.mp3"), base: base))
    }

    /// The Mac has no launch clean-up of staged files; the microphone's sweep of old recordings is what could
    /// take a kept recording, and it is told which ones to leave.
    func testTheRecordingsSweepKeepsTheFilesItIsTold() throws {
        let fm = FileManager.default
        let recordings = dir.appendingPathComponent("Recordings", isDirectory: true)
        try fm.createDirectory(at: recordings, withIntermediateDirectories: true)
        let keep = recordings.appendingPathComponent("keep.caf"), drop = recordings.appendingPathComponent("drop.caf")
        try Data("a".utf8).write(to: keep)
        try Data("b".utf8).write(to: drop)
        let old = Date().addingTimeInterval(-3 * 24 * 3600)
        for u in [keep, drop] { try fm.setAttributes([.modificationDate: old], ofItemAtPath: u.path) }
        RecordingTrimmer.purgeStale(in: recordings, keeping: ["keep.caf"])
        XCTAssertTrue(fm.fileExists(atPath: keep.path))
        XCTAssertFalse(fm.fileExists(atPath: drop.path))
    }

    /// Release review ios-storage#4: a journal that can't be read is moved aside and logged, and that launch
    /// deletes no staged file (which ones it named isn't known).
    func testAnUnreadableJournalIsMovedAsideAndNoStagedFileIsDeleted() throws {
        let fm = FileManager.default
        let folder = base.appendingPathComponent("Journal", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{\"running\": 42".utf8).write(to: folder.appendingPathComponent("work.json"))
        let j = journal()
        XCTAssertTrue(j.unreadable)
        XCTAssertEqual(j.snapshot, WorkJournal.State())
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("work.json.bad").path), "kept aside to look at")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("work.json.bad")), Data("{\"running\": 42".utf8))
        let recovered = j.recoverAtLaunch(store: store, base: base)
        XCTAssertTrue(recovered.journalUnreadable)

        // The launch's cleanup then keeps every download (the Mac's staged files; a picked file is never touched).
        let file = try staged("RecoveryTests-unnamed.m4a")
        ImportStaging.cleanUpDownloads(keeping: recovered.keepFiles, keepAll: recovered.journalUnreadable,
                                       in: base.appendingPathComponent("Downloads"))
        XCTAssertTrue(fm.fileExists(atPath: file.path), "no staged file is deleted at that launch")
        // Without that, a download nothing names goes, as before.
        ImportStaging.cleanUpDownloads(keeping: [], in: base.appendingPathComponent("Downloads"))
        XCTAssertFalse(fm.fileExists(atPath: file.path))

        // A journal that reads is not unreadable, and no journal at all (a first launch) isn't either.
        XCTAssertFalse(journal().unreadable, "the next launch reads the fresh one")
        try fm.removeItem(at: folder)
        XCTAssertFalse(journal().unreadable)
    }

    func testTheSweepKeepsTheFolderOfAnUnfinishedImport() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: store.folder("song1"), withIntermediateDirectories: true)
        try fm.createDirectory(at: store.folder("orphan"), withIntermediateDirectories: true)
        let none = dir.appendingPathComponent("none")
        let swept = store.sweepLeftovers(checkpoints: none, models: none, keeping: ["song1"])
        XCTAssertEqual(swept.songFolders, ["orphan"])
        XCTAssertTrue(fm.fileExists(atPath: store.folder("song1").path))
    }

    // MARK: Passes

    func testAPassTheRunEndedDuringCountsAndTwoHoldItBack() {
        let j = journal()
        j.setInFront(true)
        j.beginPass(.cleaner, id: "song1")
        var r = journal().recoverAtLaunch(store: store, base: base)
        XCTAssertEqual(r.interruptedPasses, [.init(pass: .cleaner, id: "song1")])
        XCTAssertEqual(journal().failures(.cleaner, id: "song1"), 1)
        XCTAssertFalse(journal().isHeldBack(.cleaner, id: "song1"), "one failure: it starts again by itself")

        let k = journal()
        k.setInFront(true)
        k.beginPass(.cleaner, id: "song1")
        r = journal().recoverAtLaunch(store: store, base: base)
        let l = journal()
        XCTAssertTrue(l.isHeldBack(.cleaner, id: "song1"), "two: it waits for Try again")
        XCTAssertEqual(l.heldBack(id: "song1"), [.cleaner])
        XCTAssertFalse(l.isHeldBack(.kitSplit, id: "song1"), "other passes are not held back")
        XCTAssertFalse(l.isHeldBack(.cleaner, id: "song2"), "nor other songs")
        l.forgetFailures(.cleaner, id: "song1")
        XCTAssertFalse(journal().isHeldBack(.cleaner, id: "song1"), "Try again starts it as new")
    }

    /// Quitting Backline during a pass is not the pass failing.
    func testAPassEndedWhileQuittingIsNotCounted() {
        let j = journal()
        j.setInFront(true)
        j.beginPass(.kitSplit, id: "song1")
        j.setInFront(false)
        let r = journal().recoverAtLaunch(store: store, base: base)
        XCTAssertEqual(r.interruptedPasses.count, 1)
        XCTAssertEqual(journal().failures(.kitSplit, id: "song1"), 0)
    }

    func testAStopIsNotAFailureAndADoneForgetsTheFailures() {
        let j = journal()
        j.beginPass(.kitSplit, id: "s")
        j.endPass(.kitSplit, id: "s", .failed)
        j.beginPass(.kitSplit, id: "s")
        j.endPass(.kitSplit, id: "s", .stopped)
        XCTAssertEqual(j.failures(.kitSplit, id: "s"), 1)
        XCTAssertTrue(j.snapshot.passes.isEmpty)
        j.beginPass(.kitSplit, id: "s")
        j.endPass(.kitSplit, id: "s", .failed)
        XCTAssertTrue(j.isHeldBack(.kitSplit, id: "s"))
        j.endPass(.kitSplit, id: "s", .done)
        XCTAssertEqual(j.failures(.kitSplit, id: "s"), 0)
        // Nothing left in progress: the next launch counts nothing.
        XCTAssertTrue(journal().recoverAtLaunch(store: store, base: base).interruptedPasses.isEmpty)
    }

    func testDeletingASongForgetsItsCounts() {
        let j = journal()
        j.endPass(.leadRefine, id: "s", .failed)
        j.endPass(.leadRefine, id: "s", .failed)
        j.forgetSong("s")
        XCTAssertEqual(journal().failures(.leadRefine, id: "s"), 0)
    }

    // MARK: The lead refinement's swap

    private func tone(_ f: Double, _ amp: Double, frames: Int = 44_100) -> StereoAudio {
        StereoAudio(left: (0..<frames).map { Float(amp * sin(Double($0) * f)) },
                    right: (0..<frames).map { Float(amp * sin(Double($0) * f * 1.1)) }, sampleRate: 44_100)
    }

    private func stereoSong() throws -> SongRecord {
        let id = "song1"
        try FileManager.default.createDirectory(at: store.folder(id), withIntermediateDirectories: true)
        for k in [StemKind.guitar, .leadGuitar, .rhythmGuitar] { try store.writeStem(tone(0.01, 0.3), to: store.stemURL(id, k)) }
        let json: [String: Any] = ["bpm": 120.0, "beats": [0.0, 0.5], "downbeats": [0.0], "key": "E minor", "tuningCents": 0.0,
                                   "sections": [] as [Any]]
        let analysis = try JSONDecoder().decode(SongAnalysis.self, from: JSONSerialization.data(withJSONObject: json))
        let split = GuitarSplit(method: LeadRefineJob.stereoMethod, confidence: 0.7, leadPeaks: [0.3], rhythmPeaks: [0.3],
                                leadScale: 1, rhythmScale: 1, otherAdjusted: false, otherPeaks: [], otherScale: 1)
        let rec = SongRecord(id: id, title: "T", artist: nil, duration: 1, sourceName: "t.mp3", addedAt: Date(), lastOpened: Date(),
                             stems: [.guitar], analysis: analysis, peaks: [:], storageScale: [:], hasArtwork: false,
                             settings: SongSettings(), guitarSplit: split)
        try store.save(rec)
        return rec
    }

    /// Writes the refined files beside the live ones, as `LeadRefineJob.run` does.
    private func refined(_ rec: SongRecord) throws -> LeadRefineJob.Refined {
        var files: [(temp: URL, live: URL)] = []
        for k in [StemKind.leadGuitar, .rhythmGuitar] {
            let live = store.stemURL(rec.id, k)
            let temp = LeadRefineJob.tempURL(live)
            try store.writeStem(tone(0.02, 0.5), to: temp)
            files.append((temp, live))
        }
        let split = GuitarSplit(method: LeadRefineJob.refinedMethod, confidence: 0.7, leadPeaks: [0.5], rhythmPeaks: [0.5],
                                leadScale: 1, rhythmScale: 1, otherAdjusted: false, otherPeaks: [], otherScale: 1)
        return LeadRefineJob.Refined(split: split, levels: [:], leadShares: nil, files: files)
    }

    private func loadRecord(_ id: String) throws -> SongRecord {
        try JSONDecoder().decode(SongRecord.self, from: Data(contentsOf: store.recordURL(id)))
    }

    /// The last pass's item: a run that ended between the renames and saving the record would refine the refined
    /// lead again. The journal finishes the swap instead: the record says refined, the files are the refined ones.
    func testASwapInterruptedAfterTheRenamesIsFinishedFromTheJournal() throws {
        let rec = try stereoSong()
        let r = try refined(rec)
        let expected = try store.readAudio(r.files[0].temp)
        let j = journal()
        j.setInFront(true)
        j.beginPass(.leadRefine, id: rec.id)
        j.beginLeadSwap(LeadRefineJob.swapEntry(r, id: rec.id))
        try LeadRefineJob.install(r.files)
        // ...and the run ends here: the record still says stereo.
        XCTAssertTrue(LeadRefineJob.isPending(try loadRecord(rec.id), modelBundled: true), "without the journal it would run again")

        let out = journal().recoverAtLaunch(store: store, base: base)
        XCTAssertEqual(out.finishedLeadSwap, rec.id)
        XCTAssertEqual(journal().failures(.leadRefine, id: rec.id), 0, "the pass got to the end: not a failure")
        let after = try loadRecord(rec.id)
        XCTAssertEqual(after.guitarSplit?.method, LeadRefineJob.refinedMethod)
        XCTAssertFalse(LeadRefineJob.isPending(after, modelBundled: true), "not refined again")
        XCTAssertEqual(try store.readAudio(store.stemURL(rec.id, .leadGuitar)).left, expected.left)
        XCTAssertNil(journal().snapshot.leadSwap)
    }

    func testASwapInterruptedBeforeEveryRenameIsFinishedToo() throws {
        let rec = try stereoSong()
        let r = try refined(rec)
        let lead = try store.readAudio(r.files[0].temp), rhythm = try store.readAudio(r.files[1].temp)
        journal().beginLeadSwap(LeadRefineJob.swapEntry(r, id: rec.id))
        XCTAssertEqual(rename(r.files[0].temp.path, r.files[0].live.path), 0)      // one of two renamed
        _ = journal().recoverAtLaunch(store: store, base: base)
        XCTAssertEqual(try store.readAudio(store.stemURL(rec.id, .leadGuitar)).left, lead.left)
        XCTAssertEqual(try store.readAudio(store.stemURL(rec.id, .rhythmGuitar)).left, rhythm.left)
        XCTAssertEqual(try loadRecord(rec.id).guitarSplit?.method, LeadRefineJob.refinedMethod)
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.files[1].temp.path))
    }

    func testRefineFilesLeftByAStoppedPassAreSweptAndTheSongIsUntouched() throws {
        let rec = try stereoSong()
        let before = try store.readAudio(store.stemURL(rec.id, .leadGuitar))
        let r = try refined(rec)                      // written, never swapped: the run ended while writing
        let out = journal().recoverAtLaunch(store: store, base: base)
        XCTAssertEqual(out.removedRefineFiles, 2)
        for f in r.files { XCTAssertFalse(FileManager.default.fileExists(atPath: f.temp.path)) }
        XCTAssertEqual(try store.readAudio(store.stemURL(rec.id, .leadGuitar)).left, before.left)
        XCTAssertEqual(try loadRecord(rec.id).guitarSplit?.method, LeadRefineJob.stereoMethod, "still pending, from the stereo files")
    }

    func testASwapForASongThatWentOnlyLosesItsFiles() throws {
        let rec = try stereoSong()
        let r = try refined(rec)
        journal().beginLeadSwap(LeadRefineJob.swapEntry(r, id: rec.id))
        try FileManager.default.removeItem(at: store.recordURL(rec.id))
        _ = journal().recoverAtLaunch(store: store, base: base)
        for f in r.files { XCTAssertFalse(FileManager.default.fileExists(atPath: f.temp.path)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.recordURL(rec.id).path), "no record is made up")
    }

    func testTheSwapNamesOnlyFilesInTheSongsFolder() {
        XCTAssertTrue(WorkJournal.isPlainName("lead.refine.caf"))
        XCTAssertFalse(WorkJournal.isPlainName("../song.json"))
        XCTAssertFalse(WorkJournal.isPlainName(".."))
        XCTAssertFalse(WorkJournal.isPlainName(""))
    }

    /// D20 (f): a stored part of another length would be added past its end; it ends the pass as a failure.
    func testTheRefinementRefusesPartsOfDifferentLengths() throws {
        let rec = try stereoSong()
        try store.writeStem(tone(0.01, 0.3, frames: 30_000), to: store.stemURL(rec.id, .leadGuitar))
        XCTAssertThrowsError(try LeadRefineJob.run(rec: rec, store: store, modelURL: URL(fileURLWithPath: "/nonexistent"),
                                                   isCancelled: { false })) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileReadCorruptFile)
        }
    }

    // MARK: Words

    @MainActor
    func testTheWords() {
        let e = WorkJournal.ImportEntry(id: "x", staged: "Downloads/x.m4a", title: "T", seconds: 552)
        XCTAssertEqual(AppModel.unfinishedLine(.init(entry: e, endedForMemory: false)),
                       "Backline closed while it was splitting this song. Click to carry on.")
        XCTAssertEqual(AppModel.deviceName, "Mac")
        XCTAssertEqual(AppModel.unfinishedLine(.init(entry: e, endedForMemory: true)),
                       "This song is too long for this Mac.")
        XCTAssertTrue(AppModel.mayTryAgain(.init(entry: e, endedForMemory: false), limit: 60))
        XCTAssertFalse(AppModel.mayTryAgain(.init(entry: e, endedForMemory: true), limit: 540),
                       "past the lowered limit: the same attempt would end the same way")
        XCTAssertTrue(AppModel.mayTryAgain(.init(entry: e, endedForMemory: true), limit: 600))
    }

    // MARK: Reset

    func testResetTakesTheJournalAway() {
        let path = WorkJournal.shared.url.standardizedFileURL.path
        XCTAssertTrue(ResetBackline.live().move.contains { path.hasPrefix($0.standardizedFileURL.path + "/") },
                      "the journal is inside a folder Reset removes")
        let j = journal()
        j.endPass(.cleaner, id: "s", .failed)
        j.forget()
        XCTAssertEqual(j.snapshot, WorkJournal.State())
    }
}
