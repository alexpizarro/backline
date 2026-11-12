import AppKit
import BacklineKit
import SwiftUI
import XCTest
@testable import Backline

/// The iOS player pieces the Mac now has (mac-finish item 2): the cleaning capsule's words, the tape cover for a
/// song without artwork, the marker face it is written in, and the scroll hint's limits.
@MainActor
final class PlayerPiecesTests: XCTestCase {
    /// As iOS `StatusWordsTests`: no stuck 0 %, then whole percents.
    func testTheCleaningCapsuleSaysCleaningThenAPercent() {
        XCTAssertEqual(CleaningCapsule.text(0), "Cleaning…")
        XCTAssertEqual(CleaningCapsule.text(0.009), "Cleaning…")
        XCTAssertEqual(CleaningCapsule.text(0.01), "Cleaning 1%")
        XCTAssertEqual(CleaningCapsule.text(0.42), "Cleaning 42%")
    }

    /// A cover is the same on every launch and on both apps: FNV-1a of the id picks two different part colours,
    /// and the label is the title's first word, eight characters at most.
    func testATapeCoverIsSeededByItsSongAndPicksTwoColours() {
        XCTAssertEqual(Tape.hash(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(Tape.hash("a"), 0xaf63_dc4c_8601_ec8c, "FNV-1a, as on iOS")
        let parts: [StemKind] = [.vocals, .guitar, .bass, .drums, .keys, .other]
        for id in ["big-rock", "volatile", "x", "8F7A-11"] {
            let (a, b) = TapeCover.colours(parts, seed: Tape.hash(id))
            XCTAssertNotEqual(a, b, "two different colours for \(id)")
            XCTAssertTrue(parts.contains(a) && parts.contains(b))
            let again = TapeCover.colours(parts, seed: Tape.hash(id))
            XCTAssertEqual(again.0, a)
            XCTAssertEqual(again.1, b)
        }
        let fallback = TapeCover.colours([], seed: 7)
        XCTAssertEqual(Set([fallback.0, fallback.1]), [.vocals, .bass], "no parts yet: vocals and bass")
        XCTAssertEqual(TapeCover.word("Volatile Reaction"), "Volatile")
        XCTAssertEqual(TapeCover.word("Extraordinarily long"), "Extraord")
        XCTAssertNil(TapeCover.word("   "))
    }

    /// The tape's marker face ships in the app and is registered at launch.
    func testTheMarkerFaceIsBundledAndRegistered() throws {
        XCTAssertNotNil(Bundle.main.url(forResource: "PermanentMarker-Regular", withExtension: "ttf"))
        FontLoader.registerBundledFonts()
        XCTAssertNotNil(NSFont(name: "PermanentMarker-Regular", size: 13) ?? NSFont(name: Typo.tapeFamily, size: 13),
                        "the tape's face is available by name")
        XCTAssertNotNil(NSImage(named: "grain-tile"), "the grain tile is in the asset catalogue")
    }

    /// A tape cover draws: stripes and a label over the raised square, not an empty frame.
    func testATapeCoverDraws() throws {
        let renderer = ImageRenderer(content: TapeCover(title: "Big Rock", parts: [.guitar, .bass, .drums], id: "big-rock")
            .frame(width: 120, height: 120))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)
        var colours = Set<Int>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: 6) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 6) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                colours.insert(Int(c.redComponent * 15) << 8 | Int(c.greenComponent * 15) << 4 | Int(c.blueComponent * 15))
            }
        }
        XCTAssertGreaterThan(colours.count, 3, "background, two stripes and the tape")
    }

    /// The scroll hint shows at most three times overall and once per launch.
    func testTheScrollHintShowsAtMostThreeTimesAndOncePerLaunch() {
        let key = ScrollHintPolicy.defaultsKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            ScrollHintPolicy.resetForTesting()
        }
        UserDefaults.standard.removeObject(forKey: key)
        ScrollHintPolicy.resetForTesting()
        XCTAssertTrue(ScrollHintPolicy.mayShow)
        ScrollHintPolicy.recordShown()
        XCTAssertFalse(ScrollHintPolicy.mayShow, "once per launch")
        for _ in 0..<2 { ScrollHintPolicy.resetForTesting(); ScrollHintPolicy.recordShown() }
        ScrollHintPolicy.resetForTesting()
        XCTAssertEqual(UserDefaults.standard.integer(forKey: key), 3)
        XCTAssertFalse(ScrollHintPolicy.mayShow, "never after the third time")
    }
}
