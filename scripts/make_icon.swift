// Renders the Backline app icon (macOS squircle, layered stem waves, one lifted away) to an iconset.
// usage: swift scripts/make_icon.swift <out.appiconset>
import AppKit
import CoreGraphics

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.appiconset")

func oklch(_ l: Double, _ c: Double, _ h: Double) -> CGColor {
    let hr = h * .pi / 180, a = c * cos(hr), b = c * sin(hr)
    let l_ = l + 0.3963377774 * a + 0.2158037573 * b
    let m_ = l - 0.1055613458 * a - 0.0638541728 * b
    let s_ = l - 0.0894841775 * a - 1.2914855480 * b
    let L = l_ * l_ * l_, M = m_ * m_ * m_, S = s_ * s_ * s_
    func g(_ x: Double) -> CGFloat { let v = max(0, min(1, x)); return CGFloat(v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055) }
    return CGColor(srgbRed: g(4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S),
                   green: g(-1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S),
                   blue: g(-0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S), alpha: 1)
}

func render(size px: Int) -> CGImage {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    // macOS icon grid: 824/1024 body with ~100 px margins and a continuous-corner squircle.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = body.width * 0.2237
    let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.45))
    ctx.addPath(shape); ctx.setFillColor(CGColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    // Background: deep violet → near-black vertical gradient with a soft top glow.
    let bg = CGGradient(colorsSpace: nil, colors: [
        CGColor(srgbRed: 0.16, green: 0.12, blue: 0.30, alpha: 1),
        CGColor(srgbRed: 0.075, green: 0.07, blue: 0.11, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    let glow = CGGradient(colorsSpace: nil, colors: [
        CGColor(srgbRed: 0.43, green: 0.34, blue: 0.81, alpha: 0.55),
        CGColor(srgbRed: 0.43, green: 0.34, blue: 0.81, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: body.midX, y: body.midY + body.height * 0.05), startRadius: 0,
                           endCenter: CGPoint(x: body.midX, y: body.midY + body.height * 0.05), endRadius: body.width * 0.62, options: [])

    // Five stem "lanes" of rounded bars. The guitar lane (magenta) lifts away and fades.
    let hues: [(Double, Bool)] = [(20, false), (330, true), (260, false), (200, false), (150, false)]
    let laneH = body.height * 0.085
    let gap = body.height * 0.045
    let totalH = CGFloat(hues.count) * laneH + CGFloat(hues.count - 1) * gap
    var y = body.midY + totalH / 2 - laneH
    let bars = 17
    let x0 = body.minX + body.width * 0.15, x1 = body.maxX - body.width * 0.15
    let bw = (x1 - x0) / CGFloat(bars) * 0.58
    for (li, (hue, lifted)) in hues.enumerated() {
        let color = oklch(0.74, 0.16, hue)
        let dy: CGFloat = lifted ? body.height * 0.035 : 0
        let dx: CGFloat = lifted ? body.width * 0.035 : 0
        for i in 0..<bars {
            let t = Double(i) / Double(bars - 1)
            let env = 0.35 + 0.65 * pow(sin(.pi * t), 0.8)
            let wig = 0.55 + 0.45 * abs(sin(Double(i) * 1.7 + Double(li) * 2.1))
            let h = laneH * CGFloat(env * wig) * 1.6
            let cx = x0 + (x1 - x0) * CGFloat(t) + dx
            let r = CGRect(x: cx - bw / 2, y: y + laneH / 2 - h / 2 + dy, width: bw, height: h)
            let p = CGPath(roundedRect: r, cornerWidth: bw / 2, cornerHeight: bw / 2, transform: nil)
            ctx.addPath(p)
            ctx.setFillColor(lifted ? color.copy(alpha: 0.95)! : color.copy(alpha: 0.9)!)
            if lifted {
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: s * 0.02, color: color.copy(alpha: 0.9)!)
                ctx.fillPath()
                ctx.restoreGState()
            } else {
                ctx.fillPath()
            }
        }
        if lifted {
            // Dashed "removed" outline where the lane used to sit.
            let lane = CGRect(x: x0 - bw, y: y + laneH * 0.1, width: x1 - x0 + bw * 2, height: laneH * 0.8)
            ctx.setStrokeColor(color.copy(alpha: 0.45)!)
            ctx.setLineWidth(max(1, s * 0.004))
            ctx.setLineDash(phase: 0, lengths: [s * 0.012, s * 0.01])
            ctx.addPath(CGPath(roundedRect: lane, cornerWidth: laneH * 0.4, cornerHeight: laneH * 0.4, transform: nil))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
        y -= laneH + gap
    }

    // Glass highlight: top sheen + hairline rim.
    let sheen = CGGradient(colorsSpace: nil, colors: [
        CGColor(gray: 1, alpha: 0.16), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY + body.height * 0.1), options: [])
    ctx.restoreGState()
    ctx.addPath(shape)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.14))
    ctx.setLineWidth(max(1, s * 0.003))
    ctx.strokePath()
    return ctx.makeImage()!
}

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let img = render(size: base * scale)
        let rep = NSBitmapImageRep(cgImage: img)
        let url = outDir.appendingPathComponent("icon_\(base)x\(base)@\(scale)x.png")
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }
}
print("icons written to", outDir.path)
