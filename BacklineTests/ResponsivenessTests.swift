import BacklineKit
import Observation
import Synchronization
import XCTest
@testable import Backline

/// The Player and the Library stay smooth (release 1.1, ios-responsive; `uiperf.md` UIP-02 to UIP-11): what
/// runs per touch, per progress callback and per frame, checked without a screen.
/// Ported from backline-ios `0005ce9`. Not here: the display rate (UIP-06, the iPhone's display link) and the
/// photo's flicker (UIP-09, no living photo on the Mac yet); the time row's whole seconds are the Mac's
/// `timeText`, which mac-player already published once a second.
@MainActor
final class ResponsivenessTests: XCTestCase {
    /// The app model lives for the whole process (see `AppLogicTests.keepAlive`).
    private static var keepAlive: [AppModel] = []
    private func makeModel() -> AppModel {
        let m = AppModel()
        Self.keepAlive.append(m)
        return m
    }

    private func record(id: String, stems: [StemKind] = [.vocals, .guitar, .bass, .drums, .keys, .other]) -> SongRecord {
        let json: [String: Any] = ["bpm": 120.0, "beats": (0..<64).map { Double($0) * 0.5 }, "downbeats": (0..<16).map { Double($0) * 2 },
                                   "key": "E minor", "tuningCents": 0.0,
                                   "sections": [["id": UUID().uuidString, "label": "Verse", "start": 0.0, "end": 32.0]]]
        let analysis = try! JSONDecoder().decode(SongAnalysis.self, from: JSONSerialization.data(withJSONObject: json))
        return SongRecord(id: id, title: "Test", artist: nil, duration: 32, sourceName: "t.mp3", addedAt: Date(), lastOpened: Date(),
                          stems: stems, analysis: analysis, peaks: [:], storageScale: [:], hasArtwork: false, settings: SongSettings())
    }

    // MARK: UIP-02 · the extra parts row

    /// The row's state comes from what `ExtraParts.refresh` found: building it, however often, never looks at
    /// the disk or asks the volume for its free space.
    func testTheExtraPartsOfferDoesNoFileAccess() {
        let m = makeModel()
        m.song = record(id: "uip02-offer")
        defer { m.song = nil }
        ExtraParts.shared.refresh()
        let before = ModelDownloads.diskLookups.load(ordering: .relaxed)
        for _ in 0..<50 { _ = m.extraPartsOffer }
        for state in [ExtraPartsState.offer, .failed, .splitting(fraction: nil)] { _ = m.extraPartsOffer(state: state) }
        XCTAssertEqual(ModelDownloads.diskLookups.load(ordering: .relaxed), before, "no file or free-space lookups in the row")
    }

    /// A refresh that finds the same answer redraws nothing; a different one does.
    func testARefreshWritesOnlyWhatChanged() {
        let extras = ExtraParts()
        extras.apply(missing: ModelDownloads.assets, hasSpace: true)
        let fired = Mutex(false)
        withObservationTracking { _ = extras.missing; _ = extras.hasSpace } onChange: { fired.withLock { $0 = true } }
        extras.apply(missing: ModelDownloads.assets, hasSpace: true)
        XCTAssertFalse(fired.withLock { $0 }, "the same answer is not a change")
        extras.apply(missing: [], hasSpace: true)
        XCTAssertTrue(fired.withLock { $0 })
        XCTAssertTrue(extras.missing.isEmpty)
    }

    /// The row's state follows the stored answer: no room means no Download button.
    func testTheRowSaysNoSpaceFromTheStoredAnswer() {
        let m = makeModel()
        m.song = record(id: "uip02-space")
        let consent = ModelDownloads.consent
        defer { m.song = nil; ModelDownloads.consent = consent; ExtraParts.shared.refresh() }
        // A download another test said yes to would be running in this model: the offer states only.
        if m.modelDownloadTask != nil { m.cancelModelDownloads() }
        ExtraParts.shared.apply(missing: ModelDownloads.assets, hasSpace: false)
        guard let offer = m.extraPartsOffer else { return }      // this device doesn't offer the models (B03)
        XCTAssertEqual(offer.state, .noSpace(needed: ModelDownloads.spaceNeededForMissing(ModelDownloads.assets)))
    }

