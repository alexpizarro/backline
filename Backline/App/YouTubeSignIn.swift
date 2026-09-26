import AppKit
import BacklineKit
import SwiftUI
import WebKit

/// "Sign in to YouTube" for videos YouTube won't give out anonymously ("confirm you're not a bot",
/// age-restricted, members-only). The user signs in on Google's own page inside Backline; the session
/// lives in a private web data store that only Backline uses, separate from their everyday browser.
/// For each download the YouTube/Google cookies are written to a temporary cookies.txt for yt-dlp and
/// deleted straight after. See docs/self-contained-install-plan.md §B.
@MainActor
enum YouTubeSignIn {
    /// Kill switch: hides every sign-in entry point; downloads stay anonymous.
    static let isEnabled = true

    private static let storeID: UUID = {
        #if DEBUG
        // Snapshot runs can use a throwaway store so the developer's real sign-in is never touched.
        if CommandLine.arguments.contains("--fresh-signin") { return UUID(uuidString: "0D5E7A11-0000-4000-8000-00000000F2E5")! }
        #endif
        return UUID(uuidString: "6B1C7E5A-3F0D-4E8B-9A51-2D7C0F4B8E61")!
    }()
    /// One instance for the app's lifetime (the web view and the cookie export must share it).
    private static var _store: WKWebsiteDataStore?
    static var store: WKWebsiteDataStore {
        if let s = _store { return s }
        let s = WKWebsiteDataStore(forIdentifier: storeID)
        _store = s
        return s
    }

    /// Only these sites (and their subdomains) may load in the sign-in window. Exact suffix match on a
    /// dot boundary — "accounts.google.evil.com" or "evilgoogle.com" never match.
    static let allowedHosts = ["google.com", "youtube.com", "gstatic.com", "googleusercontent.com", "googleapis.com"]

    static let signInURL = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&hl=en&continue=https%3A%2F%2Fwww.youtube.com%2F")!

    /// Remembered so the UI can say "Signed in" without touching the web store on every render.
    static var isSignedIn: Bool {
        get { UserDefaults.standard.bool(forKey: "youtubeSignedIn") }
        set { UserDefaults.standard.set(newValue, forKey: "youtubeSignedIn") }
    }

    static func cookies() async -> [NetscapeCookies.Cookie] {
        let all = await store.httpCookieStore.allCookies()
        return all.filter { NetscapeCookies.isYouTubeAuthDomain($0.domain) }.map {
            NetscapeCookies.Cookie(domain: $0.domain, path: $0.path, secure: $0.isSecure, httpOnly: $0.isHTTPOnly,
                                   expires: $0.expiresDate, name: $0.name, value: $0.value)
        }
    }

    static func refreshStatus() async {
        isSignedIn = NetscapeCookies.hasYouTubeLogin(await cookies())
    }

