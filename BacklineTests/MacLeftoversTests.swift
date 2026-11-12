import AppKit
import BacklineKit
import XCTest
@testable import Backline

/// The small Mac items mac-ios-trio picked up: the tape cover as Now Playing artwork, the empty-Library line
/// beside a song being imported, and no video site named in the credits.
@MainActor
final class MacLeftoversTests: XCTestCase {
    /// A song without a picture shows its tape cover in Now Playing, as on iOS (not the app's icon).
    func testTheTapeCoverIsDrawnForNowPlaying() throws {
        let image = try XCTUnwrap(TapeCover.image(title: "Summon the Rawk", parts: [.leadGuitar, .bass, .drums], id: "rawk"))
        XCTAssertEqual(image.size.width, 600)
        XCTAssertEqual(image.size.height, 600)
        // It is the cover, not a blank square: the pixels vary.
        let rep = try XCTUnwrap(image.representations.first as? NSBitmapImageRep ?? image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        var colours = Set<String>()
        for x in stride(from: 0, to: rep.pixelsWide, by: 37) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 37) {
                if let c = rep.colorAt(x: x, y: y) { colours.insert(String(format: "%.2f %.2f %.2f", c.redComponent, c.greenComponent, c.blueComponent)) }
            }
        }
        XCTAssertGreaterThan(colours.count, 2, "stripes and the card, not one colour")
    }

    /// "Songs you split appear here…" is not shown beside the first song's importing row.
    func testTheEmptyLibraryLineGivesWayToAnImport() {
        XCTAssertTrue(LibrarySidebar.showsEmptyLine(libraryIsEmpty: true, importing: false))
        XCTAssertFalse(LibrarySidebar.showsEmptyLine(libraryIsEmpty: true, importing: true))
        XCTAssertFalse(LibrarySidebar.showsEmptyLine(libraryIsEmpty: false, importing: false))
    }

    /// The credits a person opens from Settings are in the app, and name no video site or music service.
    func testTheCreditsAreThereAndNameNoService() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt"),
                                "Settings ▸ Credits opens this file")
        let text = try String(contentsOf: url, encoding: .utf8).lowercased()
        for name in ["youtube", "vimeo", "spotify", "apple music", "soundcloud"] {
            XCTAssertFalse(text.contains(name), "the credits name \(name)")
        }
    }
}
