// Makes the macOS app icon from the iOS artwork: the same picture, placed in the macOS icon grid
// (824/1024 body, continuous-corner squircle, drop shadow) so it sits correctly beside other Mac apps.
//
// usage: swift scripts/make_icon_from_ios.swift <ios-icon-1024.png> <out.appiconset>
import AppKit
import CoreGraphics
import ImageIO

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: make_icon_from_ios.swift <ios-icon-1024.png> <out.appiconset>")
    exit(2)
}
guard let source = NSImage(contentsOfFile: args[1]),
      let srcCG = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("cannot read \(args[1])")
    exit(1)
}
let outDir = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

/// One icon at `px` points square.
func render(px: Int) -> CGImage? {
    let s = CGFloat(px)
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // macOS icon grid: an 824/1024 body with 100 px margins and a continuous-corner squircle.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = body.width * 0.2237
    let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                  color: CGColor(gray: 0, alpha: 0.45))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // The iOS artwork fills the squircle. It is square, so no cropping maths is needed; the corners are
    // clipped by the shape, which is exactly how Apple's own icons are built.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.draw(srcCG, in: body)
    ctx.restoreGState()

    // A hairline inside the edge: over the dark grille cloth the body would otherwise melt into a dark
    // dock background.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10))
    ctx.setLineWidth(max(1, s * 0.0015))
    ctx.strokePath()
    ctx.restoreGState()

    return ctx.makeImage()
}

let wanted: [(String, Int)] = [
    ("icon_16x16@1x.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32@1x.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128@1x.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256@1x.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512@1x.png", 512), ("icon_512x512@2x.png", 1024),
]

for (name, px) in wanted {
    guard let image = render(px: px) else { print("render failed for \(name)"); exit(1) }
    let url = outDir.appendingPathComponent(name)
    guard let dest = CGImageDestinationCreateWithURL(url as NSURL, "public.png" as CFString, 1, nil) else {
        print("cannot write \(url.path)"); exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}
print("wrote \(wanted.count) icons to \(outDir.path)")
