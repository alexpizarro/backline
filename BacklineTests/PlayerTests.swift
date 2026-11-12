import AppKit
import BacklineKit
import MediaPlayer
import XCTest
@testable import Backline

/// The player's finish on the Mac (WP5, WP6, UIP-03, UIP-07, UIP-11): the fader writes once per gesture, the
/// ticker slows when nothing moves, Now Playing settles after seeks, the Map's pointer gestures, and the display
/// link that sleeps while its window can't be seen.
@MainActor
final class PlayerTests: XCTestCase {
    private static var keepAlive: [AppModel] = []
    private func makeModel() -> AppModel {
        let m = AppModel()
        m.appMode = .play
        Self.keepAlive.append(m)
        return m
    }

    private func record(id: String) -> SongRecord {
        let beats = (0..<64).map { Double($0) * 0.5 }, bars = (0..<16).map { Double($0) * 2 }
        let json: [String: Any] = ["bpm": 120.0, "beats": beats, "downbeats": bars, "key": "E minor", "tuningCents": 0.0,
                                   "sections": [["id": UUID().uuidString, "label": "Verse", "start": 0.0, "end": 16.0],
                                                ["id": UUID().uuidString, "label": "Solo", "start": 16.0, "end": 24.0]]]
        let analysis = try! JSONDecoder().decode(SongAnalysis.self, from: JSONSerialization.data(withJSONObject: json))
        return SongRecord(id: id, title: "Test", artist: nil, duration: 32, sourceName: "t.mp3", addedAt: Date(), lastOpened: Date(),
                          stems: [.vocals, .guitar, .bass, .drums, .keys, .other], analysis: analysis, peaks: [:],
                          storageScale: [:], hasArtwork: false, settings: SongSettings())
    }

    // MARK: The fader (UIP-03)

    /// A fader drag is heard at once but writes the settings once, on release; a release where it started writes
    /// nothing.
    func testAFaderDragWritesTheSettingsOnce() {
        let m = makeModel()
        let r = record(id: "player-fader")
        m.song = r
        defer { m.song = nil; SongStore.shared.delete(r.id) }
        let before = m.settingsChangeCount
        for i in 0..<50 { m.previewVolume(.bass, Double(30 + i)) }
        XCTAssertEqual(m.settingsChangeCount, before, "a drag in progress writes nothing")
        XCTAssertEqual(m.settings.volume(.bass), 80)
        m.setVolume(.bass, 79)
        XCTAssertEqual(m.settingsChangeCount - before, 1, "the release writes once")
        XCTAssertEqual(m.settings.volume(.bass), 79)
        m.setVolume(.bass, 79.2)
        XCTAssertEqual(m.settingsChangeCount - before, 1, "an unchanged value writes nothing")
    }

    // MARK: The ticker (UIP-11)

    /// 4 Hz with a paused song, 15 Hz under a scrubbing pointer, stopped with no song; never 30 Hz forever.
    func testTheTickerSlowsWhenNothingMovesAndStopsWithNoSong() {
        let m = makeModel()
        XCTAssertNil(m.tickerIntervalForTesting, "no song: no ticker")
        let r = record(id: "player-ticker")
        m.song = r
        defer { m.song = nil; SongStore.shared.delete(r.id) }
        XCTAssertEqual(m.tickerIntervalForTesting, 0.25, "paused: 4 Hz")
        m.beginScrub(3)
        XCTAssertEqual(m.tickerIntervalForTesting ?? 0, 1.0 / 15, accuracy: 1e-9, "scrubbing: 15 Hz")
        m.endScrub(4)
        XCTAssertEqual(m.tickerIntervalForTesting, 0.25)
        m.song = nil
        XCTAssertNil(m.tickerIntervalForTesting, "the song closed: the ticker stops")
    }

    /// The time labels change once a second, not with every tick of the playhead.
    func testTheTimeLabelsChangeOncePerSecond() {
        let m = makeModel()
        let r = record(id: "player-time")
        m.song = r
        defer { m.song = nil; SongStore.shared.delete(r.id) }
        m.seek(to: 5.1)
        let shown = m.timeText
        XCTAssertEqual(shown.elapsed, formatTime(5.1))
        XCTAssertEqual(shown.remaining, formatTime(32 - 5.1))
        m.position = 5.5
        XCTAssertEqual(m.timeText, shown, "half a second later the labels are the same")
        m.position = 6.05
        XCTAssertEqual(m.timeText.elapsed, formatTime(6.05))
    }

