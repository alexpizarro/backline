import Foundation
import Observation

/// Tells people when a newer Backline is out, so they know to update. One file, two sources, chosen when the
/// app is built:
///
/// - The Mac App Store build (`BACKLINE_APP_STORE`) asks Apple's public lookup service for the Mac listing
///   (`itunes.apple.com/lookup?id=…&entity=desktopSoftware`). iPhone, iPad and Mac share one App Store record, and
///   the plain lookup answers with the iPhone listing, whose version can be ahead of the Mac's while the Mac is in
///   review. Only a result whose devices are all Macs counts; its minimum macOS is checked. Update opens the Mac
///   App Store page.
/// - The disk image reads the releases of `alexpizarro/backline` on GitHub and takes the highest Mac release
///   (tagged `v1.2.3`; Android and model releases live there too, and GitHub's "latest" pointer is not trusted).
///   Download opens that release's page.
///
/// When the app becomes active: once a day after an answer, every 4 hours after a failure. The requests carry
/// nothing about the person: no account, no device identifier, a plain User-Agent (the App Store lookup sends the
/// Mac's country). If the version is newer than this one, the Library sidebar shows a row with the button and
/// Not now, and Settings ▸ About shows it too. Not now hides that version only; a later one shows again.
///
/// The last answer is kept, per source (both builds share one container), so the row shows at launch without
/// waiting for the network. Under XCTest, `--no-downloads` and snapshot runs nothing is fetched, and Debug runs
/// with harness arguments neither fetch nor show a kept answer; `--update-stub <version>` (Debug) puts a version
/// on screen for that run only.
@MainActor @Observable
final class AppUpdate {
    static let shared = AppUpdate()

    /// App Store Connect's ID for Backline (iPhone, iPad and Mac share it).
    nonisolated static let appID = "6825971057"
    nonisolated static let storeURL = URL(string: "macappstore://apps.apple.com/app/id\(appID)")!
    nonisolated static let storeWebURL = URL(string: "https://apps.apple.com/app/id\(appID)")!
    nonisolated static let githubList = URL(string: "https://api.github.com/repos/alexpizarro/backline/releases?per_page=100")!
    nonisolated static let githubReleases = URL(string: "https://github.com/alexpizarro/backline/releases")!
    /// How long an answer is trusted before asking again, and how long to wait after a failed try.
    nonisolated static let checkInterval: TimeInterval = 24 * 60 * 60
    nonisolated static let retryInterval: TimeInterval = 4 * 60 * 60

    /// Where this build learns about new versions.
    nonisolated enum Source: String, Sendable { case appStore, github }
    nonisolated static var source: Source {
        #if BACKLINE_APP_STORE
        .appStore
        #else
        .github
        #endif
    }

    /// A version that is out, the oldest macOS it runs on (App Store), and the page that gets it (GitHub).
    nonisolated struct Release: Codable, Equatable, Sendable {
        let version: String
        var minimumOsVersion: String?
        var page: URL?
    }

    /// What one try found: a release, a good answer with no Mac release in it, or nothing usable.
    nonisolated enum Outcome: Equatable, Sendable { case found(Release), none, failed }

    /// The newer version to offer anywhere (Settings), or nil.
    private(set) var newerVersion: String?
    /// The newer version to offer in the Library: `newerVersion` unless Not now hid it.
    private(set) var libraryOffer: String?
    /// Where Update/Download goes.
    private(set) var page: URL = AppUpdate.source == .appStore ? AppUpdate.storeURL : AppUpdate.githubReleases

    private let defaults: UserDefaults
    private let source: Source
    private var checking = false
    /// `--update-stub`: the version on screen for this run; nothing is saved.
    private var stub: String?
    private var stubHidden = false

    nonisolated static func key(_ field: String, source: Source = source) -> String { "appUpdate.\(source.rawValue).\(field)" }

    init(defaults: UserDefaults = .standard, source: Source = AppUpdate.source) {
        self.defaults = defaults
        self.source = source
        #if DEBUG
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--update-stub"), i + 1 < a.count { stub = a[i + 1] }
        #endif
        refreshOffer()
    }

