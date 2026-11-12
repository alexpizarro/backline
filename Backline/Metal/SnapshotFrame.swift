import AppKit
import Metal
import SwiftUI

/// Mac-only helpers for the Metal views: colour conversion from the palette's fixed `Color`s, and, in the snapshot
/// harness, a copy of each frame as an image (`cacheDisplay` cannot see a Metal layer).
enum SnapshotFrame {
    /// True in the Debug snapshot harness only.
    static let enabled: Bool = {
        #if DEBUG
        return Snapshotter.outputDir != nil
        #else
        return false
        #endif
    }()

    /// A palette colour in sRGB, premultiplied for the shader.
    static func premultiplied(_ c: Color, alpha: CGFloat = 1) -> SIMD4<Float> {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .white
        let al = Float(ns.alphaComponent * alpha)
        return SIMD4(Float(ns.redComponent) * al, Float(ns.greenComponent) * al, Float(ns.blueComponent) * al, al)
    }

    /// Straight-alpha sRGB components.
    static func rgba(_ c: Color) -> SIMD4<Float> {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .white
        return SIMD4(Float(ns.redComponent), Float(ns.greenComponent), Float(ns.blueComponent), Float(ns.alphaComponent))
    }

    /// Harness only: copies `texture` into a shared buffer in the same command buffer (a drawable's own storage
    /// can't be read from the CPU). Call before `commit`, then `image(of:)` after it.
    static func encodeCopy(_ texture: MTLTexture, into commands: MTLCommandBuffer, device: MTLDevice) -> (MTLBuffer, Int, Int)? {
        let w = texture.width, h = texture.height, row = w * 4
        guard let buffer = device.makeBuffer(length: row * h, options: .storageModeShared),
              let blit = commands.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: row, destinationBytesPerImage: row * h)
        blit.endEncoding()
        return (buffer, w, h)
    }

    /// Waits for `commands` and turns the copied frame (BGRA, premultiplied) into an image.
    static func image(of copy: (MTLBuffer, Int, Int), after commands: MTLCommandBuffer) -> CGImage? {
        commands.waitUntilCompleted()
        let (buffer, w, h) = copy
        let data = Data(bytes: buffer.contents(), count: w * 4 * h)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Harness only: a plain layer holding a copy of a Metal view's last frame.
final class SnapshotLayer {
    private var layer: CALayer?
    func show(_ image: CGImage?, in host: CALayer) {
        guard let image else { return }
        let l = layer ?? CALayer()
        if layer == nil {
            // Follows the view's size between frames, as the Metal layer's own contents do.
            l.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            host.addSublayer(l)
            layer = l
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.frame = host.bounds
        l.contentsGravity = .resize
        l.contents = image
        CATransaction.commit()
    }
}
