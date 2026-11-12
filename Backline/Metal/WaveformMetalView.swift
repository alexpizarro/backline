import AppKit
import Metal
import QuartzCore
import SwiftUI
import Synchronization

/// Frames a view has handed to the GPU and not yet seen finish. `nextDrawable()` blocks the main thread when
/// every drawable is still in flight (up to a second while a background pass keeps the GPU busy), so a view
/// with two frames in flight skips the frame instead of waiting.
nonisolated final class FrameGate: Sendable {
    let inFlight = Atomic<Int>(0)

    /// Made outside the main actor: Metal calls it on its own thread, where a main-actor closure would trap.
    func completion() -> MTLCommandBufferHandler {
        { [self] _ in inFlight.subtract(1, ordering: .relaxed) }
    }
}

/// Everything a waveform draws. Value type: SwiftUI hands a new one in whenever the data changes and
/// the view re-uploads geometry only if it differs.
///
/// Ported from backline-ios Backline/Metal/WaveformMetalView.swift. Colours are the Mac palette's fixed
/// `Color`s (the palette is chosen per look at the root), so a new look arrives as a new config.
struct WaveformConfig: Equatable {
    /// Peaks or bar heights (any length; they are resampled to the view's width).
    var values: [Float] = []
    /// Per-part normalisation with a gentle curve so quiet parts are still readable.
    var normalize = false
    var barColor = Theme.tokens.waveIdle
    /// When set, bars the playhead has passed take this colour (the overview); otherwise bars are one colour.
    var playedColor: Color?
    var barAlpha: CGFloat = 1
    var minBarHeight: CGFloat = 3
    /// Bar width plus gap, in points; the bar count follows the view's width.
    var barPitch: CGFloat = 4
    var gap: CGFloat = 2
    /// Space above and below the bars (the playhead and loop handles use it).
    var verticalInset: CGFloat = 0
    var loop: ClosedRange<Double>?
    var loopFill = Theme.tokens.loopFill
    var loopEdge = Theme.tokens.loopEdge
    var showLoopHandles = false
    var grid: [Double] = []
    var gridColor = Theme.tokens.ink
    var gridAlpha: CGFloat = 0.07
    var duration: Double = 1
    var showPlayhead = true
    var playheadColor = Theme.tokens.playhead
    /// Dark look; the light look draws at most 2 pt and never glows (3.4).
    var playheadWidth: CGFloat = 2
    var glow: CGFloat = 0.5
    /// The Map (3.4): bars inside the loop take this colour, played or not.
    var litColor: Color?
    /// The Map: a 12 pt knob at the top of the playhead.
    var playheadKnob = false
    /// The Map: in the dark look the glow follows the master level, 0.4 → 0.8 (2.8).
    var glowFollowsLevel = false
    /// The Map (U07): the part of the song on screen; nil is the whole song. `values` always cover the
    /// whole song.
    var visible: MapWindow?
    /// The look the colours belong to (the playhead's glow and width depend on it).
    var dark = true
}

/// A `CAMetalLayer`-backed view that draws a waveform through `Waveform.metal`. It is redrawn by the
/// shared `WaveformScheduler`, and only when something visible changed (a new data set, a morph, or the
/// playhead crossing a device pixel).
final class WaveformMetalView: NSView {
    private let gate = FrameGate()
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    var config = WaveformConfig() {
        didSet { if config != oldValue { configChanged(from: oldValue) } }
    }

    private let context: MetalContext?
    private var staticBuffer: MTLBuffer?
    private var staticCount = 0
    private var dirty = true
    private var targetHeights: [Float] = []
    private var shownHeights: [Float] = []
    private var morphFrom: [Float] = []
    private var morphStart: CFTimeInterval = 0
    private var morphing = false
    private var lastPlayheadPixel: CGFloat = -1
    private var lastGlow: Float = -1
    /// A zoom or pan changes the bars instantly; only a new data set morphs.
    private var skipMorph = false
    private var lastSize = CGSize.zero
    private static let morphDuration: CFTimeInterval = 0.25
    #if DEBUG
    /// Frames drawn (tests).
    private(set) var framesDrawn = 0
    #endif

