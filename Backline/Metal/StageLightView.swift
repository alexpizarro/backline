import AppKit
import BacklineKit
import Metal
import QuartzCore
import SwiftUI
import Synchronization

/// What the Stage light shows (2.8): one lamp per part in the main list, its colour, whether it is on, and
/// which engine tracks feed it.
struct StageLightConfig: Equatable {
    struct Lamp: Equatable {
        /// Straight-alpha RGB: the part's dark-look colour mixed 60 % toward the accent.
        var color: SIMD4<Float>
        var on: Bool
        /// Indices into the engine's loaded tracks (a row can be several, like a split kit).
        var tracks: [Int]
    }
    var lamps: [Lamp] = []
    /// False (Reduce Motion): one still frame, redrawn only when a part is switched.
    var live = true

    /// `a` mixed `t` of the way toward `b` (the Stage light only shines in the dark look, so both are dark-look
    /// colours already).
    static func mix(_ a: Color, _ b: Color, _ t: Float) -> SIMD4<Float> {
        let x = SnapshotFrame.rgba(a), y = SnapshotFrame.rgba(b)
        var m = x + (y - x) * t
        m.w = 1
        return m
    }
}

/// The Stage light layer (2.8): a Metal layer behind the parts list in the dark look. Each part in the main list
/// is a soft lamp just above the top edge, `0.06 + 0.30 × level` bright while it is on and dark when it is off;
/// a floor glow behind the transport follows the master. 1 pixel per point, 30 frames a second while playing from
/// the shared scheduler, one still frame otherwise. Still in Low Power Mode and with Reduce Motion; off while the
/// window can't be seen (the scheduler skips it).
///
/// Ported from backline-ios Backline/Metal/StageLightView.swift (an `NSView` with a `CAMetalLayer`).
final class StageLightMetalView: NSView {
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private let gate = FrameGate()
    private let context: MetalContext?

    weak var engine: PlaybackEngine?
    var config = StageLightConfig() {
        didSet {
            guard config != oldValue else { return }
            if smoothed.count != config.lamps.count { smoothed = [Float](repeating: 0, count: config.lamps.count) }
            requestRender()
        }
    }

    private var levels = [Float](repeating: 0, count: 12)
    private var smoothed: [Float] = []
    private var master: Float = 0
    private var lastDraw: CFTimeInterval = 0
    private var lastStep: CFTimeInterval = 0
    private var dirty = true
    private var wasLive = false
    #if DEBUG
    /// Frames drawn (tests).
    private(set) var framesDrawn = 0
    #endif

