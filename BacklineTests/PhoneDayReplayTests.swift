import Accelerate
import BacklineKit
import CoreML
import Foundation
import XCTest
@testable import Backline

/// The owner's iPhone on 11 and 12 November (1.1, build 307), replayed against the Mac's own scheduling code (ported
/// from iOS r11/kit-resume `PhoneDayReplayTests`): four songs, three in Beats and one in Dance for bachata, and not
/// one got its drum kit. Every kit split was stopped (the app closed, an import starting, a memory warning with
/// 4.3 GB free) and each restart began again from zero; on the fourth song the cleaner pass ran first and the kit
/// waited behind it.
///
/// What is real here: `AppModel` (opening songs, `ensureDrumSplit`, `ensureCleanerParts`, `memoryPressure`,
/// `setMode`, the end of each pass), `DrumSplitJob`, `CleanerPartsJob`, the separators' chunking and checkpoints,
/// `WorkJournal`'s recovery, the launch sweep, the sidebar's unfinished row and the import's own split. What stands
/// in: the kit model and the cleaner model, replaced by a tiny Core ML model installed where a downloaded one goes
/// (`StandInModel`: each part a fixed share of what it is given), which counts its calls and can hold a pass at a
/// chosen call so a stop lands at a known chunk. An import that stops a kit split is the part of `startImport` that
/// touches the passes (`splitRunning` and `pauseBackgroundWork`); the second test runs a real import.
///
/// The Mac's differences from the iPhone, by design: a Mac has no app memory warning, only the system's pressure
/// source, and only its critical level stops the passes (`memoryPressure`); a close the person makes is a quit (the
/// journal's "quitting (not counted)"); and an import opens the person's file where it is, so its unfinished row
/// names that file, and a click on the row carries on ("Click to carry on").
///
/// What must hold: every song ends with its kit split; a pressure warning with plenty free doesn't stop a pass and a
/// critical one does; no restart begins from zero when a checkpoint exists (each restart's first model call finds
/// what the last run kept, and each song's kit costs one model call per chunk plus one per restart); the kit takes
/// over from a running cleaner pass and the cleaner carries on from its checkpoint after the kit; an import the app
/// was closed during carries on from its sidebar row.
@MainActor
final class PhoneDayReplayTests: XCTestCase {
    /// The app model lives for the whole process (a deinit bug): tests keep theirs.
    private static var keepAlive: [AppModel] = []
    private let fm = FileManager.default
    private var songs: [String] = []
    private var installed: [String] = []
    private var scratch: URL!

