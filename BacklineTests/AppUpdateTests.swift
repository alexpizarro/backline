import XCTest
@testable import Backline

/// The update notice (`AppUpdate`): which answers count, when a version is offered, when to ask, the words for
/// each build, and what Not now hides. Nothing here touches the network.
final class AppUpdateTests: XCTestCase {
    private typealias U = AppUpdate
    private let tahoe = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)

    func testVersionsCompareNumberByNumber() {
        XCTAssertTrue(U.isNewer("1.1.1", than: "1.1"))
        XCTAssertTrue(U.isNewer("1.10", than: "1.9"))
        XCTAssertFalse(U.isNewer("1.1", than: "1.1.0"))
        XCTAssertFalse(U.isNewer("1.1", than: "1.1.1"))
    }

    func testOnlyANewerVersionThisMacCanRunIsOffered() {
        XCTAssertEqual(U.offer(U.Release(version: "1.2"), current: "1.1.1", os: tahoe), "1.2")
        XCTAssertNil(U.offer(U.Release(version: "1.1.1"), current: "1.1.1", os: tahoe))
        XCTAssertNil(U.offer(U.Release(version: "1.1"), current: "1.1.1", os: tahoe), "a build ahead of the release is never told to go back")
        XCTAssertNil(U.offer(U.Release(version: "1.2", minimumOsVersion: "27.0"), current: "1.1.1", os: tahoe),
                     "a version this Mac can't install is not offered")
        XCTAssertEqual(U.offer(U.Release(version: "1.2", minimumOsVersion: "15.0"), current: "1.1.1", os: tahoe), "1.2")
        XCTAssertNil(U.offer(nil, current: "1.1.1", os: tahoe))
    }

    /// GitHub's list holds Mac, Android and model releases; only the highest published Mac one counts, whatever
    /// GitHub calls latest and whatever order the list is in.
    func testTheGitHubListCountsOnlyMacReleases() {
        let list = #"""
        [{"tag_name":"v1.0","html_url":"https://github.com/alexpizarro/backline/releases/tag/v1.0","draft":false,"prerelease":false},
         {"tag_name":"android-v1.9","html_url":"https://github.com/alexpizarro/backline/releases/tag/android-v1.9","draft":false,"prerelease":false},
         {"tag_name":"models-android-1","html_url":"https://github.com/alexpizarro/backline/releases/tag/models-android-1","draft":false,"prerelease":false},
         {"tag_name":"v1.1.1","html_url":"https://github.com/alexpizarro/backline/releases/tag/v1.1.1","draft":false,"prerelease":false},
         {"tag_name":"v1.3","html_url":"https://github.com/alexpizarro/backline/releases/tag/v1.3","draft":false,"prerelease":true},
         {"tag_name":"v1.4","html_url":"https://github.com/alexpizarro/backline/releases/tag/v1.4","draft":true,"prerelease":false}]
        """#
        XCTAssertEqual(U.parseGitHub(Data(list.utf8)),
                       .found(U.Release(version: "1.1.1", page: URL(string: "https://github.com/alexpizarro/backline/releases/tag/v1.1.1"))))
        let noMac = #"[{"tag_name":"android-v1.1","html_url":"https://github.com/x","draft":false,"prerelease":false}]"#
        XCTAssertEqual(U.parseGitHub(Data(noMac.utf8)), .none, "a good answer with no Mac release in it")
        XCTAssertEqual(U.parseGitHub(Data(#"{"message":"API rate limit exceeded"}"#.utf8)), .failed)
    }

    func testOnlyBacklinesOwnReleasePagesAreOpened() {
        let list = #"[{"tag_name":"v2.0","html_url":"https://evil.example/releases/tag/v2.0","draft":false,"prerelease":false}]"#
        XCTAssertEqual(U.parseGitHub(Data(list.utf8)), .found(U.Release(version: "2.0", page: nil)), "the releases page instead")
        XCTAssertNil(U.releasePage(URL(string: "http://github.com/alexpizarro/backline/releases/tag/v2.0")!))
        XCTAssertNil(U.releasePage(URL(string: "https://github.com/alexpizarro/backline-evil/releases/tag/v2.0")!))
    }

    /// The shared App Store record: the plain lookup is the iPhone listing (which names the Mac too); only the
    /// listing whose devices are all Macs counts (shapes taken from the live lookup on 19 November 2026).
    func testTheAppStoreAnswerCountsOnlyTheMacListing() {
        let mac = #"{"resultCount":1,"results":[{"version":"1.1","minimumOsVersion":"15.0","supportedDevices":["MacDesktop-MacDesktop"]}]}"#
        XCTAssertEqual(U.parseLookup(Data(mac.utf8)), .found(U.Release(version: "1.1", minimumOsVersion: "15.0")))
        let phone = #"{"resultCount":1,"results":[{"version":"1.1.1","minimumOsVersion":"18.0","supportedDevices":["MacDesktop-MacDesktop","iPhone5s-iPhone5s"]}]}"#
        XCTAssertEqual(U.parseLookup(Data(phone.utf8)), .none, "the iPhone's version is never offered on the Mac")
        XCTAssertEqual(U.parseLookup(Data(#"{"resultCount":0,"results":[]}"#.utf8)), .none)
        XCTAssertEqual(U.parseLookup(Data("<html>".utf8)), .failed)
        XCTAssertEqual(U.lookupURL(region: "AU").absoluteString,
                       "https://itunes.apple.com/lookup?id=6825971057&entity=desktopSoftware&country=au")
    }

    func testItAsksDailyAndEveryFourHoursAfterAFailure() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(U.isDue(lastChecked: nil, lastFailed: nil, now: now))
        XCTAssertFalse(U.isDue(lastChecked: now.addingTimeInterval(-23 * 3600), lastFailed: nil, now: now))
        XCTAssertTrue(U.isDue(lastChecked: now.addingTimeInterval(-25 * 3600), lastFailed: nil, now: now))
        XCTAssertFalse(U.isDue(lastChecked: nil, lastFailed: now.addingTimeInterval(-3600), now: now), "not on every switch back")
        XCTAssertTrue(U.isDue(lastChecked: nil, lastFailed: now.addingTimeInterval(-5 * 3600), now: now))
        XCTAssertTrue(U.isDue(lastChecked: now.addingTimeInterval(3600), lastFailed: nil, now: now), "a clock set back asks again")
    }

    func testEachBuildSaysWhereTheUpdateIs() {
        XCTAssertEqual(U.line(version: "1.2", source: .appStore), "Version 1.2 is in the App Store.")
        XCTAssertEqual(U.buttonTitle(source: .appStore), "Update")
        XCTAssertEqual(U.settingsTitle(version: "1.2", source: .appStore), "Update to version 1.2")
        XCTAssertEqual(U.line(version: "1.2", source: .github), "Version 1.2 is ready to download.")
        XCTAssertEqual(U.buttonTitle(source: .github), "Download")
        XCTAssertEqual(U.settingsTitle(version: "1.2", source: .github), "Download version 1.2")
        XCTAssertEqual(U.source, .github, "the test build is the disk image's")
    }

    @MainActor func testNotNowHidesThatVersionFromTheLibraryOnly() throws {
        let (defaults, done) = try scratch()
        defer { done() }
        let now = Date()
        var update = AppUpdate(defaults: defaults, source: .github)
        update.record(.found(U.Release(version: "98.0", page: URL(string: "https://github.com/alexpizarro/backline/releases/tag/v98.0"))), now: now)
        XCTAssertEqual(update.libraryOffer, "98.0")
        XCTAssertEqual(update.page, URL(string: "https://github.com/alexpizarro/backline/releases/tag/v98.0"), "Download opens that release's page")
        update.hide()
        XCTAssertEqual(update.newerVersion, "98.0", "Settings still offers it")
        XCTAssertNil(update.libraryOffer)
        XCTAssertNil(AppUpdate(defaults: defaults, source: .github).libraryOffer, "Not now lasts across launches")
        update.record(.found(U.Release(version: "99.0")), now: now)
        XCTAssertEqual(update.libraryOffer, "99.0", "a later version shows again")
        update.record(.none, now: now)
        XCTAssertNil(update.newerVersion, "a good answer with no release clears the old one")
    }

    /// Both builds share one container: the disk image's GitHub answer never shows in the App Store build, and the
    /// App Store build's Update always opens the App Store.
    @MainActor func testTheTwoBuildsKeepTheirOwnAnswers() throws {
        let (defaults, done) = try scratch()
        defer { done() }
        AppUpdate(defaults: defaults, source: .github)
            .record(.found(U.Release(version: "98.0", page: URL(string: "https://github.com/alexpizarro/backline/releases/tag/v98.0"))), now: Date())
        let store = AppUpdate(defaults: defaults, source: .appStore)
        XCTAssertNil(store.newerVersion)
        store.record(.found(U.Release(version: "97.0", minimumOsVersion: "15.0")), now: Date())
        XCTAssertEqual(store.newerVersion, "97.0")
        XCTAssertEqual(store.page, U.storeURL)
    }

    /// A failed try keeps the last answer and waits 4 hours; it doesn't count as a day's answer.
    @MainActor func testAFailureKeepsTheLastAnswer() throws {
        let (defaults, done) = try scratch()
        defer { done() }
        let update = AppUpdate(defaults: defaults, source: .github)
        update.record(.found(U.Release(version: "98.0")), now: Date())
        update.record(.failed, now: Date())
        XCTAssertEqual(update.newerVersion, "98.0")
        XCTAssertNotNil(defaults.object(forKey: U.key("lastFailed", source: .github)))
    }

    func testTestsNeverAsk() { XCTAssertFalse(U.isEnabled) }

    /// The real services, as each build asks them: Apple's Mac listing and GitHub's Mac releases both answer with
    /// a version (skip with BACKLINE_SKIP_NETWORK_TESTS).
    func testTheLiveServicesAnswer() async throws {
        if ProcessInfo.processInfo.environment["BACKLINE_SKIP_NETWORK_TESTS"] != nil { throw XCTSkip("BACKLINE_SKIP_NETWORK_TESTS is set") }
        for source in [U.Source.appStore, .github] {
            guard case .found(let r) = await U.fetch(source) else { return XCTFail("\(source): no release") }
            XCTAssertTrue(r.version.first?.isNumber == true, "\(source): \(r.version)")
            if source == .github { XCTAssertNotNil(r.page) } else { XCTAssertEqual(r.minimumOsVersion, "15.0") }
            print("[live] \(source): \(r)")
        }
    }

    private func scratch() throws -> (UserDefaults, () -> Void) {
        let suite = "AppUpdateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }
}
