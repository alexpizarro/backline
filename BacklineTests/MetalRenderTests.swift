import AppKit
import BacklineKit
import Metal
import SwiftUI
import XCTest
@testable import Backline

/// Every Metal view draws (mac-finish item 1): one frame of the Map, a part row, the mini player's waveform and
/// the Stage light, each rendered off screen into a texture of its own and read back pixel by pixel. No window,
/// display link or screen is involved, so a blank harness capture can be told apart from a view that draws
/// nothing: these frames come from the same encoder the screen uses.
@MainActor
final class MetalRenderTests: XCTestCase {
    /// Straight-alpha RGBA, 0…255, of one pixel of a premultiplied BGRA image.
    private struct Pixels {
        let width: Int, height: Int
        private let bytes: [UInt8]

        init(_ image: CGImage) {
            width = image.width
            height = image.height
            var b = [UInt8](repeating: 0, count: width * height * 4)
            let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            b.withUnsafeMutableBytes { buf in
                let ctx = CGContext(data: buf.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            bytes = b
        }

        /// (r, g, b, a) premultiplied; y counts from the top.
        func at(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let i = (y * width + x) * 4
            return (Int(bytes[i + 2]), Int(bytes[i + 1]), Int(bytes[i]), Int(bytes[i + 3]))
        }

        /// The share of pixels with any coverage.
        var coverage: Double {
            var n = 0
            for i in stride(from: 3, to: bytes.count, by: 4) where bytes[i] > 8 { n += 1 }
            return Double(n) / Double(width * height)
        }

        /// The share of a column's pixels with coverage.
        func columnCoverage(_ x: Int) -> Double {
            Double((0..<height).filter { at(x, $0).a > 8 }.count) / Double(height)
        }
    }

    private func requireGPU() throws {
        guard MetalContext.shared != nil else { throw XCTSkip("no Metal device") }
    }

    private static let peaks: [Float] = (0..<400).map { 0.3 + 0.6 * abs(sin(Float($0) * 0.11)) }

    // MARK: Waveforms

    /// A part row (normalised bars, one colour, a thin playhead): bars fill the view's height band, the playhead
    /// sits where the time says, and nothing is drawn outside the bars and the line.
    func testAPartRowDrawsBarsAndItsPlayhead() throws {
        try requireGPU()
        let view = WaveformMetalView(frame: NSRect(x: 0, y: 0, width: 300, height: 48))
        view.config = WaveformConfig(values: Self.peaks, normalize: true, barColor: .blue, playedColor: nil, barAlpha: 1,
                                     minBarHeight: 2, barPitch: 4, gap: 2, duration: 20, showPlayhead: true,
                                     playheadColor: .red, playheadWidth: 1, glow: 0, dark: false)
        let image = try XCTUnwrap(view.renderOffscreen(time: 15, scale: 2))
        XCTAssertEqual(image.width, 600)
        XCTAssertEqual(image.height, 96)
        let px = Pixels(image)
        XCTAssertGreaterThan(px.coverage, 0.2, "bars cover a good part of the row")
        // The middle row of pixels crosses every bar: blue, and the gaps between them clear.
        let mid = px.height / 2
        let blue = (0..<px.width).filter { let p = px.at($0, mid); return p.a > 200 && p.b > 150 && p.r < 60 }.count
        XCTAssertGreaterThan(blue, px.width / 3, "bars are drawn in their colour across the row")
        let clear = (0..<px.width).filter { px.at($0, mid).a == 0 }.count
        XCTAssertGreaterThan(clear, px.width / 10, "the gaps between bars stay clear")
        // The playhead at 15 of 20 s: three quarters of the way across, red, top to bottom.
        let x = Int(Double(px.width) * 0.75)
        let red = (x - 2...x + 2).contains { cx in let p = px.at(cx, 2); return p.r > 150 && p.g < 80 && p.a > 150 }
        XCTAssertTrue(red, "the playhead is drawn at 0.75 of the width, from the top")
    }

    /// The Map through its own view (bars that change colour once played, the loop, the knob): bars left of the
    /// playhead take the played colour, bars right of it the idle one, and the loop's fill shows above the bars.
    func testTheMapDrawsPlayedAndUnplayedBarsAndTheLoop() throws {
        try requireGPU()
        let map = MapView(frame: NSRect(x: 0, y: 0, width: 400, height: 70))
        map.layout()
        XCTAssertEqual(map.waveform.frame.size, NSSize(width: 400, height: 70))
        map.visible = .whole(20)
        map.config = WaveformConfig(values: Self.peaks, normalize: false, barColor: .gray, playedColor: .black,
                                    minBarHeight: 3, barPitch: 4, gap: 2, verticalInset: 8, loop: 12...16,
                                    loopFill: Color.green.opacity(0.5), loopEdge: .green, showLoopHandles: true,
                                    duration: 20, showPlayhead: true, playheadColor: .orange, playheadWidth: 2,
                                    glow: 0, playheadKnob: true, dark: false)
        let image = try XCTUnwrap(map.waveform.renderOffscreen(time: 5, scale: 2))
        let px = Pixels(image)
        let mid = px.height / 2
        func darkest(_ range: Range<Int>) -> Int { range.map { let p = px.at($0, mid); return p.a > 200 ? p.r : 255 }.min() ?? 255 }
        XCTAssertLessThan(darkest(20..<200), 40, "played bars (before 5 s) are black")
        let unplayed = darkest(660..<790)          // after the loop (16 s = 640 px): no green edge
        XCTAssertGreaterThan(unplayed, 80, "bars after the playhead are the idle grey, not the played colour")
        // The loop at 12 to 16 s: its fill shows between bars, near the top (above the inset where no bar is).
        let loopX = Int(Double(px.width) * 0.7)
        let fill = px.at(loopX, 10)
        XCTAssertGreaterThan(fill.g, fill.r, "the loop's green fill is drawn")
        XCTAssertGreaterThan(fill.a, 60)
        // The knob: a 12 pt dot at the top of the playhead (5 s = a quarter of the way).
        let knob = px.at(px.width / 4, 6)
        XCTAssertTrue(knob.r > 150 && knob.a > 150, "the playhead's knob is drawn at the top")
    }

    /// The mini player's waveform, as `MiniWaveform` configures it: drawn, with played bars before the playhead.
    func testTheMiniPlayersWaveformDraws() throws {
        try requireGPU()
        let view = WaveformMetalView(frame: NSRect(x: 0, y: 0, width: 416, height: 30))
        view.config = WaveformConfig(values: Self.peaks, normalize: false, barColor: Theme.tokens.waveIdle,
                                     playedColor: Theme.tokens.wavePlayed, minBarHeight: 2, barPitch: 3, gap: 1.5,
                                     duration: 20, showPlayhead: true, playheadColor: Theme.tokens.playhead,
                                     playheadWidth: 2, glow: 0.4, dark: Theme.isDark)
        let image = try XCTUnwrap(view.renderOffscreen(time: 10, scale: 2))
        let px = Pixels(image)
        XCTAssertGreaterThan(px.coverage, 0.25, "the mini player's bars are drawn")
        XCTAssertGreaterThan(px.columnCoverage(px.width / 2), 0.9, "the playhead runs top to bottom at the middle")
    }

    /// A view with no data still draws its playhead, and one with no size draws nothing (never a crash).
    func testEdgeCasesDrawOrDeclineCleanly() throws {
        try requireGPU()
        let empty = WaveformMetalView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        empty.config = WaveformConfig(values: [], duration: 10, showPlayhead: true, playheadColor: .red, playheadWidth: 2, glow: 0)
        let px = Pixels(try XCTUnwrap(empty.renderOffscreen(time: 5)))
        XCTAssertGreaterThan(px.columnCoverage(px.width / 2), 0.9)
        XCTAssertNil(WaveformMetalView(frame: .zero).renderOffscreen(time: 0))
    }

    // MARK: Stage light

    /// The Stage light at rest: each lamp that is on glows faintly in its colour near the top edge, a lamp that
    /// is off leaves its third dark, and the floor glow lights the bottom.
    func testTheStageLightDrawsItsLampsAndFloor() throws {
        try requireGPU()
        guard MetalContext.shared?.stagePipeline != nil else { throw XCTSkip("no Stage light pipeline") }
        let view = StageLightMetalView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.config = StageLightConfig(lamps: [.init(color: SIMD4(1, 0, 0, 1), on: true, tracks: [0]),
                                               .init(color: SIMD4(0, 1, 0, 1), on: false, tracks: [1]),
                                               .init(color: SIMD4(0, 0, 1, 1), on: true, tracks: [2])])
        let px = Pixels(try XCTUnwrap(view.renderOffscreen()))
        XCTAssertEqual(px.width, 300, "one pixel per point")
        // Average a patch near the top of each lamp, to see past the grain.
        func patch(_ cx: Int, _ cy: Int) -> (r: Double, g: Double, b: Double) {
            var r = 0.0, g = 0.0, b = 0.0, n = 0.0
            for x in cx - 6...cx + 6 { for y in cy - 3...cy + 3 { let p = px.at(x, y); r += Double(p.r); g += Double(p.g); b += Double(p.b); n += 1 } }
            return (r / n, g / n, b / n)
        }
        let left = patch(50, 6), middle = patch(150, 6), right = patch(250, 6)
        XCTAssertGreaterThan(left.r, 3, "the red lamp glows")
        XCTAssertGreaterThan(left.r, left.b + 2, "in red")
        XCTAssertGreaterThan(right.b, right.r + 2, "the blue lamp glows in blue")
        XCTAssertLessThan(middle.g, 1.5, "the lamp that is off adds no green")
        let floor = patch(150, 195)
        XCTAssertGreaterThan(floor.r + floor.g + floor.b, 3, "the floor glow lights the bottom")
    }
}
