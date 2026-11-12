import SwiftUI

/// "3 more ⌄" (design plan 3.4): a 32 pt glass pill over the bottom of the parts list, the first few times the list
/// is longer than the window shows. It goes on the first scroll, after 4 s, or on a click (which brings the next row
/// up). Ported from backline-ios Backline/UI/ScrollHint.swift.
struct ScrollHintPill: View {
    let hidden: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text("\(hidden) more")
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
            }
            .font(Typo.ui(13, .semibold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .glassSurface(Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline3))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Show the next part")
        .accessibilityIdentifier("scroll-hint")
        .accessibilityLabel(hidden == 1 ? "1 more part below" : "\(hidden) more parts below")
        .accessibilityHint("Shows the next part")
    }
}

/// When to show the hint: at most 3 times overall (`partsHintShown`), once per launch, never after the person has
/// scrolled the parts in this player session.
@MainActor
enum ScrollHintPolicy {
    static let defaultsKey = "partsHintShown"
    static let maxShows = 3
    private static var shownThisLaunch = false

    static var mayShow: Bool {
        !shownThisLaunch && UserDefaults.standard.integer(forKey: defaultsKey) < maxShows
    }

    static func recordShown() {
        shownThisLaunch = true
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: defaultsKey) + 1, forKey: defaultsKey)
    }

    #if DEBUG
    /// Tests: forget this launch's showing.
    static func resetForTesting() { shownThisLaunch = false }
    #endif
}
