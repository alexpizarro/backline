import BacklineKit
import SwiftUI

/// Design tokens from the Backline handoff (dark appearance only).
enum Theme {
    // Surfaces / ink
    static let bg = Color(hex: 0x0F0F14)
    static let chrome = Color(hex: 0x13131B)
    static let elevated = Color(hex: 0x181824)
    static let card = Color(hex: 0x1F1F2C)
    static let cardHover = Color(hex: 0x262636)
    static let inset = Color(hex: 0x15151E)
    static let toggleOff = Color(hex: 0x2E2E40)
    static let ink = Color(hex: 0xF4F4F5)
    static let ink2 = Color(hex: 0xD4D4D8)
    static let muted = Color(hex: 0x8B8B9E)
    static let hairline = Color.white.opacity(0.06)
    static let hairline2 = Color.white.opacity(0.08)
    static let hairline3 = Color.white.opacity(0.10)
    static let inaudibleBar = Color(hex: 0x3A3A4C)

    // Accent
    static let primary = Color(hex: 0x6E56CF)
    static let primaryHover = Color(hex: 0x7C66D9)
    static let primaryTint = Color(hex: 0xA594F0)
    static let magenta = Color(hex: 0xD946EF)
    static let magentaText = Color(hex: 0xF0ABFC)

    // Status
    static let success = Color(hex: 0x22C55E)
    static let warning = Color(hex: 0xF59E0B)
    static let danger = Color(hex: 0xEF4444)

    /// `oklch(0.72 0.15 hue)` → sRGB.
    static func stemColor(hue: Double) -> Color {
        let (r, g, b) = oklchToSRGB(l: 0.72, c: 0.15, h: hue)
        return Color(.sRGB, red: r, green: g, blue: b)
    }

    static func oklchToSRGB(l: Double, c: Double, h: Double) -> (Double, Double, Double) {
        let hr = h * .pi / 180
        let a = c * cos(hr), b = c * sin(hr)
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let L = l_ * l_ * l_, M = m_ * m_ * m_, S = s_ * s_ * s_
        let rl = 4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S
        let gl = -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S
        let bl = -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S
        func gamma(_ x: Double) -> Double {
            let v = max(0, min(1, x))
            return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        return (gamma(rl), gamma(gl), gamma(bl))
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

// MARK: - Type

enum Typo {
    static let uiFamily = "Plus Jakarta Sans"
    static let monoFamily = "JetBrains Mono"

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(uiFamily, fixedSize: size).weight(weight)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(monoFamily, fixedSize: size).weight(weight).monospacedDigit()
    }
}

// MARK: - Reusable styles

/// Secondary button: card bg, hairline border, hover lift.
struct SecondaryButtonStyle: ButtonStyle {
    var padding = EdgeInsets(top: 8, leading: 13, bottom: 8, trailing: 13)
    func makeBody(configuration: Configuration) -> some View {
        SecondaryButtonBody(configuration: configuration, padding: padding)
    }
    private struct SecondaryButtonBody: View {
        let configuration: Configuration
        let padding: EdgeInsets
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(Typo.ui(13, .semibold))
                .foregroundStyle(Theme.ink)
                .padding(padding)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hover || configuration.isPressed ? Theme.cardHover : Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline3))
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .opacity(enabled ? 1 : 0.45)
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: hover)
                .contentShape(Rectangle())
        }
    }
}

/// Primary button: violet fill.
struct PrimaryButtonStyle: ButtonStyle {
    var padding = EdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16)
    func makeBody(configuration: Configuration) -> some View {
        PrimaryBody(configuration: configuration, padding: padding)
    }
    private struct PrimaryBody: View {
        let configuration: Configuration
        let padding: EdgeInsets
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(Typo.ui(13, .semibold))
                .foregroundStyle(.white)
                .padding(padding)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hover || configuration.isPressed ? Theme.primaryHover : Theme.primary))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom)))
                .shadow(color: Theme.primary.opacity(hover ? 0.45 : 0.25), radius: hover ? 12 : 6, y: 2)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: hover)
                .contentShape(Rectangle())
        }
    }
}

extension View {
    /// Pointing-hand cursor on hover (macOS).
    func pointerCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Responsive layout

/// Smallest main window. Below this the transport bar (even in its most compact form) and the stem
/// rows no longer fit, and controls get clipped — so the window simply can't be made smaller.
/// Anyone who wants Backline smaller uses the mini player instead.
enum WindowLimits {
    static let minContentWidth: CGFloat = 760
    static let minHeight: CGFloat = 640
    static let sidebarWidth: CGFloat = 220
    /// The library only shows when the mixer still gets its full minimum width next to it.
    static let sidebarThreshold: CGFloat = minContentWidth + sidebarWidth
}

/// Layout density derived from the content width.
enum LayoutWidth: Int, Comparable {
    case compact = 0     // < 760 pt: waveforms hidden in stem rows, short labels
    case regular = 1     // < 1000 pt
    case wide = 2

    init(width: CGFloat) {
        self = width < 760 ? .compact : (width < 1000 ? .regular : .wide)
    }
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

private struct LayoutWidthKey: EnvironmentKey { static let defaultValue: LayoutWidth = .wide }
extension EnvironmentValues {
    var layoutWidth: LayoutWidth {
        get { self[LayoutWidthKey.self] }
        set { self[LayoutWidthKey.self] = newValue }
    }
}

// MARK: - Glass with accessibility fallback

/// Liquid Glass surface that falls back to a solid, high-contrast fill when the user has
/// Reduce Transparency on (and in debug snapshot runs, which cannot capture compositor glass).
struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    var tint: Color? = nil
    var fallback: Color = Theme.chrome
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency || GlassSurfaceOverride.forceSolid {
            content.background(shape.fill(fallback))
        } else if #available(macOS 26.0, *) {
            let glass: Glass = tint.map { Glass.regular.tint($0) } ?? .regular
            content.glassEffect(interactive ? glass.interactive() : glass, in: shape)
        } else {
            // macOS 15: frosted material with the same tint.
            content.background(shape.fill(.ultraThinMaterial))
                .background(shape.fill((tint ?? fallback).opacity(tint == nil ? 0.55 : 0.35)))
        }
    }
}

enum GlassSurfaceOverride {
    /// Debug snapshot runs force the solid fallback so captures show the real layout.
    nonisolated(unsafe) static var forceSolid = CommandLine.arguments.contains("--solid-glass")
}

extension View {
    func glassSurface<S: Shape>(_ shape: S, tint: Color? = nil, fallback: Color = Theme.chrome, interactive: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint, fallback: fallback, interactive: interactive))
    }
}
