import XCTest
@testable import Backline

/// Settings' storage figure (storage F11), ported from iOS: the whole container, with what the songs and the
/// extra parts take under it.
final class StorageUseTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-use-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, bytes: Int) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
    }

    func testTheTotalCountsEverythingNotOnlySongs() throws {
        try write("Library/Application Support/Backline/Songs/a/vocals.caf", bytes: 300_000)
        try write("Library/Application Support/Backline/Songs/a/drums.caf", bytes: 200_000)
        try write("Library/Application Support/Backline/Models/M.mlmodelc/weights.bin", bytes: 400_000)
        try write("Library/Caches/Backline/checkpoint.bin", bytes: 100_000)
        try write("tmp/staging.m4a", bytes: 50_000)
        let songs = root.appendingPathComponent("Library/Application Support/Backline/Songs")
        let models = root.appendingPathComponent("Library/Application Support/Backline/Models")

        let use = StorageUse.measure(container: root, songs: songs, models: models)

        // Allocated sizes round up to whole blocks, so each is at least what was written.
        XCTAssertGreaterThanOrEqual(use.songs, 500_000)
        XCTAssertLessThan(use.songs, 600_000)
        XCTAssertGreaterThanOrEqual(use.models, 400_000)
        XCTAssertLessThan(use.models, 500_000)
        XCTAssertGreaterThanOrEqual(use.total, use.songs + use.models + 150_000, "checkpoints and staging count too")
        XCTAssertLessThan(use.total, 1_400_000)
    }

    func testTheLineNamesTheExtraPartsOnlyOnceTheyAreHere() {
        XCTAssertEqual(StorageUse(total: 10, songs: 5, models: 0).detail, "Songs \(StorageUse.format(5))")
        let both = StorageUse(total: 1_200_000_000, songs: 610_000_000, models: 547_000_000)
        XCTAssertEqual(both.detail, "Songs \(StorageUse.format(610_000_000)) · Extra parts \(StorageUse.format(547_000_000))")
    }

    /// A Mac container links to the person's own folders (Desktop, Downloads, Music, Pictures): never counted.
    func testLinksOutOfTheContainerAreNotCounted() throws {
        try write("Library/Application Support/Backline/Songs/a/vocals.caf", bytes: 100_000)
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data(repeating: 1, count: 3_000_000).write(to: outside.appendingPathComponent("big.mp3"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Music"), withDestinationURL: outside)
        let use = StorageUse.measure(container: root, songs: root.appendingPathComponent("none"),
                                     models: root.appendingPathComponent("none"))
        XCTAssertGreaterThanOrEqual(use.total, 100_000)
        XCTAssertLessThan(use.total, 1_000_000, "the linked folder's 3 MB are not Backline's")
    }

    func testAMissingFolderIsZero() {
        let use = StorageUse.measure(container: root, songs: root.appendingPathComponent("none"),
                                     models: root.appendingPathComponent("none either"))
        XCTAssertEqual(use.songs, 0)
        XCTAssertEqual(use.models, 0)
    }
}
