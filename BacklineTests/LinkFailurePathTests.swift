import BacklineKit
import XCTest
@testable import Backline

/// The failure paths of links (review 11 Nov, links.md L1, L2, L3, L10, L11), offline: a stub plays YouTube, its
/// streams and the search, so these run without the network and never touch the song service.
nonisolated final class LinkFailurePathTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        YouTubeStub.reset()
        YouTubeExtractor.VisitorCache.shared.drop()
        PlayerScript.forgetPlayerID()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("link-paths-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        // Nothing the stub handed out may reach the live tests that run after these.
        YouTubeExtractor.VisitorCache.shared.drop()
        PlayerScript.forgetPlayerID()
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [YouTubeStub.self]
        return URLSession(configuration: c)
    }

    /// The default ladder, with the TV client's streams handed out unlocked so no player script is needed here.
    private var ladder: [InnerTubeClient] {
        var tv = InnerTubeClient.tvSamsung
        tv.needsPlayer = false
        return [.visionOS, tv, .ios, .androidVR]
    }

    private func fetch(trace: Said = Said(), stages: Stages = Stages()) async throws -> YouTubeExtractor.Output {
        try await YouTubeExtractor.fetch(videoID: YouTubeStub.videoID, cookies: .none, destination: dir, ladder: ladder,
                                         proofOfOrigin: .off, session: session(), trace: { trace.add($0) },
                                         onStage: { stages.add($0) }, progress: { _ in }, isCancelled: { false })
    }

    // MARK: L1 refused streams

    /// Every stream refused (the bot wall the proof-of-origin step exists for): one more player answer per client
    /// (it was two), none after the TV client's ad slot, and no `android_vr` turn once both defaults were refused.
    func testRefusedStreamsAreAskedForAgainOnceAndNeverAfterAnAd() async throws {
        YouTubeStub.streams = .refuse
        let trace = Said()
        let stages = Stages()
        let start = Date()
        do {
            _ = try await fetch(trace: trace, stages: stages)
            XCTFail("every stream was refused")
        } catch {
            XCTAssertEqual((error as? YouTubeImport.Failure)?.errorDescription, YouTubeExtractor.genericMessage)
        }
        let players = YouTubeStub.playerRequests
        XCTAssertEqual(players["VISIONOS"], 2, "one retry (it was three tries)")
        XCTAssertEqual(players["TVHTML5"], 1, "no retry after waiting for an ad slot")
        XCTAssertEqual(players["IOS"], 2, "ios keeps its turn: its HLS rendition isn't gated")
        XCTAssertNil(players["ANDROID_VR"], "android_vr would need a token too")
        XCTAssertEqual(trace.all.filter { $0.contains("for the ad slot") }.count, 1, "one ad wait in all")
        XCTAssertTrue(trace.all.contains { $0.hasPrefix("android_vr: skipped") })
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "one 1 s ad wait, not three")
        XCTAssertTrue(stages.all.contains(.waitingForVideo), "the screen hears about the ad slot")
        XCTAssertEqual(stages.all.last, .connecting)
    }

    /// A random refusal of a fresh URL is still covered: the second answer's stream downloads.
    func testOneRefusalIsStillAskedAgain() async throws {
        YouTubeStub.streams = .refuseFirst(1)
        let out = try await fetch()
        XCTAssertEqual(out.clientID, "visionos")
        XCTAssertEqual(YouTubeStub.playerRequests["VISIONOS"], 2)
        XCTAssertEqual(try Data(contentsOf: out.file).count, YouTubeStub.audio.count)
    }

    // MARK: L11 visitor data and the player version

    /// The second link reuses the first one's anonymous visitor data; a refused stream drops it.
    func testVisitorDataIsFetchedOncePerSession() async throws {
        YouTubeStub.streams = .serve
        _ = try await fetch()
        let trace = Said()
        _ = try await fetch(trace: trace)
        XCTAssertEqual(YouTubeStub.count(path: "/youtubei/v1/visitor_id"), 1, "one visitor_id for two links")
        XCTAssertTrue(trace.all.contains("visitor data: reused"))

        YouTubeStub.streams = .refuseFirst(1)
        _ = try await fetch()
        XCTAssertEqual(YouTubeStub.count(path: "/youtubei/v1/visitor_id"), 2, "a refused stream asks for fresh visitor data")
        XCTAssertNotNil(YouTubeExtractor.VisitorCache.shared.current(), "and keeps the fresh one")
        XCTAssertNil(YouTubeExtractor.VisitorCache.shared.current(now: Date().addingTimeInterval(31 * 60)), "for 30 minutes")
    }

    func testThePlayerVersionIsAskedForOnceInTenMinutes() async throws {
        let s = session()
        let first = try await PlayerScript.playerID(session: s)
        let second = try await PlayerScript.playerID(session: s)
        XCTAssertEqual(first, "0123abcd")
        XCTAssertEqual(second, first)
        XCTAssertEqual(YouTubeStub.count(path: "/iframe_api"), 1)
        _ = try await PlayerScript.playerID(session: s, now: Date().addingTimeInterval(11 * 60))
        XCTAssertEqual(YouTubeStub.count(path: "/iframe_api"), 2, "asked again after ten minutes")
    }

    // MARK: L10 HLS segments

    /// Six in flight, the next one started as each finishes, appended strictly in order.
    func testHLSSegmentsSlideThroughASixWideWindowInOrder() async throws {
        let urls = (0..<40).map { URL(string: "https://seg.test/\($0).ts")! }
        let flight = InFlight()
        var appended: [Int] = []
        let fractions = Said()
        try await HLSAudio.fetchInOrder(urls, window: HLSAudio.window, fetch: { url in
            flight.enter()
            defer { flight.leave() }
            let i = Int(url.deletingPathExtension().lastPathComponent)!
            // Every fifth segment is slow: the others keep the window full meanwhile.
            try await Task.sleep(for: .milliseconds(i % 5 == 0 ? 60 : 5))
            return Data([UInt8(i)])
        }, append: { appended.append(Int($0[0])) }, progress: { fractions.add("\($0)") }, isCancelled: { false })
        XCTAssertEqual(appended, Array(0..<40), "in order")
        XCTAssertEqual(flight.peak, 6, "six at a time")
        XCTAssertEqual(fractions.all.count, 40)
        XCTAssertEqual(fractions.all.last, "1.0")
    }

    func testHLSStopsWhenCancelled() async {
        let urls = (0..<20).map { URL(string: "https://seg.test/\($0).ts")! }
        let calls = Said()
        do {
            try await HLSAudio.fetchInOrder(urls, window: 6, fetch: { _ in calls.add("x"); return Data([0]) }, append: { _ in },
                                            progress: { _ in }, isCancelled: { calls.all.count >= 3 })
            XCTFail("cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertLessThan(calls.all.count, 20)
    }

    // MARK: L3 a failed search

    private let song = SpotifySong(id: "558kPt5dAK4XskceUBSnqi", title: "Volatile Reaction", artists: ["Kevin MacLeod"], seconds: 165.355)

    /// A refused or rate-limited search is its own failure, which the song service gets round; offline isn't.
    func testARefusedSearchIsItsOwnFailure() async throws {
        YouTubeStub.search = .status(429)
        do {
            _ = try await SongSearch.find(song, session: session())
            XCTFail("the search was refused")
        } catch {
            XCTAssertEqual(error as? SpotifyImport.Failure, .searchFailed)
            XCTAssertTrue(AppModel.searchFailureTriesAnotherWay(error))
        }
        XCTAssertEqual(SpotifyImport.Failure.searchFailed.errorDescription, "Couldn't search for this song. Try again.")

        YouTubeStub.search = .fail(URLError(.notConnectedToInternet))
        do {
            _ = try await SongSearch.find(song, session: session())
            XCTFail("offline")
        } catch {
            XCTAssertEqual(error as? SpotifyImport.Failure, .offline)
            XCTAssertFalse(AppModel.searchFailureTriesAnotherWay(error), "offline, the service can't be reached either")
        }

        YouTubeStub.search = .fail(URLError(.timedOut))
        do {
            _ = try await SongSearch.find(song, session: session())
            XCTFail("timed out")
        } catch {
            XCTAssertEqual(error as? SpotifyImport.Failure, .network)
            XCTAssertTrue(AppModel.searchFailureTriesAnotherWay(error))
        }
        XCTAssertFalse(AppModel.searchFailureTriesAnotherWay(CancellationError()))
    }

    // MARK: L2 the song service's audio

    /// The service's audio arrives through a download task: the bar moves, reaches the end, and the file lands on
    /// disk without passing through memory whole.
    func testTheServicesAudioReportsProgressToTheEnd() async throws {
        let reply = Data("""
        {"song": {"song_id": "sng_1", "title": "T", "artist": "A", "duration_s": 165.0},
         "audio": {"url": "https://storage.test/a.m4a"}, "identity": "confirmed", "processing": {"fetched": false}}
        """.utf8)
        ServiceStub.reset()
        ServiceStub.answers = [.init(status: 200, body: reply), .init(status: 200, body: Data(repeating: 9, count: 300_000))]
        defer { ServiceStub.reset() }
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [ServiceStub.self]
        let fractions = Said()
        let got = try await SongService.fetch(SongService.Ask(artist: "A", title: "T"), expectedSeconds: 165,
                                              config: SongService.Config(base: URL(string: "https://service.test")!, key: "k"),
                                              into: dir, session: URLSession(configuration: c), sleep: { _ in },
                                              progress: { fractions.add("\($0)") })
        XCTAssertEqual(try Data(contentsOf: got.file).count, 300_000)
        XCTAssertEqual(fractions.all.last, "1.0", "progress reaches 1")
        XCTAssertLessThanOrEqual(fractions.all.count, 102)
        XCTAssertNil(ServiceStub.seen.last?.key, "the signed link is fetched without the key")
    }

    func testAServiceDownloadCanBeCancelled() async throws {
        let reply = Data("""
        {"song": {"song_id": "sng_2", "title": "T", "artist": "A", "duration_s": 165.0},
         "audio": {"url": "https://stall.test/a.m4a"}, "identity": "confirmed", "processing": {"fetched": false}}
        """.utf8)
        ServiceStub.reset()
        ServiceStub.answers = [.init(status: 200, body: reply)]
        defer { ServiceStub.reset() }
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StallProtocol.self, ServiceStub.self]
        let folder = dir!
        let task = Task {
            try await SongService.fetch(SongService.Ask(artist: "A", title: "T"), config: SongService.Config(base: URL(string: "https://service.test")!, key: "k"),
                                        into: folder, session: URLSession(configuration: c), sleep: { _ in })
        }
        try await Task.sleep(for: .milliseconds(500))
        let start = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    // MARK: L2 what the screen says

    @MainActor
    func testTheGettingTheSongLineDuringALongWait() {
        func p(_ f: Double) -> ImportProgress { ImportProgress(phase: 0, fraction: f, secondsRemaining: nil) }
        XCTAssertEqual(AnalyzingView.eta(p(0), getting: true), "Connecting…")
        XCTAssertEqual(AnalyzingView.eta(p(0), getting: true, wait: .waitingForVideo), "Waiting for the video…")
        XCTAssertEqual(AnalyzingView.eta(p(0), getting: true, wait: .waitingForVideo, stillTrying: true),
                       "Still trying. This can take a minute.")
        XCTAssertEqual(AnalyzingView.eta(p(0), getting: true, finding: true, stillTrying: true), "Still trying. This can take a minute.")
        XCTAssertEqual(AnalyzingView.eta(p(0.2), getting: true, stillTrying: true), "Downloading…", "bytes arriving win")
        XCTAssertEqual(AnalyzingView.eta(p(0), getting: true, anotherWay: true, stillTrying: true), "Trying another way…")
        XCTAssertEqual(AnalyzingView.eta(p(0), getting: true, anotherWay: true, serviceMinutes: 2), "Trying another way · 2 min")
        XCTAssertEqual(AnalyzingView.eta(p(0.4), getting: true, anotherWay: true, serviceMinutes: 3), "Downloading…",
                       "the service's audio has progress")

        XCTAssertFalse(AnalyzingView.offersRecording(getting: true, fraction: 0, stillTrying: false, anotherWay: false))
        XCTAssertTrue(AnalyzingView.offersRecording(getting: true, fraction: 0, stillTrying: true, anotherWay: false))
        XCTAssertFalse(AnalyzingView.offersRecording(getting: true, fraction: 0.3, stillTrying: true, anotherWay: false))
        XCTAssertTrue(AnalyzingView.offersRecording(getting: true, fraction: 0.3, stillTrying: true, anotherWay: true))
        XCTAssertFalse(AnalyzingView.offersRecording(getting: false, fraction: 0, stillTrying: true, anotherWay: true))
    }

    /// The clock behind "Still trying": it starts with the link, stops with it, and counts the service's minutes.
    @MainActor
    func testTheWaitClock() async throws {
        let wait = LinkWait(stillTryingAfter: .milliseconds(150), minute: .milliseconds(100))
        wait.begin()
        XCTAssertFalse(wait.stillTrying)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(wait.stillTrying)
        wait.serviceBegan()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertGreaterThanOrEqual(wait.serviceMinutes, 1, "a minute is counted")
        wait.stage = .waitingForVideo
        wait.end()
        XCTAssertFalse(wait.stillTrying)
        XCTAssertEqual(wait.serviceMinutes, 0)
        XCTAssertEqual(wait.stage, .connecting)
        wait.begin()
        wait.end()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(wait.stillTrying, "an ended link never says it is still trying")
    }
}

// MARK: - Helpers

final class Said: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ s: String) { lock.withLock { lines.append(s) } }
    var all: [String] { lock.withLock { lines } }
}

