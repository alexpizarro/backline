import XCTest
@testable import Backline

/// The song service's client (owner, 6 November 2026), offline: a stub plays the service and its storage. The real
/// service is billed while awake, so no test ever calls it.
final class SongServiceTests: XCTestCase {
    private let config = SongService.Config(base: URL(string: "https://service.test")!, key: "test-key")
    private var dir: URL!

    override func setUp() {
        super.setUp()
        ServiceStub.reset()
        SongService.resetStopForTests()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("song-service-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        SongService.resetStopForTests()
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [ServiceStub.self]
        return URLSession(configuration: c, delegate: SongService.KeyGuard(), delegateQueue: nil)
    }

    private static func reply(identity: String = "unconfirmed", seconds: Double? = 163.35, url: String? = "https://storage.test/a.m4a") -> Data {
        let link = url.map { "\"\($0)\"" } ?? "null"
        let length = seconds.map { "\($0)" } ?? "null"
        return Data("""
        {"song": {"song_id": "sng_abc123", "title": "Volatile Reaction", "artist": "Kevin MacLeod", "duration_s": \(length)},
         "audio": {"url": \(link), "content_type": "audio/mp4", "format": "m4a", "size_bytes": 4000},
         "identity": "\(identity)", "processing": {"fetched": true, "elapsed_s": 31.2}, "new_field": 1}
        """.utf8)
    }

    func testTheServiceIsOffInTests() {
        XCTAssertNil(SongService.config, "tests never reach the real, billed service")
    }

    func testTheBuildSettingsMustBeFilledIn() {
        XCTAssertEqual(SongService.Config.fromBuild(["BLSongServiceBaseURL": "https://a.test", "BLSongServiceKey": "k"]),
                       SongService.Config(base: URL(string: "https://a.test")!, key: "k"))
        XCTAssertNil(SongService.Config.fromBuild(["BLSongServiceBaseURL": "", "BLSongServiceKey": ""]), "no key file on this Mac")
        XCTAssertNil(SongService.Config.fromBuild(["BLSongServiceBaseURL": "$(BL_SONG_SERVICE_URL)", "BLSongServiceKey": "$(BL_SONG_SERVICE_KEY)"]))
        XCTAssertNil(SongService.Config.fromBuild(["BLSongServiceBaseURL": "http://a.test", "BLSongServiceKey": "k"]), "https only")
        XCTAssertNil(SongService.Config.fromBuild(nil))
    }

    func testTheRequestCarriesOnlyWhatIsKnown() throws {
        let both = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SongService.Ask(artist: "A", title: "T"))) as? [String: String]
        XCTAssertEqual(both, ["artist": "A", "title": "T"])
        let link = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SongService.Ask(artist: " ", reference: "https://www.youtube.com/watch?v=x"))) as? [String: String]
        XCTAssertEqual(link, ["reference": "https://www.youtube.com/watch?v=x"])
        XCTAssertFalse(SongService.Ask(artist: "A").isUsable, "a name needs its title too")
        XCTAssertTrue(SongService.Ask(reference: "https://www.youtube.com/watch?v=x").isUsable)
    }

    func testEveryAnswerByTheServicesRules() {
        XCTAssertEqual(SongService.attempt(status: 400, data: Data(), retryAfter: nil), .failed(.badRequest))
        XCTAssertEqual(SongService.attempt(status: 401, data: Data(), retryAfter: nil), .failed(.unauthorized))
        XCTAssertEqual(SongService.attempt(status: 404, data: Data(#"{"error": "not held"}"#.utf8), retryAfter: nil), .failed(.notHeld))
        XCTAssertEqual(SongService.attempt(status: 404, data: Data(#"{"detail": "Not Found"}"#.utf8), retryAfter: nil), .failed(.unavailable),
                       "the route isn't deployed")
        XCTAssertEqual(SongService.attempt(status: 502, data: Data(), retryAfter: nil), .failed(.refused))
        XCTAssertEqual(SongService.attempt(status: 503, data: Data(), retryAfter: "7"), .busy(7))
        XCTAssertEqual(SongService.attempt(status: 503, data: Data(), retryAfter: nil), .busy(5))
        XCTAssertEqual(SongService.attempt(status: 504, data: Data(), retryAfter: nil), .transient)
        XCTAssertEqual(SongService.attempt(status: 500, data: Data(), retryAfter: nil), .transient)
        XCTAssertEqual(SongService.attempt(status: 200, data: Data("not json".utf8), retryAfter: nil), .failed(.unavailable))
        guard case .reply(let r) = SongService.attempt(status: 200, data: Self.reply(identity: "something-new"), retryAfter: nil) else {
            return XCTFail("a 200 with a song is a reply")
        }
        XCTAssertEqual(r.song.songID, "sng_abc123")
        XCTAssertEqual(r.song.seconds, 163.35)
        XCTAssertTrue(r.fetched)
        XCTAssertEqual(r.identity, "something-new", "an unknown identity is not a mismatch")
    }

    func testGetsTheAudioWithTheKeyOnlyForTheService() async throws {
        ServiceStub.answers = [.init(status: 200, body: Self.reply()), .init(status: 200, body: Data(repeating: 7, count: 4_000))]
        let song = try await SongService.fetch(SongService.Ask(artist: "Kevin MacLeod", title: "Volatile Reaction"), expectedSeconds: 165.355,
                                               config: config, into: dir, session: session(), sleep: { _ in })
        XCTAssertEqual(song.title, "Volatile Reaction")
        XCTAssertEqual(song.file.lastPathComponent, "song-sng_abc123.m4a")
        XCTAssertEqual(try Data(contentsOf: song.file).count, 4_000)
        let seen = ServiceStub.seen
        XCTAssertEqual(seen.map(\.host), ["service.test", "storage.test"])
        XCTAssertEqual(seen[0].method, "POST")
        XCTAssertEqual(seen[0].path, "/v1/songs/download")
        XCTAssertEqual(seen[0].key, "test-key")
        XCTAssertNil(seen[1].key, "the signed link is fetched without the key")
    }

    func testBusyThenTransientAreTriedAgainAsTheServiceAsks() async throws {
        ServiceStub.answers = [.init(status: 503, body: Data(), retryAfter: "3"), .init(status: 504, body: Data()),
                               .init(status: 200, body: Self.reply()), .init(status: 200, body: Data(repeating: 1, count: 2_000))]
        let slept = Sleeps()
        _ = try await SongService.fetch(SongService.Ask(reference: "https://www.youtube.com/watch?v=x"), config: config, into: dir,
                                        session: session(), sleep: { slept.add($0) })
        XCTAssertEqual(slept.all, [3, 5])
    }

    func testGivesUpAfterThreeTransientAnswers() async {
        ServiceStub.answers = Array(repeating: .init(status: 504, body: Data()), count: 3)
        let slept = Sleeps()
        do {
            _ = try await SongService.fetch(SongService.Ask(artist: "A", title: "T"), config: config, into: dir, session: session(),
                                            sleep: { slept.add($0) })
            XCTFail("three transient answers are the end")
        } catch {
            XCTAssertEqual(error as? SongService.Failure, .unavailable)
        }
        XCTAssertEqual(slept.all, [5, 15])
        XCTAssertEqual(ServiceStub.seen.count, 3)
    }

    func testAnotherRecordingIsNeverUsed() async {
        ServiceStub.answers = [.init(status: 200, body: Self.reply(identity: "mismatch"))]
        await assertFails(.wrongRecording, SongService.Ask(artist: "A", title: "T"), expected: nil)
        ServiceStub.reset()
        ServiceStub.answers = [.init(status: 200, body: Self.reply(seconds: 190))]
        await assertFails(.wrongRecording, SongService.Ask(artist: "A", title: "T"), expected: 165.355)
        XCTAssertEqual(ServiceStub.seen.count, 1, "nothing is downloaded for a recording of another length")
    }

    /// The contract allows a null length. Then the audio itself is measured, and audio that can't be measured (or
    /// is too far from the song's length) is refused and deleted: an unchecked length is never a pass.
    func testAMissingLengthIsMeasuredNotTrusted() async {
        ServiceStub.answers = [.init(status: 200, body: Self.reply(seconds: nil)), .init(status: 200, body: Data(repeating: 7, count: 4_000))]
        await assertFails(.wrongRecording, SongService.Ask(artist: "A", title: "T"), expected: 165.355)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertTrue(left.isEmpty, "the refused audio is deleted: \(left)")
    }

    /// A 401 (a rotated key) stops the service for the rest of the run, as its contract asks; a 502 doesn't.
    func testARejectedKeyStopsTheService() async {
        ServiceStub.answers = [.init(status: 502, body: Data(#"{"error": "refused"}"#.utf8))]
        await assertFails(.refused, SongService.Ask(artist: "A", title: "T"), expected: nil)
        XCTAssertFalse(SongService.isStopped)
        ServiceStub.answers = [.init(status: 401, body: Data(#"{"detail": "bad key"}"#.utf8))]
        await assertFails(.unauthorized, SongService.Ask(artist: "A", title: "T"), expected: nil)
        XCTAssertTrue(SongService.isStopped)
        XCTAssertFalse(SongService.isEnabled, "no more calls this run")
    }

    func testTheSourceRefusingIsNotTriedAgain() async {
        ServiceStub.answers = [.init(status: 502, body: Data(#"{"error": "refused"}"#.utf8))]
        await assertFails(.refused, SongService.Ask(artist: "A", title: "T"), expected: nil)
        XCTAssertEqual(ServiceStub.seen.count, 1)
    }

    func testTheKeyStaysOnTheServicesHostAcrossARedirect() {
        var request = URLRequest(url: URL(string: "https://storage.test/a.m4a")!)
        request.setValue("k", forHTTPHeaderField: "X-Api-Key")
        XCTAssertNil(SongService.KeyGuard.redirect(request, from: URL(string: "https://service.test/v1/songs/x/audio"))
            .value(forHTTPHeaderField: "X-Api-Key"))
        request.url = URL(string: "https://service.test/elsewhere")
        XCTAssertEqual(SongService.KeyGuard.redirect(request, from: URL(string: "https://service.test/v1"))
            .value(forHTTPHeaderField: "X-Api-Key"), "k")
    }

    private func assertFails(_ expected: SongService.Failure, _ ask: SongService.Ask, expected seconds: Double?,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await SongService.fetch(ask, expectedSeconds: seconds, config: config, into: dir, session: session(), sleep: { _ in })
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SongService.Failure, expected, file: file, line: line)
        }
    }
}

private final class Sleeps: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: [Double] = []
    func add(_ s: Double) { lock.withLock { seconds.append(s) } }
    var all: [Double] { lock.withLock { seconds } }
}

/// Plays the service and its storage: each request takes the next answer, in order, and is noted.
final class ServiceStub: URLProtocol, @unchecked Sendable {
    struct Answer { var status: Int; var body: Data; var retryAfter: String? = nil }
    struct Seen { var host: String?; var path: String; var method: String?; var key: String? }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [Answer] = []
    nonisolated(unsafe) private static var noted: [Seen] = []

    static var answers: [Answer] {
        get { lock.withLock { queue } }
        set { lock.withLock { queue = newValue } }
    }
    static var seen: [Seen] { lock.withLock { noted } }
    static func reset() { lock.withLock { queue = []; noted = [] } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let answer: Answer? = Self.lock.withLock {
            Self.noted.append(Seen(host: url.host, path: url.path, method: request.httpMethod,
                                   key: request.value(forHTTPHeaderField: "X-Api-Key")))
            return Self.queue.isEmpty ? nil : Self.queue.removeFirst()
        }
        let a = answer ?? Answer(status: 500, body: Data())
        var headers = ["Content-Type": "application/json"]
        if let r = a.retryAfter { headers["Retry-After"] = r }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: a.status, httpVersion: "HTTP/1.1", headerFields: headers)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: a.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
