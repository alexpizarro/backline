import BacklineKit
import XCTest
@testable import Backline

/// R01a: links are sorted into files, YouTube, Vimeo and everything else; file links download as they are,
/// and only music or video is kept.
final class WebLinkImportTests: XCTestCase {
    func testLinksAreSorted() {
        XCTAssertEqual(WebLink.classify("https://example.com/songs/My%20Song.mp3"), .file(URL(string: "https://example.com/songs/My%20Song.mp3")!))
        XCTAssertEqual(WebLink.classify("look: http://192.168.1.4:8000/clip.M4V"), .file(URL(string: "http://192.168.1.4:8000/clip.M4V")!))
        XCTAssertEqual(WebLink.classify("https://youtu.be/zpzdgmqIHOQ?si=ua9Hg8NTG57YZUv9"), .youTube(YouTubeLink.parse("https://youtu.be/zpzdgmqIHOQ")!))
        XCTAssertEqual(WebLink.classify("https://vimeo.com/channels/musicvideos/926983242"), .vimeo(id: "926983242", hash: nil))
        XCTAssertEqual(WebLink.classify("vimeo.com/76979871"), .vimeo(id: "76979871", hash: nil))
        XCTAssertEqual(WebLink.classify("https://vimeo.com/123456789/abcdef1234"), .vimeo(id: "123456789", hash: "abcdef1234"))
        XCTAssertEqual(WebLink.classify("https://player.vimeo.com/video/123456789?h=fedcba9876"), .vimeo(id: "123456789", hash: "fedcba9876"))
        XCTAssertEqual(WebLink.classify("https://soundcloud.com/forss/flickermood"), .unsupported(URL(string: "https://soundcloud.com/forss/flickermood")!))
        XCTAssertEqual(WebLink.classify("https://vimeo.com/about"), .unsupported(URL(string: "https://vimeo.com/about")!))
        XCTAssertNil(WebLink.classify("my favourite song"))
        XCTAssertNil(WebLink.classify("ftp://example.com/a.mp3"))
    }

    /// S01: a link to a song on a music service is sorted before the "any other page" fallback, as pasted,
    /// as shared (words around it) and as the service's own URI.
    func testMusicServiceLinksAreSortedBeforeThePageFallback() {
        let track = SpotifyLink(kind: .track, id: "558kPt5dAK4XskceUBSnqi")
        XCTAssertEqual(WebLink.classify("https://open.spotify.com/track/558kPt5dAK4XskceUBSnqi?si=9f1"), .spotify(.link(track)))
        XCTAssertEqual(WebLink.classify("Check out this song on Spotify: https://open.spotify.com/intl-de/track/558kPt5dAK4XskceUBSnqi?si=9f1"),
                       .spotify(.link(track)))
        XCTAssertEqual(WebLink.classify("spotify:track:558kPt5dAK4XskceUBSnqi"), .spotify(.link(track)))
        XCTAssertEqual(WebLink.classify("https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M"),
                       .spotify(.link(SpotifyLink(kind: .playlist, id: "37i9dQZF1DXcBWIGoYBM5M"))))
        XCTAssertEqual(WebLink.classify("https://spotify.link/hRkBrwub9xb"),
                       .spotify(.short(URL(string: "https://spotify.link/hRkBrwub9xb")!)))
        XCTAssertEqual(WebLink.classify("https://open.spotify.com/concert/558kPt5dAK4XskceUBSnqi"),
                       .unsupported(URL(string: "https://open.spotify.com/concert/558kPt5dAK4XskceUBSnqi")!),
                       "anything else on the same host is still just a page")
    }

    /// The Add Song sheet's link field: the Go arrow appears for a shared sentence too (S01).
    func testTheLinkFieldTakesASharedSentence() {
        XCTAssertNotNil(LinkField.link(in: "Check out this song on Spotify: https://open.spotify.com/track/558kPt5dAK4XskceUBSnqi?si=9f1"))
        XCTAssertNotNil(LinkField.link(in: "spotify:album:6N9PS4QXF1D0OWPk0Sxtb4"))
        XCTAssertNil(LinkField.link(in: "my favourite song"))
    }