final class Stages: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [YouTubeExtractor.Stage] = []
    func add(_ s: YouTubeExtractor.Stage) { lock.withLock { stages.append(s) } }
    var all: [YouTubeExtractor.Stage] { lock.withLock { stages } }
}

final class InFlight: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0
    private var top = 0
    func enter() { lock.withLock { now += 1; top = max(top, now) } }
    func leave() { lock.withLock { now -= 1 } }
    var peak: Int { lock.withLock { top } }
}

/// Plays YouTube for the extractor: visitor data, a player answer per client (the TV one with a 1 s pre-roll ad),
/// the audio stream (refused or served), `iframe_api`, and the search.
final class YouTubeStub: URLProtocol, @unchecked Sendable {
    enum Streams { case refuse, serve, refuseFirst(Int) }
    enum Search { case status(Int), fail(URLError) }

    static let videoID = "2pXa5jzaOBg"
    /// An MP4 header and some bytes: enough for the ranged download's checks.
    static let audio = Data([0, 0, 0, 0x18] + Array("ftypM4A ".utf8)) + Data(repeating: 1, count: 2_000)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _streams = Streams.refuse
    nonisolated(unsafe) private static var _search = Search.status(429)
    nonisolated(unsafe) private static var paths: [String] = []
    nonisolated(unsafe) private static var players: [String: Int] = [:]
    nonisolated(unsafe) private static var refusedSoFar = 0