    /// Thousands of progress callbacks for one model reach the screen at most once per whole percent and
    /// never more than four times a second; the end always gets through.
    func testDownloadProgressIsThrottledAtTheSource() {
        let throttle = ProgressThrottle()
        var published: [Double] = []
        // 34,000 callbacks (16 KB chunks of a 550 MB download) spread over 120 s.
        let n = 34_000
        for i in 1...n {
            let p = Double(i) / Double(n)
            if throttle.shouldPublish(p, now: 120 * Double(i) / Double(n)) { published.append(p) }
        }
        XCTAssertLessThanOrEqual(published.count, 101)
        XCTAssertGreaterThanOrEqual(published.count, 90, "every percent still shows on a slow download")
        XCTAssertEqual(published.last, 1, "the end is never dropped")

        // A fast download: 100 % in one second gives at most five figures.
        let fast = ProgressThrottle()
        let quick = (1...1000).filter { fast.shouldPublish(Double($0) / 1000, now: Double($0) / 1000) }
        XCTAssertLessThanOrEqual(quick.count, 6)
        XCTAssertEqual(quick.last, 1000)
    }

    // MARK: UIP-03 · faders

    /// A drag previews in the engine without touching the settings; the release writes them once.
    func testAFaderDragWritesTheSettingsOnce() {
        let m = makeModel()
        m.song = record(id: "uip03-fader")
        m.loadedTracks = [.vocals, .guitar, .bass, .drums, .keys, .other]
        defer { m.song = nil; m.loadedTracks = []; SongStore.shared.delete("uip03-fader") }
        let before = m.settingsChangeCount
        for step in 0..<50 { m.previewVolume(.bass, Double(80 - step)) }
        XCTAssertEqual(m.settingsChangeCount, before, "previews never touch the settings")
        XCTAssertEqual(m.pushedGains[.bass] ?? -1, AppModel.gain(forVolume: 31), accuracy: 1e-6, "the engine has the last step")
        XCTAssertEqual(m.settings.volume(.bass), 80, "the stored fader waits for the release")
        m.setVolume(.bass, 31)
        XCTAssertEqual(m.settingsChangeCount - before, 1, "one write per gesture")
        XCTAssertEqual(m.settings.volume(.bass), 31)
        XCTAssertEqual(m.pushedGains[.bass] ?? -1, AppModel.gain(forVolume: 31), accuracy: 1e-6)
        m.setVolume(.bass, 31)
        XCTAssertEqual(m.settingsChangeCount - before, 1, "the same value is not a second write")
    }

    /// A preview only moves the dragged row's tracks.
    func testAFaderPreviewLeavesTheOtherPartsAlone() {
        let m = makeModel()
        m.song = record(id: "uip03-others")
        m.loadedTracks = [.vocals, .guitar, .bass]
        defer { m.song = nil; m.loadedTracks = []; SongStore.shared.delete("uip03-others") }
        m.pushAll()
        let vocals = m.pushedGains[.vocals]
        m.previewVolume(.bass, 10)
        XCTAssertEqual(m.pushedGains[.vocals], vocals)
        XCTAssertEqual(m.pushedGains[.bass] ?? -1, AppModel.gain(forVolume: 10), accuracy: 1e-6)
    }

    // MARK: UIP-05 · the Library at launch

