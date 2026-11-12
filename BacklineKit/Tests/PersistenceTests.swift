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

    /// 0.17 adds practice modes. A 0.16 build must still read the file, and the new fields round-trip.
    func testPracticeModeFieldsRoundTripAndStayReadableByOldBuilds() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("v011_song.json"))
        var rec = try JSONDecoder().decode(SongRecord.self, from: data)
        XCTAssertNil(rec.settings.mode)
        XCTAssertNil(rec.settings.danceStyle)
        rec.settings.mode = .dance
        rec.settings.danceStyle = .bachata
        rec.settings.countOne = 12.5
        rec.settings.spotlight = .bass
        rec.settings.removedByMode = ["play": ["leadGuitar"], "beats": ["vocals"]]
        let out = try JSONEncoder().encode(rec)

        XCTAssertNoThrow(try JSONDecoder().decode(V011Record.self, from: out))
        let back = try JSONDecoder().decode(SongRecord.self, from: out)
        XCTAssertEqual(back.settings.mode, .dance)
        XCTAssertEqual(back.settings.danceStyle, .bachata)
        XCTAssertEqual(back.settings.countOne, 12.5)
        XCTAssertEqual(back.settings.spotlight, .bass)
        XCTAssertEqual(back.settings.removedByMode["beats"], ["vocals"])
    }

    /// A mode or style from a newer build falls back to nil instead of hiding the song.
    func testUnknownModeFallsBack() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("v011_song.json"))
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var st = obj["settings"] as! [String: Any]
        st["mode"] = "karaoke"; st["danceStyle"] = "tango"; st["spotlight"] = "theremin"
        obj["settings"] = st
        let rec = try JSONDecoder().decode(SongRecord.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertNil(rec.settings.mode)
        XCTAssertNil(rec.settings.danceStyle)
        XCTAssertNil(rec.settings.spotlight)
        XCTAssertFalse(rec.stems.isEmpty)
    }

    /// 1.1 (D18): the kept source file is an optional field. Older records read as before (no field, the
    /// original is `original.caf` when `originalScale` says so), and an older build still reads a new record.
    func testKeptSourceFieldRoundTripsAndOldRecordsAreUnchanged() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("v011_song.json"))
        var rec = try JSONDecoder().decode(SongRecord.self, from: data)
        XCTAssertNil(rec.originalFile)
        XCTAssertFalse(rec.hasOriginal)
        rec.originalScale = 0.9
        XCTAssertTrue(rec.hasOriginal, "original.caf")
        rec.originalScale = nil
        rec.originalFile = "source.mp3"
        XCTAssertTrue(rec.hasOriginal, "the kept source")
        let out = try JSONEncoder().encode(rec)
        XCTAssertNoThrow(try JSONDecoder().decode(V011Record.self, from: out))
        let back = try JSONDecoder().decode(SongRecord.self, from: out)
        XCTAssertEqual(back.originalFile, "source.mp3")
        XCTAssertNil(back.originalScale)
        // A record without the field writes no key for it (older builds see exactly what they wrote).
        rec.originalFile = nil
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rec)) as! [String: Any]
        XCTAssertNil(plain["originalFile"])
    }
}