    /// Writes a private, temporary cookies.txt for one yt-dlp run. nil when not signed in.
    static func writeCookieFile() async -> URL? {
        guard isEnabled else { return nil }
        let list = await cookies()
        guard NetscapeCookies.hasYouTubeLogin(list) else { isSignedIn = false; return nil }
        let url = cookieDirectory.appendingPathComponent("yt-\(UUID().uuidString).txt")
        try? FileManager.default.createDirectory(at: cookieDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // Created 0600 before any secret is written into it.
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let h = try? FileHandle(forWritingTo: url) else { return nil }
        h.write(Data(NetscapeCookies.serialize(list).utf8))
        try? h.close()
        return url
    }

    /// After yt-dlp ran: YouTube may have rotated cookies (yt-dlp writes them back to the jar). Copy any
    /// changed values into our store so the next download uses the fresh session, then delete the file.
    static func finish(cookieFile url: URL) async {
        defer { try? FileManager.default.removeItem(at: url) }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let updated = NetscapeCookies.parse(text).filter { NetscapeCookies.isYouTubeAuthDomain($0.domain) }
        guard !updated.isEmpty else { return }
        let current = await store.httpCookieStore.allCookies().filter { NetscapeCookies.isYouTubeAuthDomain($0.domain) }
        let key: (String, String, String) -> String = { "\($0)|\($1)|\($2)" }
        let known = Dictionary(current.map { (key($0.domain, $0.path, $0.name), $0.value) }, uniquingKeysWith: { a, _ in a })
        let kept = Set(updated.map { key($0.domain, $0.path, $0.name) })
        // Cookies yt-dlp dropped (expired or cleared by YouTube) are removed from our store too.
        for c in current where !kept.contains(key(c.domain, c.path, c.name)) {
            await store.httpCookieStore.deleteCookie(c)
        }
        for c in updated where known[key(c.domain, c.path, c.name)] != c.value {
            var props: [HTTPCookiePropertyKey: Any] = [.domain: c.domain, .path: c.path, .name: c.name, .value: c.value]
            if c.secure { props[.secure] = "TRUE" }
            if let e = c.expires { props[.expires] = e }
            if c.httpOnly { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let cookie = HTTPCookie(properties: props) { await store.httpCookieStore.setCookie(cookie) }
        }
    }

    static var cookieDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("yt-cookies", isDirectory: true)
    }

    /// Leftovers from a crash mid-download (called at launch).
    static func cleanUp() { try? FileManager.default.removeItem(at: cookieDirectory) }

    /// YouTube rejected our cookies: wipe the stale session so the sign-in window starts fresh
    /// (otherwise it would see the old cookies and close straight away).
    static func sessionExpired() async { await signOut() }

    /// Forgets the session entirely (Settings → Sign out of YouTube).
    static func signOut() async {
        isSignedIn = false
        // Clear everything in the store first (works even while a web view still holds it), then drop it.
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        _store = nil
        try? await WKWebsiteDataStore.remove(forIdentifier: storeID)
    }
}

extension WKHTTPCookieStore {
    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { c in getAllCookies { c.resume(returning: $0) } }
    }
}

// MARK: - Sign-in window

/// Google's sign-in page in a web view, with a plain-language header and a clear way out.
struct YouTubeSignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onSignedIn: () -> Void = {}
    /// Starts at .checking: an existing session is detected before any web page is shown, so a signed-in
    /// user never sees Google's blank redirect pages.
    @State private var state: SignInWebView.State = .checking
    /// Google asked for a passkey. Passkeys can't work in an app's sign-in window (Apple only allows them in
    /// web browsers), so a banner walks the user to "Try another way" → password.
    @State private var passkeyAsked = false
    @State private var tryAnotherWay = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 26)).foregroundStyle(Theme.primaryTint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sign in to YouTube").font(Typo.ui(17, .bold)).foregroundStyle(Theme.ink)
                    Text(headline).font(Typo.ui(13)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(state == .done ? "Done" : "Cancel") { finish() }.buttonStyle(SecondaryButtonStyle())
            }
            .padding(18)
            if passkeyAsked && state == .ready { passkeyBanner }
            Divider()
            ZStack {
                if state != .checking && state != .done {
                    SignInWebView(state: $state, passkeyAsked: $passkeyAsked, tryAnotherWay: tryAnotherWay)
                }
                switch state {
                case .checking, .loading, .working: waitingView
                case .blocked: blockedHelp
                case .done: doneView
                case .ready: EmptyView()
                }
            }
        }
        .frame(width: 560, height: 680)
        .background(Theme.bg)
        .task {
            await YouTubeSignIn.refreshStatus()
            state = YouTubeSignIn.isSignedIn ? .done : .loading
        }
    }

    private func finish() {
        let signedIn = state == .done
        dismiss()
        if signedIn { onSignedIn() }
    }

    var headline: String {
        switch state {
        case .blocked: passkeyAsked ? "Here's another way to get the song." : "Google didn't allow sign-in here."
        case .done: "You're signed in. You can close this window."
        case .checking: "Checking…"
        default: "Use your Google email and password. Passkeys don't work here. Backline never sees your password."
        }
    }

    /// Covers the web view while Google's pages load or redirect, so there's never a blank white page.
    var waitingView: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(state == .working ? "Finishing sign-in…" : (state == .checking ? "Checking…" : "Opening Google sign-in…"))
                .font(Typo.ui(15, .semibold)).foregroundStyle(Theme.ink2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    var doneView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 60)).foregroundStyle(Theme.success)
            Text("You're signed in").font(Typo.ui(22, .bold)).foregroundStyle(Theme.ink)
            Text("Backline can now get videos that need a sign-in.")
                .font(Typo.ui(14)).foregroundStyle(Theme.ink2)
            Button(onSignedInIsRetry ? "Try the video again" : "Done") { finish() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    /// Shown when Google asks for a passkey: what to do instead, in plain words, with a button that does it.
    var passkeyBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "key.slash").foregroundStyle(Theme.warning)
                Text("Passkeys don't work here").font(Typo.ui(14, .bold)).foregroundStyle(Theme.ink)
            }
            Text("Click the button below. Then pick **Enter your password**.")
                .font(Typo.ui(13)).foregroundStyle(Theme.ink2)
            Text("You can also pick **Tap Yes on your phone** if your phone has the YouTube or Gmail app.")
                .font(Typo.ui(12)).foregroundStyle(Theme.muted)
            HStack(spacing: 8) {
                Button("Show other ways") { tryAnotherWay += 1 }.buttonStyle(PrimaryButtonStyle())
                Button("I don't know my password") { state = .blocked }.buttonStyle(SecondaryButtonStyle())
            }
            .padding(.top, 2)
        }
        .padding(EdgeInsets(top: 12, leading: 18, bottom: 14, trailing: 18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.opacity(0.10))
    }

    /// Set by callers that retry a download after sign-in (changes the button label only).
    var onSignedInIsRetry = false

    var blockedHelp: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(passkeyAsked ? "No password? That's OK." : "Google said no to signing in here").font(Typo.ui(18, .bold)).foregroundStyle(Theme.ink)
            Text("You can still get the song. You don't need to sign in:").font(Typo.ui(14)).foregroundStyle(Theme.ink2)
            Label("Play the video in your web browser. Then use **Record from an app**. Backline records the song while it plays.",
                  systemImage: "record.circle")
            Label("Or ask a grown-up to help you sign in.", systemImage: "person.2")
            Button("Close") { dismiss() }.buttonStyle(PrimaryButtonStyle())
        }
        .font(Typo.ui(13.5))
        .foregroundStyle(Theme.ink2)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg)
    }
}