    /// Reading the records several at once gives exactly what reading them one by one gives, in the same
    /// order, and still leaves out a song whose parts are missing.
    func testTheLibraryLoadsTheSameInParallel() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("uip05-\(UUID().uuidString)/Songs", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root.deletingLastPathComponent()) }
        let store = SongStore(root: root)
        for i in 0..<24 {
            var rec = record(id: "song-\(i)", stems: [.vocals, .other])
            rec.peaks = ["vocals": (0..<1600).map { Float($0 % 97) / 97 }, "other": [Float](repeating: 0.25, count: 1600)]
            rec.lastOpened = Date(timeIntervalSince1970: Double(1_000_000 + i * 37 % 11))
            try store.save(rec)
            // Parts present except for one song, which must be left out either way.
            guard i != 7 else { continue }
            for k in rec.stems { try Data([0]).write(to: store.stemURL(rec.id, k)) }
        }
        let sequential = store.loadAll(parallel: false)
        let parallel = store.loadAll(parallel: true)
        XCTAssertEqual(sequential.count, 23)
        XCTAssertFalse(parallel.contains { $0.id == "song-7" })
        XCTAssertEqual(parallel, sequential)
    }

    /// How long a hundred real-sized records take to read, one by one and several at once (printed for the
    /// report; the gain depends on the cores the Simulator gets).
    func testAHundredSongsLoadFasterInParallel() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("uip05p-\(UUID().uuidString)/Songs", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root.deletingLastPathComponent()) }
        let store = SongStore(root: root)
        let curve = (0..<1600).map { Float(sin(Double($0) * 0.013) * 0.5 + 0.5) }
        for i in 0..<100 {
            var rec = record(id: "song-\(i)", stems: [.vocals, .guitar, .bass, .drums, .keys, .other])
            // About the size of a real record: ten arrays of 1,600 peaks.
            for k in ["vocals", "guitar", "bass", "drums", "keys", "other", "leadGuitar", "rhythmGuitar", "kick", "snare"] {
                rec.peaks[k] = curve
            }
            try store.save(rec)
            for k in rec.stems { try Data([0]).write(to: store.stemURL(rec.id, k)) }
        }
        let t0 = Date()
        let one = store.loadAll(parallel: false)
        let t1 = Date()
        let many = store.loadAll(parallel: true)
        let t2 = Date()
        XCTAssertEqual(one.count, 100)
        XCTAssertEqual(many.count, 100)
        print("[perf] 100 records: one by one \(Int(t1.timeIntervalSince(t0) * 1000)) ms, "
              + "in parallel \(Int(t2.timeIntervalSince(t1) * 1000)) ms (and now off the main thread)")
    }

    // MARK: UIP-11 · the time row and the counts

    /// The time row's seconds and the count strip's count change only when what they show changes.
    func testTheReadoutsChangeOnlyWhenWhatTheyShowChanges() {
        let m = makeModel()
        var r = record(id: "uip11-readouts")
        r.settings.countOne = 0
        m.song = r
        m.settings = r.settings
        m.appMode = .dance
        defer { m.song = nil; m.appMode = .play; SongStore.shared.delete(r.id) }
        m.position = 10.02
        XCTAssertEqual(m.timeText, .init(elapsed: formatTime(10.02), remaining: formatTime(21.98)))
        let fired = Mutex(0)
        withObservationTracking { _ = m.timeText } onChange: { fired.withLock { $0 += 1 } }
        for i in 1..<30 { m.position = 10.02 + Double(i) / 31 }      // 29 ticks within the same second
        XCTAssertEqual(fired.withLock { $0 }, 0, "the time row isn't told about ticks within a second")
        m.position = 11.01
        XCTAssertEqual(fired.withLock { $0 }, 1)
        XCTAssertEqual(m.timeText, .init(elapsed: formatTime(11.01), remaining: formatTime(20.99)))

        // The section under the playhead is stored, and only a new section is a change.
        let sectioned = Mutex(0)
        withObservationTracking { _ = m.playheadSection } onChange: { sectioned.withLock { $0 += 1 } }
        for i in 1..<30 { m.position = 11.01 + Double(i) / 10 }
        XCTAssertEqual(sectioned.withLock { $0 }, 0, "the same section is not a change")
        XCTAssertEqual(m.playheadSection, 0)

        // Beats every 0.5 s with the 1 on the first: the count follows the playhead.
        m.position = 0.1
        XCTAssertEqual(m.playheadBeat.count, m.currentCount)
        XCTAssertEqual(m.playheadBeat.count, 1)
        let counted = Mutex(0)
        withObservationTracking { _ = m.playheadBeat } onChange: { counted.withLock { $0 += 1 } }
        m.position = 0.2
        m.position = 0.3
        XCTAssertEqual(counted.withLock { $0 }, 0, "same beat, no redraw")
        m.position = 0.6
        XCTAssertEqual(counted.withLock { $0 }, 1)
        XCTAssertEqual(m.playheadBeat.count, 2)
    }

    /// Until the Library has been read it is not "empty", so launch never flashes the empty screen; once read,
    /// `libraryReady` returns and the songs are there.
    func testTheLibraryIsNotEmptyUntilItHasBeenRead() async {
        let m = makeModel()
        if !m.libraryLoaded { XCTAssertFalse(m.libraryIsEmpty, "still reading: the canvas, not the empty screen") }
        await m.libraryReady()
        XCTAssertTrue(m.libraryLoaded)
        XCTAssertEqual(m.libraryIsEmpty, m.library.isEmpty)
    }
}