    /// The accent, for the floor glow (dark look).
    private static var floorColor: SIMD4<Float> { SnapshotFrame.rgba(BacklineColors.dark.accent) }
    /// RMS to a 0…1 level on a loudness scale: −40 dBFS and below is 0, −6 dBFS is 1.
    nonisolated static func level(rms: Float) -> Float {
        guard rms > 1e-5 else { return 0 }
        return min(1, max(0, (20 * log10(rms) + 40) / 34))
    }
    private static let attack: Float = 0.06, release: Float = 0.35

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
        l.contentsScale = 1
        l.maximumDrawableCount = 3
        l.allowsNextDrawableTimeout = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { CAMetalLayer() }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            WaveformScheduler.shared.register(self)
            requestRender()
        } else {
            WaveformScheduler.shared.unregister(self)
        }
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
        metalLayer.contentsScale = 1
        let size = CGSize(width: max(1, bounds.width.rounded()), height: max(1, bounds.height.rounded()))
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
            requestRender()
        }
    }

    private func requestRender() {
        dirty = true
        WaveformScheduler.shared.kick()
    }

    /// Called by the scheduler on every display frame. Returns true while it wants more frames.
    func render(playing: Bool, now: CFTimeInterval) -> Bool {
        guard let context, let pipeline = context.stagePipeline, bounds.width > 1, bounds.height > 1 else { return false }
        let live = playing && config.live && !ProcessInfo.processInfo.isLowPowerModeEnabled
        // Still: draw once (and once more on the way out of playing), then sleep.
        if !live && !dirty && !wasLive { return false }
        // Live: 30 frames a second is plenty for light this soft.
        if live && now - lastDraw < 1.0 / 30 - 0.004 { return true }
        if gate.inFlight.load(ordering: .relaxed) >= 2 { return true }

        if live { advance(now: now) } else { rest() }

        guard let drawable = metalLayer.nextDrawable(), let commands = context.queue.makeCommandBuffer(),
              encode(into: drawable.texture, commands: commands, pipeline: pipeline, now: now) else { return live }
        let snapshot = SnapshotFrame.enabled ? SnapshotFrame.encodeCopy(drawable.texture, into: commands, device: context.device) : nil
        commands.present(drawable)
        gate.inFlight.add(1, ordering: .relaxed)
        commands.addCompletedHandler(gate.completion())
        #if DEBUG
        if StageLightTiming.shared.enabled { commands.addCompletedHandler(StageLightTiming.shared.handler()) }
        framesDrawn += 1
        #endif
        commands.commit()
        if let snapshot { snapshotLayer.show(SnapshotFrame.image(of: snapshot, after: commands), in: metalLayer) }
        dirty = false
        wasLive = live
        lastDraw = now
        return live
    }

    /// Encodes one frame of the lamps and the floor glow into `texture` (the drawable, or the render test's own).
    private func encode(into texture: MTLTexture, commands: MTLCommandBuffer, pipeline: MTLRenderPipelineState,
                        now: CFTimeInterval) -> Bool {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(pipeline)
        let n = config.lamps.count
        var lamps = (0..<max(1, n)).map { i -> StageLamp in
            guard i < n else { return StageLamp(geom: .zero, color: .zero) }
            let lamp = config.lamps[i]
            let x = (Float(i) + 0.5) / Float(n)
            let intensity: Float = lamp.on ? 0.06 + 0.30 * smoothed[i] : 0
            return StageLamp(geom: SIMD4(x, -0.15, 0.45, 0.55), color: SIMD4(lamp.color.x, lamp.color.y, lamp.color.z, intensity))
        }
        var uniforms = StageUniforms(size: SIMD2(Float(texture.width), Float(texture.height)),
                                     time: Float(now.truncatingRemainder(dividingBy: 1000)),
                                     floorGlow: 0.04 + 0.12 * master, floorColor: Self.floorColor,
                                     lampCount: UInt32(n), grain: 0.025)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<StageUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&lamps, length: MemoryLayout<StageLamp>.stride * lamps.count, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    /// The still frame (lamps at rest), drawn into a texture of its own and read back: the render test, with
    /// no window, display link or screen. Nil when there is no GPU or no size.
    func renderOffscreen() -> CGImage? {
        guard let context, let pipeline = context.stagePipeline, bounds.width > 1, bounds.height > 1 else { return nil }
        rest()
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(bounds.width.rounded()),
                                                         height: Int(bounds.height.rounded()), mipmapped: false)
        d.usage = .renderTarget
        d.storageMode = .private
        guard let texture = context.device.makeTexture(descriptor: d), let commands = context.queue.makeCommandBuffer(),
              encode(into: texture, commands: commands, pipeline: pipeline, now: CACurrentMediaTime()),
              let copy = SnapshotFrame.encodeCopy(texture, into: commands, device: context.device) else { return nil }
        commands.commit()
        return SnapshotFrame.image(of: copy, after: commands)
    }

    /// The snapshot harness renders windows through the layer tree, which never sees a Metal layer's frames:
    /// there, the last frame is also shown as an ordinary image layer on top.
    private let snapshotLayer = SnapshotLayer()

    /// Reads the engine's levels and eases each lamp toward them (attack 60 ms, release 350 ms).
    private func advance(now: CFTimeInterval) {
        let dt = Float(min(0.1, max(0, now - lastStep)))
        lastStep = now
        let m = engine?.levels(into: &levels) ?? 0
        func ease(_ current: Float, _ target: Float) -> Float {
            let tau = target > current ? Self.attack : Self.release
            return current + (target - current) * (1 - exp(-dt / tau))
        }
        for (i, lamp) in config.lamps.enumerated() where i < smoothed.count {
            let rms = sqrt(lamp.tracks.reduce(Float(0)) { $0 + ($1 < levels.count ? levels[$1] * levels[$1] : 0) })
            smoothed[i] = ease(smoothed[i], lamp.on ? Self.level(rms: rms) : 0)
        }
        master = ease(master, Self.level(rms: m))
    }

    /// Paused or still: the lamps at rest (on parts glow faintly, off parts are dark).
    private func rest() {
        for i in smoothed.indices { smoothed[i] = 0 }
        master = 0
        lastStep = CACurrentMediaTime()
    }
}

/// SwiftUI wrapper; the light never takes clicks and VoiceOver never sees it.
struct StageLight: NSViewRepresentable {
    let engine: PlaybackEngine
    var config: StageLightConfig

    func makeNSView(context: Context) -> StageLightMetalView {
        let v = StageLightMetalView(frame: .zero)
        v.engine = engine
        v.config = config
        return v
    }

    func updateNSView(_ view: StageLightMetalView, context: Context) {
        view.engine = engine
        view.config = config
    }
}

#if DEBUG
/// `--stagelight-timing`: prints the layer's average and worst GPU time every 120 frames.
nonisolated final class StageLightTiming: Sendable {
    static let shared = StageLightTiming()
    let enabled = CommandLine.arguments.contains("--stagelight-timing")
    private let acc = Mutex<(total: Double, worst: Double, count: Int)>((0, 0, 0))

    func handler() -> MTLCommandBufferHandler {
        { [self] cb in
            let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            guard ms > 0 else { return }
            let report: (Double, Double)? = acc.withLock { a in
                a.total += ms; a.worst = max(a.worst, ms); a.count += 1
                guard a.count >= 120 else { return nil }
                defer { a = (0, 0, 0) }
                return (a.total / Double(a.count), a.worst)
            }
            if let (avg, worst) = report { print(String(format: "[stagelight] GPU %.3f ms average, %.3f ms worst (120 frames)", avg, worst)) }
        }
    }
}
#endif