struct SignInWebView: NSViewRepresentable {
    /// checking: looking for an existing session · loading: first page on its way · ready: a page the user
    /// can act on is showing · working: between pages (redirects) · blocked: Google refused · done: signed in.
    enum State: Equatable { case checking, loading, ready, working, blocked, done }
    @Binding var state: State
    @Binding var passkeyAsked: Bool
    /// Bumped by the "Show other ways" button: clicks Google's own "Try another way".
    var tryAnotherWay: Int = 0

    /// Reports any passkey (WebAuthn) request from Google's page. In an app's web view these always fail,
    /// so the app can explain and offer the password route instead. Nothing is changed on the page.
    static let passkeyHook = """
    (() => {
      const say = () => { try { window.webkit.messageHandlers.passkey.postMessage(location.pathname); } catch (e) {} };
      // Patch the prototype: Google's page may hold its own reference to navigator.credentials.
      const C = window.CredentialsContainer && CredentialsContainer.prototype;
      if (!C) return;
      for (const k of ['get', 'create']) {
        const orig = C[k];
        if (typeof orig !== 'function') continue;
        C[k] = function (opts) { if (opts && opts.publicKey) say(); return orig.call(this, opts); };
      }
    })();
    """

    static let clickTryAnotherWay = """
    (() => {
      const want = ['try another way', 'use another method', 'more ways to sign in'];
      const els = Array.from(document.querySelectorAll('button, [role="button"], a'));
      const b = els.find(e => want.includes((e.innerText || '').trim().toLowerCase()));
      if (b) { b.click(); return true; }
      return false;
    })();
    """

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = YouTubeSignIn.store
        config.userContentController.add(context.coordinator, name: "passkey")
        config.userContentController.addUserScript(WKUserScript(source: Self.passkeyHook, injectionTime: .atDocumentStart,
                                                                forMainFrameOnly: false))
        let web = WKWebView(frame: .zero, configuration: config)
        // WKWebView is Safari's engine; identify as Safari so Google shows its normal page.
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = NSColor(Theme.bg)
        context.coordinator.web = web
        #if DEBUG
        Self.debugLastWebView = web
        #endif
        web.load(URLRequest(url: YouTubeSignIn.signInURL))
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if tryAnotherWay != context.coordinator.handledTryAnotherWay {
            context.coordinator.handledTryAnotherWay = tryAnotherWay
            nsView.evaluateJavaScript(Self.clickTryAnotherWay) { _, _ in }
        }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "passkey")
        coordinator.stopObserving()
        nsView.stopLoading()
    }

    #if DEBUG
    /// Lets the snapshot harness photograph the page (web content draws out of process).
    @MainActor static weak var debugLastWebView: WKWebView?
    #endif

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver, WKScriptMessageHandler {
        let parent: SignInWebView
        weak var web: WKWebView?
        var handledTryAnotherWay = 0

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "passkey" { parent.passkeyAsked = true }
        }
        private var poll: Task<Void, Never>?

        init(_ p: SignInWebView) {
            parent = p
            super.init()
            // The moment Google hands over the YouTube login cookies, sign-in is done — whatever the page is
            // showing (after the password step Google/YouTube go through blank white redirect pages). The
            // cookie observer isn't always called for cookies set during redirects, so also look once a second.
            YouTubeSignIn.store.httpCookieStore.add(self)
            poll = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, self.parent.state != .done else { return }
                    if NetscapeCookies.hasYouTubeLogin(await YouTubeSignIn.cookies()) {
                        YouTubeSignIn.isSignedIn = true
                        self.parent.state = .done
                        return
                    }
                }
            }
        }

        nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            Task { @MainActor in
                guard self.parent.state != .done else { return }
                if NetscapeCookies.hasYouTubeLogin(await YouTubeSignIn.cookies()) {
                    YouTubeSignIn.isSignedIn = true
                    self.parent.state = .done
                }
            }
        }

        func stopObserving() {
            poll?.cancel()
            YouTubeSignIn.store.httpCookieStore.remove(self)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            // Redirects after the password step go through blank pages; show "Finishing sign-in…" instead.
            if parent.state == .ready || (parent.state == .loading && webView.url?.host?.hasSuffix("youtube.com") == true) {
                parent.state = .working
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { await check(webView) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { await check(webView) }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Task { await check(webView) }
        }

        /// Only Google and YouTube pages load in this window; anything else opens in the user's browser.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let host = action.request.url?.host?.lowercased() else { return .allow }
            let ok = YouTubeSignIn.allowedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
            if ok { return .allow }
            if action.navigationType == .linkActivated, let url = action.request.url { NSWorkspace.shared.open(url) }
            return .cancel
        }

        private func check(_ webView: WKWebView) async {
            let cookies = await YouTubeSignIn.cookies()
            if NetscapeCookies.hasYouTubeLogin(cookies) {
                YouTubeSignIn.isSignedIn = true
                parent.state = .done
                return
            }
            if let u = webView.url, u.host == "accounts.google.com", u.path.contains("/signin/challenge/pk") {
                parent.passkeyAsked = true
            }
            // Reveal the page once it has something on it (never a blank redirect page). If nothing shows up
            // within a few seconds, reveal it anyway so the window can't get stuck on "Finishing sign-in…".
            let hasContent = ((try? await webView.evaluateJavaScript("document.body ? document.body.innerText.trim().length : 0") as? Int) ?? 0) > 0
            if hasContent && !webView.isLoading { parent.state = .ready; return }
            let started = Date()
            try? await Task.sleep(for: .seconds(6))
            if parent.state == .working || parent.state == .loading, Date().timeIntervalSince(started) >= 6 {
                if NetscapeCookies.hasYouTubeLogin(await YouTubeSignIn.cookies()) { YouTubeSignIn.isSignedIn = true; parent.state = .done }
                else { parent.state = .ready }
            }
            // Google's "This browser or app may not be secure" / disallowed_useragent page.
            let text = (try? await webView.evaluateJavaScript("document.body ? document.body.innerText.slice(0, 4000) : ''") as? String) ?? ""
            let url = webView.url?.absoluteString ?? ""
            if url.contains("disallowed_useragent") || text.contains("may not be secure") || text.contains("Couldn’t sign you in")
                || text.contains("Couldn't sign you in") {
                parent.state = .blocked
            }
        }
    }
}
