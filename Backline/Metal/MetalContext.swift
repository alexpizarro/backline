import Metal
import QuartzCore

/// The GPU objects every Metal view shares: one device, one queue, the waveform pipeline and the Stage
/// light's (nil if it fails to build, so a problem there never takes the waveforms with it).
@MainActor
final class MetalContext {
    static let shared: MetalContext? = MetalContext()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let stagePipeline: MTLRenderPipelineState?

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "rectVertex"),
              let fragment = library.makeFunction(name: "rectFragment") else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.label = "Backline waveform"
        d.vertexFunction = vertex
        d.fragmentFunction = fragment
        let a = d.colorAttachments[0]!
        a.pixelFormat = .bgra8Unorm
        a.isBlendingEnabled = true
        // Premultiplied alpha.
        a.sourceRGBBlendFactor = .one
        a.destinationRGBBlendFactor = .oneMinusSourceAlpha
        a.sourceAlphaBlendFactor = .one
        a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let state = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = state
        // Stage light: one full-screen triangle written once per pixel, so no blending.
        if let v = library.makeFunction(name: "stageVertex"), let f = library.makeFunction(name: "stageFragment") {
            let s = MTLRenderPipelineDescriptor()
            s.label = "Backline stage light"
            s.vertexFunction = v
            s.fragmentFunction = f
            s.colorAttachments[0].pixelFormat = .bgra8Unorm
            stagePipeline = try? device.makeRenderPipelineState(descriptor: s)
        } else {
            stagePipeline = nil
        }
    }
}

/// Matches `Rect` in Waveform.metal (four float4s).
struct RectInstance {
    var frame: SIMD4<Float>
    var colorA: SIMD4<Float>
    var colorB: SIMD4<Float>
    var params: SIMD4<Float>
}

/// Matches `Uniforms` in Waveform.metal.
struct WaveformUniforms {
    var viewSize: SIMD2<Float>
    var playheadX: Float
    var scale: Float
}

/// Matches `StageUniforms` in StageLight.metal (48 bytes).
struct StageUniforms {
    var size: SIMD2<Float>
    var time: Float
    var floorGlow: Float
    var floorColor: SIMD4<Float>
    var lampCount: UInt32
    var grain: Float
    var pad = SIMD2<Float>(0, 0)
}

/// Matches `Lamp` in StageLight.metal: centre and radius as fractions of the view, colour and intensity.
struct StageLamp {
    var geom: SIMD4<Float>
    var color: SIMD4<Float>
}