    // MARK: Now Playing (WP6)

    /// T09: Now Playing shows the new time after a seek, at most 4 times a second, and the last seek lands.
    func testSeeksRefreshTheLockScreenOnceTheySettle() {
        let m = makeModel()
        let r = record(id: "player-nowplaying")
        m.song = r
        defer { m.song = nil; SongStore.shared.delete(r.id) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        m.nowPlayingSeekRefreshes = []
        m.seek(to: 3); m.seek(to: 4); m.seek(to: 5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        XCTAssertEqual(m.nowPlayingSeekRefreshes, [5], "three quick seeks: one refresh, showing the last")
        m.seek(to: 9)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(m.nowPlayingSeekRefreshes.last, 9)
    }

    /// MediaPlayer asks for the artwork on its own queue; a closure written in main-actor code traps there.
    func testNowPlayingArtworkCanBeDrawnOffTheMainThread() {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in
            NSColor.red.setFill(); r.fill(); return true
        }
        let art = NowPlaying.makeArtwork(image)
        let done = expectation(description: "drawn on a background queue")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = art.image(at: CGSize(width: 4, height: 4))
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    // MARK: Stage light

    /// T40: the Stage light reads loudness, not raw RMS: −40 dBFS is dark, −6 dBFS is full.
    func testStageLightLevelIsALoudnessScale() {
        XCTAssertEqual(StageLightMetalView.level(rms: 0), 0)
        XCTAssertEqual(StageLightMetalView.level(rms: 0.01), 0, accuracy: 1e-4)        // −40 dBFS
        XCTAssertEqual(StageLightMetalView.level(rms: 0.1), 20.0 / 34, accuracy: 1e-3)  // −20 dBFS
        XCTAssertEqual(StageLightMetalView.level(rms: 0.5012), 1, accuracy: 1e-3)       // −6 dBFS
        XCTAssertEqual(StageLightMetalView.level(rms: 0.9), 1)
    }

    // MARK: The Map's pointer (WP5)

    private func mouse(_ type: NSEvent.EventType, x: CGFloat, option: Bool = false) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 30), modifierFlags: option ? [.option] : [],
                           timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func mapView() -> MapView {
        let v = MapView(frame: NSRect(x: 0, y: 0, width: 400, height: 70))
        v.duration = 180
        v.visible = .whole(180)
        return v
    }

    /// A click jumps; a sideways drag scrubs with one begin, moves and one end.
    func testAClickJumpsAndADragScrubs() {
        let v = mapView()
        var taps: [Double] = [], scrubs: [MapView.Phase] = []
        v.onTap = { taps.append($0) }
        v.onScrub = { phase, _ in scrubs.append(phase) }
        v.mouseDown(with: mouse(.leftMouseDown, x: 100))
        v.mouseUp(with: mouse(.leftMouseUp, x: 101))
        XCTAssertEqual(taps.count, 1)
        XCTAssertEqual(taps[0], 101.0 / 400 * 180, accuracy: 1e-9)
        XCTAssertTrue(scrubs.isEmpty, "a click is not a scrub")

        v.mouseDown(with: mouse(.leftMouseDown, x: 100))
        for x in stride(from: 110, through: 200, by: 10) { v.mouseDragged(with: mouse(.leftMouseDragged, x: CGFloat(x))) }
        v.mouseUp(with: mouse(.leftMouseUp, x: 200))
        XCTAssertEqual(scrubs.first, .began)
        XCTAssertEqual(scrubs.last, .ended)
        XCTAssertEqual(scrubs.filter { $0 == .began }.count, 1)
        XCTAssertEqual(scrubs.filter { $0 == .ended }.count, 1)
        XCTAssertEqual(taps.count, 1, "a drag is not a click")
    }

    /// Option-drag previews the loop as it moves and commits it once, on release; dragging an edge does the same.
    func testDrawingALoopPreviewsThenCommitsOnce() {
        let v = mapView()
        var previews: [ClosedRange<Double>] = [], commits: [(ClosedRange<Double>, Bool)] = []
        v.onLoopPreview = { previews.append($0) }
        v.onLoopEnd = { if case .committed(let r, let n) = $0 { commits.append((r, n)) } }
        v.mouseDown(with: mouse(.leftMouseDown, x: 100, option: true))
        for x in stride(from: 110, through: 200, by: 10) { v.mouseDragged(with: mouse(.leftMouseDragged, x: CGFloat(x))) }
        v.mouseUp(with: mouse(.leftMouseUp, x: 200))
        XCTAssertGreaterThan(previews.count, 1, "the loop is heard while it is drawn")
        XCTAssertEqual(commits.count, 1, "and written once")
        XCTAssertEqual(commits[0].0.lowerBound, 45, accuracy: 1e-9)
        XCTAssertEqual(commits[0].0.upperBound, 90, accuracy: 1e-9)
        XCTAssertTrue(commits[0].1, "a new loop")

        v.loopRange = 45...90
        previews = []; commits = []
        v.mouseDown(with: mouse(.leftMouseDown, x: 201))           // the end edge, at 200 pt
        for x in stride(from: 210, through: 300, by: 10) { v.mouseDragged(with: mouse(.leftMouseDragged, x: CGFloat(x))) }
        v.mouseUp(with: mouse(.leftMouseUp, x: 300))
        XCTAssertGreaterThan(previews.count, 1)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].0.lowerBound, 45, accuracy: 1e-9, "the start stays")
        XCTAssertEqual(commits[0].0.upperBound, 135, accuracy: 1e-9)
        XCTAssertFalse(commits[0].1, "a moved edge is not a new loop")
    }

    /// Command and the wheel zoom around the pointer: the time under it stays under it.
    func testZoomingKeepsTheTimeUnderThePointer() throws {
        let v = mapView()
        let x: CGFloat = 100
        let before = v.time(atX: x)
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 40, wheel2: 0, wheel3: 0))
        cg.location = CGPoint(x: x, y: 30)
        cg.flags = .maskCommand
        let e = try XCTUnwrap(NSEvent(cgEvent: cg))
        v.scrollWheel(with: e)
        XCTAssertTrue(v.visible.isZoomed, "zoomed in")
        XCTAssertLessThan(v.visible.length, 180)
        XCTAssertEqual(v.time(atX: x), before, accuracy: 0.01, "the same time under the pointer")
    }

    // MARK: The display link (UIP-07)

    private final class FakeEngine: EngineStatusSource, @unchecked Sendable {
        var playing = true
        let sampleRate = 44_100.0
        var status: PlaybackEngine.Status { PlaybackEngine.Status(position: 0, playing: playing, rate: 1) }
    }

    /// While a song plays the link keeps drawing, but only while its window can be seen: a hidden window lets it
    /// sleep, and showing the window wakes it.
    func testTheDisplayLinkSleepsWhileTheWindowIsHidden() throws {
        let scheduler = WaveformScheduler.shared
        let savedClock = scheduler.clock
        scheduler.clock = TransportClock(engine: FakeEngine())
        defer { scheduler.clock = savedClock }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = WaveformMetalView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        view.config = WaveformConfig(values: [0.2, 0.8, 0.5], duration: 10)
        window.contentView = view
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        defer { window.close() }
        // A test host without a visible desktop (a locked screen) can't show windows.
        guard WaveformScheduler.isOnScreen(view) else { throw XCTSkip("no visible desktop for a test window") }
        XCTAssertTrue(scheduler.step(now: CACurrentMediaTime()), "playing in a visible window: more frames")
        XCTAssertTrue(scheduler.isRunning)
        window.orderOut(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(WaveformScheduler.isOnScreen(view))
        XCTAssertFalse(scheduler.step(now: CACurrentMediaTime()), "hidden: no frames, even while playing")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(scheduler.isRunning, "the link sleeps")
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(scheduler.isRunning, "showing the window wakes it")
    }
}
