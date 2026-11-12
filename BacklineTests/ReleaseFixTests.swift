import BacklineKit
import Security
import XCTest
@testable import Backline

/// The 1.1 release review's Mac findings (docs/reviews/2026-11-12-release-review in the iOS repository): the
/// privacy manifest and the boot-time API, the bookmark entitlement, Quit during a recording, unused link
/// downloads, the split's keep-awake, and one download figure.
@MainActor
final class ReleaseFixTests: XCTestCase {
    private static var keepAlive: [AppModel] = []

    // MARK: ios-ui-links#1, mac-shell#1

    /// The app carries its own privacy manifest with every required-reason API it uses declared.
    func testTheAppHasItsOwnPrivacyManifest() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
                                "Contents/Resources/PrivacyInfo.xcprivacy")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Resources")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        let types = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var reasons: [String: [String]] = [:]
        for t in types {
            let name = (t["NSPrivacyAccessedAPIType"] as? String ?? "").replacingOccurrences(of: "NSPrivacyAccessedAPICategory", with: "")
            reasons[name] = t["NSPrivacyAccessedAPITypeReasons"] as? [String]
        }
        XCTAssertEqual(reasons, ["UserDefaults": ["CA92.1"], "FileTimestamp": ["C617.1"], "DiskSpace": ["E174.1"]],
                       "the iOS app's reasons for the same uses, and no boot time")
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
    }

    /// No boot-time API anywhere in the app's sources (the manifest declares none).
    func testNoBootTimeAPIInTheApp() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var found: [String] = []
        for dir in ["Backline", "BacklineKit/Sources"] {
            let e = try XCTUnwrap(FileManager.default.enumerator(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil))
            for case let u as URL in e where u.pathExtension == "swift" {
                let text = try String(contentsOf: u, encoding: .utf8)
                if text.contains("systemUptime") || text.contains("mach_absolute_time") { found.append(u.lastPathComponent) }
            }
        }
        XCTAssertEqual(found, [])
    }

    // MARK: parity#5

    /// Try again on a person's own file resolves a security-scoped bookmark made in an earlier run: the sandbox
    /// needs the app-scope bookmark entitlement for that.
    func testTheAppMayKeepBookmarksToAPersonsFiles() throws {
        let task = try XCTUnwrap(SecTaskCreateFromSelf(nil))
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.files.bookmarks.app-scope" as CFString, nil)
        XCTAssertEqual(value as? Bool, true)
    }

    // MARK: mac-core#1

    func testQuitAsksFirstDuringARecording() {
        let m = AppModel()
        Self.keepAlive.append(m)
        XCTAssertNil(AppDelegate.quitQuestion(m), "nothing under way: quit at once")
        m.recordingUnderWay = true
        XCTAssertEqual(AppDelegate.quitQuestion(m), "A song is still being recorded.")
        m.recordingUnderWay = false
        m.screen = .analyzing
        XCTAssertEqual(AppDelegate.quitQuestion(m), "A song is still being split.")
        m.screen = .empty
    }

    // MARK: mac-core#2

    /// At launch a link's download nothing waits for goes; an unfinished import's file stays for Try again.
    func testUnusedLinkDownloadsAreRemovedAtLaunch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Downloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("cache"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let kept = dir.appendingPathComponent("kept-song.m4a"), old = dir.appendingPathComponent("failed-song.m4a")
        let video = dir.appendingPathComponent("big-video.mp4")
        for u in [kept, old, video] { try Data("audio".utf8).write(to: u) }
        ImportStaging.cleanUpDownloads(keeping: [kept.standardizedFileURL.path], in: dir)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        XCTAssertEqual(left, ["kept-song.m4a", "cache"])
    }

    // MARK: mac-core#3

    /// The Mac stays awake and out of App Nap for the length of an import, and lets go when it ends.
    func testAnImportKeepsTheMacAwakeUntilItEnds() async throws {
        let m = AppModel()
        Self.keepAlive.append(m)
        await m.libraryReady()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("not-audio-\(UUID().uuidString).mp3")
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let before = ImportKeepAwake.timesHeld
        m.open(file)
        for _ in 0..<400 where ImportKeepAwake.timesHeld == before { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(ImportKeepAwake.timesHeld, before + 1, "held when the import started")
        for _ in 0..<1200 { if case .failed = m.screen { break }; try await Task.sleep(for: .milliseconds(25)) }
        guard case .failed = m.screen else { return XCTFail("the import of a file that isn't audio ends with a message") }
        XCTAssertFalse(ImportKeepAwake.isHeld, "let go when the import ended")
        m.screen = .empty
    }

    func testKeepAwakeIsHeldOnce() {
        ImportKeepAwake.begin()
        ImportKeepAwake.begin()
        XCTAssertTrue(ImportKeepAwake.isHeld)
        ImportKeepAwake.end()
        XCTAssertFalse(ImportKeepAwake.isHeld, "one end lets go")
        ImportKeepAwake.end()
    }

    // MARK: parity#8

    /// Settings ▸ Extra parts says the same round figure as the General tab and the player's row.
    func testOneDownloadFigureEverywhere() {
        XCTAssertEqual(ModelsView.downloadLine(344_259_466 + 202_873_466), "One-time 550 MB download.")
        XCTAssertEqual(AppModel.extraPartsSize(344_259_466 + 202_873_466), "550 MB")
    }
}
