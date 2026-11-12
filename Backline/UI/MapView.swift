import AppKit
import SwiftUI

/// The Map's pointer surface (WP5), ported from backline-ios Backline/UI/MapView.swift with the Mac's own
/// gestures. The events are handled here, in AppKit, so a drag never runs SwiftUI work per event:
///
/// - a click jumps (onto the beat within 120 ms); a sideways drag scrubs (one seek on release);
/// - a drag that starts on a loop edge moves that edge;
/// - Option-drag draws a new loop (in Beats a plain drag does, bar line to bar line);
/// - pinch on a trackpad, or Command and the scroll wheel, zooms up to 8× around the pointer; a sideways scroll
///   moves a zoomed view; a drag that reaches the edge of a zoomed view slides it along.
///
/// Loop gestures preview on the Metal view and in the engine as they move, and write the settings once, on release.
final class MapView: NSView {
    enum Phase { case began, changed, ended }
    enum LoopEnd { case committed(ClosedRange<Double>, newLoop: Bool), cancelled }

    let waveform = WaveformMetalView(frame: .zero)
    var duration: Double = 1
    var loopRange: ClosedRange<Double>?
    /// Beats: a plain drag draws a loop (bar line to bar line); elsewhere it scrubs.
    var plainDragDrawsLoop = false
    /// The part of the song on screen, shared with the section strip through `AppModel.mapWindow`.
    var visible = MapWindow.whole(1) {
        didSet { if visible != oldValue { applyConfig() } }
    }
    /// The new window and whether a pinch or scroll is still moving it.
    var onWindow: (MapWindow, Bool) -> Void = { _, _ in }
    private(set) var zooming = false
    /// The config SwiftUI last gave; a loop gesture in progress overrides its loop.
    private var baseConfig = WaveformConfig()
    var config: WaveformConfig {
        get { baseConfig }
        set { baseConfig = newValue; applyConfig() }
    }
    var onScrub: (Phase, Double) -> Void = { _, _ in }
    var onTap: (Double) -> Void = { _ in }
    /// The time under the pointer while it hovers (nil when it leaves or a drag starts).
    var onHover: (Double?, CGFloat) -> Void = { _, _ in }
    /// Snaps a loop edge (beats, or bars in Beats).
    var snap: (Double) -> Double = { $0 }
    var onLoopPreview: (ClosedRange<Double>) -> Void = { _ in }
    var onLoopEnd: (LoopEnd) -> Void = { _ in }

    private enum Drag { case pending, scrub, loopStart, loopEnd, newLoop }
    private var drag: Drag?
    private var downX: CGFloat = 0
    private var drawAnchor: Double?
    /// The loop being drawn or resized, shown instead of the settings' loop until release.
    private var preview: ClosedRange<Double>?
    private var tracking: NSTrackingArea?
    private var magnifyStart = MapWindow.whole(1)
    private var magnifyAnchor: Double = 0
    private var magnifyScale: CGFloat = 1
    private var scrollEnd: DispatchWorkItem?
    /// The shortest loop an edge drag can make.
    static let minimumLoop = 0.5
    /// A drag that starts this close to a loop edge belongs to the edge.
    static let loopEdgeTolerance: CGFloat = 8
    /// How far the pointer moves before a press is a drag, not a click.
    static let dragThreshold: CGFloat = 3

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(waveform)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        waveform.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    private func applyConfig() {
        var c = baseConfig
        c.visible = visible.isZoomed ? visible : nil
        if let preview {
            c.loop = preview
            c.showLoopHandles = true
        }
        waveform.config = c
    }

    func time(atX x: CGFloat) -> Double {
        guard bounds.width > 0 else { return 0 }
        return visible.time(atX: max(0, min(bounds.width, x)), width: bounds.width)
    }

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    // MARK: Zoom (U07)

    private func setVisible(_ w: MapWindow, active: Bool) {
        visible = w
        onWindow(w, active)
    }

