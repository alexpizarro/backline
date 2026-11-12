import BacklineKit
import XCTest
@testable import Backline

/// D20 (c) on the Mac: the background passes ask before they start and before each chunk, stop cleanly when
/// short, and a memory-pressure warning stops them without touching playback; they start again a minute later.
/// The import keeps the Mac's length tiers (there is no per-app limit to ask about).
@MainActor
final class MemoryBudgetTests: XCTestCase {
    private static var keepAlive: [AppModel] = []

    override func setUp() async throws {
        MemoryBudget.clearShort()
        MemoryBudget.pretendAvailable(nil)
    }

    override func tearDown() async throws {
        MemoryBudget.clearShort()
        MemoryBudget.pretendAvailable(nil)
    }

    private let a = MemoryBudget.bytesPerSecond

    /// A Mac sets no per-app limit: nothing is ever short for want of room, only after a pressure warning.
    func testAMacHasNoPerAppLimit() throws {
        XCTAssertEqual(MemoryBudget.available, 0)
        XCTAssertTrue(MemoryBudget.hasRoom(for: 1e15))
        XCTAssertNoThrow(try MemoryBudget.requireRoom(for: .cleaner, seconds: 30 * 60))
        XCTAssertTrue(MemoryBudget.roomForNextChunk(of: .cleaner, seconds: 30 * 60))
        XCTAssertTrue(MemoryBudget.mayStartPass)
        // The tiers decide how long a song may be, as before.
        XCTAssertEqual(DeviceLimits.maxSongSeconds(memory: 8_000_000_000), 20 * 60)
        XCTAssertEqual(DeviceLimits.maxSongSeconds(memory: 64_000_000_000), 30 * 60)
    }

    /// A pass that is short of room doesn't start; that holds back nothing else (ios-import#4). A pass already
    /// running that is short at its next chunk stops, and then none starts for a minute (the same rule as iOS, here
    /// with a pretended limit).
    func testPassesAskBeforeStartingAndBeforeEachChunk() throws {
        let seconds = 240.0
        let whole = MemoryBudget.Pass.kitSplit.need.bytes(seconds: seconds) + MemoryBudget.passFloor
        XCTAssertNoThrow(try MemoryBudget.requireRoom(for: .kitSplit, seconds: seconds, available: UInt64(whole) + 1))
        XCTAssertTrue(MemoryBudget.mayStartPass)

        XCTAssertThrowsError(try MemoryBudget.requireRoom(for: .kitSplit, seconds: seconds, available: UInt64(whole) - 1)) {
            XCTAssertEqual(($0 as? MemoryBudget.Short)?.pass, .kitSplit, "short of memory: not a failure")
            XCTAssertEqual(($0 as? MemoryBudget.Short)?.refusedAtStart, true)
        }
        XCTAssertTrue(MemoryBudget.mayStartPass, "a refusal to start is not a memory stop")

        let chunk = MemoryBudget.Pass.cleaner.afterChunks * seconds * a + MemoryBudget.passFloor
        XCTAssertTrue(MemoryBudget.roomForNextChunk(of: .cleaner, seconds: seconds, available: UInt64(chunk) + 1))
        XCTAssertTrue(MemoryBudget.mayStartPass)
        XCTAssertFalse(MemoryBudget.roomForNextChunk(of: .cleaner, seconds: seconds, available: UInt64(chunk) - 1))
        XCTAssertFalse(MemoryBudget.mayStartPass, "a memory stop holds the passes back")
        XCTAssertFalse(MemoryBudget.mayStartPass(at: Date().addingTimeInterval(MemoryBudget.backoff - 1)))
        XCTAssertTrue(MemoryBudget.mayStartPass(at: Date().addingTimeInterval(MemoryBudget.backoff + 1)), "for a minute")
        XCTAssertThrowsError(try MemoryBudget.requireRoom(for: .leadRefine, seconds: seconds, available: 0),
                             "even with room, nothing starts within the minute") {
            XCTAssertEqual(($0 as? MemoryBudget.Short)?.refusedAtStart, false, "waiting after a stop, not refused for room")
        }
    }

    /// ios-import#4: a pass that can't fit is refused without the minute's hold, without the retry, and without
    /// telling the app a memory stop happened; the song is remembered as waiting for room for that pass, and the
    /// Library refinement goes on to the next song.
    func testARefusalToStartIsNotAMemoryStop() throws {
        let posted = Counter()
        let token = NotificationCenter.default.addObserver(forName: MemoryBudget.shortNotification, object: nil, queue: nil) { _ in
            posted.increment()
        }
        defer { NotificationCenter.default.removeObserver(token) }
        XCTAssertThrowsError(try MemoryBudget.requireRoom(for: .leadRefine, seconds: 540, available: 1_000_000))
        XCTAssertTrue(MemoryBudget.mayStartPass, "no minute's hold on every other pass")
        XCTAssertEqual(posted.value, 0, "no retry scheduled")
    }

