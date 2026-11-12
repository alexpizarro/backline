import XCTest
@testable import Backline

/// U07: the Map's zoom and the section tapes share one time→x mapping.
final class MapWindowTests: XCTestCase {
    func testZoomKeepsTheTimeUnderTheFingers() {
        let w = MapWindow.whole(180)
        let t = w.time(atX: 100, width: 400)                  // 45 s
        let z = w.zoomed(length: 60, keeping: t, atX: 100, width: 400)
        XCTAssertEqual(z.length, 60)
        XCTAssertEqual(z.time(atX: 100, width: 400), t, accuracy: 1e-9)
        XCTAssertTrue(z.isZoomed)
    }

    func testZoomStopsAtEightTimesAndAtTheWholeSong() {
        let w = MapWindow.whole(180)
        XCTAssertEqual(w.zoomed(length: 1, keeping: 90, atX: 200, width: 400).length, 22.5, "an eighth of the song")
        XCTAssertEqual(w.zoomed(length: 1000, keeping: 90, atX: 200, width: 400), w)
        XCTAssertEqual(MapWindow.whole(20).shortest, 4, "never under 4 s")
        XCTAssertEqual(MapWindow.whole(3).shortest, 3, "a very short song can't zoom")
    }

    func testTheViewStaysInsideTheSong() {
        let z = MapWindow(start: 0, length: 30, duration: 180)
        XCTAssertEqual(z.panned(by: -50).start, 0)
        XCTAssertEqual(z.panned(by: 500).start, 150)
        XCTAssertEqual(z.panned(by: 10).start, 10)
    }

    func testPlayingZoomedTurnsThePage() {
        let z = MapWindow(start: 0, length: 30, duration: 180)
        XCTAssertNil(z.following(12), "still in view")
        XCTAssertEqual(z.following(31)?.start ?? -1, 28, accuracy: 1e-9, "a tenth of the way in")
        XCTAssertEqual(z.following(179)?.start ?? -1, 150, accuracy: 1e-9, "the last page")
        XCTAssertNil(MapWindow.whole(180).following(200), "the whole song never pages")
    }

    func testTapesSitExactlyOnTheirSections() {
        let sections = [0.0...20, 20.0...50, 50.0...56, 56.0...180]
        let whole = MapWindow.whole(180).tapeFrames(sections, width: 360)
        XCTAssertEqual(whole.map(\.x), [0, 40, 100, 112], "x = time / 180 × 360: no minimum width")
        XCTAssertEqual(whole.map(\.width), [40, 60, 12, 248])
        let zoomed = MapWindow(start: 45, length: 30, duration: 180).tapeFrames(sections, width: 360)
        XCTAssertEqual(zoomed.map(\.index), [1, 2, 3], "the intro is out of view")
        XCTAssertEqual(zoomed[0].x, 0); XCTAssertEqual(zoomed[0].width, 60, accuracy: 1e-9, "45-50 s, clipped at the left")
        XCTAssertEqual(zoomed[1].x, 60, accuracy: 1e-9); XCTAssertEqual(zoomed[1].width, 72, accuracy: 1e-9)
        XCTAssertEqual(zoomed[2].x + zoomed[2].width, 360, accuracy: 1e-9, "clipped at the right")
    }

    func testZoomedBarsComeFromTheVisiblePart() {
        var values = [Float](repeating: 0.1, count: 1600)
        for i in 800..<1600 { values[i] = 0.9 }               // the second half is loud
        let first = MapWindow(start: 0, length: 60, duration: 180).bars(values, count: 100)
        let last = MapWindow(start: 120, length: 60, duration: 180).bars(values, count: 100)
        XCTAssertEqual(first.max(), 0.1)
        XCTAssertEqual(last.min(), 0.9)
    }
}