    func testOnlyMusicAndVideoAreKept() {
        let mp3 = URL(string: "https://x.com/a.mp3")!, page = URL(string: "https://x.com/a")!
        XCTAssertTrue(FileLinkDownload.isMedia(mimeType: "audio/mpeg", url: page))
        XCTAssertTrue(FileLinkDownload.isMedia(mimeType: "video/mp4", url: page))
        XCTAssertTrue(FileLinkDownload.isMedia(mimeType: "application/octet-stream", url: mp3))
        XCTAssertFalse(FileLinkDownload.isMedia(mimeType: "application/octet-stream", url: page))
        XCTAssertFalse(FileLinkDownload.isMedia(mimeType: "text/html", url: mp3), "a web page that pretends")
    }

    // MARK: Downloads against a stubbed server

    private func config() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        return c
    }

    private var folder: URL!
    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("WebLinkImportTests-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    func testAMusicFileDownloads() async throws {
        StubProtocol.reply = .init(status: 200, mime: "audio/mpeg", body: Data(repeating: 7, count: 300_000))
        let file = try await FileLinkDownload.download(URL(string: "https://stub.test/Big_Rock.mp3")!, into: folder,
                                                       configuration: config(), progress: { _ in }, isCancelled: { false })
        XCTAssertEqual(try Data(contentsOf: file).count, 300_000)
        XCTAssertEqual(ImportStaging.displayName(for: file), "Big Rock", "the song is named after the link's file")
    }

    /// A web page is still refused; since L7 it says so in its own words (see the next test).
    func testAWebPageIsRefused() async {
        StubProtocol.reply = .init(status: 200, mime: "text/html", body: Data("<html></html>".utf8))
        await assertFails(.webPage, "https://stub.test/page.mp3")
        StubProtocol.reply = .init(status: 200, mime: "application/json", body: Data("{}".utf8))
        await assertFails(.notMedia, "https://stub.test/data.mp3")
    }

    func testAMissingFileIsRefused() async {
        StubProtocol.reply = .init(status: 404, mime: "audio/mpeg", body: Data())
        await assertFails(.notMedia, "https://stub.test/gone.mp3")
    }

    func testTooLargeStopsTheDownload() async {
        StubProtocol.reply = .init(status: 200, mime: "audio/mpeg", body: Data(repeating: 1, count: 1000),
                                   claimedLength: FileLinkDownload.maxBytes + 1)
        await assertFails(.tooLarge, "https://stub.test/huge.wav")
    }

    func testANetworkFailure() async {
        StubProtocol.reply = .init(status: 0, mime: nil, body: Data(), error: URLError(.timedOut))
        await assertFails(.network, "https://stub.test/slow.mp3")
    }

    /// L7: a share page served for a link ending in `.mp3` says what to do instead of "Try again".
    func testAWebPageSaysToCopyTheFilesOwnLink() async {
        StubProtocol.reply = .init(status: 200, mime: "text/html; charset=utf-8", body: Data("<html></html>".utf8))
        await assertFails(.webPage, "https://stub.test/share/song.mp3?rlkey=x&dl=0")
        XCTAssertEqual(FileLinkDownload.Failure.webPage.errorDescription, FileLinkDownload.webPageMessage)
    }

    @MainActor
    func testAWebPageOffersAnotherSongNotTryAgain() {
        let screen = FailureView.content(message: FileLinkDownload.webPageMessage, fromLink: true, canSignIn: false)
        XCTAssertEqual([screen.primary, screen.secondary], [.anotherSong, .notNow], "Try again would fetch the same page")
    }

    /// L7: the file-sharing service's share link is asked for its direct-download form; nothing else changes.
    func testAShareLinkIsAskedForTheFileItself() {
        func direct(_ s: String) -> String { FileLinkDownload.directForm(URL(string: s)!).absoluteString }
        XCTAssertEqual(direct("https://www.dropbox.com/scl/fi/abc/My%20Song.mp3?rlkey=k1&dl=0"),
                       "https://www.dropbox.com/scl/fi/abc/My%20Song.mp3?rlkey=k1&dl=1")
        XCTAssertEqual(direct("https://dropbox.com/s/abc/song.mp3?dl=0"), "https://dropbox.com/s/abc/song.mp3?dl=1")
        XCTAssertEqual(direct("https://www.dropbox.com/s/abc/song.mp3?dl=1"), "https://www.dropbox.com/s/abc/song.mp3?dl=1")
        XCTAssertEqual(direct("https://example.com/song.mp3?dl=0"), "https://example.com/song.mp3?dl=0", "another host is left alone")
        XCTAssertEqual(direct("https://www.dropbox.com/s/abc/song.mp3"), "https://www.dropbox.com/s/abc/song.mp3")
    }

    /// L7: Cancel lands at once even while the server has sent its headers and then nothing (it used to wait for
    /// the 20 s idle timeout).
    func testCancelLandsAtOnceOnAStalledServer() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StallProtocol.self]
        let folder = folder!
        let task = Task {
            try await FileLinkDownload.download(URL(string: "https://stub.test/stalled.mp3")!, into: folder, configuration: config,
                                                progress: { _ in }, isCancelled: { false })
        }
        try await Task.sleep(for: .milliseconds(500))
        let start = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled download returns no file")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "Cancel returns within a second")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "nothing is kept")
    }

    /// L7: a big file in small writes reports progress at most once per percent, and reaches the end.
    func testProgressIsReportedAtMostOncePerPercent() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChunkProtocol.self]
        let calls = Calls()
        let file = try await FileLinkDownload.download(URL(string: "https://stub.test/Many.mp3")!, into: folder, configuration: config,
                                                       progress: { calls.add($0) }, isCancelled: { false })
        XCTAssertEqual(try Data(contentsOf: file).count, ChunkProtocol.chunks * ChunkProtocol.chunkSize)
        XCTAssertGreaterThan(calls.all.count, 0)
        XCTAssertLessThanOrEqual(calls.all.count, 101, "at most once per percent")
        XCTAssertEqual(calls.all.last ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(calls.all, calls.all.sorted(), "never backwards")
    }

    func testTheProgressThrottleNeverRepeatsAPercent() {
        let calls = Calls()
        let reporter = RangedDownload.ProgressReporter { calls.add($0) }
        for i in 0...10_000 { reporter.report(Double(i) / 10_000) }
        XCTAssertLessThanOrEqual(calls.all.count, 101)
        XCTAssertGreaterThanOrEqual(calls.all.count, 90)
        XCTAssertEqual(calls.all.first, 0)
    }

    private func assertFails(_ expected: FileLinkDownload.Failure, _ link: String, line: UInt = #line) async {
        do {
            _ = try await FileLinkDownload.download(URL(string: link)!, into: folder, configuration: config(),
                                                    progress: { _ in }, isCancelled: { false })
            XCTFail("expected \(expected)", line: line)
        } catch {
            XCTAssertEqual(error as? FileLinkDownload.Failure, expected, line: line)
        }
    }
}