    static var streams: Streams {
        get { lock.withLock { _streams } }
        set { lock.withLock { _streams = newValue; refusedSoFar = 0 } }
    }
    static var search: Search {
        get { lock.withLock { _search } }
        set { lock.withLock { _search = newValue } }
    }
    static var playerRequests: [String: Int] { lock.withLock { players } }
    static func count(path: String) -> Int { lock.withLock { paths.filter { $0 == path }.count } }
    static func reset() {
        lock.withLock { _streams = .refuse; _search = .status(429); paths = []; players = [:]; refusedSoFar = 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.withLock { Self.paths.append(url.path) }
        switch (url.host ?? "", url.path) {
        case (_, "/youtubei/v1/visitor_id"):
            reply(200, json: #"{"responseContext":{"visitorData":"CgtTdHViVmlzaXRvcg%3D%3D"}}"#)
        case (_, "/youtubei/v1/player"):
            let name = Self.clientName(request.value(forHTTPHeaderField: "X-YouTube-Client-Name"))
            Self.lock.withLock { Self.players[name, default: 0] += 1 }
            let ad = name == "TVHTML5"
                ? #","adPlacements":[{"adPlacementRenderer":{"config":{"adPlacementConfig":{"kind":"AD_PLACEMENT_KIND_START"}},"renderer":{"instreamVideoAdRenderer":{"skipOffsetMilliseconds":1000}}}}]"#
                : ""
            reply(200, json: #"{"playabilityStatus":{"status":"OK"},"videoDetails":{"videoId":"\#(Self.videoID)","title":"Volatile Reaction","author":"Kevin MacLeod","lengthSeconds":"163"},"streamingData":{"adaptiveFormats":[{"itag":140,"mimeType":"audio/mp4; codecs=\"mp4a.40.2\"","url":"https://stream.test/videoplayback?itag=140","contentLength":"\#(Self.audio.count)"}]}\#(ad)}"#)
        case ("stream.test", _):
            let refuse: Bool = Self.lock.withLock {
                switch Self._streams {
                case .refuse: return true
                case .serve: return false
                case .refuseFirst(let n):
                    guard Self.refusedSoFar < n else { return false }
                    Self.refusedSoFar += 1
                    return true
                }
            }
            if refuse { reply(403, json: "") } else { reply(200, body: Self.audio, type: "audio/mp4") }
        case (_, "/iframe_api"):
            reply(200, body: Data(#"var a="https:\/\/www.youtube.com\/s\/player\/0123abcd\/www-widgetapi.vflset\/www-widgetapi.js";"#.utf8),
                  type: "text/javascript")
        case (_, "/youtubei/v1/search"):
            switch Self.search {
            case .status(let code): reply(code, json: "{}")
            case .fail(let error): client?.urlProtocol(self, didFailWithError: error)
            }
        default:
            reply(404, json: "")
        }
    }

    private static func clientName(_ id: String?) -> String {
        switch id {
        case "101": "VISIONOS"
        case "7": "TVHTML5"
        case "5": "IOS"
        case "28": "ANDROID_VR"
        default: id ?? "?"
        }
    }

    private func reply(_ status: Int, json: String) { reply(status, body: Data(json.utf8), type: "application/json") }

    private func reply(_ status: Int, body: Data, type: String) {
        let headers = ["Content-Type": type, "Content-Length": String(body.count)]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
