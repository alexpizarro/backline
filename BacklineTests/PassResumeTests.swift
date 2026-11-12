import BacklineKit
import Foundation
import XCTest
@testable import Backline

/// The owner, 12 November: "if the app closes while splitting, it should resume when the user goes back to that
/// song". Each pass keeps a checkpoint under its own key (K2, R1 to R4 of the iOS kit-resume package, ported to the
/// Mac); the separators' own tests (BacklineKit, SeparatorResumeTests) prove a resumed result is the same as an
/// uninterrupted one. K1 is not the Mac's: a Mac already stops the passes on critical pressure only
/// (MemoryBudgetTests.testOnlyCriticalPressureStopsThePasses).
@MainActor
final class PassResumeTests: XCTestCase {
    private static var keepAlive: [AppModel] = []
    private let fm = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("resume-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        MemoryBudget.clearShort()
        MemoryBudget.pretendAvailable(nil)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
        MemoryBudget.clearShort()
        MemoryBudget.pretendAvailable(nil)
        MemoryWatch.retry?.cancel()
        MemoryWatch.retry = nil
    }

    private func url(_ path: String) -> URL { root.appendingPathComponent(path) }
    private func write(_ path: String, _ text: String = "x") throws {
        let u = url(path)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
    }
    private func exists(_ path: String) -> Bool { fm.fileExists(atPath: url(path).path) }

    private func record(id: String, stems: [StemKind] = [.vocals, .guitar, .bass, .drums, .other]) -> SongRecord {
        let analysis = try! JSONDecoder().decode(SongAnalysis.self, from: JSONSerialization.data(withJSONObject: [
            "bpm": 120.0, "beats": [0.0, 0.5], "downbeats": [0.0], "key": "E minor", "tuningCents": 0.0, "sections": [],
        ] as [String: Any]))
        return SongRecord(id: id, title: id, artist: nil, duration: 258, sourceName: "t.mp3", addedAt: Date(), lastOpened: Date(),
                          stems: stems, analysis: analysis, peaks: [:], storageScale: ["drums": 0.9, "guitar": 0.8],
                          hasArtwork: false, settings: SongSettings())
    }

    // MARK: K2: the kit split takes over from a running cleaner pass

    /// While the open song should get its kit first (Beats), a running cleaner pass is told to stop (it keeps its
    /// checkpoint) and the kit doesn't start beside it: the cleaner's end starts it. Switching into Beats does the
    /// same.
    func testInBeatsTheKitTakesOverFromARunningCleanerPass() throws {
        // The kit model, as an install leaves it (a folder and its marker), only if this Mac's Debug container has none.
        let modelDir = ModelStore.directory.appendingPathComponent("\(DrumSeparator.modelName).mlmodelc", isDirectory: true)
        let marker = ModelStore.directory.appendingPathComponent("\(DrumSeparator.modelName).sha256")
        let hadModel = fm.fileExists(atPath: marker.path)
        if !hadModel {
            try fm.createDirectory(at: modelDir, withIntermediateDirectories: true)
            try Data("test".utf8).write(to: marker)
        }
        defer { if !hadModel { try? fm.removeItem(at: modelDir); try? fm.removeItem(at: marker) } }

        let model = AppModel()
        Self.keepAlive.append(model)
        for (switchIn, id) in [(false, "kit-first-\(UUID().uuidString)"), (true, "kit-switch-\(UUID().uuidString)")] {
            model.song = record(id: id)
            var st = SongSettings()
            st.mode = switchIn ? .play : .beats
            model.settings = st
            let cleaner = CancelBox()
            model.hqCancel = cleaner
            model.hqJob = Task<Void, Never> {}
            if switchIn {
                XCTAssertFalse(model.kitGoesFirst, "in Play the cleaner pass goes on")
                model.ensureDrumSplit()
                XCTAssertFalse(cleaner.value)
                model.setMode(.beats)
            } else {
                model.ensureDrumSplit()
            }
            XCTAssertTrue(model.kitGoesFirst)
            XCTAssertTrue(cleaner.value, "the cleaner pass is told to stop for the kit (switching in: \(switchIn))")
            XCTAssertNil(model.drumJob, "the kit never runs beside it: the cleaner's end starts it")
            model.hqJob = nil; model.hqCancel = nil
        }
        model.song = nil
    }