    override func magnify(with e: NSEvent) {
        guard bounds.width > 0, duration > 0 else { return }
        let x = point(e).x
        switch e.phase {
        case .began:
            zooming = true
            magnifyStart = visible
            magnifyAnchor = visible.time(atX: x, width: bounds.width)
            magnifyScale = 1
        case .changed:
            magnifyScale = max(0.05, magnifyScale * (1 + e.magnification))
            setVisible(magnifyStart.zoomed(length: magnifyStart.length / Double(magnifyScale), keeping: magnifyAnchor,
                                           atX: x, width: bounds.width), active: true)
        case .ended, .cancelled:
            zooming = false
            // Almost the whole song is the whole song.
            setVisible(visible.length >= duration * 0.95 ? .whole(duration) : visible, active: false)
        default: break
        }
    }

    override func scrollWheel(with e: NSEvent) {
        guard bounds.width > 0, duration > 0 else { return super.scrollWheel(with: e) }
        let precise = e.hasPreciseScrollingDeltas
        if e.modifierFlags.contains(.command) {
            // Command and the wheel zoom around the pointer (for a mouse; a trackpad pinches).
            let dy = precise ? e.scrollingDeltaY : e.scrollingDeltaY * 8
            guard dy != 0 else { return }
            let x = point(e).x
            let anchor = visible.time(atX: x, width: bounds.width)
            let w = visible.zoomed(length: visible.length * exp(-Double(dy) * 0.01), keeping: anchor, atX: x, width: bounds.width)
            zooming = true
            setVisible(w.length >= duration * 0.95 ? .whole(duration) : w, active: true)
            settleScroll()
            return
        }
        // Sideways (a trackpad swipe, or Shift and the wheel) moves a zoomed view; anything else isn't ours.
        let dx = precise ? e.scrollingDeltaX : e.scrollingDeltaX * 8
        guard visible.isZoomed, abs(dx) > abs(e.scrollingDeltaY) else { return super.scrollWheel(with: e) }
        zooming = true
        setVisible(visible.panned(by: -Double(dx / bounds.width) * visible.length), active: true)
        settleScroll()
    }

