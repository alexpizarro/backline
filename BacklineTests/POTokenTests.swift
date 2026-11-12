import AVFoundation
import os
import XCTest
@testable import Backline

/// R01p: proof-of-origin tokens. The pure parts on recorded shapes; the live tests (skipped when
/// `BACKLINE_SKIP_NETWORK_TESTS` is set) mint a real token in the hidden web view.
@MainActor
final class POTokenTests: XCTestCase {
    func testChallengeAndConfigInTheHomepage() {
        let html = #"<script nonce="x">ytcfg.set({"EVENT_ID":"abc","INNERTUBE_API_KEY":"k"});</script><script>window.ytAtN({'R': '\x7b\x22bgChallenge\x22:\x7b\x22program\x22:\x22p\x22\x7d\x7d','T': 'AZd7\x3d',})</script>"#
        XCTAssertEqual(POTokenMinter.configText(inHomepage: html), #"{"EVENT_ID":"abc","INNERTUBE_API_KEY":"k"}"#)
        XCTAssertEqual(POTokenMinter.challengeText(inHomepage: html), #"{'R': '\x7b\x22bgChallenge\x22:\x7b\x22program\x22:\x22p\x22\x7d\x7d','T': 'AZd7\x3d',}"#)
        XCTAssertNil(POTokenMinter.challengeText(inHomepage: "<html></html>"))
    }

    func testTheVideoBindingExperimentIsRead() {
        XCTAssertTrue(POTokenMinter.bindsStreamTokenToVideo(inHomepage: #"serializedExperimentFlags":"a\u003d1\u0026html5_generate_content_po_token\u003dtrue\u0026b"#))
        XCTAssertTrue(POTokenMinter.bindsStreamTokenToVideo(inHomepage: "x&html5_generate_content_po_token=true&y"))
        XCTAssertFalse(POTokenMinter.bindsStreamTokenToVideo(inHomepage: #"&html5_generate_content_po_token\u003dfalse"#))
        XCTAssertFalse(POTokenMinter.bindsStreamTokenToVideo(inHomepage: "&disable_html5_generate_content_po_token=true"),
                       "only the flag itself, not one that ends with its name")
    }

    func testOnlyGooglesInterpreterIsAccepted() {
        XCTAssertEqual(POTokenMinter.interpreterURL("//www.google.com/js/th/UuzLx1YTO8P6u56myU4poj.js")?.absoluteString,
                       "https://www.google.com/js/th/UuzLx1YTO8P6u56myU4poj.js")
        for bad in ["//evil.example/js/th/x.js", "http://www.google.com/js/th/x.js", "//www.google.com/other/x.js",
                    "//www.google.com/js/th/../../evil.js", "//www.google.com:8443/js/th/x.js", "//user@www.google.com/js/th/x.js",
                    "//www.google.com/js/th/x.js?y=1", "//www.google.com/js/th/x.js#y", "//www.google.com.evil.example/js/th/x.js"] {
            XCTAssertNil(POTokenMinter.interpreterURL(bad), bad)
        }
    }

    func testTokensAreWebSafeBase64OfASaneLength() {
        XCTAssertTrue(POTokenMinter.isToken(String(repeating: "Mn_o-p", count: 20) + "=="))
        XCTAssertFalse(POTokenMinter.isToken("short"))
        XCTAssertFalse(POTokenMinter.isToken(String(repeating: "a", count: 600)))
        XCTAssertFalse(POTokenMinter.isToken(String(repeating: "ab+/", count: 20)))
        XCTAssertFalse(POTokenMinter.isToken(String(repeating: "ab", count: 30) + "<script>"))
    }

    func testCookiesStayOnTheirHostAcrossRedirects() {
        var watch = URLRequest(url: URL(string: "https://www.youtube.com/watch?v=x")!)
        watch.setValue("SID=1", forHTTPHeaderField: "Cookie")
        watch.setValue("SAPISIDHASH 1_x", forHTTPHeaderField: "Authorization")
        watch.setValue("UA", forHTTPHeaderField: "User-Agent")
        let original = URL(string: "https://www.youtube.com/watch?v=x")
        var away = watch
        away.url = URL(string: "https://www.google.com/sorry/index")
        let stripped = YouTubeExtractor.RedirectGuard.redirect(away, from: original)
        XCTAssertNil(stripped.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(stripped.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(stripped.value(forHTTPHeaderField: "User-Agent"), "UA")
        var same = watch
        same.url = URL(string: "https://www.youtube.com/watch?v=x&bpctr=1")
        XCTAssertEqual(YouTubeExtractor.RedirectGuard.redirect(same, from: original).value(forHTTPHeaderField: "Cookie"), "SID=1")
    }

    /// The guard as a session's delegate, on a real redirect (offline, through a stub protocol). Its `async`
    /// form crashed the app on the first redirect it handled; the request must finish, on the other host,
    /// without the cookie.
    func testTheGuardFollowsARealRedirectWithoutTheCookie() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RedirectStub.self]
        let session = URLSession(configuration: config, delegate: YouTubeExtractor.RedirectGuard(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: URL(string: "https://start.test/watch")!)
        request.setValue("SID=1", forHTTPHeaderField: "Cookie")
        let (data, response) = try await session.data(for: request)
        XCTAssertEqual(response.url?.host, "end.test")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "landed")
        XCTAssertNil(RedirectStub.landedCookie.withLock { $0 }, "the cookie stays on its own host")
    }

    func testIntegrityTokenResponse() {
        XCTAssertEqual(POTokenMinter.integrityToken(inResponse: Data(#"["CjI4abc",43200,32400,"fallback"]"#.utf8)), "CjI4abc")
        XCTAssertNil(POTokenMinter.integrityToken(inResponse: Data(#"[null,0]"#.utf8)))
        XCTAssertNil(POTokenMinter.integrityToken(inResponse: Data("<html>".utf8)))
    }

    func testTheMinterScriptIsBundled() {
        XCTAssertTrue(POTokenMinter.script.contains("window.backlinePot"))
    }

    func testTheRungRunsOnlyForWhatATokenCanFix() {
        typealias E = YouTubeExtractor
        XCTAssertTrue(E.wantsProofOfOrigin([.forbidden, .rejected], signedIn: false), "streams refused")
        XCTAssertTrue(E.wantsProofOfOrigin([.noAudio], signedIn: false), "no usable stream (SABR only)")
        XCTAssertTrue(E.wantsProofOfOrigin([.cutOff], signedIn: false), "a stream that stops after its first MiB")
        XCTAssertFalse(E.wantsProofOfOrigin([.rejected, .rejected], signedIn: false), "HTTP errors and refused clients aren't a token problem")
        XCTAssertFalse(E.wantsProofOfOrigin([.loginRequired, .forbidden], signedIn: false), "sign in first: the signed-in path comes before tokens")
        XCTAssertTrue(E.wantsProofOfOrigin([.loginRequired, .loginRequired], signedIn: true), "the signed-in path already failed")
        XCTAssertFalse(E.wantsProofOfOrigin([.unavailable, .forbidden], signedIn: true), "the video is gone")
        XCTAssertFalse(E.wantsProofOfOrigin([.liveOffline], signedIn: false))
        XCTAssertFalse(E.wantsProofOfOrigin([.unreadableAudio, .forbidden], signedIn: false), "no AAC anywhere")
        XCTAssertFalse(E.wantsProofOfOrigin([.network, .network], signedIn: false), "offline")
        XCTAssertFalse(E.wantsProofOfOrigin([], signedIn: false))
    }

    func testTokensInTheRequestAndTheStream() throws {
        let url = try XCTUnwrap(PlayerResponse.adding(pot: "Mn+o/p=", to: URL(string: "https://rr1.googlevideo.com/videoplayback?a=%2C&n=x&pot=old")!))
        XCTAssertEqual(url.absoluteString, "https://rr1.googlevideo.com/videoplayback?a=%2C&n=x&pot=Mn%2Bo%2Fp%3D")

        let body = InnerTubeClient.mweb.playerRequestBody(videoID: "x", visitorData: "V", signatureTimestamp: 20529, poToken: "PLAYER")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual((root["serviceIntegrityDimensions"] as? [String: Any])?["poToken"] as? String, "PLAYER")
        XCTAssertEqual(((root["context"] as? [String: Any])?["client"] as? [String: Any])?["clientName"] as? String, "MWEB")
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: InnerTubeClient.visionOS.playerRequestBody(videoID: "x", visitorData: nil)) as? [String: Any])
        XCTAssertNil(plain["serviceIntegrityDimensions"], "no token unless the rung mints one")
        XCTAssertTrue(InnerTubeClient.mweb.takesPOToken)
        XCTAssertFalse(InnerTubeClient.ladder.contains { $0.takesPOToken }, "the PO client is only the last rung")
    }

    func testDataSyncIDInTheWatchPage() {
        XCTAssertEqual(YouTubeExtractor.dataSyncID(inWatchPage: #"ytcfg.set({"DATASYNC_ID":"1234567890||","x":1})"#), "1234567890||")
        XCTAssertNil(YouTubeExtractor.dataSyncID(inWatchPage: "<html></html>"))
    }

    func testTheGateSettlesOnce() async throws {
        let gate = Gate<Int>()
        XCTAssertTrue(gate.resume(.success(1)), "a result before the continuation is kept")
        XCTAssertFalse(gate.resume(.failure(POTokenMinter.Failure.timeout)), "the deadline after it loses")
        let value = try await withCheckedThrowingContinuation { gate.set($0) }
        XCTAssertEqual(value, 1)
        XCTAssertTrue(gate.isDone)

        let racing = Gate<Int>()
        async let settled: Int = withCheckedThrowingContinuation { racing.set($0) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(racing.resume(.failure(CancellationError())))
        XCTAssertFalse(racing.resume(.success(2)))
        do { _ = try await settled; XCTFail("cancel won") } catch { XCTAssertTrue(error is CancellationError) }
    }

    // MARK: - Live

    /// Cancel lands at once wherever the mint is (fetching the homepage or inside the web view).
    func testCancellingAMintReturnsAtOnce() async throws {
        if ProcessInfo.processInfo.environment["BACKLINE_SKIP_NETWORK_TESTS"] != nil { throw XCTSkip("BACKLINE_SKIP_NETWORK_TESTS is set") }
        let session = YouTubeExtractor.makeSession()
        defer { session.finishTasksAndInvalidate() }
        for delay in [0.3, 1.5] {
            let task = Task { try await POTokenMinter.mint(streamBinding: nil, videoID: "2pXa5jzaOBg", session: session, say: { _ in }) }
            try await Task.sleep(for: .seconds(delay))
            let cancelled = Date()
            task.cancel()
            do {
                _ = try await task.value
            } catch {
                let isCancel = error is CancellationError || (error as? URLError)?.code == .cancelled
                XCTAssertTrue(isCancel, "after \(delay) s: \(error)")
            }
            XCTAssertLessThan(Date().timeIntervalSince(cancelled), 1.0, "after \(delay) s")
        }
    }

    /// A cancelled mint's work goes on for a few seconds, and the caller invalidates its session at once (as
    /// `YouTubeExtractor` does). A request on an invalidated session raises an exception that ends the app.
    func testACancelledMintOutlivesTheCallersSession() async throws {
        if ProcessInfo.processInfo.environment["BACKLINE_SKIP_NETWORK_TESTS"] != nil { throw XCTSkip("BACKLINE_SKIP_NETWORK_TESTS is set") }
        for delay in [0.8, 1.4, 2.0] {
            let session = YouTubeExtractor.makeSession()
            let task = Task { try await POTokenMinter.mint(streamBinding: nil, videoID: "2pXa5jzaOBg", session: session, say: { _ in }) }
            try await Task.sleep(for: .seconds(delay))
            task.cancel()
            _ = try? await task.value
            session.invalidateAndCancel()
        }
        try await Task.sleep(for: .seconds(10))   // the abandoned work finishes or fails meanwhile
    }

    func testMintsATokenInTheHiddenWebView() async throws {
        if ProcessInfo.processInfo.environment["BACKLINE_SKIP_NETWORK_TESTS"] != nil { throw XCTSkip("BACKLINE_SKIP_NETWORK_TESTS is set") }
        let session = YouTubeExtractor.makeSession()
        defer { session.finishTasksAndInvalidate() }
        // Any string binds a token; this one is made up.
        let tokens = try await POTokenMinter.mint(streamBinding: "CgtYWVlZWVlZWVlZWSiAgICABjIKCgJYWBIEGgAgAA%3D%3D", videoID: "2pXa5jzaOBg",
                                                  session: session, say: { print("[pot] \($0)") })
        XCTAssertEqual(tokens.stream.count, 2, "both bindings, to try in turn")
        XCTAssertTrue(tokens.stream.allSatisfy(POTokenMinter.isToken))
        XCTAssertTrue(POTokenMinter.isToken(tokens.player))
        XCTAssertTrue(tokens.stream.contains(tokens.player), "one of them is the video-bound token")
        print("[pot] lengths stream=\(tokens.stream.map(\.count)) player=\(tokens.player.count)")
    }

    /// The rung alone: a token minted in the web view unlocks the mobile web client's direct stream.
    func testDownloadsThroughTheProofOfOriginRung() async throws {
        if ProcessInfo.processInfo.environment["BACKLINE_SKIP_NETWORK_TESTS"] != nil { throw XCTSkip("BACKLINE_SKIP_NETWORK_TESTS is set") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pot-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let lines = TraceLines()
        let result: YouTubeImport.Result
        do {
            result = try await YouTubeImport.download(YouTubeImport.parse("https://youtu.be/2pXa5jzaOBg")!, jar: .none, into: dir,
                                                      routes: .directOnly, proofOfOrigin: .only, trace: { lines.append($0) },
                                                      progress: { _ in }, isCancelled: { false })
        } catch {
            return XCTFail("\(error)\n" + lines.all.joined(separator: "\n"))
        }
        XCTAssertTrue(lines.all.contains { $0.hasPrefix("mweb: direct itag") }, lines.all.joined(separator: "\n"))
        XCTAssertEqual(result.clientID, "mweb")
        XCTAssertFalse(lines.all.contains { line in tokensLeak(line) }, "trace lines never carry a token")
        let audio = try AVAudioFile(forReading: result.file)
        XCTAssertEqual(Double(audio.length) / audio.processingFormat.sampleRate, 163.35, accuracy: 1)
        print("[pot] rung: " + lines.all.joined(separator: " | "))
    }

    /// Evidence, not a gate: the same client without a token (YouTube decides; printed for the Log).
    func testTheMobileWebClientWithoutAToken() async throws {
        if ProcessInfo.processInfo.environment["BACKLINE_SKIP_NETWORK_TESTS"] != nil { throw XCTSkip("BACKLINE_SKIP_NETWORK_TESTS is set") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pot-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let lines = TraceLines()
        do {
            _ = try await YouTubeImport.download(YouTubeImport.parse("https://youtu.be/2pXa5jzaOBg")!, jar: .none, into: dir, ladder: [.mweb],
                                                 routes: .directOnly, proofOfOrigin: .off, trace: { lines.append($0) },
                                                 progress: { _ in }, isCancelled: { false })
            print("[pot] without a token: downloaded | " + lines.all.joined(separator: " | "))
        } catch {
            print("[pot] without a token: \(error) | " + lines.all.joined(separator: " | "))
        }
    }
}

/// A token-shaped run of 40+ web-safe base64 characters in a trace line.
private func tokensLeak(_ line: String) -> Bool {
    line.range(of: #"[A-Za-z0-9_-]{40,}"#, options: .regularExpression) != nil
}

nonisolated private final class TraceLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

/// Answers `start.test` with a 302 to `end.test`, and `end.test` with "landed", noting the cookie that arrived.
final class RedirectStub: URLProtocol, @unchecked Sendable {
    static let landedCookie = OSAllocatedUnfairLock<String?>(initialState: nil)

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.host == "start.test" {
            var next = request      // the same headers, cookie included: dropping it is the guard's job
            next.url = URL(string: "https://end.test/landed")!
            let moved = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "https://end.test/landed"])!
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: moved)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        Self.landedCookie.withLock { $0 = request.value(forHTTPHeaderField: "Cookie") }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("landed".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