    override init(frame: CGRect) {
        context = MetalContext.shared
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        let l = metalLayer
        l.device = context?.device
        l.pixelFormat = .bgra8Unorm
        l.framebufferOnly = !SnapshotFrame.enabled
        l.isOpaque = false
        l.maximumDrawableCount = 3
        l.allowsNextDrawableTimeout = true
        l.backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { CAMetalLayer() }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    /// Interaction is layered on top (the Map's own view, or SwiftUI).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            WaveformScheduler.shared.register(self)
            resize()
            requestRender()
        } else {
            WaveformScheduler.shared.unregister(self)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        resize()
    }

    override func layout() {
        super.layout()
        resize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resize()
    }

    private func resize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
        if bounds.size != lastSize {
            lastSize = bounds.size
            targetHeights = []          // the bar count depends on the width
            morphing = false
            requestRender()
        }
    }

    // MARK: Data

    private func configChanged(from old: WaveformConfig) {
        let moved = old.visible != config.visible
        let dataChanged = old.values != config.values || old.normalize != config.normalize || moved
        if moved { skipMorph = true }
        if dataChanged { targetHeights = [] }
        dirty = true
        requestRender()
    }

    private func requestRender() {
        dirty = true
        WaveformScheduler.shared.kick()
    }

    private func resolveHeights() {
        guard bounds.width > 0 else { return }
        let count = max(20, Int(bounds.width / config.barPitch))
        var heights = config.visible.map { $0.bars(config.values, count: count) } ?? Self.resample(config.values, to: count)
        if config.normalize {
            let m = max(heights.max() ?? 1, 1e-6)
            heights = heights.map { powf($0 / m, 0.8) }
        }
        if heights == targetHeights { return }
        let previous = shownHeights
        targetHeights = heights
        let morph = !skipMorph
        skipMorph = false
        if morph, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, previous.count == heights.count,
           !previous.isEmpty, window != nil {
            morphFrom = previous
            morphStart = CACurrentMediaTime()
            morphing = true
        } else {
            shownHeights = heights
            morphing = false
        }
    }

    static func resample(_ p: [Float], to count: Int) -> [Float] {
        guard count > 0, !p.isEmpty else { return [Float](repeating: 0, count: max(0, count)) }
        return (0..<count).map { i in
            let s = i * p.count / count, e = max(s + 1, (i + 1) * p.count / count)
            return p[s..<min(e, p.count)].max() ?? 0
        }
    }

    // MARK: Drawing

    /// Draws one frame if needed. Returns true while more frames are needed (a morph in progress).
    @discardableResult
    func render(sample: TransportClock.Sample) -> Bool {
        guard let context, bounds.width > 1, bounds.height > 1 else { return false }
        if targetHeights.isEmpty || dirty { resolveHeights() }

        var morphT: Float = 1
        if morphing {
            let t = Float(min(1, (CACurrentMediaTime() - morphStart) / Self.morphDuration))
            morphT = 1 - pow(1 - t, 3)
            if t >= 1 { morphing = false; shownHeights = targetHeights }
        }
        let scale = metalLayer.contentsScale
        let width = Float(bounds.width), height = Float(bounds.height)
        let playheadX = config.duration > 0 ? (config.visible.map { Float($0.x(sample.time, width: CGFloat(width))) }
                                                ?? Float(max(0, min(1, sample.time / config.duration))) * width) : 0
        let pixel = (CGFloat(playheadX) * scale * 2).rounded()
        let playheadMoved = (config.showPlayhead || config.playedColor != nil) && pixel != lastPlayheadPixel
        let glow = playheadGlow()
        let glowChanged = config.showPlayhead && abs(glow - lastGlow) > 0.02
        guard dirty || morphing || playheadMoved || glowChanged else { return false }
        // The GPU is behind: try again next frame rather than wait for a drawable on the main thread.
        if gate.inFlight.load(ordering: .relaxed) >= 2 { return true }

        if dirty || morphing { rebuildStatic(context: context, morphT: morphT, width: width, height: height) }
        lastPlayheadPixel = pixel
        lastGlow = glow

        guard let drawable = metalLayer.nextDrawable(), let commands = context.queue.makeCommandBuffer() else { return morphing }
        guard encode(into: drawable.texture, commands: commands, context: context, playheadX: playheadX, glow: glow,
                     width: width, height: height, scale: Float(scale)) else { return morphing }
        let snapshot = SnapshotFrame.enabled ? SnapshotFrame.encodeCopy(drawable.texture, into: commands, device: context.device) : nil
        commands.present(drawable)
        gate.inFlight.add(1, ordering: .relaxed)
        commands.addCompletedHandler(gate.completion())
        commands.commit()
        #if DEBUG
        framesDrawn += 1
        #endif
        if let snapshot { snapshotLayer.show(SnapshotFrame.image(of: snapshot, after: commands), in: metalLayer) }
        return morphing
    }

    /// The bars, loop and grid as instances, from the current (or morphing) heights.
    private func rebuildStatic(context: MetalContext, morphT: Float, width: Float, height: Float) {
        var heights = targetHeights
        if morphing, morphFrom.count == targetHeights.count {
            heights = zip(morphFrom, targetHeights).map { $0 + ($1 - $0) * morphT }
            shownHeights = heights
        }
        let instances = buildStatic(heights: heights, width: width, height: height)
        staticCount = instances.count
        staticBuffer = instances.isEmpty ? nil : instances.withUnsafeBytes {
            context.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        dirty = false
    }

    /// Encodes one frame into `texture`: the screen's drawable, or an off-screen texture in the render test.
    private func encode(into texture: MTLTexture, commands: MTLCommandBuffer, context: MetalContext, playheadX: Float,
                        glow: Float, width: Float, height: Float, scale: Float) -> Bool {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(context.pipeline)
        var uniforms = WaveformUniforms(viewSize: SIMD2(width, height), playheadX: playheadX, scale: scale)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<WaveformUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WaveformUniforms>.stride, index: 1)
        if let staticBuffer, staticCount > 0 {
            encoder.setVertexBuffer(staticBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: staticCount)
        }
        if config.showPlayhead, playheadX > -8, playheadX < width + 8 {
            var head = playheadInstances(x: playheadX, height: height, glow: glow)
            encoder.setVertexBytes(&head, length: MemoryLayout<RectInstance>.stride * head.count, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: head.count)
        }
        encoder.endEncoding()
        return true
    }

    /// What the view shows with the playhead at `time`, drawn into a texture of its own and read back (the
    /// render test: no window, no display link, no screen). Nil when there is no GPU or no size.
    func renderOffscreen(time: Double, scale: CGFloat = 2) -> CGImage? {
        guard let context, bounds.width > 1, bounds.height > 1 else { return nil }
        if targetHeights.isEmpty || dirty { resolveHeights() }
        let width = Float(bounds.width), height = Float(bounds.height)
        rebuildStatic(context: context, morphT: 1, width: width, height: height)
        let playheadX = config.duration > 0 ? (config.visible.map { Float($0.x(time, width: bounds.width)) }
                                                ?? Float(max(0, min(1, time / config.duration))) * width) : 0
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(bounds.width * scale),
                                                         height: Int(bounds.height * scale), mipmapped: false)
        d.usage = .renderTarget
        d.storageMode = .private
        guard let texture = context.device.makeTexture(descriptor: d), let commands = context.queue.makeCommandBuffer(),
              encode(into: texture, commands: commands, context: context, playheadX: playheadX, glow: playheadGlow(),
                     width: width, height: height, scale: Float(scale)),
              let copy = SnapshotFrame.encodeCopy(texture, into: commands, device: context.device) else { return nil }
        commands.commit()
        return SnapshotFrame.image(of: copy, after: commands)
    }

    /// The snapshot harness renders windows through the layer tree, which never sees a Metal layer's frames:
    /// there, the last frame is also shown as an ordinary image layer on top.
    private let snapshotLayer = SnapshotLayer()

    /// Resolves a colour, premultiplied for the shader.
    private func premultiplied(_ c: Color, alpha: CGFloat = 1) -> SIMD4<Float> {
        SnapshotFrame.premultiplied(c, alpha: alpha)
    }

    private var isDark: Bool { config.dark }

    /// A time's x in points: through the visible window on the Map, else across the whole song.
    private func timeX(_ t: Double, _ width: Float) -> Float {
        if let v = config.visible { return Float(v.x(t, width: CGFloat(width))) }
        return Float(t / config.duration) * width
    }

    /// The playhead's glow for this frame: none in the light look; in the dark look either fixed or, on the
    /// Map, following the master level (0.4 → 0.8).
    private func playheadGlow() -> Float {
        guard isDark else { return 0 }
        guard config.glowFollowsLevel else { return Float(config.glow) }
        return 0.4 + 0.4 * WaveformScheduler.shared.masterLevel
    }

    /// The beam (2 pt without glow in the light look) and, on the Map, its 12 pt knob at the top.
    private func playheadInstances(x: Float, height: Float, glow: Float) -> [RectInstance] {
        let w = Float(isDark ? config.playheadWidth : min(2, config.playheadWidth))
        let color = premultiplied(config.playheadColor)
        var out = [RectInstance(frame: SIMD4(x - w / 2, 0, w, height), colorA: color, colorB: color * glow,
                                params: SIMD4(w / 2, 0, glow > 0 ? 6 : 0, glow))]
        if config.playheadKnob {
            out.append(RectInstance(frame: SIMD4(x - 6, 0, 12, 12), colorA: color, colorB: color * glow,
                                    params: SIMD4(6, 0, glow > 0 ? 4 : 0, glow * 0.6)))
        }
        return out
    }

    private func buildStatic(heights: [Float], width: Float, height: Float) -> [RectInstance] {
        var out: [RectInstance] = []
        out.reserveCapacity(heights.count + config.grid.count + 6)
        let inset = Float(config.verticalInset)
        let areaH = max(1, height - 2 * inset)

        if let r = config.loop, config.duration > 0 {
            let x0 = timeX(r.lowerBound, width), x1 = timeX(r.upperBound, width)
            let fill = premultiplied(config.loopFill)
            out.append(RectInstance(frame: SIMD4(x0, 0, max(2, x1 - x0), height), colorA: fill, colorB: fill, params: SIMD4(0, 0, 0, 0)))
            let edge = premultiplied(config.loopEdge)
            // An edge outside a zoomed view has no line and no tab (a tab pinned to the side would lie).
            for x in [x0, x1] where x >= -1 && x <= width + 1 {
                out.append(RectInstance(frame: SIMD4(x - 0.75, 0, 1.5, height), colorA: edge, colorB: edge, params: SIMD4(0.75, 0, 0, 0)))
                if config.showLoopHandles {
                    // A strip of spike tape at the top of each edge: the thing the pointer grabs.
                    let tabX = min(max(x - 6, 0), width - 12)    // whole, even at the song's first or last frame
                    out.append(RectInstance(frame: SIMD4(tabX, 0, 12, 20), colorA: edge, colorB: edge, params: SIMD4(3, 0, 0, 0)))
                }
            }
        }

        if !config.grid.isEmpty, config.duration > 0 {
            let line = premultiplied(config.gridColor, alpha: config.gridAlpha)
            var lastX: Float = -.infinity
            for t in config.grid {
                let x = timeX(t, width)
                guard x - lastX >= 5, x >= 0, x <= width else { continue }
                out.append(RectInstance(frame: SIMD4(x, inset, 1, areaH), colorA: line, colorB: line, params: SIMD4(0, 0, 0, 0)))
                lastX = x
            }
        }

        let n = heights.count
        guard n > 0 else { return out }
        let gap = Float(config.gap)
        let barW = max(1, (width - gap * Float(n - 1)) / Float(n))
        let base = premultiplied(config.barColor, alpha: config.barAlpha)
        let played = config.playedColor.map { premultiplied($0, alpha: config.barAlpha) } ?? base
        let follows: Float = config.playedColor == nil ? 0 : 1
        let radius = min(1.2, barW / 2)
        let minH = Float(config.minBarHeight)
        // The Map: bars inside the loop are lit, whether played or not.
        var litX: ClosedRange<Float>?
        var lit = base
        if let c = config.litColor, let r = config.loop, config.duration > 0 {
            litX = timeX(r.lowerBound, width)...max(timeX(r.lowerBound, width), timeX(r.upperBound, width))
            lit = premultiplied(c, alpha: config.barAlpha)
        }
        for (i, v) in heights.enumerated() {
            let h = min(areaH, max(minH, v * areaH))
            let x = Float(i) * (barW + gap)
            let inLoop = litX?.contains(x + barW / 2) ?? false
            out.append(RectInstance(frame: SIMD4(x, inset + (areaH - h) / 2, barW, h),
                                    colorA: inLoop ? lit : base, colorB: inLoop ? lit : played,
                                    params: SIMD4(radius, inLoop ? 0 : follows, 0, 0)))
        }
        return out
    }
}

/// SwiftUI wrapper. Interaction is layered on top.
struct WaveformView: NSViewRepresentable {
    var config: WaveformConfig
    func makeNSView(context: Context) -> WaveformMetalView {
        let v = WaveformMetalView(frame: .zero)
        v.config = config
        return v
    }
    func updateNSView(_ view: WaveformMetalView, context: Context) { view.config = config }
}