    /// Scroll events have no reliable end: the view settles a moment after the last one.
    private func settleScroll() {
        scrollEnd?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.zooming = false
                self.setVisible(self.visible, active: false)
            }
        }
        scrollEnd = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    /// A drag that reaches the edge of a zoomed view slides the view along with it.
    private func followPointer(_ x: CGFloat) {
        guard visible.isZoomed, bounds.width > 0 else { return }
        let edge: CGFloat = 16
        if x < edge { setVisible(visible.panned(by: -visible.length * 0.03), active: false) }
        else if x > bounds.width - edge { setVisible(visible.panned(by: visible.length * 0.03), active: false) }
    }

    // MARK: Pointer

    override func mouseDown(with e: NSEvent) {
        let p = point(e)
        downX = p.x
        onHover(nil, 0)
        let t = time(atX: p.x)
        if let start = loopEdge(near: p.x) {
            drag = start ? .loopStart : .loopEnd
        } else if e.modifierFlags.contains(.option) || plainDragDrawsLoop {
            drag = .newLoop
            drawAnchor = snap(t)
        } else {
            drag = .pending
        }
    }

    override func mouseDragged(with e: NSEvent) {
        let p = point(e)
        let moved = abs(p.x - downX) >= Self.dragThreshold
        if moved { followPointer(p.x) }
        let t = time(atX: p.x)
        switch drag {
        case .pending:
            guard moved else { return }
            drag = .scrub
            onScrub(.began, t)
        case .scrub:
            onScrub(.changed, t)
        case .loopStart, .loopEnd:
            guard let r = preview ?? loopRange else { drag = nil; return }
            let edge = snap(t)
            showPreview(drag == .loopStart
                        ? min(edge, r.upperBound - Self.minimumLoop)...r.upperBound
                        : r.lowerBound...max(edge, r.lowerBound + Self.minimumLoop))
        case .newLoop:
            guard moved, let a = drawAnchor else { return }
            let b = snap(t)
            if abs(b - a) >= Self.minimumLoop { showPreview(min(a, b)...max(a, b)) }
        case nil: break
        }
    }

    override func mouseUp(with e: NSEvent) {
        let t = time(atX: point(e).x)
        switch drag {
        case .pending: onTap(t)
        case .scrub: onScrub(.ended, t)
        case .loopStart, .loopEnd: finishLoop(newLoop: false)
        case .newLoop:
            // A click without a loop drawn (Beats, or Option-click) still jumps there.
            if preview != nil { finishLoop(newLoop: true) } else { drawAnchor = nil; onTap(t) }
        case nil: break
        }
        drag = nil
        hover(e)
    }

    override func mouseMoved(with e: NSEvent) { hover(e) }
    override func mouseExited(with e: NSEvent) { onHover(nil, 0) }

    override func cursorUpdate(with e: NSEvent) {
        if loopEdge(near: point(e).x) != nil { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
    }

    private func hover(_ e: NSEvent) {
        let x = point(e).x
        guard drag == nil, bounds.width > 0, x >= 0, x <= bounds.width else { return onHover(nil, 0) }
        if loopEdge(near: x) != nil { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
        onHover(time(atX: x), x)
    }

    private func showPreview(_ r: ClosedRange<Double>) {
        guard r != preview else { return }
        preview = r
        applyConfig()
        onLoopPreview(r)
    }

    private func finishLoop(newLoop: Bool) {
        let r = preview
        preview = nil
        drawAnchor = nil
        if let r { onLoopEnd(.committed(r, newLoop: newLoop)) }
        applyConfig()
    }

    /// True for the loop start, false for the end, nil when `x` is not within an edge's zone.
    private func loopEdge(near x: CGFloat) -> Bool? {
        guard let r = loopRange, duration > 0, bounds.width > 0 else { return nil }
        let a = visible.x(r.lowerBound, width: bounds.width), b = visible.x(r.upperBound, width: bounds.width)
        let da = abs(x - a), db = abs(x - b)
        guard min(da, db) < Self.loopEdgeTolerance else { return nil }
        return da <= db
    }
}

/// Puts a `MapView` in SwiftUI. The handlers call `AppModel` directly, never SwiftUI state (except the hover
/// readout, which only changes while the pointer moves over the Map without a button down).
struct MapRepresentable: NSViewRepresentable {
    var config: WaveformConfig
    var duration: Double
    var loopRange: ClosedRange<Double>?
    var visible: MapWindow
    var plainDragDrawsLoop: Bool
    let model: AppModel
    var onHover: (Double?, CGFloat) -> Void

    func makeNSView(context: Context) -> MapView {
        let view = MapView(frame: .zero)
        apply(to: view)
        return view
    }

    func updateNSView(_ view: MapView, context: Context) { apply(to: view) }

    private func apply(to view: MapView) {
        view.config = config
        view.duration = duration
        view.loopRange = loopRange
        view.plainDragDrawsLoop = plainDragDrawsLoop
        // The model's window, unless a pinch or scroll is moving the view right now.
        if !view.zooming { view.visible = visible }
        view.onHover = onHover
        view.onWindow = { [weak model] w, active in
            guard let model else { return }
            model.mapGestureActive = active
            if model.mapWindow != w { model.mapWindow = w }
        }
        view.onScrub = { [weak model] phase, t in
            guard let model else { return }
            switch phase {
            case .began: model.beginScrub(t)
            case .changed: model.updateScrub(t)
            case .ended: model.endScrub(t)
            }
        }
        view.onTap = { [weak model] t in model?.tapMap(t) }
        view.snap = { [weak model] t in
            guard let model else { return t }
            return model.mode == .beats ? model.snapToBarLine(t) : model.snapToBeat(t)
        }
        view.onLoopPreview = { [weak model] r in model?.previewLoop(r) }
        view.onLoopEnd = { [weak model] end in
            switch end {
            case .committed(let r, let newLoop): model?.commitLoop(r, seekToStart: newLoop)
            case .cancelled: model?.cancelLoopPreview()
            }
        }
    }
}
