import XCTest
@testable import Backline

/// Release 1.1 on the Mac (ported from iOS ios-models): the downloaded models stay out of Time Machine and the
/// songs stay in it (D5, Mac: models only), Core ML's compiled cache is cleared when the build changes (D6), the
/// launch sweep removes only what nothing can reach (storage.md F5, split.md F12), and a model host that sends
/// nothing fails that source after 15 s.
final class StorageHygieneTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("hygiene-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    private func write(_ path: String, _ text: String = "x") throws {
        let u = url(path)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
    }

    private func exists(_ path: String) -> Bool { fm.fileExists(atPath: url(path).path) }

    // MARK: D5: backup

    func testTheModelsFolderIsExcludedFromBackupAndMadeIfMissing() {
        let folder = url("Application Support/Backline/Models")
        XCTAssertFalse(exists("Application Support/Backline/Models"))
        XCTAssertTrue(BacklineFolders.ensureExcludedFromBackup(folder))
        XCTAssertTrue(exists("Application Support/Backline/Models"))
        XCTAssertTrue(BacklineFolders.isExcludedFromBackup(folder))
        // Again is harmless.
        XCTAssertTrue(BacklineFolders.ensureExcludedFromBackup(folder))
    }

    /// The flag is on the folder: a fresh folder made in its place after a reset would lose it, so Reset
    /// makes the folder again, excluded.
    func testResetMakesTheModelsFolderAgainExcludedFromBackup() throws {
        let support = url("Library/Application Support/Backline")
        let models = url("Library/Application Support/Backline/Models")
        try write("Library/Application Support/Backline/Songs/abc/song.json")
        try write("Library/Application Support/Backline/Models/BSRoformerSW.sha256")
        XCTAssertTrue(BacklineFolders.ensureExcludedFromBackup(models))
        let loc = ResetBackline.Locations(
            move: [support], delete: [], tmp: nil, trashRoot: url("tmp/Reset"), marker: url("Library/backline-reset-pending"),
            recreateExcludedFromBackup: [models])
        XCTAssertEqual(ResetBackline.removeFiles(loc), [])
        XCTAssertFalse(exists("Library/Application Support/Backline/Songs/abc/song.json"), "the song went")
        XCTAssertFalse(exists("Library/Application Support/Backline/Models/BSRoformerSW.sha256"), "the model went")
        XCTAssertTrue(exists("Library/Application Support/Backline/Models"), "the models folder is back, empty")
        XCTAssertTrue(BacklineFolders.isExcludedFromBackup(models), "and still out of backup")
        XCTAssertFalse(BacklineFolders.isExcludedFromBackup(support), "the songs' folder is backed up")
    }

    /// Mac: only the models are kept out of Time Machine; the songs, with their loops and mixes, stay in it.
    func testOnlyTheModelsAreKeptOutOfTimeMachine() {
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        XCTAssertEqual(BacklineFolders.support.standardizedFileURL, support.appendingPathComponent("Backline").standardizedFileURL)
        XCTAssertEqual(BacklineFolders.models.standardizedFileURL, ModelStore.directory.standardizedFileURL)
        XCTAssertTrue(SongStore.shared.root.path.hasPrefix(BacklineFolders.support.path + "/"))
        // The app ran its launch path in this test host: the real models folder is excluded, the songs are not.
        XCTAssertTrue(BacklineFolders.isExcludedFromBackup(BacklineFolders.models))
        XCTAssertFalse(BacklineFolders.isExcludedFromBackup(BacklineFolders.support))
        XCTAssertFalse(BacklineFolders.isExcludedFromBackup(SongStore.shared.root))
        XCTAssertEqual(ResetBackline.live().recreateExcludedFromBackup.map(\.standardizedFileURL),
                       [BacklineFolders.models.standardizedFileURL])
    }

    // MARK: D6: Core ML's cache

    private func defaults() -> UserDefaults {
        let name = "hygiene-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return d
    }

    func testTheCacheIsClearedOnceWhenTheBuildChanges() throws {
        let d = defaults()
        let folders = CoreMLCache.folders(caches: url("Caches"), bundleID: "com.example.app")
        XCTAssertEqual(folders.map { $0.path.replacingOccurrences(of: root.path + "/", with: "") },
                       ["Caches/com.apple.e5rt.e5bundlecache", "Caches/com.example.app/com.apple.e5rt.e5bundlecache"])
        try write("Caches/com.example.app/com.apple.e5rt.e5bundlecache/26A/abc/model.bin")
        try write("Caches/com.apple.e5rt.e5bundlecache/26A/def/model.bin")
        try write("Caches/com.example.app/other.bin")

        // First launch of this build (1.0 never wrote one): cleared.
        XCTAssertTrue(CoreMLCache.clearIfStale(build: "1.1 (190)", defaults: d, folders: folders))
        XCTAssertFalse(exists("Caches/com.example.app/com.apple.e5rt.e5bundlecache"))
        XCTAssertFalse(exists("Caches/com.apple.e5rt.e5bundlecache"))
        XCTAssertTrue(exists("Caches/com.example.app/other.bin"), "nothing else in Caches")

        // Same build again: Core ML's new entries stay.
        try write("Caches/com.example.app/com.apple.e5rt.e5bundlecache/26A/new/model.bin")
        XCTAssertFalse(CoreMLCache.clearIfStale(build: "1.1 (190)", defaults: d, folders: folders))
        XCTAssertTrue(exists("Caches/com.example.app/com.apple.e5rt.e5bundlecache/26A/new/model.bin"))

        // A replaced downloaded model asks for one clear at the next launch.
        CoreMLCache.requestClear(defaults: d)
        XCTAssertTrue(CoreMLCache.clearIfStale(build: "1.1 (190)", defaults: d, folders: folders))
        XCTAssertFalse(exists("Caches/com.example.app/com.apple.e5rt.e5bundlecache"))
        XCTAssertFalse(CoreMLCache.clearIfStale(build: "1.1 (190)", defaults: d, folders: folders), "once")

        // The next build.
        try write("Caches/com.example.app/com.apple.e5rt.e5bundlecache/26A/x/model.bin")
        XCTAssertTrue(CoreMLCache.clearIfStale(build: "1.1 (191)", defaults: d, folders: folders))
        XCTAssertFalse(exists("Caches/com.example.app/com.apple.e5rt.e5bundlecache"))
    }

    func testResetRemovesTheCompiledModels() {
        let loc = ResetBackline.live()
        for folder in CoreMLCache.folders() {
            XCTAssertTrue(loc.move.contains(folder), "\(folder.path) is in Reset's list")
        }
    }

    // MARK: The launch sweep

    func testTheSweepRemovesOnlyWhatNothingCanReach() throws {
        let store = SongStore(root: url("Backline/Songs"))
        let checkpoints = url("Caches/Backline/Cleaner")
        let models = url("Backline/Models")
        try write("Backline/Songs/live/song.json", "{}")
        try write("Backline/Songs/live/vocals.caf")
        try write("Backline/Songs/unreadable/song.json", "not json")      // a song that fails to load is kept (D7)
        try write("Backline/Songs/orphan/original.caf")                    // an import killed before its record
        try write("Backline/Songs/importing/original.caf")                 // the import running now
        try write("Caches/Backline/Cleaner/live/part-0.f32")
        try write("Caches/Backline/Cleaner/gone/part-0.f32")
        try write("Backline/Models/.BSRoformerSW-unpack/weights/weight.bin")
        try write("Backline/Models/BSRoformerSW.mlmodelc/weights/weight.bin")
        try write("Backline/Models/BSRoformerSW.sha256")

        let sweep = store.sweepLeftovers(checkpoints: checkpoints, models: models, keeping: ["importing"])
        XCTAssertEqual(sweep, SongStore.Sweep(songFolders: ["orphan"], checkpoints: ["gone"], unpacks: [".BSRoformerSW-unpack"]))
        XCTAssertTrue(exists("Backline/Songs/live/vocals.caf"))
        XCTAssertTrue(exists("Backline/Songs/unreadable/song.json"))
        XCTAssertFalse(exists("Backline/Songs/orphan"))
        XCTAssertTrue(exists("Backline/Songs/importing/original.caf"))
        XCTAssertTrue(exists("Caches/Backline/Cleaner/live/part-0.f32"), "a library song's checkpoint stays")
        XCTAssertFalse(exists("Caches/Backline/Cleaner/gone"))
        XCTAssertFalse(exists("Backline/Models/.BSRoformerSW-unpack"))
        XCTAssertTrue(exists("Backline/Models/BSRoformerSW.mlmodelc/weights/weight.bin"))
        XCTAssertTrue(exists("Backline/Models/BSRoformerSW.sha256"))
    }

    /// A cleaner swap interrupted with the live folder set aside: the song is put back first, then kept.
    func testTheSweepPutsBackAnInterruptedSwapBeforeLooking() throws {
        let store = SongStore(root: url("Backline/Songs"))
        try fm.createDirectory(at: store.root, withIntermediateDirectories: true)
        try write("Backline/Staging/abc-old/song.json", "{}")
        try write("Backline/Staging/abc-old/vocals.caf")
        try write("Caches/Backline/Cleaner/abc/part-0.f32")
        let sweep = store.sweepLeftovers(checkpoints: url("Caches/Backline/Cleaner"), models: url("Backline/Models"))
        XCTAssertEqual(sweep, SongStore.Sweep())
        XCTAssertTrue(exists("Backline/Songs/abc/vocals.caf"), "the song is back in place")
        XCTAssertTrue(exists("Caches/Backline/Cleaner/abc/part-0.f32"), "and its checkpoint kept")
    }

    func testTheSweepWithNothingThereDoesNothing() {
        let store = SongStore(root: url("nowhere/Songs"))
        XCTAssertEqual(store.sweepLeftovers(checkpoints: url("nowhere/c"), models: url("nowhere/m")), SongStore.Sweep())
    }

    // MARK: A model host that sends nothing

    /// The Mac's downloads use an ordinary session: its idle limit is the 15 s after which a source that sends
    /// nothing fails, so `install` moves on to the next source and the row offers Try again.
    func testTheDownloadSessionGivesUpAfterFifteenSecondsOfNothing() {
        XCTAssertEqual(Downloader.stallLimit, 15)
        XCTAssertEqual(Downloader.shared.configuration.timeoutIntervalForRequest, 15)
        XCTAssertFalse(Downloader.shared.configuration.waitsForConnectivity, "no waiting for a network that may come")
    }

    /// A host that never answers (an address nothing replies from) fails within the limit, not after a minute.
    func testAHostThatSendsNothingFailsWithinTheLimit() async {
        let started = Date()
        do {
            _ = try await Downloader.shared.fetch(URL(string: "http://10.255.255.1/model.aar")!, maxBytes: 1_000, progress: { _ in })
            XCTFail("nothing can arrive from there")
        } catch {
            XCTAssertFalse(error is CancellationError, "it failed on its own: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), Downloader.stallLimit + 8, "gave up after the limit")
    }

    // MARK: Deleted songs left in tmp

    /// Release review ios-storage#3: a deleted song's folder that a run left in tmp goes at the next launch and
    /// in Reset; nothing else in tmp is touched.
    func testADeletedSongsFolderLeftInTmpGoesAtLaunchAndInReset() throws {
        let deleting = ImportStaging.deletingPrefix + UUID().uuidString
        try write("tmp/\(deleting)/vocals.caf")
        try write("tmp/\(deleting)/original.caf")
        try write("tmp/keep-me.txt")
        ImportStaging.removeDeletedSongs(in: url("tmp"))
        XCTAssertFalse(exists("tmp/\(deleting)"), "the launch removes it")
        XCTAssertTrue(exists("tmp/keep-me.txt"))

        // Reset covers it too.
        XCTAssertTrue(ResetBackline.live().tmpPrefixes.contains { deleting.hasPrefix($0) }, "Reset doesn't cover tmp/deleting-*")
        try write("tmp/\(deleting)/bass.caf")
        var loc = ResetBackline.live()
        loc.move = []
        loc.delete = []
        loc.recreateExcludedFromBackup = []
        loc.tmp = url("tmp")
        loc.trashRoot = url("trash")
        loc.marker = url("marker")
        _ = ResetBackline.removeFiles(loc)
        XCTAssertFalse(exists("tmp/\(deleting)"), "Reset removes it")
        XCTAssertTrue(exists("tmp/keep-me.txt"))
    }
}
