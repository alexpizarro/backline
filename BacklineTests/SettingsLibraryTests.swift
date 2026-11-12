import BacklineKit
import XCTest
@testable import Backline

/// WP7: the Library's search and the Settings words.
final class SettingsLibraryTests: XCTestCase {
    private func song(_ title: String, _ artist: String?) -> SongRecord {
        let json: [String: Any] = ["bpm": 120.0, "beats": [Double](), "downbeats": [Double](), "sections": [[String: Any]]()]
        let analysis = try! JSONDecoder().decode(SongAnalysis.self, from: JSONSerialization.data(withJSONObject: json))
        return SongRecord(id: UUID().uuidString, title: title, artist: artist, duration: 60, sourceName: "x.mp3", addedAt: Date(),
                          lastOpened: Date(), stems: [.vocals], analysis: analysis, peaks: [:], storageScale: [:], hasArtwork: false,
                          settings: SongSettings())
    }

    func testSearchMatchesTitleOrArtistIgnoringCase() {
        let songs = [song("Big Rock", "The Band"), song("Volatile", nil), song("Slow Song", "rockers")]
        XCTAssertEqual(LibrarySidebar.filter(songs, query: "").map(\.title), ["Big Rock", "Volatile", "Slow Song"])
        XCTAssertEqual(LibrarySidebar.filter(songs, query: "  ").map(\.title), ["Big Rock", "Volatile", "Slow Song"],
                       "spaces alone are no search")
        XCTAssertEqual(LibrarySidebar.filter(songs, query: "ROCK").map(\.title), ["Big Rock", "Slow Song"],
                       "the title, or the artist")
        XCTAssertEqual(LibrarySidebar.filter(songs, query: "band").map(\.title), ["Big Rock"])
        XCTAssertEqual(LibrarySidebar.filter(songs, query: "nothing like it"), [])
        XCTAssertEqual(LibrarySidebar.searchFrom, 8, "search appears from 8 songs, as on iOS")
    }

    func testTheModelsRowSaysWhereTheDownloadIs() {
        XCTAssertEqual(GeneralSettings.modelStatus(progress: 0.42, missing: true), "Downloading 42%")
        XCTAssertEqual(GeneralSettings.modelStatus(progress: nil, missing: true), "Not downloaded")
        XCTAssertEqual(GeneralSettings.modelStatus(progress: nil, missing: false), "Ready")
    }

    func testTheSiteLinksAreTheOnesIOSUses() {
        XCTAssertEqual(BacklineSite.privacy.absoluteString, "https://backlinestems.com/privacy/")
        XCTAssertEqual(BacklineSite.support.absoluteString, "https://backlinestems.com/#support")
    }

    func testStorageCountsTheSongsFolder() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("a"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(count: 2_000_000).write(to: dir.appendingPathComponent("a/vocals.caf"))
        XCTAssertGreaterThanOrEqual(AppModel.directorySize(dir), 2_000_000)
        let use = await AppModel.storageUse(container: dir, songs: dir, models: dir.appendingPathComponent("none"))
        XCTAssertTrue(StorageUse.format(use.total).contains("MB"), StorageUse.format(use.total))
    }
}