    func testASongRefusedForRoomIsSkippedUntilItIsOpenedAgain() throws {
        try XCTSkipIf(LeadSeparator.bundledModel() == nil, "no lead model in this build")
        let model = AppModel()
        Self.keepAlive.append(model)
        func pending(_ id: String) throws -> SongRecord {
            let json: [String: Any] = ["bpm": 120.0, "beats": [0.0], "downbeats": [0.0], "key": "E minor", "tuningCents": 0.0,
                                       "sections": [] as [Any]]
            let analysis = try JSONDecoder().decode(SongAnalysis.self, from: JSONSerialization.data(withJSONObject: json))
            var r = SongRecord(id: id, title: id, artist: nil, duration: 540, sourceName: "t.mp3", addedAt: Date(), lastOpened: Date(),
                               stems: [.vocals, .guitar, .drums, .other], analysis: analysis, peaks: [:], storageScale: [:],
                               hasArtwork: false, settings: SongSettings())
            r.guitarSplit = GuitarSplit(method: LeadRefineJob.stereoMethod, confidence: 0.8, leadPeaks: [], rhythmPeaks: [],
                                        leadScale: 1, rhythmScale: 1, otherAdjusted: false, otherPeaks: [], otherScale: 1)
            return r
        }
        let long = try pending("room-long"), next = try pending("room-next")
        model.library = [long, next]
        defer { model.library = []; model.roomRefused = [:] }
        XCTAssertEqual(model.nextLibraryLeadRefine()?.id, "room-long")
        model.noteRoomRefused(.leadRefine, "room-long")
        XCTAssertEqual(model.nextLibraryLeadRefine()?.id, "room-next", "the Library goes on to the next song")
        XCTAssertTrue(model.isRoomRefused(.leadRefine, "room-long"))
        XCTAssertFalse(model.isRoomRefused(.cleaner, "room-long"), "only that pass")
        // The Mac comes back to the front: it is tried again.
        model.retryRoomRefused()
        XCTAssertFalse(model.isRoomRefused(.leadRefine, "room-long"))
        XCTAssertEqual(model.nextLibraryLeadRefine()?.id, "room-long")
    }

    /// A pressure warning stops the passes that are running (their cancel flags), holds new ones back, leaves
    /// playback alone, and the passes are started again later.
    func testAPressureWarningStopsThePassesButNotPlayback() async throws {
        let model = AppModel()
        Self.keepAlive.append(model)
        let lead = CancelBox(), kit = CancelBox(), cleaner = CancelBox()
        model.leadCancel = lead; model.drumCancel = kit; model.hqCancel = cleaner
        let idle = Task<Void, Never> {}
        model.leadJob = idle
        let playingBefore = model.isPlaying

        model.memoryWarning("pressure")
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(lead.value && kit.value && cleaner.value, "every pass is told to stop")
        XCTAssertFalse(MemoryBudget.mayStartPass, "and none starts for a minute")
        XCTAssertEqual(model.isPlaying, playingBefore, "playback is not touched")
        XCTAssertNotNil(MemoryWatch.retry, "the passes are started again later")
        XCTAssertNotNil(MemoryWatch.source, "the system's memory-pressure source is listened to")
        MemoryWatch.retry?.cancel()
        MemoryWatch.retry = nil
        model.leadJob = nil; model.leadCancel = nil; model.drumCancel = nil; model.hqCancel = nil
    }

    /// On a Mac the pressure is the whole system's: a warning is written down and the passes go on (each checks its
    /// own room before a chunk); only critical pressure stops them (review mac-core#6).
    func testOnlyCriticalPressureStopsThePasses() async throws {
        let model = AppModel()
        Self.keepAlive.append(model)
        let lead = CancelBox()
        model.leadCancel = lead
        model.leadJob = Task<Void, Never> {}
        model.memoryPressure(critical: false)
        XCTAssertFalse(lead.value, "a warning doesn't stop the lead refinement")
        XCTAssertTrue(MemoryBudget.mayStartPass, "and holds nothing back")
        XCTAssertNil(MemoryWatch.retry, "so there is nothing to start again")
        model.memoryPressure(critical: true)
        XCTAssertTrue(lead.value, "critical pressure stops it")
        XCTAssertFalse(MemoryBudget.mayStartPass)
        try await Task.sleep(for: .milliseconds(50))
        MemoryWatch.retry?.cancel()
        MemoryWatch.retry = nil
        model.leadJob = nil; model.leadCancel = nil
    }

    /// With nothing running, a warning only holds the passes back.
    func testAPressureWarningWithNothingRunning() async throws {
        let model = AppModel()
        Self.keepAlive.append(model)
        let lead = CancelBox()
        model.leadCancel = lead
        model.memoryWarning("pressure")
        XCTAssertFalse(lead.value, "nothing was running, nothing to stop")
        XCTAssertFalse(MemoryBudget.mayStartPass)
        try await Task.sleep(for: .milliseconds(50))
        MemoryWatch.retry?.cancel()
        MemoryWatch.retry = nil
        model.leadCancel = nil
    }
}
