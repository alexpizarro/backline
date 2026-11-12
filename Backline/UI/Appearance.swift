import AppKit
import SwiftUI

/// The look the owner picks in Settings ▸ Look (AD-2): auto follows macOS, or a fixed light or dark.
/// The palette itself is fixed per look (never a dynamic colour), so a sheet, a snapshot and the
/// window can never disagree about which look they are drawing.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case auto, light, dark

    static let defaultsKey = "appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .auto: nil
        case .light: .light
        case .dark: .dark
        }
    }

    static var saved: AppearanceMode {
        AppearanceMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .auto
    }
}

/// Reads the current palette and gives every view the same one.
///
/// `dark` is resolved from the chosen look (or the system, in Auto) and the palette is swapped for the
/// Increase Contrast variant when the person has that on. Views read `@Environment(\.palette)`.
struct PaletteKey: EnvironmentKey {
    static let defaultValue = BacklineColors.dark
}

extension EnvironmentValues {
    var palette: BacklineColors {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// The current look, including the system's light/dark in Auto and Increase Contrast.
struct PaletteReader<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage(AppearanceMode.defaultsKey) private var raw = AppearanceMode.auto.rawValue
    @ViewBuilder var content: (BacklineColors) -> Content

    var body: some View {
        let mode = AppearanceMode(rawValue: raw) ?? .auto
        let dark = mode.colorScheme.map { $0 == .dark } ?? (scheme == .dark)
        content(BacklineColors.of(dark: dark, highContrast: contrast == .increased))
    }
}

/// Applies the chosen look to a window and hands every view the matching palette.
///
/// `Theme.tokens` is assigned here, in `body`, not in `onAppear`: a body is evaluated top-down, so every
/// child draws the new palette in the same pass. Assigning it in `onAppear` came a frame late and left
/// parts of the tree (the sidebar, say) drawing the previous look's ink on the new look's paper.
struct ChosenLook: ViewModifier {
    @AppStorage(AppearanceMode.defaultsKey) private var raw = AppearanceMode.auto.rawValue
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let mode = AppearanceMode(rawValue: raw) ?? .auto
        let dark = mode.colorScheme.map { $0 == .dark } ?? (systemScheme == .dark)
        let colors = BacklineColors.of(dark: dark, highContrast: contrast == .increased)
        Theme.tokens = colors
        return content
            .preferredColorScheme(mode.colorScheme)
            .environment(\.palette, colors)
    }
}
