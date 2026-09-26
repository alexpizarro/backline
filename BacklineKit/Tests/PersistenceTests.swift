import XCTest
@testable import BacklineKit

/// The library must survive upgrades and rollbacks: a decode failure hides a song completely.
final class PersistenceTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    /// v0.11 wrote this JSON; v0.12 must read it with defaults for every new field.
    func testDecodesV011Song() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("v011_song.json"))
        let rec = try JSONDecoder().decode(SongRecord.self, from: data)
        XCTAssertFalse(rec.stems.isEmpty)
        XCTAssertEqual(rec.settings.tempoScale, 1)
        XCTAssertFalse(rec.settings.guide)
        XCTAssertNil(rec.guitarSplit)
        XCTAssertFalse(rec.analysis.sections.isEmpty)
    }

    /// Mirrors v0.11's synthesized Codable types so we can prove a rolled-back build still reads v0.12 files.
    struct V011Settings: Codable {
        enum Kind: String, Codable { case vocals, guitar, bass, drums, keys, other }
        var removed: Set<Kind>; var volumes: [String: Double]; var solo: Kind?
        var loopEnabled: Bool; var loopStart: Double?; var loopEnd: Double?
        var speed: Int; var pitch: Int; var countIn: Bool
        var sectionNames: [String: String]; var lastPosition: Double
    }
    struct V011Record: Codable {
        var id: String; var title: String; var duration: Double; var stems: [V011Settings.Kind]
        var settings: V011Settings
    }

    func testV012FileStillReadableByV011() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("v011_song.json"))
        var rec = try JSONDecoder().decode(SongRecord.self, from: data)
        rec.settings.removed = [.leadGuitar]
        rec.settings.solo = .rhythmGuitar
        rec.settings.guide = true
        rec.settings.tempoScale = 0.5
        rec.guitarSplit = GuitarSplit(method: "stereo-v1", confidence: 0.6, leadPeaks: [0.1], rhythmPeaks: [0.2],
                                      leadScale: 1, rhythmScale: 1)
        let out = try JSONEncoder().encode(rec)

        // Old build: sees `guitar` removed and soloed.
        let old = try JSONDecoder().decode(V011Record.self, from: out)
        XCTAssertEqual(old.settings.removed, [.guitar])
        XCTAssertEqual(old.settings.solo, .guitar)

        // New build: exact choices round-trip.
        let back = try JSONDecoder().decode(SongRecord.self, from: out)
        XCTAssertEqual(back.settings.removed, [.leadGuitar])
        XCTAssertEqual(back.settings.solo, .rhythmGuitar)
        XCTAssertEqual(back.settings.tempoScale, 0.5)
        XCTAssertTrue(back.settings.guide)
        XCTAssertEqual(back.guitarSplit?.confidence, 0.6)
    }

    /// Unknown future stem kinds must not make the song vanish.
    func testUnknownStemKindsAreSkipped() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("v011_song.json"))
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj["stems"] = ["guitar", "theremin", "bass"]
        var st = obj["settings"] as! [String: Any]
        st["removed"] = ["theremin"]
        obj["settings"] = st
        let rec = try JSONDecoder().decode(SongRecord.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertEqual(rec.stems, [.guitar, .bass])
        XCTAssertTrue(rec.settings.removed.isEmpty)
    }
}
