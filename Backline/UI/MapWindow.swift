import CoreGraphics

/// The part of the song the Map and its section tapes show (U07): the whole song, or a zoomed window of it.
/// Both turn times into x with `x(_:width:)`, so a tape always sits over its section on the wave.
///
/// Ported byte-identical from backline-ios Backline/UI/MapWindow.swift.
nonisolated struct MapWindow: Equatable, Sendable {
    var start: Double
    var length: Double
    var duration: Double

    /// The closest zoom: an eighth of the song, never under 4 s.
    static let maxZoom: Double = 8
    static let shortestWindow: Double = 4

    static func whole(_ duration: Double) -> MapWindow {
        let d = max(duration, 0.001)
        return MapWindow(start: 0, length: d, duration: d)
    }

    var end: Double { start + length }
    var isZoomed: Bool { length < duration * 0.99 }
    var shortest: Double { min(duration, max(duration / Self.maxZoom, Self.shortestWindow)) }

    func x(_ t: Double, width: CGFloat) -> CGFloat { CGFloat((t - start) / length) * width }

    func time(atX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return start }
        return start + Double(x / width) * length
    }

    /// A new length, keeping time `t` under the fingers at `x`; clamped between 8× and the whole song.
    func zoomed(length newLength: Double, keeping t: Double, atX x: CGFloat, width: CGFloat) -> MapWindow {
        let l = min(duration, max(shortest, newLength))
        return MapWindow(start: t - Double(x / max(width, 1)) * l, length: l, duration: duration).clamped()
    }

    func panned(by seconds: Double) -> MapWindow {
        MapWindow(start: start + seconds, length: length, duration: duration).clamped()
    }

    /// Inside the song, and no closer than 8×.
    func clamped() -> MapWindow {
        let l = min(duration, max(shortest, length))
        return MapWindow(start: min(max(0, start), duration - l), length: l, duration: duration)
    }

    /// While playing zoomed: once the playhead leaves the view, turn the page so it sits a tenth of the way in.
    func following(_ t: Double) -> MapWindow? {
        guard isZoomed, t < start || t >= end else { return nil }
        return MapWindow(start: t - length * 0.1, length: length, duration: duration).clamped()
    }

    /// Where each section's tape goes in a strip `width` wide: exactly over its time range on the Map,
    /// clipped to the strip. Sections out of view are left out.
    func tapeFrames(_ ranges: [ClosedRange<Double>], width: CGFloat) -> [(index: Int, x: CGFloat, width: CGFloat)] {
        ranges.enumerated().compactMap { i, r in
            let a = max(0, x(r.lowerBound, width: width)), b = min(width, x(r.upperBound, width: width))
            return b - a >= 0.5 ? (i, a, b - a) : nil
        }
    }

    /// Bar heights for the visible part of a whole-song envelope `values`, `count` bars, each the loudest
    /// value under it.
    func bars(_ values: [Float], count: Int) -> [Float] {
        guard count > 0, !values.isEmpty, duration > 0 else { return [Float](repeating: 0, count: max(0, count)) }
        let n = values.count
        return (0..<count).map { i in
            let t0 = start + length * Double(i) / Double(count), t1 = start + length * Double(i + 1) / Double(count)
            let a = min(n - 1, max(0, Int((t0 / duration * Double(n)).rounded(.down))))
            let b = min(n, max(a + 1, Int((t1 / duration * Double(n)).rounded(.up))))
            return values[a..<b].max() ?? 0
        }
    }
}