    /// The same in Dance for bachata (the güira is the hi-hat part): switching the style to bachata stops a running
    /// cleaner pass for the kit; salsa doesn't.
    func testForBachataTheKitTakesOverFromARunningCleanerPass() throws {
        let modelDir = ModelStore.directory.appendingPathComponent("\(DrumSeparator.modelName).mlmodelc", isDirectory: true)
        let marker = ModelStore.directory.appendingPathComponent("\(DrumSeparator.modelName).sha256")
        let hadModel = fm.fileExists(atPath: marker.path)
        if !hadModel {
            try fm.createDirectory(at: modelDir, withIntermediateDirectories: true)
            try Data("test".utf8).write(to: marker)
        }
        defer { if !hadModel { try? fm.removeItem(at: modelDir); try? fm.removeItem(at: marker) } }

        let model = AppModel()
        Self.keepAlive.append(model)
        model.song = record(id: "bachata-\(UUID().uuidString)")
        var st = SongSettings()
        st.mode = .dance
        st.danceStyle = .salsa
        model.settings = st
        let cleaner = CancelBox()
        model.hqCancel = cleaner
        model.hqJob = Task<Void, Never> {}
        model.ensureDrumSplit()
        XCTAssertFalse(model.kitGoesFirst)
        XCTAssertFalse(cleaner.value, "salsa: the cleaner pass goes on")
        model.setDanceStyle(.bachata)
        XCTAssertTrue(model.kitGoesFirst)
        XCTAssertTrue(cleaner.value, "bachata: the cleaner pass is told to stop for the kit")
        XCTAssertNil(model.drumJob, "the kit never runs beside it: the cleaner's end starts it")
        model.hqJob = nil; model.hqCancel = nil
        model.song = nil
    }

    // MARK: R1 to R3: what each checkpoint is keyed by

    func testTheKitCheckpointFollowsTheDrumsPartItReads() throws {
        let store = SongStore(root: url("Songs"))
        var rec = record(id: "song1")
        try write("Songs/song1/drums.caf", "drums")
        let model = URL(fileURLWithPath: "/models/DrumSepMDX23C.mlmodelc")
        let a = DrumSplitJob.checkpoint(for: rec, store: store, modelURL: model)
        XCTAssertEqual(a.key, DrumSplitJob.checkpoint(for: rec, store: store, modelURL: model).key, "the same drums: the same key")
        XCTAssertEqual(a.directory, PassCheckpoints.directory(.kit, "song1"))

        rec.storageScale["drums"] = 0.5
        XCTAssertNotEqual(a.key, DrumSplitJob.checkpoint(for: rec, store: store, modelURL: model).key, "another storage gain")
        rec.storageScale["drums"] = 0.9
        // The cleaner pass writes the drums again.
        try write("Songs/song1/drums.caf", "cleaner drums")
        XCTAssertNotEqual(a.key, DrumSplitJob.checkpoint(for: rec, store: store, modelURL: model).key, "another drums file")
    }

    func testTheLeadCheckpointFollowsTheGuitarItReads() throws {
        let store = SongStore(root: url("Songs"))
        let rec = record(id: "song1")
        try write("Songs/song1/guitar.caf", "guitar")
        let a = LeadRefineJob.checkpoint(for: rec, store: store, frames: 100)
        XCTAssertEqual(a.key, LeadRefineJob.checkpoint(for: rec, store: store, frames: 100).key)
        XCTAssertEqual(a.directory, PassCheckpoints.directory(.lead, "song1"))
        XCTAssertNotEqual(a.key, LeadRefineJob.checkpoint(for: rec, store: store, frames: 100, computeUnits: "other").key)
        try write("Songs/song1/guitar.caf", "another guitar")
        XCTAssertNotEqual(a.key, LeadRefineJob.checkpoint(for: rec, store: store, frames: 100).key)
    }

