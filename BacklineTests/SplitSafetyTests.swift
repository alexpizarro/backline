import BacklineKit
import XCTest
@testable import Backline

/// Release 1.1, ios-split-safety, ported to the Mac (mac-ios-trio): the CPU fallback is not for ever (3), the kit
/// can go first without dropping a refined guitar (4), a reset leaves no stale job handle behind (5), and a starting
/// cleaner pass removes other songs' checkpoints (6). The last section is the Mac's own: the start order itself,
/// with a stand-in kit model (the iOS app checks it with a UI test).
@MainActor
final class SplitSafetyTests: XCTestCase {
    private static var keepAlive: [AppModel] = []

    // MARK: (3) the CPU fallback

    private let day: TimeInterval = 24 * 3600

    func testNoFailureMeansTheGPU() {
        XCTAssertFalse(CPUFallback.decide(nil, build: "190", now: Date()).cpu)
    }

    func testOneFailureKeepsTheCPUForFourteenDaysThenTriesTheGPUOnce() {
        let t0 = Date(timeIntervalSince1970: 2_000_000_000)
        let first = CPUFallback.failed(nil, build: "190", now: t0)
        XCTAssertEqual(first.failures, 1)
        XCTAssertTrue(CPUFallback.decide(first, build: "190", now: t0 + 1 * day).cpu)
        XCTAssertTrue(CPUFallback.decide(first, build: "190", now: t0 + 13.9 * day).cpu)
        XCTAssertFalse(CPUFallback.decide(first, build: "190", now: t0 + 14 * day).cpu, "14 days: the GPU once more")

        // It fails again on the same build: the CPU for the rest of that build, however long.
        let second = CPUFallback.failed(first, build: "190", now: t0 + 14 * day)
        XCTAssertEqual(second.failures, 2)
        XCTAssertTrue(CPUFallback.decide(second, build: "190", now: t0 + 100 * day).cpu)
        // A new build tries the GPU again, and a failure there counts from one.
        XCTAssertFalse(CPUFallback.decide(second, build: "191", now: t0 + 15 * day).cpu)
        XCTAssertEqual(CPUFallback.failed(second, build: "191", now: t0 + 15 * day).failures, 1)
    }

    func testANewBuildTriesTheGPUTheNextDay() {
        let t0 = Date()
        let s = CPUFallback.failed(nil, build: "190", now: t0)
        let (cpu, reason) = CPUFallback.decide(s, build: "191", now: t0 + day)
        XCTAssertFalse(cpu)
        XCTAssertTrue(reason.contains("new build"), reason)
    }