/// Answers every request with `reply`.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status: Int
        var mime: String?
        var body: Data
        var claimedLength: Int64? = nil
        var error: URLError? = nil
    }
    nonisolated(unsafe) static var reply = Reply(status: 200, mime: "audio/mpeg", body: Data())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let r = Self.reply
        if let e = r.error { client?.urlProtocol(self, didFailWithError: e); return }
        var headers = ["Content-Length": String(r.claimedLength ?? Int64(r.body.count))]
        if let m = r.mime { headers["Content-Type"] = m }
        let response = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: r.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ v: Double) { lock.withLock { values.append(v) } }
    var all: [Double] { lock.withLock { values } }
}

/// Sends the headers of an audio file, then nothing, until it is stopped. Leaves the song service's host to its stub.
final class StallProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host != "service.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "audio/mpeg", "Content-Length": "5000000"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
    override func stopLoading() {}
}

/// An audio file sent in many small writes.
final class ChunkProtocol: URLProtocol, @unchecked Sendable {
    static let chunks = 2_000
    static let chunkSize = 1_024
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let total = Self.chunks * Self.chunkSize
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "audio/mpeg", "Content-Length": String(total)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for _ in 0..<Self.chunks { client?.urlProtocol(self, didLoad: Data(repeating: 3, count: Self.chunkSize)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