    override func setUp() async throws {
        scratch = fm.temporaryDirectory.appendingPathComponent("phone-day-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        MemoryBudget.clearShort()
        MemoryBudget.pretendAvailable(nil)
        StandInScript.shared.reset()
    }

    override func tearDown() async throws {
        // A pass held at a call must never be left waiting.
        StandInScript.shared.reset()
        for m in Self.keepAlive { m.pauseBackgroundWork() }
        for m in Self.keepAlive { await m.waitForPassesToStop(upTo: .seconds(60), stop: { false }) }
        for m in Self.keepAlive where m.song.map({ songs.contains($0.id) }) == true { m.song = nil }
        for id in songs {
            SongStore.shared.delete(id)
            PassCheckpoints.discardAll(id)
            WorkJournal.shared.forgetSong(id)
        }
        for name in installed {
            try? fm.removeItem(at: ModelStore.directory.appendingPathComponent("\(name).mlmodelc", isDirectory: true))
            try? fm.removeItem(at: ModelStore.directory.appendingPathComponent("\(name).sha256"))
        }
        try? fm.removeItem(at: scratch)
        MemoryBudget.clearShort()
        MemoryBudget.pretendAvailable(nil)
        MemoryWatch.retry?.cancel()
        MemoryWatch.retry = nil
    }

    // MARK: The day

    func testThePhonesDayEndsWithEveryKitSplitAndNoRestartBeginsFromZero() async throws {
        try await installStandIn(DrumSeparator.modelName, input: [1, 4, 1024, 1024], output: [1, 5, 4, 1024, 1024], name: "freq")
        try await installStandIn(CleanerPartsJob.modelName, input: [1, 1151, 4100], output: [1, 6, 1151, 4100], name: "out")
        let script = StandInScript.shared
        let a = try makeSong("a", mode: .beats)                         // 8721… on the phone
        let c = try makeSong("c", mode: .play, original: true)          // 09a0…: opened while the cleaner ran
        let d = try makeSong("d", mode: .dance, style: .bachata)
        var ledger = KitLedger(chunks: Self.kitChunks(seconds: a.duration))

        var model = try await launch()

        // 1. Song a opens in Beats and its kit split starts. Three model calls in, the app is closed (on a Mac, quit).
        model.select(a)
        try await ledger.startRun(a.id, in: model)
        try await ledger.hold(atCallOfRun: 3)
        let journalAtClose = try snapshotJournal()
        try await ledger.stop(a.id, in: model) { model.drumCancel?.value = true }   // the process ends here

        // 2. The relaunch: the journal says the kit split was running when the person quit, which is not a failure;
        //    the launch sweep keeps the song's checkpoint.
        let recovery = try relaunchRecovery(from: journalAtClose, inFront: false)
        XCTAssertEqual(recovery.interruptedPasses.map(\.pass), [.kitSplit])
        XCTAssertEqual(recovery.interruptedPasses.map(\.id), [a.id])
        SongStore.shared.sweepLeftovers(keeping: recovery.keepSongs)
        XCTAssertNotNil(Self.checkpointBytes(.kit, a.id), "the launch sweep keeps a Library song's kit checkpoint")
        XCTAssertFalse(WorkJournal.shared.isHeldBack(.kitSplit, id: a.id))
        model.song = nil
        model = try await launch()

        // 3. Song a again, in Beats: its kit split carries on. Two model calls in, an import (song b) starts and
        //    stops it.
        model.select(a)
        try await ledger.startRun(a.id, in: model)
        try await ledger.hold(atCallOfRun: 2)
        try await ledger.stop(a.id, in: model) {
            // What `startImport` does to the passes before it splits.
            model.splitRunning = 1
            model.pauseBackgroundWork()
        }
        XCTAssertNil(model.drumJob, "nothing starts beside an import")

        // 4. The import ends: song b (2985… on the phone) is in the Library and opens in Beats, and its kit split
        //    starts. Song a's checkpoint stays although another song's kit split has started.
        let b = try makeSong("b", mode: .beats)
        model.library.insert(b, at: 0)
        model.select(b)
        try await waitUntil("song b is open") { model.song?.id == b.id }
        XCTAssertNil(model.drumJob, "while the import is still under way nothing starts")
        try await ledger.startRun(b.id, in: model) {
            model.splitRunning = nil
            model.importMayHaveEnded()
        }
        XCTAssertNotNil(Self.checkpointBytes(.kit, a.id), "a stopped kit split keeps its checkpoint while another song's runs")

        // 5. Three calls in: the system's pressure source at its warning level, with 4.37 GB free (the phone's
        //    figure). On a Mac only the critical level stops the passes: the kit split goes on.
        try await ledger.hold(atCallOfRun: 3)
        MemoryBudget.pretendAvailable(4_370 << 20)
        model.memoryPressure(critical: false)
        XCTAssertEqual(model.drumCancel?.value, false, "a pressure warning with plenty free doesn't stop the kit split")
        XCTAssertTrue(MemoryBudget.mayStartPass, "and holds nothing back")

        // 6. Five calls in: the pressure source's critical level. That stops it.
        try await ledger.hold(atCallOfRun: 5)
        try await ledger.stop(b.id, in: model) {
            model.memoryPressure(critical: true)
            XCTAssertEqual(model.drumCancel?.value, true, "critical pressure stops the kit split")
        }
        MemoryBudget.pretendAvailable(nil)
        stopTheMinutesRetry()
        // Within the minute after it, a start does no model work and keeps the checkpoint (the phone's
        // "stopped after 0 s").
        XCTAssertFalse(MemoryBudget.mayStartPass, "the minute after a memory stop")
        let callsBefore = script.calls(.kit)
        let keptBefore = Self.checkpointBytes(.kit, b.id)
        model.ensureDrumSplit()
        try await waitUntil("the start within the minute ends") { model.drumJob == nil }
        XCTAssertEqual(script.calls(.kit), callsBefore, "no model work within the minute")
        XCTAssertEqual(Self.checkpointBytes(.kit, b.id), keptBefore, "and the checkpoint is as it was")

        // 7. The minute is up: what the retry does. Song b's kit split carries on and lands.
        MemoryBudget.clearShort()
        try await ledger.startRun(b.id, in: model) { model.ensureDrumSplit() }
        try await ledger.finish(b.id, in: model)

        // 8. Song c opens in Play: the cleaner pass starts. Three cleaner calls in, the person switches to Beats:
        //    the kit takes over (the cleaner is told to stop and the kit doesn't run beside it).
        let cleanerStart = script.calls(.cleaner)
        script.hold(.cleaner, atCall: cleanerStart + 3)
        model.select(c)
        try await waitUntil("the cleaner pass reaches its third model call") { script.isHeld(.cleaner) }
        XCTAssertNil(model.drumJob, "in Play the cleaner pass runs and the kit doesn't")
        model.setMode(.beats)
        XCTAssertEqual(model.hqCancel?.value, true, "in Beats the kit takes over from the cleaner pass")
        XCTAssertNil(model.drumJob, "and never runs beside it")
        // The cleaner stops at its next check (its checkpoint kept); its end starts the kit.
        script.hold(.cleaner, atCall: script.calls(.cleaner) + 1)
        try await ledger.startRun(c.id, in: model) { script.moveOn(.cleaner, holdingAt: script.calls(.cleaner) + 1) }
        let cleanerKept = Self.checkpointBytes(.cleaner, c.id)
        XCTAssertGreaterThan(cleanerKept ?? 0, 0, "the stopped cleaner pass kept its checkpoint")
        XCTAssertNil(model.hqJob, "the cleaner pass has stopped")
        try await ledger.finish(c.id, in: model)

        // 9. The kit is in: the cleaner pass starts again, and at its first model call its checkpoint still holds
        //    what it kept (it carries on, it doesn't start again).
        try await waitUntil("the cleaner pass carries on after the kit") { script.isHeld(.cleaner) }
        XCTAssertEqual(Self.checkpointBytes(.cleaner, c.id), cleanerKept, "the cleaner pass carries on from its checkpoint after the kit")
        XCTAssertEqual(script.calls(.cleaner) - cleanerStart, 4, "three calls before the kit, then the first one after it")
        model.hqCancel?.value = true
        script.moveOn(.cleaner, holdingAt: nil)
        try await waitUntil("the cleaner pass stops") { model.hqJob == nil }

        // 10. Song d, Dance for bachata (the güira): its kit split runs and lands.
        model.select(d)
        try await ledger.startRun(d.id, in: model)
        try await ledger.finish(d.id, in: model)

        // 11. Back to song a, in Beats: it carries on from where the import stopped it, after three other songs'
        //     kit splits, and lands.
        XCTAssertNotNil(Self.checkpointBytes(.kit, a.id), "song a's checkpoint outlived three other kit splits")
        model.select(a)
        try await ledger.startRun(a.id, in: model)
        try await ledger.finish(a.id, in: model)

        // Every song ends with its kit split, on disk.
        try await waitUntil("every song's record has its kit") {
            let saved = Dictionary(uniqueKeysWithValues: SongStore.shared.loadAll().map { ($0.id, $0) })
            return [a, b, c, d].allSatisfy { saved[$0.id]?.drumSplit != nil }
        }
        for s in [a, b, c, d] { XCTAssertNil(Self.checkpointBytes(.kit, s.id), "\(s.title): nothing left to carry on from") }
        // No restart began from zero: each run after the first found what the last one kept, and each song's kit
        // cost one model call per chunk plus one per restart (the chunk that straddles the kept part).
        ledger.assertNoRestartFromZero()
        XCTAssertEqual(ledger.runs[a.id]?.count, 3, "song a: the first run, after the relaunch, after the import")
        XCTAssertEqual(ledger.runs[b.id]?.count, 2, "song b: the first run, after the minute")
    }

    /// The import of a song is stopped part-way through its six-part split when the app is closed. At the next
    /// launch the sidebar offers it ("Click to carry on"); a click carries on from where the split stopped and the
    /// song is saved. The real six-part model, with the compute units the import itself chooses (the GPU on a Mac).
    func testAnImportTheAppWasClosedDuringCarriesOnFromItsSidebarRow() async throws {
        // The person's own file, opened where it is (a Mac doesn't stage a picked file).
        let fixture = LeadRefineTests.fixtures.appendingPathComponent("SummonTheRawk-20s.mp3")
        let file = scratch.appendingPathComponent("Summon the Rawk.mp3")
        try fm.copyItem(at: fixture, to: file)
        let id = try SongStore.contentID(of: file)
        songs.append(id)
        SongStore.shared.delete(id)
        PassCheckpoints.discardAll(id)
        WorkJournal.shared.forgetSong(id)
        WorkJournal.shared.forgetUnfinished(id)

        // The import starts (its journal entry), and its split gets two chunks in before the app is closed.
        let first = try await launch()
        first.importTitle = "Summon the Rawk"
        first.noteImportStarted(url: file, id: id)
        let audio = try AudioDecoder.decode(file)
        let separator = try await SeparationService.shared.separator()
        let checkpoint = ImportPipeline.splitCheckpoint(id: id, frames: audio.frameCount, units: separator.computeUnits)
        let chunksDone = Counter()
        let stopped = await Task.detached {
            do {
                _ = try separator.separate(audio, checkpoint: checkpoint, progress: { _ in chunksDone.increment() },
                                           isCancelled: { chunksDone.value >= 2 })
                return false
            } catch { return error is CancellationError }
        }.value
        SeparationService.shared.release()
        XCTAssertTrue(stopped)
        let stride = Int(0.75 * Double(DemucsSeparator.segment))
        let chunks = (audio.frameCount + stride - 1) / stride
        let kept = try XCTUnwrap(Self.checkpointBytes(.importSplit, id), "the split kept its checkpoint")
        let keptChunks = kept / (stride * MemoryLayout<Float>.size)
        XCTAssertGreaterThan(keptChunks, 0)
        XCTAssertLessThan(keptChunks, chunks)

        // The next launch: the journal keeps the import to try again, the sweep keeps its checkpoint and the
        // downloads' cleanup keeps what the journal names.
        let recovery = WorkJournal.shared.recoverAtLaunch(store: .shared)
        XCTAssertTrue(recovery.unfinished.contains { $0.id == id })
        SongStore.shared.sweepLeftovers(keeping: recovery.keepSongs)
        ImportStaging.cleanUpDownloads(keeping: recovery.keepFiles, keepAll: recovery.journalUnreadable)
        XCTAssertEqual(Self.checkpointBytes(.importSplit, id), kept, "the launch keeps an unfinished import's checkpoint")
        XCTAssertTrue(fm.fileExists(atPath: file.path))

        // The sidebar row says so, and a click on it carries on.
        let model = try await launch()
        let row = try XCTUnwrap(model.unfinishedImports.first { $0.id == id }, "the sidebar offers the song")
        XCTAssertEqual(AppModel.unfinishedLine(row), "Backline closed while it was splitting this song. Click to carry on.")
        XCTAssertTrue(AppModel.mayTryAgain(row))
        model.retryUnfinished(row)

        // While it splits: the checkpoint never goes below what was kept, and the split's progress starts past it.
        var smallest = kept
        var lowest = 1.0
        let end = Date().addingTimeInterval(480)
        while !model.library.contains(where: { $0.id == id }) {
            if Date() > end { XCTFail("the import didn't finish"); break }
            if case .failed(let why) = model.screen { XCTFail("the import failed: \(why)"); break }
            if let bytes = Self.checkpointBytes(.importSplit, id) { smallest = min(smallest, bytes) }
            if model.importProgress.phase >= 1 { lowest = min(lowest, model.importProgress.fraction) }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(smallest, kept, "the split carried on from its checkpoint: what it had kept was never thrown away")
        // The first chunk a resumed split reports is the one after those it kept (0.05 + 0.85 × its share).
        XCTAssertGreaterThanOrEqual(lowest, 0.05 + 0.85 * Double(keptChunks) / Double(chunks) - 1e-9,
                                    "the split's progress starts past the chunks it kept, not from the first")
        XCTAssertTrue(model.library.contains { $0.id == id }, "the song is saved")
        XCTAssertNil(Self.checkpointBytes(.importSplit, id), "the finished import leaves no checkpoint")
        XCTAssertFalse(WorkJournal.shared.unfinished.contains { $0.id == id }, "nor an unfinished entry")
        XCTAssertFalse(model.unfinishedImports.contains { $0.id == id }, "nor a row")
        // The new song opens after it is saved: wait for that, so nothing opens it after the test has ended.
        try await waitUntil("the imported song is open") { model.song?.id == id }
    }

    // MARK: Opening the app

    /// A launch: a new app model, its Library read.
    private func launch() async throws -> AppModel {
        let m = AppModel()
        Self.keepAlive.append(m)
        await m.libraryReady()
        return m
    }

    /// The journal file as it is now: what the app leaves on disk if it is closed at this moment.
    private func snapshotJournal() throws -> URL {
        let folder = scratch.appendingPathComponent("journal-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.copyItem(at: WorkJournal.shared.url, to: folder.appendingPathComponent("work.json"))
        return folder
    }

    /// The launch's reading of a journal left by a closed app (still in front: a crash; not: the person quit).
    private func relaunchRecovery(from folder: URL, inFront: Bool) throws -> WorkJournal.Recovery {
        WorkJournal(folder: folder).setInFront(inFront)
        return WorkJournal(folder: folder).recoverAtLaunch(store: .shared, base: scratch)
    }

    /// The minute after a memory stop: the test starts the passes again itself, as the retry would.
    private func stopTheMinutesRetry() {
        MemoryWatch.retry?.cancel()
        MemoryWatch.retry = nil
    }

    // MARK: Songs

    /// A 30-second song in the Library with every part on disk (the drums are noise, so every chunk goes to the
    /// model) and its practice mode set.
    private func makeSong(_ name: String, mode: PracticeMode, style: DanceStyle? = nil, original: Bool = false) throws -> SongRecord {
        let id = "phone-day-\(name)-\(UUID().uuidString.prefix(8))"
        songs.append(id)
        let store = SongStore.shared
        try fm.createDirectory(at: store.folder(id), withIntermediateDirectories: true)
        let seconds = 30.0
        let stems: [StemKind] = [.vocals, .guitar, .bass, .drums, .other]
        for (i, k) in stems.enumerated() {
            try store.writeStem(Self.audio(seconds: seconds, seed: UInt64(i + 1), tone: 110 * Double(i + 1)), to: store.stemURL(id, k))
        }
        if original { try store.writeStem(Self.audio(seconds: seconds, seed: 99, tone: 220), to: store.originalURL(id)) }
        let analysis = try JSONDecoder().decode(SongAnalysis.self, from: JSONSerialization.data(withJSONObject: [
            "bpm": 120.0, "beats": (0..<60).map { Double($0) * 0.5 }, "downbeats": (0..<15).map { Double($0) * 2 },
            "key": "E minor", "tuningCents": 0.0, "sections": [],
        ] as [String: Any]))
        var settings = SongSettings()
        settings.mode = mode
        settings.danceStyle = style
        var rec = SongRecord(id: id, title: "Song \(name)", artist: nil, duration: seconds, sourceName: "\(name).mp3",
                             addedAt: Date(), lastOpened: Date(), stems: stems, analysis: analysis, peaks: [:],
                             storageScale: [:], hasArtwork: false, settings: settings)
        if original { rec.originalScale = 1 }
        try store.save(rec)
        return rec
    }

    /// Two tones and noise in bursts, the same every run, within full scale.
    private static func audio(seconds: Double, seed: UInt64, tone: Double) -> StereoAudio {
        let sr = 44_100.0, n = Int(seconds * sr)
        var s = seed &* 0x9E37_79B9_7F4A_7C15
        var l = [Float](repeating: 0, count: n), r = l
        for i in 0..<n {
            s = s &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Float(Double(s >> 11) / Double(1 << 53) - 0.5)
            let t = Double(i) / sr
            let env = Float(exp(-Double(i % 11_025) / sr * 30))
            l[i] = Float(0.2 * sin(t * 2 * .pi * tone)) + 0.5 * env * noise
            r[i] = Float(0.2 * sin(t * 2 * .pi * tone * 1.5)) + 0.5 * env * noise
        }
        return StereoAudio(left: l, right: r, sampleRate: sr)
    }

    /// How many chunks the kit split makes of a song this long (`DrumSeparator`, overlap 2).
    static func kitChunks(seconds: Double) -> Int {
        let n = Int(seconds * 44_100), step = DrumSeparator.chunk / DrumSplitJob.overlap
        let border = DrumSeparator.chunk - step
        let padded = n > 2 * border ? n + 2 * border : n
        return (padded + step - 1) / step
    }

    /// The size of the first channel of a pass's checkpoint (what it has kept), or nil when there is none.
    static func checkpointBytes(_ kind: PassCheckpoints.Kind, _ id: String) -> Int? {
        let url = PassCheckpoints.directory(kind, id).appendingPathComponent("ch0.f32")
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    }

    // MARK: The stand-in models

    /// Compiles a stand-in for `model` (input `spec`, one output) and installs it where a downloaded model goes,
    /// with its marker, as the download would.
    private func installStandIn(_ model: String, input: [Int], output: [Int], name: String) async throws {
        let dir = ModelStore.directory
        let dest = dir.appendingPathComponent("\(model).mlmodelc", isDirectory: true)
        if fm.fileExists(atPath: dest.path) { throw XCTSkip("a real \(model) is installed in this container") }
        let spec = scratch.appendingPathComponent("\(model).mlmodel")
        try StandInModel.specification(input: input, output: output, outputName: name).write(to: spec)
        let compiled = try await MLModel.compileModel(at: spec)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        installed.append(model)
        try fm.moveItem(at: compiled, to: dest)
        try "stand-in for the phone-day replay".write(to: dir.appendingPathComponent("\(model).sha256"), atomically: true, encoding: .utf8)
        XCTAssertNotNil(ModelStore.url(model))
    }

    // MARK: Waiting

    private struct TimedOut: Error {}

    private func waitUntil(_ what: String, timeout: TimeInterval = 180, _ done: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !done() {
            if Date() > end {
                XCTFail("timed out waiting until \(what)")
                throw TimedOut()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Each kit run of each song: the model calls it made and what its checkpoint held at its first call.
    @MainActor
    struct KitLedger {
        let chunks: Int
        private(set) var runs: [String: [Int]] = [:]
        /// What the checkpoint held at each run's first model call, and what each stopped run left.
        private(set) var foundAtStart: [String: [Int]] = [:]
        private(set) var leftAtStop: [String: [Int]] = [:]
        private var running: (id: String, from: Int)?

        init(chunks: Int) { self.chunks = chunks }

        /// Waits for the open song's kit split (started by `start`, or by opening the song) to reach its first model
        /// call, and notes what its checkpoint held then.
        mutating func startRun(_ id: String, in model: AppModel, start: () -> Void = {}) async throws {
            let script = StandInScript.shared
            let from = script.calls(.kit)
            script.hold(.kit, atCall: from + 1)
            start()
            try await Self.wait("the kit split of \(id) reaches the model") { script.isHeld(.kit) }
            XCTAssertEqual(model.song?.id, id)
            running = (id, from)
            foundAtStart[id, default: []].append(PhoneDayReplayTests.checkpointBytes(.kit, id) ?? 0)
        }

        /// Lets the running kit split go on to its `n`-th model call of this run, and holds it there.
        func hold(atCallOfRun n: Int) async throws {
            let script = StandInScript.shared
            guard let running else { return XCTFail("no kit split running") }
            script.moveOn(.kit, holdingAt: running.from + n)
            try await Self.wait("the kit split's call \(n)") { script.isHeld(.kit) && script.calls(.kit) == running.from + n }
        }

        /// `event` happens while the kit split is held at a call; then it goes on and must stop.
        mutating func stop(_ id: String, in model: AppModel, by event: () -> Void) async throws {
            event()
            StandInScript.shared.moveOn(.kit, holdingAt: nil)
            try await Self.wait("the kit split of \(id) stops") { model.drumJob == nil }
            XCTAssertNil(model.song?.drumSplit, "stopped, not landed")
            endRun()
            leftAtStop[id, default: []].append(PhoneDayReplayTests.checkpointBytes(.kit, id) ?? 0)
        }

        /// Lets the running kit split go to its end, and waits for the kit to land.
        mutating func finish(_ id: String, in model: AppModel) async throws {
            StandInScript.shared.moveOn(.kit, holdingAt: nil)
            try await Self.wait("the kit of \(id) lands", timeout: 300) { model.drumJob == nil && model.song?.drumSplit != nil }
            endRun()
        }

        private mutating func endRun() {
            guard let r = running else { return }
            runs[r.id, default: []].append(StandInScript.shared.calls(.kit) - r.from)
            running = nil
        }

        func assertNoRestartFromZero(file: StaticString = #filePath, line: UInt = #line) {
            for (id, counts) in runs.sorted(by: { $0.key < $1.key }) {
                let found = foundAtStart[id] ?? [], left = leftAtStop[id] ?? []
                XCTAssertEqual(found.first, 0, "\(id): the first run starts with nothing kept", file: file, line: line)
                for i in 1..<max(found.count, 1) {
                    XCTAssertGreaterThan(found[i], 0, "\(id): restart \(i) found a checkpoint", file: file, line: line)
                    XCTAssertEqual(found[i], i - 1 < left.count ? left[i - 1] : -1,
                                   "\(id): restart \(i) began from what the last run kept, not from zero", file: file, line: line)
                }
                XCTAssertEqual(counts.reduce(0, +), chunks + counts.count - 1,
                               "\(id): one model call per chunk plus one per restart (runs: \(counts))", file: file, line: line)
            }
        }

        private static func wait(_ what: String, timeout: TimeInterval = 180, _ done: () -> Bool) async throws {
            let end = Date().addingTimeInterval(timeout)
            while !done() {
                if Date() > end {
                    XCTFail("timed out waiting until \(what)")
                    throw TimedOut()
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }
}

/// Counts each stand-in model's calls and holds a pass at a chosen call until the test lets it go on.
final class StandInScript: @unchecked Sendable {
    enum Model: String { case kit = "freq", cleaner = "out" }
    static let shared = StandInScript()
    private let cond = NSCondition()
    private var calls: [Model: Int] = [:]
    private var holdAt: [Model: Int] = [:]
    private var held: Set<Model> = []

    func calls(_ m: Model) -> Int { cond.lock(); defer { cond.unlock() }; return calls[m] ?? 0 }
    func isHeld(_ m: Model) -> Bool { cond.lock(); defer { cond.unlock() }; return held.contains(m) }

    /// The next time the model's calls reach `call`, that call waits.
    func hold(_ m: Model, atCall call: Int) {
        cond.lock(); holdAt[m] = call; cond.unlock()
    }

    /// A held call goes on; the model is held again at `call` (nil: not again).
    func moveOn(_ m: Model, holdingAt call: Int?) {
        cond.lock()
        holdAt[m] = call
        held.remove(m)
        cond.broadcast()
        cond.unlock()
    }

    /// Forgets the counts and lets every held call go.
    func reset() {
        cond.lock()
        calls = [:]; holdAt = [:]; held = []
        cond.broadcast()
        cond.unlock()
    }

    /// Called by the stand-in at each prediction.
    func called(_ m: Model) {
        cond.lock()
        calls[m, default: 0] += 1
        if calls[m] == holdAt[m] {
            held.insert(m)
            while held.contains(m) { cond.wait() }
        }
        cond.unlock()
    }
}

/// A tiny Core ML model: Core ML loads it from a compiled model like any other and hands each prediction to this
/// class. Each of its output's parts is a fixed share of the input (as the separators' own tests do), so the passes
/// add up, write and land as with the real model.
@objc(BacklineStandInModel)
final class StandInModel: NSObject, MLCustomModel {
    private let outputName: String
    private let output: MLMultiArray
    private let parts: Int
    private let lock = NSLock()

    init(modelDescription: MLModelDescription, parameters: [String: Any]) throws {
        guard let out = modelDescription.outputDescriptionsByName.first,
              let shape = out.value.multiArrayConstraint?.shape else { throw CocoaError(.coderValueNotFound) }
        outputName = out.key
        parts = shape[1].intValue
        output = try MLMultiArray(shape: shape, dataType: .float32)
        super.init()
    }

    func prediction(from input: MLFeatureProvider, options: MLPredictionOptions) throws -> MLFeatureProvider {
        guard let spec = input.featureValue(for: "spec")?.multiArrayValue,
              let model = StandInScript.Model(rawValue: outputName) else { throw CocoaError(.coderValueNotFound) }
        StandInScript.shared.called(model)
        lock.lock(); defer { lock.unlock() }
        let block = output.count / parts, n = min(block, spec.count)
        let src = spec.dataPointer.assumingMemoryBound(to: Float.self)
        let dst = output.dataPointer.assumingMemoryBound(to: Float.self)
        for p in 0..<parts {
            var w = Float(p + 1) / Float(parts * (parts + 1) / 2)
            vDSP_vsmul(src, 1, &w, dst + p * block, 1, vDSP_Length(n))
        }
        return try MLDictionaryFeatureProvider(dictionary: [outputName: MLFeatureValue(multiArray: output)])
    }

    /// The model's specification (Core ML's protocol buffer, written by hand): one float32 input `spec`, one
    /// float32 output, and this class as its implementation.
    static func specification(input: [Int], output: [Int], outputName: String) -> Data {
        func varint(_ v: Int) -> [UInt8] {
            var v = UInt64(v), out: [UInt8] = []
            repeat {
                let b = UInt8(v & 0x7F)
                v >>= 7
                out.append(v == 0 ? b : b | 0x80)
            } while v != 0
            return out
        }
        func field(_ number: Int, _ bytes: [UInt8]) -> [UInt8] { varint(number << 3 | 2) + varint(bytes.count) + bytes }
        func number(_ number: Int, _ value: Int) -> [UInt8] { varint(number << 3) + varint(value) }
        func feature(_ name: String, _ shape: [Int]) -> [UInt8] {
            // ArrayFeatureType: shape (1, packed), dataType (2) FLOAT32 = 65568; in FeatureType's multiArrayType (5).
            let array = field(1, shape.flatMap(varint)) + number(2, 65_568)
            return field(1, Array(name.utf8)) + field(3, field(5, array))
        }
        let description = field(1, feature("spec", input)) + field(10, feature(outputName, output))
        // Model: specificationVersion (1), description (2), customModel (555) with its className (10).
        let model = number(1, 4) + field(2, description) + field(555, field(10, Array("BacklineStandInModel".utf8)))
        return Data(model)
    }
}
