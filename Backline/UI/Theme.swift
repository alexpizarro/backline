import BacklineKit
import SwiftUI

/// Design tokens (the Soundcheck palette). Every value comes from `BacklineColors`, generated from
/// `docs/design/tokens.json` — the same file the iOS app builds its colour sets from — so the Mac now
/// follows the chosen look and Increase Contrast instead of being dark-only.
///
/// The names below are the Mac's own (`bg`, `card`, `muted`…) kept so every view reads one vocabulary;
/// `Theme.tokens` is the palette for the current look, and each name maps to a token.
enum Theme {
    /// The palette for the current look. Set once at the root by `ChosenLook` (and by the snapshot
    /// harness), so views draw the same look wherever they are.
    static var tokens: BacklineColors = .dark
    /// The dark look (or its Increase Contrast variant) is on.
    static var isDark: Bool { tokens == .dark || tokens == .darkHc }

    // Surfaces / ink
    static var bg: Color { tokens.canvas }
    static var chrome: Color { tokens.canvas }
    static var elevated: Color { tokens.surface }
    static var card: Color { tokens.raised }
    static var cardHover: Color { tokens.pressed }
    static var inset: Color { tokens.sunken }
    static var toggleOff: Color { tokens.switchOff }
    static var ink: Color { tokens.ink }
    static var ink2: Color { tokens.ink2 }
    static var ink3: Color { tokens.ink3 }
    /// Kept as the Mac's name for tertiary text.
    static var muted: Color { tokens.ink3 }
    static var hairline: Color { tokens.hairline }
    static var hairline2: Color { tokens.hairline }
    static var hairline3: Color { tokens.stroke }
    static var inaudibleBar: Color { tokens.waveOff }

    // Accent
    static var primary: Color { tokens.accent }
    static var primaryHover: Color { tokens.accentPressed }
    static var primaryTint: Color { tokens.accentText }
    /// The Mac's old magenta highlight is the palette's accent-as-text.
    static var magenta: Color { tokens.accent }
    static var magentaText: Color { tokens.accentText }

    // Status
    static var success: Color { tokens.ok }
    static var warning: Color { tokens.caution }
    static var danger: Color { tokens.live }

    /// A part's colour at the token lightness for the current look.
    static func stemColor(hue: Double) -> Color {
        tokens.stem(hue)
    }

    static func oklchToSRGB(l: Double, c: Double, h: Double) -> (Double, Double, Double) {
        BacklineColors.oklchToSRGB(l: l, c: c, h: h)
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

// MARK: - Motion

/// Reduce Motion (WP5): with it on, the player's springs, slides and morphs become instant changes.
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// For `withAnimation`: nil (no animation) when Reduce Motion is on.
    static func animation(_ a: Animation) -> Animation? { reduced ? nil : a }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduce
    let animation: Animation?
    let value: V
    func body(content: Content) -> some View { content.animation(reduce ? nil : animation, value: value) }
}

extension View {
    /// `.animation(_:value:)` that stands still under Reduce Motion.
    func motion<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}
