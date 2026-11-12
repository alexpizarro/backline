import Foundation

/// The website pages the app links to (R01): one place to change while the domain (backlinestems.com,
/// Decision 7) is still the owner's to buy. The site publishes the privacy policy at `/privacy/` and
/// support at `#support` (Phase W).
nonisolated enum BacklineSite {
    static let privacy = URL(string: "https://backlinestems.com/privacy/")!
    static let support = URL(string: "https://backlinestems.com/#support")!
}
