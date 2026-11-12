import AppKit
import BacklineKit
import QuartzCore

/// One display link for every waveform on screen (and the Stage light). It runs only while something needs frames
/// (playing, a bar morph, a drag) and only while one of its views is on screen: a closed, minimised, hidden or fully
/// covered window lets it sleep, and it wakes when the window shows again. It asks the transport clock for the
/// playhead once per frame, so SwiftUI is never invalidated by it.
///
/// Ported from backline-ios Backline/Metal/WaveformScheduler.swift. The Mac's link comes from a view on screen
/// (`NSView.displayLink`, so it follows that screen's refresh rate) instead of `CADisplayLink(target:)`, and
/// "on screen" is the window's visibility and occlusion instead of the app's state.
@MainActor
final class WaveformScheduler {
    static let shared = WaveformScheduler()

    var clock: TransportClock?
    /// Where the master level comes from (the playhead's glow follows it in the dark look).
    weak var engine: PlaybackEngine?
    /// The master level, 0…1 on a loudness scale, eased 60 ms up and 350 ms down; 0 when paused.
    private(set) var masterLevel: Float = 0
    private var lastLevelTime: CFTimeInterval = 0
    private var levelScratch: [Float] = []
    private let views = NSHashTable<WaveformMetalView>.weakObjects()
    private let lights = NSHashTable<StageLightMetalView>.weakObjects()
    private var link: CADisplayLink?
    private weak var linkHost: NSView?
    private var linkFast = false
    private(set) var latest = TransportClock.Sample(time: 0, playing: false)
    private var observers: [NSObjectProtocol] = []

    var isPlaying = false { didSet { if isPlaying != oldValue { kick() } } }

    private init() {
        // A window that shows again (un-minimised, uncovered, the app unhidden) wakes the link.
        let nc = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didDeminiaturizeNotification,
                     NSApplication.didUnhideNotification, NSWindow.didChangeScreenNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { WaveformScheduler.shared.kick() }
            })
        }
    }

    func register(_ view: WaveformMetalView) { views.add(view); kick() }
    func unregister(_ view: WaveformMetalView) { views.remove(view) }
    func register(_ light: StageLightMetalView) { lights.add(light); kick() }
    func unregister(_ light: StageLightMetalView) { lights.remove(light) }

    /// True when a view can be seen: in a visible, unminimised window that isn't fully covered, in an app that
    /// isn't hidden.
    static func isOnScreen(_ view: NSView) -> Bool {
        guard let window = view.window, window.isVisible, !window.isMiniaturized,
              window.occlusionState.contains(.visible), !view.isHiddenOrHasHiddenAncestor else { return false }
        return !NSApp.isHidden
    }

    /// The display link runs (tests).
    var isRunning: Bool { link.map { !$0.isPaused } ?? false }

    /// A view has something to draw: make sure frames are coming.
    func kick() {
        let hosts: [NSView] = views.allObjects + lights.allObjects
        if link == nil || linkHost.map({ !Self.isOnScreen($0) }) ?? true {
            link?.invalidate()
            link = nil
            linkHost = nil
            // A link needs a view on screen to follow; with none, there is nothing to draw.
            guard let host = hosts.first(where: Self.isOnScreen) else { return }
            let l = host.displayLink(target: LinkTarget { [weak self] link in self?.tick(link) },
                                     selector: #selector(LinkTarget.fire(_:)))
            l.add(to: .main, forMode: .common)
            link = l
            linkHost = host
            linkFast = !(clock?.isOverriding ?? false)      // forces the first rate set below
        }
        setRate()
        if link?.isPaused == true { link?.isPaused = false }
    }

    /// 120 Hz under a dragging pointer, 60 otherwise, 30 at most in Low Power Mode: the playhead of a song moves a
    /// few points a second, and only the pointer needs the display's full rate.
    private func setRate() {
        guard let link else { return }
        let fast = clock?.isOverriding ?? false
        guard fast != linkFast else { return }
        linkFast = fast
        let low = ProcessInfo.processInfo.isLowPowerModeEnabled
        link.preferredFrameRateRange = low ? CAFrameRateRange(minimum: 30, maximum: 60, preferred: 30)
            : CAFrameRateRange(minimum: 30, maximum: 120, preferred: fast ? 120 : 60)
    }

    private func tick(_ link: CADisplayLink) {
        if !step(now: link.targetTimestamp) { link.isPaused = true }
    }

    /// One frame. Returns false when no more frames are needed (the link then sleeps).
    @discardableResult
    func step(now: CFTimeInterval) -> Bool {
        if let clock { latest = clock.sample(hostTime: now) }
        updateMasterLevel(now: now)
        setRate()
        var onScreen = false
        // An optimistic playhead (a pointer, or a seek the engine hasn't reached yet) needs frames too.
        var wantsMore = latest.playing || (clock?.isOverriding ?? false)
        for view in views.allObjects where Self.isOnScreen(view) {
            onScreen = true
            if view.render(sample: latest) { wantsMore = true }
        }
        for light in lights.allObjects where Self.isOnScreen(light) {
            onScreen = true
            if light.render(playing: latest.playing, now: now) { wantsMore = true }
        }
        // Nothing can be seen: sleep until a window shows again (the notifications above wake it).
        return wantsMore && onScreen
    }

    private func updateMasterLevel(now: CFTimeInterval) {
        let dt = Float(min(0.1, max(0, now - lastLevelTime)))
        lastLevelTime = now
        let target = latest.playing ? StageLightMetalView.level(rms: engine?.levels(into: &levelScratch) ?? 0) : 0
        let tau: Float = target > masterLevel ? 0.06 : 0.35
        masterLevel += (target - masterLevel) * (1 - exp(-dt / tau))
    }

    #if DEBUG
    /// The harness's account of the Metal views: how many, whether each can be seen, frames drawn.
    func debugReport() -> String {
        func describe(_ v: NSView, _ frames: Int) -> String {
            let w = v.window
            return "\(type(of: v)) \(Int(v.bounds.width))x\(Int(v.bounds.height)) onScreen=\(Self.isOnScreen(v)) frames=\(frames)"
                + " window(visible=\(w?.isVisible ?? false) occluded=\(!(w?.occlusionState.contains(.visible) ?? false)) key=\(w?.isKeyWindow ?? false))"
        }
        var lines = ["link running=\(isRunning) host=\(linkHost.map { "\(type(of: $0))" } ?? "none") app active=\(NSApp.isActive)"]
        lines += views.allObjects.map { describe($0, $0.framesDrawn) }
        lines += lights.allObjects.map { describe($0, $0.framesDrawn) }
        return lines.joined(separator: "\n")
    }
    #endif

    /// Display links retain their target; this keeps the scheduler weakly referenced.
    private final class LinkTarget: NSObject {
        let handler: (CADisplayLink) -> Void
        init(_ handler: @escaping (CADisplayLink) -> Void) { self.handler = handler }
        @objc func fire(_ link: CADisplayLink) { handler(link) }
    }
}
