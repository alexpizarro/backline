import Foundation
import WebKit

/// Mints YouTube proof-of-origin (PO) tokens (R01p): the last resort when YouTube refuses streams that
/// lack one, after the signed-in path. Google's BotGuard runs in a hidden `WKWebView` (WebKit has the JIT
/// an app's own JavaScriptCore lacks) on a blank page whose origin is www.youtube.com, in a non-persistent
/// data store, so no cookies, Google session or website data are shared with it or kept. Tokens live only
/// in memory for one download and go only to YouTube (the player request) and googlevideo (the stream).
/// See `docs/release/po-token-ios.md`.
@MainActor
final class POTokenMinter: NSObject, WKNavigationDelegate, WKUIDelegate {
    /// Kill switch: when false the extractor never mints as a fallback (rollback and R01F). Tests and the
    /// smoke run can still ask for the rung alone.
    nonisolated static let isEnabled = true
    /// The whole mint, whatever WebKit or Google's code does: past this the caller gets `timeout`.
    nonisolated static let deadline: Duration = .seconds(40)

    struct Tokens: Sendable {
        /// Stream tokens (`pot`) to try in order: bound the way the homepage's config says first (the video
        /// id under YouTube's content-binding experiment, else the visitor data or the data sync id), then
        /// the other binding, in case this session's experiment differs from the homepage's.
        var stream: [String]
        /// For the player request (`serviceIntegrityDimensions.poToken`), bound to the video id.
        var player: String
    }

    enum Failure: Error, Equatable {
        case noChallenge, badInterpreter, noIntegrityToken, page, timeout
        case script(String)
    }

    /// What the homepage gives the minter.
    struct Challenge: Sendable {
        var atn: String
        var ytcfg: String
        var bindsToVideo: Bool
    }

    nonisolated static let homepage = URL(string: "https://www.youtube.com/")!
    /// The web client's request key and YouTube's public browser API key, as the youtube.com page sends
    /// them to GenerateIT (bgutils-js constants); neither is a Backline credential.
    nonisolated static let requestKey = "O43z0dpjhgX20SCx4KAo"
    nonisolated static let googleAPIKey = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw"
    nonisolated static let generateIT = URL(string: "https://jnn-pa.googleapis.com/$rpc/google.internal.waa.v1.Waa/GenerateIT")!

    private var webView: WKWebView?
    private var loaded: CheckedContinuation<Void, Error>?
    /// Only the blank page itself may load; anything the page's code tries afterwards is refused.
    private var allowsNavigation = true