    func testTheImportCheckpointIsTheStagedFilesAndItsComputeUnits() {
        let gpu = ImportPipeline.splitCheckpoint(id: "abc", frames: 1000, units: .cpuAndGPU)
        let cpu = ImportPipeline.splitCheckpoint(id: "abc", frames: 1000, units: .cpuOnly)
        XCTAssertEqual(gpu.directory, PassCheckpoints.directory(.importSplit, "abc"))
        XCTAssertEqual(gpu.directory, cpu.directory, "a split on the CPU replaces the GPU's")
        XCTAssertNotEqual(gpu.key, cpu.key)
        XCTAssertNotEqual(gpu.key, ImportPipeline.splitCheckpoint(id: "abd", frames: 1000, units: .cpuAndGPU).key)
    }

    /// A new checkpoint is kept only with room for it beside a margin (the parts still have to be written); one
    /// already on disk is always carried on from.
    func testANewCheckpointNeedsRoomOnTheDevice() throws {
        let cp = SeparationCheckpoint(directory: url("Caches/Backline/Kit/song1"), key: "k")
        let gb = 1_000_000_000.0
        XCTAssertNil(PassCheckpoints.ifRoom(cp, bytes: gb, free: Int64(2 * gb) - 1))
        XCTAssertNotNil(PassCheckpoints.ifRoom(cp, bytes: gb, free: Int64(2 * gb)))
        XCTAssertNotNil(PassCheckpoints.ifRoom(cp, bytes: gb, free: nil), "a device that won't say refuses nothing")
        try write("Caches/Backline/Kit/song1/ch0.f32")
        XCTAssertNotNil(PassCheckpoints.ifRoom(cp, bytes: gb, free: 0), "one on disk is carried on from")
    }

    // MARK: When the checkpoints go

    /// The launch sweep: a song's kit and lead checkpoints stay while the song is in the Library (it carries on when
    /// next opened, R4); an import's stays only while the journal names it.
    func testTheSweepKeepsTheCheckpointsSomethingCanCarryOnFrom() throws {
        let store = SongStore(root: url("Backline/Songs"))
        try write("Backline/Songs/live/song.json", "{}")
        for kind in ["Cleaner", "Kit", "Lead"] {
            try write("Caches/Backline/\(kind)/live/ch0.f32")
            try write("Caches/Backline/\(kind)/gone/ch0.f32")
        }
        try write("Caches/Backline/Import/unfinished/ch0.f32")
        try write("Caches/Backline/Import/forgotten/ch0.f32")
        try write("Caches/Backline/Import/live/ch0.f32")         // finished, but the journal entry wasn't cleared

        let sweep = store.sweepLeftovers(checkpoints: url("Caches/Backline/Cleaner"), models: url("Backline/Models"),
                                         keeping: ["unfinished"])
        XCTAssertEqual(Set(sweep.checkpoints), ["gone", "Kit/gone", "Lead/gone", "Import/forgotten", "Import/live"])
        for kind in ["Cleaner", "Kit", "Lead"] {
            XCTAssertTrue(exists("Caches/Backline/\(kind)/live/ch0.f32"), "\(kind): a Library song's checkpoint stays")
            XCTAssertFalse(exists("Caches/Backline/\(kind)/gone"), "\(kind): a deleted song's goes")
        }
        XCTAssertTrue(exists("Caches/Backline/Import/unfinished/ch0.f32"), "an unfinished import carries on from its own")
        XCTAssertFalse(exists("Caches/Backline/Import/forgotten"))
    }