    func testOnePointOhsForeverFlagBecomesARetry() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "split-safety-\(UUID().uuidString)"))
        defaults.set(true, forKey: CPUFallback.legacyKey)
        let state = CPUFallback.load(defaults)
        XCTAssertNotNil(state)
        XCTAssertFalse(CPUFallback.decide(state, build: "190", now: Date()).cpu, "1.0 moved the device for good; 1.1 tries the GPU")

        CPUFallback.save(CPUFallback.failed(state, build: "190", now: Date()), defaults)
        XCTAssertFalse(defaults.bool(forKey: CPUFallback.legacyKey), "the old flag is gone once the new state is written")
        XCTAssertEqual(CPUFallback.load(defaults)?.failures, 1)
        CPUFallback.save(nil, defaults)
        XCTAssertNil(CPUFallback.load(defaults), "a GPU split that adds up forgets the failure")
    }

    // MARK: (5) a reset leaves no stale handle

    func testAfterAResetNoStoppedJobHoldsItsPlace() async {
        let m = AppModel()
        Self.keepAlive.append(m)
        let finished = Task<Void, Never> {}
        await finished.value
        m.hqJob = finished; m.drumJob = finished; m.leadJob = finished; m.modelDownloadTask = finished
        m.hqCancel = CancelBox(); m.drumCancel = CancelBox(); m.leadCancel = CancelBox(); m.leadStoppedForKit = true
        m.forgetStoppedWork()
        XCTAssertNil(m.hqJob)
        XCTAssertNil(m.drumJob)
        XCTAssertNil(m.leadJob)
        XCTAssertNil(m.modelDownloadTask)
        XCTAssertNil(m.hqCancel)
        XCTAssertNil(m.drumCancel)
        XCTAssertNil(m.leadCancel)
        XCTAssertFalse(m.leadStoppedForKit)
    }

    // MARK: (4) the kit with a refined guitar waiting

    private func record(id: String = "s", separator: String? = nil, drumsScale: Float = 0.8) -> SongRecord {
        let json: [String: Any] = ["bpm": 120.0, "beats": [0.0, 0.5], "downbeats": [0.0], "key": "E minor", "tuningCents": 0.0, "sections": []]
        let analysis = try! JSONDecoder().decode(SongAnalysis.self, from: JSONSerialization.data(withJSONObject: json))
        var r = SongRecord(id: id, title: "T", artist: nil, duration: 10, sourceName: "t.mp3", addedAt: Date(), lastOpened: Date(),
                           stems: [.vocals, .drums, .bass, .guitar, .other], analysis: analysis, peaks: [:],
                           storageScale: ["drums": drumsScale], hasArtwork: false, settings: SongSettings())
        r.separator = separator
        return r
    }

    func testTheKitMaySplitWhileARefinedGuitarWaitsButNotNewCleanerParts() {
        let m = AppModel()
        Self.keepAlive.append(m)
        let open = record()
        m.pendingRecord = nil
        XCTAssertTrue(m.pendingRecordKeepsDrums(open))
        var refined = open
        refined.guitarSplit = GuitarSplit(method: LeadRefineJob.refinedMethod, confidence: 0.8, leadPeaks: [], rhythmPeaks: [],
                                          leadScale: 1, rhythmScale: 1)
        m.pendingRecord = refined
        XCTAssertTrue(m.pendingRecordKeepsDrums(open), "the lead refinement leaves drums.caf as it is")
        m.pendingRecord = record(separator: CleanerPartsJob.method, drumsScale: 0.7)
        XCTAssertFalse(m.pendingRecordKeepsDrums(open), "cleaner parts replace drums.caf: they land first")
        m.pendingRecord = record(id: "other")
        XCTAssertFalse(m.pendingRecordKeepsDrums(open))
        m.pendingRecord = nil
    }

    // MARK: (6) other songs' cleaner checkpoints

    func testAStartingCleanerPassRemovesOtherSongsCheckpointsOnly() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cleaner-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        for id in ["open", "a", "b"] {
            let dir = root.appendingPathComponent(id, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("vocals.L.f32"))
        }
        let removed = CleanerPartsJob.dropOtherCheckpoints(keeping: "open", root: root)
        XCTAssertEqual(Set(removed), ["a", "b"])
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("open/vocals.L.f32").path), "the open song's checkpoint stays")
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("a").path))
        XCTAssertEqual(CleanerPartsJob.dropOtherCheckpoints(keeping: "open", root: root), [])
        // No folder at all: nothing to do.
        XCTAssertEqual(CleanerPartsJob.dropOtherCheckpoints(keeping: "open", root: root.appendingPathComponent("none")), [])
    }

    // MARK: ios-import#2 the CPU's second opinion

    /// What the GPU's pass held goes first, and only then does the CPU split. (iOS asks for room between the two; a
    /// Mac has no per-app limit to ask about.)
    func testTheSecondOpinionFreesFirstThenSplits() async throws {
        let steps = Steps()
        let parts = try await ImportPipeline.secondOpinion(freeFirst: { steps.add("free") },
                                                           split: { steps.add("split"); return [] })
        XCTAssertEqual(parts.count, 0)
        XCTAssertEqual(steps.all, ["free", "split"])
    }

    // MARK: (4) the start order, on the Mac

    /// A stand-in kit model in this test run's own container, so `kitGoesFirst` can be true. Its split fails at
    /// once (the folder holds no model). Left alone when a real one is installed.
    private func standInKitModel() throws {
        let fm = FileManager.default
        let dir = ModelStore.directory.appendingPathComponent("\(DrumSeparator.modelName).mlmodelc", isDirectory: true)
        let marker = ModelStore.directory.appendingPathComponent("\(DrumSeparator.modelName).sha256")
        guard ModelStore.url(DrumSeparator.modelName) == nil else { return }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("stand-in".utf8).write(to: marker)
        addTeardownBlock { try? fm.removeItem(at: dir); try? fm.removeItem(at: marker) }
    }

    /// A short song on disk with drums, open in `mode`.
    private func openSong(_ m: AppModel, mode: PracticeMode, style: DanceStyle? = nil) throws -> SongRecord {
        let store = SongStore.shared
        let id = "split-safety-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(at: store.folder(id), withIntermediateDirectories: true)
        let n = 2 * 44_100
        let tone = StereoAudio(left: (0..<n).map { Float(0.3 * sin(Double($0) * 0.05)) },
                               right: (0..<n).map { Float(0.3 * sin(Double($0) * 0.03)) }, sampleRate: 44_100)
        var r = record(id: id)
        r.duration = 2
        for k in r.stems { try store.writeStem(tone, to: store.stemURL(id, k)) }
        try store.save(r)
        addTeardownBlock { store.delete(id) }
        r.settings.mode = mode
        r.settings.danceStyle = style
        m.song = r
        m.settings = r.settings
        return r
    }

    private func makeModel() async -> AppModel {
        let m = AppModel()
        Self.keepAlive.append(m)
        await m.libraryReady()
        return m
    }

    /// In Beats (and Dance for bachata) the kit doesn't wait for the lead refinement: a refinement under way is
    /// told to stop, and the kit starts when it has.
    func testInBeatsTheKitStopsARunningRefinementAndGoesFirst() async throws {
        try standInKitModel()
        let m = await makeModel()
        _ = try openSong(m, mode: .beats)
        XCTAssertTrue(m.kitGoesFirst)
        let cancel = CancelBox()
        let running = Task<Void, Never> {}
        m.leadJob = running; m.leadCancel = cancel
        m.ensureDrumSplit()
        XCTAssertTrue(cancel.value, "the refinement is told to stop")
        XCTAssertTrue(m.leadStoppedForKit)
        XCTAssertNil(m.drumJob, "never side by side: the kit waits for the refinement to end")
        // ensureLeadRefine never starts a refinement while the kit goes first.
        m.leadJob = nil; m.leadCancel = nil; m.leadStoppedForKit = false
        m.song?.drumSplit = nil
        m.drumSplitFailedFor = "another song"
        m.ensureLeadRefine()
        XCTAssertNil(m.leadJob, "the kit first")
        XCTAssertNotNil(m.drumJob, "the kit split started")
        await m.drumJob?.value
        m.drumCancel?.value = true
        m.song = nil
    }

    func testInDanceForBachataTheKitGoesFirstToo() async throws {
        try standInKitModel()
        let m = await makeModel()
        _ = try openSong(m, mode: .dance, style: .bachata)
        XCTAssertTrue(m.kitGoesFirst)
        m.song = nil
    }

    /// In other modes the refinement goes first, as before: the kit split leaves a running refinement alone.
    func testInPlayTheRefinementGoesFirst() async throws {
        try standInKitModel()
        let m = await makeModel()
        _ = try openSong(m, mode: .play)
        XCTAssertFalse(m.kitGoesFirst)
        let cancel = CancelBox()
        m.leadJob = Task<Void, Never> {}; m.leadCancel = cancel
        m.ensureDrumSplit()
        XCTAssertFalse(cancel.value)
        XCTAssertFalse(m.leadStoppedForKit)
        XCTAssertNil(m.drumJob)
        m.leadJob = nil; m.leadCancel = nil
        m.song = nil
    }

    /// A kit split that fails (the stand-in model can't load) is a failure; one stopped for memory is not.
    func testAKitSplitStoppedForMemoryIsNotAFailure() async throws {
        try standInKitModel()
        MemoryBudget.clearShort()
        let m = await makeModel()
        let rec = try openSong(m, mode: .beats)
        MemoryBudget.noteShort("test")
        m.ensureDrumSplit()
        await m.drumJob?.value
        XCTAssertNil(m.drumSplitFailedFor, "short of memory: tried again later, not marked as failed")
        MemoryBudget.clearShort()
        MemoryWatch.retry?.cancel(); MemoryWatch.retry = nil
        m.ensureDrumSplit()
        await m.drumJob?.value
        XCTAssertEqual(m.drumSplitFailedFor, rec.id, "a split that really failed is not tried again this session")
        m.song = nil
    }
}

/// Steps in the order they happened (the closures may be called from any thread).
private final class Steps: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ s: String) { lock.withLock { list.append(s) } }
    var all: [String] { lock.withLock { list } }
}
