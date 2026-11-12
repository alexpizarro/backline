import XCTest
@testable import Backline

/// R01c: Reset removes everything Backline keeps and nothing else (a temporary container stands in for the
/// app's sandbox), finishes an interrupted reset from its marker, and covers every place the app writes.
/// Ported from iOS with the Mac's locations: no App Group, no Documents, and the Core ML cache (D6).
final class ResetBacklineTests: XCTestCase {
    private var root: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("reset-\(UUID().uuidString)", isDirectory: true)
        outside = FileManager.default.temporaryDirectory.appendingPathComponent("reset-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }

    private func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    private func write(_ path: String, _ text: String = "x") throws {
        let u = url(path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
    }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: url(path).path) }

    /// The same shape as `ResetBackline.live()`, under `root`.
    private func locations() -> ResetBackline.Locations {
        ResetBackline.Locations(
            move: [url("Library/Application Support/Backline"), url("Library/Caches/Backline"), url("Library/Caches/links"),
                   url("Library/Caches/models-manifest.json"), url("Library/Logs/Backline.log"),
                   url("Library/Caches/com.alexpizarro.backline.dev/com.apple.e5rt.e5bundlecache")],
            delete: [],
            tmp: url("tmp"), tmpPrefixes: ["Exports", "BacklineModelCache", "model-", "link-smoke", "models-debug",
                                          "CFNetworkDownload_", "yt-cookies"],
            trashRoot: url("tmp/Reset"), marker: url("Library/backline-reset-pending"))
    }

    /// Every place Backline keeps something, plus files it doesn't know by name.
    private func fill() throws {
        for path in [
            "Library/Application Support/Backline/Songs/abc/vocals.caf", "Library/Application Support/Backline/Songs/abc/song.json",
            "Library/Application Support/Backline/Staging/abc-old/song.json",
            "Library/Application Support/Backline/Downloads/x.m4a", "Library/Application Support/Backline/Downloads/cache/youtube-sigfuncs/x.json",
            "Library/Application Support/Backline/Recordings/recording-1.wav",
            "Library/Application Support/Backline/Models/BSRoformerSW.sha256",
            "Library/Application Support/Backline/Models/BSRoformerSW.mlmodelc/weights/weight.bin",
            "Library/Application Support/Backline/unknown-new-thing.bin",
            "Library/Caches/Backline/Cleaner/abc/ch0.f32", "Library/Caches/links/jsc/abcd1234.js",
            "Library/Caches/models-manifest.json", "Library/Logs/Backline.log",
            "Library/Caches/com.alexpizarro.backline.dev/com.apple.e5rt.e5bundlecache/1234/model.bin",
            "tmp/BacklineModelCache/a.bin", "tmp/model-1234.aar", "tmp/yt-cookies/yt-1.txt", "tmp/models-debug.txt",
            "tmp/CFNetworkDownload_abc.tmp",
        ] { try write(path) }
    }