    /// A deleted song takes every checkpoint with it; an import that failed with Try again on screen keeps its split's.
    func testDeletingASongTakesItsCheckpoints() throws {
        let store = SongStore(root: url("Songs"))
        let id = "delete-\(UUID().uuidString)"
        for kind in PassCheckpoints.Kind.allCases {
            try fm.createDirectory(at: PassCheckpoints.directory(kind, id), withIntermediateDirectories: true)
        }
        defer { PassCheckpoints.discardAll(id) }
        store.delete(id, keepingImport: true)
        XCTAssertTrue(fm.fileExists(atPath: PassCheckpoints.directory(.importSplit, id).path), "kept for Try again")
        XCTAssertFalse(fm.fileExists(atPath: PassCheckpoints.directory(.kit, id).path))
        store.delete(id)
        for kind in PassCheckpoints.Kind.allCases {
            XCTAssertFalse(fm.fileExists(atPath: PassCheckpoints.directory(kind, id).path), "\(kind)")
        }
    }

    /// A kit split starting keeps its own song's checkpoint and the two others written most recently: a song whose
    /// kit was stopped by an import still carries on after the new song's kit split has started.
    func testTheRunningSongsCheckpointAndTheTwoNewestOthersAreKept() throws {
        let base = url("Caches/Backline")
        let now = Date()
        for (i, id) in ["old", "older", "newer", "newest", "running"].enumerated() {
            try write("Caches/Backline/Kit/\(id)/ch0.f32")
            let age: [String: TimeInterval] = ["old": 300, "older": 400, "newer": 20, "newest": 10, "running": 500]
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-age[id]! - Double(i))],
                                 ofItemAtPath: url("Caches/Backline/Kit/\(id)/ch0.f32").path)
        }
        XCTAssertEqual(Set(PassCheckpoints.dropOthers(.kit, keeping: ["running"], newest: PassCheckpoints.kept, root: base)),
                       ["old", "older"])
        for id in ["running", "newer", "newest"] { XCTAssertTrue(exists("Caches/Backline/Kit/\(id)/ch0.f32"), id) }
        XCTAssertEqual(Set(PassCheckpoints.dropOthers(.importSplit, keeping: [], root: base)), [], "nothing there")
        try write("Caches/Backline/Import/a/ch0.f32")
        XCTAssertEqual(PassCheckpoints.dropOthers(.importSplit, keeping: ["b"], root: base), ["a"])
    }

    // MARK: R4: after a relaunch, a pass carries on, and two failures still hold it back

    /// A kit split the last run ended during: when the person quit it isn't counted, otherwise it is one failure; the
    /// checkpoint stays either way (the sweep keeps it for a Library song), so the next open carries on from it.
    /// Two such failures hold the pass back, as before.
    func testAfterARelaunchThePassCarriesOnAndTwoFailuresStillHoldItBack() throws {
        let store = SongStore(root: url("Backline/Songs"))
        try write("Backline/Songs/song1/song.json", "{}")
        try write("Caches/Backline/Kit/song1/ch0.f32")
        func journal() -> WorkJournal { WorkJournal(folder: url("Journal")) }

        var j = journal()
        j.beginPass(.kitSplit, id: "song1")
        j.setInFront(false)     // the person quit
        var r = journal().recoverAtLaunch(store: store, base: url("Backline"))
        XCTAssertEqual(r.interruptedPasses.map(\.pass), [.kitSplit])
        j = journal()
        XCTAssertEqual(j.failures(.kitSplit, id: "song1"), 0, "quitting: not counted")
        store.sweepLeftovers(checkpoints: url("Caches/Backline/Cleaner"), models: url("Backline/Models"), keeping: r.keepSongs)
        XCTAssertTrue(exists("Caches/Backline/Kit/song1/ch0.f32"), "kept to carry on from")

        for n in 1...2 {
            j = journal()
            j.beginPass(.kitSplit, id: "song1")
            j.setInFront(true)      // a crash or a forced quit
            r = journal().recoverAtLaunch(store: store, base: url("Backline"))
            store.sweepLeftovers(checkpoints: url("Caches/Backline/Cleaner"), models: url("Backline/Models"), keeping: r.keepSongs)
            XCTAssertEqual(journal().failures(.kitSplit, id: "song1"), n)
            XCTAssertTrue(exists("Caches/Backline/Kit/song1/ch0.f32"))
        }
        XCTAssertTrue(journal().isHeldBack(.kitSplit, id: "song1"), "two failures: it waits for Try again")
    }
}