    /// A main-actor class otherwise gets an isolated deinit, which crashes on this deployment target
    /// (`swift_task_deinitOnExecutorMainActorBackDeploy`). The app keeps only `shared`; the tests make their own.
    nonisolated deinit {}

    // MARK: Asking

    /// A Debug run started with harness arguments (snapshots, scripted runs): it neither asks nor shows a kept answer.
    nonisolated static var isHarnessRun: Bool {
        #if DEBUG
        CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--") }
        #else
        false
        #endif
    }

    /// Off in tests: XCTest, `--no-downloads`, snapshot and harness runs never reach the network.
    nonisolated static var isEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["XCTestSessionIdentifier"] != nil { return false }
        let args = CommandLine.arguments
        if args.contains("--no-downloads") || args.contains("--snapshot") || isHarnessRun { return false }
        return true
    }

    /// Whether it's time to ask: a day after an answer, 4 hours after a failure (a clock set back asks again).
    nonisolated static func isDue(lastChecked: Date?, lastFailed: Date?, now: Date) -> Bool {
        func waited(_ since: Date?, _ interval: TimeInterval) -> Bool {
            guard let since, since <= now else { return true }
            return now.timeIntervalSince(since) >= interval
        }
        return waited(lastChecked, checkInterval) && waited(lastFailed, retryInterval)
    }

    /// Called each time the app becomes active; asks only when `isDue`.
    func checkIfDue(now: Date = Date()) {
        guard Self.isEnabled, !checking,
              Self.isDue(lastChecked: defaults.object(forKey: Self.key("lastChecked", source: source)) as? Date,
                         lastFailed: defaults.object(forKey: Self.key("lastFailed", source: source)) as? Date, now: now)
        else { return }
        checking = true
        let source = source
        Task {
            defer { checking = false }
            let outcome = await Self.fetch(source)
            record(outcome, now: now)
        }
    }

    /// What a try found, kept for the next launch. A good answer with no Mac release in it clears the old one.
    func record(_ outcome: Outcome, now: Date) {
        switch outcome {
        case .failed:
            defaults.set(now, forKey: Self.key("lastFailed", source: source))
            return
        case .found(let release):
            if let data = try? JSONEncoder().encode(release) { defaults.set(data, forKey: Self.key("release", source: source)) }
        case .none:
            defaults.removeObject(forKey: Self.key("release", source: source))
        }
        defaults.set(now, forKey: Self.key("lastChecked", source: source))
        defaults.removeObject(forKey: Self.key("lastFailed", source: source))
        refreshOffer()
    }

    /// Not now: the Library stops offering this version. Settings still offers it.
    func hide() {
        guard let v = newerVersion else { return }
        if stub != nil { stubHidden = true } else { defaults.set(v, forKey: Self.key("hidden", source: source)) }
        refreshOffer()
    }

    /// Reads the kept answer again (after Reset Backline cleared it).
    func refreshOffer() {
        if let stub {
            newerVersion = stub
            libraryOffer = stubHidden ? nil : stub
            return
        }
        guard !Self.isHarnessRun, !CommandLine.arguments.contains("--snapshot") else {
            newerVersion = nil; libraryOffer = nil; return
        }
        let release = defaults.data(forKey: Self.key("release", source: source))
            .flatMap { try? JSONDecoder().decode(Release.self, from: $0) }
        newerVersion = Self.offer(release, current: Self.currentVersion, os: ProcessInfo.processInfo.operatingSystemVersion)
        libraryOffer = newerVersion == defaults.string(forKey: Self.key("hidden", source: source)) ? nil : newerVersion
        page = source == .appStore ? Self.storeURL : (release?.page ?? Self.githubReleases)
    }

    nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    nonisolated static func fetch(_ source: Source) async -> Outcome {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // A plain User-Agent: not the app's build number and the Mac's Darwin version that URLSession sends.
        config.httpAdditionalHeaders = ["User-Agent": "Backline", "Accept-Language": "en"]
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        switch source {
        case .github:
            var request = URLRequest(url: githubList)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return .failed }
            return parseGitHub(data)
        case .appStore:
            // The Mac's App Store country first; with no Mac listing there, the lookup without a country.
            var regions: [String?] = [nil]
            if let region = Locale.current.region?.identifier, region.count == 2 { regions.insert(region, at: 0) }
            var outcome = Outcome.failed
            for region in regions {
                guard let (data, response) = try? await session.data(from: lookupURL(region: region)),
                      (response as? HTTPURLResponse)?.statusCode == 200 else { return .failed }
                outcome = parseLookup(data)
                if case .found = outcome { return outcome }
            }
            return outcome
        }
    }

    // MARK: Plain rules (tested)

    nonisolated static func lookupURL(region: String?) -> URL {
        var c = URLComponents(string: "https://itunes.apple.com/lookup")!
        c.queryItems = [URLQueryItem(name: "id", value: appID), URLQueryItem(name: "entity", value: "desktopSoftware")]
        if let region { c.queryItems?.append(URLQueryItem(name: "country", value: region.lowercased())) }
        return c.url!
    }

    /// The Mac listing in a lookup answer: the result whose devices are all Macs. The iPhone listing names the Mac
    /// too (iPhone apps run on Apple silicon), so "names a Mac" isn't enough.
    nonisolated static func parseLookup(_ data: Data) -> Outcome {
        struct Answer: Decodable {
            struct R: Decodable { let version: String?; let minimumOsVersion: String?; let supportedDevices: [String]? }
            let results: [R]
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { return .failed }
        let mac = answer.results.first { r in
            guard let d = r.supportedDevices, !d.isEmpty else { return false }
            return d.allSatisfy { $0.hasPrefix("MacDesktop") }
        }
        guard let mac, let v = mac.version, !v.isEmpty else { return .none }
        return .found(Release(version: v, minimumOsVersion: mac.minimumOsVersion))
    }

    /// The highest published Mac release (`v` and a number) in GitHub's release list. Android, model, draft and
    /// pre-releases are skipped; a page outside Backline's releases is never opened.
    nonisolated static func parseGitHub(_ data: Data) -> Outcome {
        struct R: Decodable { let tag_name: String; let html_url: String?; let draft: Bool?; let prerelease: Bool? }
        guard let list = try? JSONDecoder().decode([R].self, from: data) else { return .failed }
        let macs = list.filter { r in
            r.draft != true && r.prerelease != true && r.tag_name.hasPrefix("v") && r.tag_name.dropFirst().first?.isNumber == true
        }
        guard let best = macs.max(by: { isNewer(String($1.tag_name.dropFirst()), than: String($0.tag_name.dropFirst())) })
        else { return .none }
        let page = best.html_url.flatMap(URL.init(string:)).flatMap(releasePage)
        return .found(Release(version: String(best.tag_name.dropFirst()), page: page))
    }

    /// Only a page under `https://github.com/alexpizarro/backline/releases/`.
    nonisolated static func releasePage(_ url: URL) -> URL? {
        url.absoluteString.hasPrefix(githubReleases.absoluteString + "/") && url.scheme == "https" ? url : nil
    }

    /// The version that is out, when it's newer than `current` and this macOS can run it.
    nonisolated static func offer(_ release: Release?, current: String, os: OperatingSystemVersion) -> String? {
        guard let release, isNewer(release.version, than: current) else { return nil }
        if let min = release.minimumOsVersion,
           isNewer(min, than: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)") { return nil }
        return release.version
    }

    /// Dotted version numbers, compared part by part: 1.1.1 is newer than 1.1, and 1.10 than 1.9.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    nonisolated private static func parts(_ v: String) -> [Int] {
        v.trimmingCharacters(in: .whitespaces).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    // MARK: Words

    /// The line under the row's title.
    nonisolated static func line(version: String, source: Source = source) -> String {
        source == .appStore ? "Version \(version) is in the App Store." : "Version \(version) is ready to download."
    }
    /// The row's button.
    nonisolated static func buttonTitle(source: Source = source) -> String { source == .appStore ? "Update" : "Download" }
    /// Settings ▸ About.
    nonisolated static func settingsTitle(version: String, source: Source = source) -> String {
        source == .appStore ? "Update to version \(version)" : "Download version \(version)"
    }
}