    func testEveryLocationIsEmptiedAndNothingElseIsTouched() throws {
        try fill()
        // Not Backline's: system-managed folders, the URL cache beside Core ML's, a harness song in tmp, and a
        // folder outside the container.
        try write("Library/Preferences/com.apple.something.plist")
        try write("Library/WebKit/Website.data")
        try write("Library/Caches/com.alexpizarro.backline.dev/Cache.db")
        try write("tmp/com.apple.system-scratch")
        try write("tmp/song.mp3")
        try Data("keep".utf8).write(to: outside.appendingPathComponent("keep.txt"))
        // A symlink inside Backline's folder that points outside: the link goes, the target stays.
        try FileManager.default.removeItem(at: url("Library/Caches/links"))
        try FileManager.default.createSymbolicLink(at: url("Library/Caches/links"), withDestinationURL: outside)

        let loc = locations()
        let failures = ResetBackline.removeFiles(loc)
        XCTAssertEqual(failures, [])
        XCTAssertTrue(exists("Library/backline-reset-pending"), "the marker is written before anything moves")
        ResetBackline.finish(loc)
        ResetBackline.emptyTrash(loc)

        for gone in ["Library/Application Support/Backline", "Library/Caches/Backline", "Library/Caches/links",
                     "Library/Caches/models-manifest.json", "Library/Logs/Backline.log",
                     "Library/Caches/com.alexpizarro.backline.dev/com.apple.e5rt.e5bundlecache",
                     "tmp/BacklineModelCache", "tmp/model-1234.aar", "tmp/yt-cookies", "tmp/models-debug.txt",
                     "tmp/CFNetworkDownload_abc.tmp", "tmp/Reset", "Library/backline-reset-pending"] {
            XCTAssertFalse(exists(gone), "\(gone) should be gone")
        }
        for kept in ["Library/Preferences/com.apple.something.plist", "Library/WebKit/Website.data",
                     "Library/Caches/com.alexpizarro.backline.dev/Cache.db", "tmp/com.apple.system-scratch", "tmp/song.mp3",
                     "Library", "tmp", "Library/Application Support"] {
            XCTAssertTrue(exists(kept), "\(kept) should stay")
        }
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("keep.txt"), encoding: .utf8), "keep",
                       "nothing outside the container is followed or touched")
    }

    func testAnInterruptedResetIsFinishedAtLaunch() throws {
        try fill()
        let loc = locations()
        // Interrupted after the marker and the first move.
        FileManager.default.createFile(atPath: loc.marker.path, contents: Data())
        try FileManager.default.createDirectory(at: loc.trashRoot.appendingPathComponent("half"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: loc.move[0], to: loc.trashRoot.appendingPathComponent("half/0-Backline"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "reset-test-\(UUID().uuidString)"))
        defaults.set(true, forKey: "welcomeSeen")
        defaults.set("yes", forKey: "modelDownloadConsent")

        XCTAssertTrue(ResetBackline.finishPendingIfNeeded(loc, defaults: defaults, domain: nil))
        for gone in ["Library/Caches/Backline", "Library/Logs/Backline.log", "tmp/model-1234.aar", "tmp/Reset",
                     "Library/backline-reset-pending"] {
            XCTAssertFalse(exists(gone), "\(gone) should be gone")
        }
        XCTAssertNil(defaults.object(forKey: "welcomeSeen"))
        XCTAssertNil(defaults.object(forKey: "modelDownloadConsent"))
        XCTAssertFalse(ResetBackline.finishPendingIfNeeded(loc, defaults: defaults, domain: nil), "nothing pending any more")
    }

    func testTheEpochStopsOldWork() {
        let started = ResetBackline.epoch
        XCTAssertTrue(ResetBackline.isCurrent(started))
        let next = ResetBackline.bumpEpoch()
        XCTAssertEqual(next, started + 1)
        XCTAssertFalse(ResetBackline.isCurrent(started), "work started before a reset is no longer current")
        XCTAssertTrue(ResetBackline.isCurrent(next))
    }

    /// Every place the app writes is inside something Reset removes (a new folder can't be forgotten).
    @MainActor func testEveryPlaceTheAppWritesIsCovered() {
        let loc = ResetBackline.live()
        func covered(_ u: URL) -> Bool {
            let p = u.standardizedFileURL.path
            let byMove = loc.move.contains { p == $0.standardizedFileURL.path || p.hasPrefix($0.standardizedFileURL.path + "/") }
            let byDelete = loc.delete.contains { p == $0.standardizedFileURL.path || p.hasPrefix($0.standardizedFileURL.path + "/") }
            let byTmp = loc.tmp.map { tmp in
                p.hasPrefix(tmp.standardizedFileURL.path + "/")
                    && loc.tmpPrefixes.contains { String(p.dropFirst(tmp.standardizedFileURL.path.count + 1)).hasPrefix($0) }
            } ?? false
            return byMove || byDelete || byTmp
        }
        let tmp = FileManager.default.temporaryDirectory
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let paths: [URL] = [
            SongStore.shared.root, SongStore.shared.staging.root,
            ImportStaging.recordingsDirectory, ImportStaging.downloadsDirectory, // the link engine downloads here too
            ModelStore.directory, CleanerPartsJob.checkpointDirectory("abc"), AppLog.url, ModelManifest.cacheURL,
            YouTubeSignIn.cookieDirectory, caches.appendingPathComponent("links/jsc"),
            caches.appendingPathComponent("\(Bundle.main.bundleIdentifier ?? "")/com.apple.e5rt.e5bundlecache"),
            tmp.appendingPathComponent("model-1.aar"), tmp.appendingPathComponent("models-debug.txt"),
        ]
        for p in paths { XCTAssertTrue(covered(p), "Reset doesn't cover \(p.path)") }
    }

    /// Reset only ever runs inside this build's own sandbox container, never at a path another app or the
    /// person owns: the Music folder (saved tracks) and the home folder are never in the list.
    func testResetStaysInTheContainer() throws {
        XCTAssertTrue(ResetBackline.isInOwnContainer, "the test host is the sandboxed Debug app")
        let id = try XCTUnwrap(Bundle.main.bundleIdentifier)
        XCTAssertNotEqual(id, "com.alexpizarro.backline", "a Debug build never has the installed app's id (D15)")
        let container = NSHomeDirectory()
        let loc = ResetBackline.live()
        for u in loc.move + loc.delete + [loc.marker, loc.trashRoot] + (loc.tmp.map { [$0] } ?? []) {
            XCTAssertTrue(u.standardizedFileURL.path.hasPrefix(container + "/"), "\(u.path) is outside \(container)")
            XCTAssertFalse(u.path.contains("/Music/"), "saved tracks are the person's own")
        }
        XCTAssertFalse(loc.move.contains { $0.lastPathComponent == id }, "the whole caches folder (the URL cache) stays")
    }
}