    /// Mints the player token for `videoID` and the stream tokens: bound to the video and, when
    /// `streamBinding` is given (visitor data, or the data sync id when signed in), to that too.
    static func mint(streamBinding: String?, videoID: String, session: URLSession,
                     say: @escaping @Sendable (String) -> Void) async throws -> Tokens {
        let start = Date()
        let challenge = try await homepageChallenge(session: session)
        let minter = POTokenMinter()
        let gate = Gate<Tokens>()
        // When the deadline or a cancel settles the gate first, the work goes on for a while, but the caller
        // invalidates its session as soon as this returns, and a request on an invalidated session raises an
        // exception that ends the app. So the work has its own session, invalidated only once it's done.
        let own = YouTubeExtractor.makeSession()
        let tokens = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Tokens, Error>) in
                gate.set(c)
                guard !gate.isDone else { own.finishTasksAndInvalidate(); return }
                let timer = Task {
                    try await Task.sleep(for: deadline)
                    if gate.resume(.failure(Failure.timeout)) { await minter.tearDown() }
                }
                Task { @MainActor in
                    let result: Result<Tokens, Error>
                    do {
                        result = .success(try await minter.run(challenge: challenge, streamBinding: streamBinding, videoID: videoID,
                                                               session: own))
                    } catch {
                        result = .failure(error)
                    }
                    own.finishTasksAndInvalidate()
                    timer.cancel()
                    gate.resume(result)
                    minter.tearDown()
                }
            }
        } onCancel: {
            if gate.resume(.failure(CancellationError())) { Task { @MainActor in minter.tearDown() } }
        }
        say("po token: minted in \(String(format: "%.1f", Date().timeIntervalSince(start))) s, stream token bound to the "
            + (challenge.bindsToVideo || streamBinding == nil ? "video" : "session") + " first")
        return tokens
    }

    private func run(challenge: Challenge, streamBinding: String?, videoID: String, session: URLSession) async throws -> Tokens {
        // 1. A blank page with YouTube's origin, the minter script, then the challenge.
        let web = try await page()
        // Scripts end on `true`: the async evaluateJavaScript throws on an undefined result.
        _ = try await web.evaluateJavaScript(Self.script + "\n;true")
        let parsed = try await call(web, "return window.backlinePot.challenge(atn, ytcfg);", ["atn": challenge.atn, "ytcfg": challenge.ytcfg])
        guard let c = parsed as? [String: Any], let program = c["program"] as? String, let globalName = c["globalName"] as? String,
              let interpreter = (c["interpreterUrl"] as? String).flatMap(Self.interpreterURL) else { throw Failure.noChallenge }

        // 2. Google's BotGuard interpreter (only from www.google.com/js/th/), then one snapshot.
        _ = try await web.evaluateJavaScript(try await Self.interpreterScript(interpreter, session: session) + "\n;true")
        guard let snapshot = try await call(web, "return await window.backlinePot.snapshot(program, globalName);",
                                             ["program": program, "globalName": globalName]) as? String, !snapshot.isEmpty else {
            throw Failure.script("empty snapshot")
        }

        // 3. The integrity token, then the minter and the tokens.
        guard let integrity = try await Self.integrityToken(snapshot: snapshot, session: session) else { throw Failure.noIntegrityToken }
        _ = try await call(web, "return await window.backlinePot.minter(token);", ["token": integrity])
        func mint(_ binding: String) async throws -> String {
            guard let token = try await call(web, "return await window.backlinePot.mint(binding);", ["binding": binding]) as? String,
                  Self.isToken(token) else { throw Failure.script("not a token") }
            return token
        }
        let player = try await mint(videoID)
        let bound = try await streamBinding.asyncMap(mint)
        let stream = challenge.bindsToVideo || bound == nil ? [player] + [bound].compactMap { $0 } : [bound!, player]
        return Tokens(stream: stream, player: player)
    }

    // MARK: Page

    private func page() async throws -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        web.customUserAgent = YouTubeExtractor.desktopUserAgent
        web.navigationDelegate = self
        web.uiDelegate = self
        webView = web
        // A local string with no subresources: it finishes or fails at once.
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loaded = c
            web.loadHTMLString("<!doctype html><html><head><meta charset=\"utf-8\"><title>YouTube</title></head><body></body></html>",
                               baseURL: Self.homepage)
        }
        return web
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        allowsNavigation = false
        finishLoading(nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        allowsNavigation ? .allow : .cancel
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishLoading(Failure.page)
    }

    // The page never gets the microphone, the camera or a new window.
    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo,
                 type: WKMediaCaptureType) async -> WKPermissionDecision {
        .deny
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoading(Failure.page)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoading(Failure.page)
    }

    private func finishLoading(_ error: Error?) {
        guard let c = loaded else { return }
        loaded = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }

    private func tearDown() {
        allowsNavigation = false
        finishLoading(Failure.page)
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
    }

    /// Runs a function body in the page with named arguments (the script's own steps time out after 10 s).
    private func call(_ web: WKWebView, _ body: String, _ arguments: [String: Any]) async throws -> Any? {
        do {
            return try await web.callAsyncJavaScript(body, arguments: arguments, contentWorld: .page)
        } catch {
            throw Failure.script((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? "\(error)")
        }
    }

    // MARK: Pure parts

    nonisolated static let script: String = {
        guard let url = Bundle.main.url(forResource: "potoken", withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }()

    /// The homepage's challenge, config and binding flag. No cookies but YouTube's non-identifying consent
    /// cookie (as yt-dlp sends), so visitors in the EU and UK get the page rather than the consent form.
    /// Fetched and parsed off the main thread.
    @concurrent nonisolated static func homepageChallenge(session: URLSession) async throws -> Challenge {
        var request = URLRequest(url: homepage)
        request.timeoutInterval = 20
        request.setValue(YouTubeExtractor.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("SOCS=CAI", forHTTPHeaderField: "Cookie")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, response.url?.host == homepage.host else { throw Failure.noChallenge }
        let html = String(decoding: data, as: UTF8.self)
        guard let atn = challengeText(inHomepage: html), let ytcfg = configText(inHomepage: html) else { throw Failure.noChallenge }
        return Challenge(atn: atn, ytcfg: ytcfg, bindsToVideo: bindsStreamTokenToVideo(inHomepage: html))
    }

    /// The interpreter script: 200, still at an accepted URL after any redirect, at most 2 MB.
    @concurrent nonisolated static func interpreterScript(_ url: URL, session: URLSession) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(YouTubeExtractor.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let final = response.url, interpreterURL(final.absoluteString) != nil,
              !data.isEmpty, data.count <= 2 << 20 else { throw Failure.badInterpreter }
        return String(decoding: data, as: UTF8.self)
    }

    /// Web-safe base64 of a sane length, nothing else.
    nonisolated static func isToken(_ text: String) -> Bool {
        (40...512).contains(text.count) && text.range(of: #"^[A-Za-z0-9_-]+=*$"#, options: .regularExpression) != nil
    }

    /// The argument of `window.ytAtN(…)` in the homepage: an object literal holding the BotGuard challenge.
    nonisolated static func challengeText(inHomepage html: String) -> String? {
        first(#"window\.ytAtN\(\s*(\{[\s\S]*?\})\s*\)"#, in: html)
    }

    /// YouTube's experiment that binds stream tokens to the video id instead of the visitor (yt-dlp reads
    /// the same flag, `html5_generate_content_po_token`, from the page's player config).
    nonisolated static func bindsStreamTokenToVideo(inHomepage html: String) -> Bool {
        html.range(of: #"(\\u0026|&|")html5_generate_content_po_token(\\u003d|=)true"#, options: .regularExpression) != nil
    }

    /// The first `ytcfg.set({…});` object, which carries EVENT_ID.
    nonisolated static func configText(inHomepage html: String) -> String? {
        first(#"ytcfg\.set\((\{[\s\S]+?\})\);"#, in: html)
    }

    /// Only Google's BotGuard interpreter is accepted: https, www.google.com, `/js/th/<name>.js`, no port,
    /// user, query or fragment.
    nonisolated static func interpreterURL(_ wrapped: String) -> URL? {
        guard let c = URLComponents(string: wrapped.hasPrefix("//") ? "https:" + wrapped : wrapped),
              c.scheme == "https", c.host == "www.google.com", c.port == nil, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil,
              c.path.range(of: #"^/js/th/[A-Za-z0-9_-]+\.js$"#, options: .regularExpression) != nil else { return nil }
        return c.url
    }

    /// GenerateIT: `[requestKey, snapshot]` in, `[integrityToken, ttl, refresh, fallback]` out.
    @concurrent nonisolated static func integrityToken(snapshot: String, session: URLSession) async throws -> String? {
        var request = URLRequest(url: generateIT)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue(googleAPIKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue("grpc-web-javascript/0.1", forHTTPHeaderField: "X-User-Agent")
        request.setValue(YouTubeExtractor.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [requestKey, snapshot])
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return integrityToken(inResponse: data)
    }

    nonisolated static func integrityToken(inResponse data: Data) -> String? {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any], let token = array.first as? String,
              !token.isEmpty else { return nil }
        return token
    }

    private nonisolated static func first(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}

/// Resumes a continuation exactly once, whichever comes first: the work, the deadline or a cancel. A result
/// that arrives before the continuation exists is kept for it.
nonisolated final class Gate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var early: Result<T, Error>?
    private var done = false

    var isDone: Bool { lock.withLock { done } }

    func set(_ c: CheckedContinuation<T, Error>) {
        lock.lock()
        if let r = early {
            early = nil
            done = true
            lock.unlock()
            c.resume(with: r)
            return
        }
        continuation = c
        lock.unlock()
    }

    /// True for the call that settled it.
    @discardableResult func resume(_ r: Result<T, Error>) -> Bool {
        lock.lock()
        if done || early != nil { lock.unlock(); return false }
        guard let c = continuation else {
            early = r
            lock.unlock()
            return true
        }
        continuation = nil
        done = true
        lock.unlock()
        c.resume(with: r)
        return true
    }
}

private extension Optional {
    func asyncMap<U>(_ transform: (Wrapped) async throws -> U) async rethrows -> U? {
        guard let self else { return nil }
        return try await transform(self)
    }
}
