#if BACKLINE_YTDLP
import BacklineKit
import Foundation
import WebKit

/// The 1.0 link engine, kept for one release as the way back (decision D10): the bundled yt-dlp fetches the
/// audio track. Built only with `BACKLINE_YTDLP=1`, which also embeds the helper (`scripts/embed-ytdlp.sh`);
/// the default build uses the Swift engine in `YouTubeImport` and `Backline/App/YouTube/`, the same one as iOS.
/// See docs/youtube-url-plan.md for the security design.
nonisolated enum YTDLPImport {
    typealias Video = YouTubeLink
    typealias Failure = YouTubeImport.Failure

    struct Result: Sendable {
        var file: URL
        var title: String?
        var uploader: String?
    }

    static var helperURL: URL? {
        // The launcher sits inside a folder of the same name (Resources/yt-dlp/yt-dlp).
        let u = Bundle.main.resourceURL?.appendingPathComponent("yt-dlp", isDirectory: true).appendingPathComponent("yt-dlp")
        return u.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    /// Bundled QuickJS-NG for YouTube's JS challenge (never a Deno/Node installed on the Mac).
    static var jsRuntimeURL: URL? {
        let u = Bundle.main.resourceURL?.appendingPathComponent("yt-dlp/qjs")
        return u.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    static var downloadsDirectory: URL { ImportStaging.downloadsDirectory }

    /// Downloads the audio track. `progress` receives 0…1; cancellation terminates the helper.
    /// `cookieFile` (a temporary cookies.txt from the in-app YouTube sign-in) is optional.
    @concurrent
    static func download(_ video: Video, cookieFile: URL? = nil, progress: @escaping @Sendable (Double) -> Void,
                         isCancelled: @escaping @Sendable () -> Bool) async throws -> Result {
        guard let helper = helperURL else { throw Failure.failed("This copy of Backline can't get songs from links.") }
        let dir = downloadsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cache = dir.appendingPathComponent("cache", isDirectory: true)

        let p = Process()
        p.executableURL = helper
        // Explicit argument array, canonical URL rebuilt from the id: nothing user-typed reaches argv.
        // Self-contained: ignore any yt-dlp config/plugins on this Mac, never read browsers directly,
        // and use only the bundled JS runtime.
        var args = ["--ignore-config", "--no-plugin-dirs", "--no-playlist", "--no-part", "--no-mtime",
                    "--no-cookies-from-browser", "--no-warnings", "--no-js-runtimes"]
        if let qjs = jsRuntimeURL { args += ["--js-runtimes", "quickjs:\(qjs.path)"] }
        if let cookieFile { args += ["--cookies", cookieFile.path] } else { args += ["--no-cookies"] }
        p.arguments = args + [
            "--cache-dir", cache.path,
            "--max-filesize", "150M", "--match-filters", "duration < 1200",
            "-f", "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]",
            "-o", dir.appendingPathComponent("%(id)s.%(ext)s").path,
            "--progress", "--newline", "--progress-template", "download:BL-PROGRESS %(progress._percent_str)s",
            "--print", "before_dl:BL-META %(title)s\u{1F}%(uploader)s",
            "--print", "after_move:BL-FILE %(filepath)s",
            video.canonicalURL.absoluteString,
        ]
        p.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin",
                         "TMPDIR": FileManager.default.temporaryDirectory.path, "LANG": "en_US.UTF-8"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        let state = OutputState()
        func handle(_ line: Substring, stderr: Bool) {
            if line.hasPrefix("BL-PROGRESS") {
                let pct = line.dropFirst("BL-PROGRESS".count).trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "%", with: "")
                if let v = Double(pct) { progress(min(1, v / 100)) }
            } else if !stderr, line.hasPrefix("BL-META ") {
                let parts = line.dropFirst(8).split(separator: "\u{1F}", omittingEmptySubsequences: false)
                state.set(title: parts.first.map(String.init), uploader: parts.count > 1 ? String(parts[1]) : nil)
            } else if !stderr, line.hasPrefix("BL-FILE ") {
                state.set(file: String(line.dropFirst(8)))
            }
        }
        // Each pipe is drained to EOF on its own thread, so nothing yt-dlp prints just before exiting
        // (e.g. the final BL-FILE line) can be lost.
        let drained = DispatchGroup()
        for (pipe, isErr) in [(out, false), (err, true)] {
            drained.enter()
            Thread.detachNewThread {
                let h = pipe.fileHandleForReading
                var pending = Data()
                while true {
                    let d = h.availableData
                    if d.isEmpty { break }
                    pending.append(d)
                    while let nl = pending.firstIndex(of: 0x0A) {
                        let lineData = pending[pending.startIndex..<nl]
                        pending.removeSubrange(pending.startIndex...nl)
                        if let line = String(data: lineData, encoding: .utf8) {
                            handle(Substring(line), stderr: isErr)
                            if isErr { state.appendError(line + "\n") }
                        }
                    }
                }
                if !pending.isEmpty, let line = String(data: pending, encoding: .utf8) {
                    handle(Substring(line), stderr: isErr)
                    if isErr { state.appendError(line) }
                }
                drained.leave()
            }
        }

        let exited = ExitSignal()
        p.terminationHandler = { _ in exited.fire() }
        try p.run()
        let deadline = Date().addingTimeInterval(300)
        while !exited.isFired {
            if isCancelled() || Date() > deadline {
                p.terminate()
                // Give it a moment to exit cleanly, then force it (never block a concurrency thread).
                for _ in 0..<30 where !exited.isFired { try? await Task.sleep(for: .milliseconds(100)) }
                if !exited.isFired { kill(p.processIdentifier, SIGKILL) }
                removePartials(of: video, in: dir)
                if isCancelled() { throw CancellationError() }
                throw Failure.failed("The download took too long. Check your internet and try again.")
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        await withCheckedContinuation { c in drained.notify(queue: .global()) { c.resume() } }
        let snap = state.snapshot()
        #if DEBUG
        // Never logs argv or cookie contents — only yt-dlp's own messages and whether sign-in was used.
        try? "status \(p.terminationStatus) signedIn=\(cookieFile != nil)\nfile=\(snap.file ?? "nil") title=\(snap.title ?? "nil")\n\(snap.error)".write(to: dir.appendingPathComponent("last-error.log"), atomically: true, encoding: .utf8)
        #endif
        guard p.terminationStatus == 0, let path = snap.file, FileManager.default.fileExists(atPath: path) else {
            let e = snap.error
            if e.contains("Requested format is not available") { throw Failure.unsupportedFormat }
            if e.contains("does not pass filter") { throw Failure.tooLong }
            if e.contains("Sign in") || e.contains("sign in") || e.contains("age-restricted") || e.contains("inappropriate for some users")
                || e.contains("members") || e.contains("Private video") || e.contains("cookies") {
                throw Failure.needsSignIn
            }
            if e.contains("Video unavailable") { throw Failure.failed("This video isn't available.") }
            if e.contains("Unable to download") || e.contains("HTTP Error") || e.contains("nodename nor servname") {
                throw Failure.failed(YouTubeExtractor.networkMessage)
            }
            throw Failure.failed("Couldn't get the song. Check the link, or use Record a song.")
        }
        progress(1)
        return Result(file: URL(fileURLWithPath: path), title: snap.title, uploader: snap.uploader)
    }

    /// Removes whatever yt-dlp left for this video (any extension, partial or finished).
    private static func removePartials(of video: Video, in dir: URL) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(video.id + ".") {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    private final class ExitSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func fire() { lock.withLock { fired = true } }
        var isFired: Bool { lock.withLock { fired } }
    }

    private final class OutputState: @unchecked Sendable {
        private let lock = NSLock()
        private var title: String?, uploader: String?, file: String?, error = ""
        func set(title: String?, uploader: String?) { lock.withLock { self.title = title; self.uploader = uploader } }
        func set(file: String) { lock.withLock { self.file = file } }
        func appendError(_ s: String) { lock.withLock { if error.count < 20_000 { error += s } } }
        func snapshot() -> (title: String?, uploader: String?, file: String?, error: String) {
            lock.withLock { (title, uploader, file, error) }
        }
    }
}

/// The cookies.txt hand-off the yt-dlp engine needs (the Swift engine reads the store directly).
extension YouTubeSignIn {
    /// Writes a private, temporary cookies.txt for one yt-dlp run. nil when not signed in.
    static func writeCookieFile() async -> URL? {
        guard isEnabled else { return nil }
        let list = await cookies().map {
            NetscapeCookies.Cookie(domain: $0.domain, path: $0.path, secure: $0.isSecure, httpOnly: $0.isHTTPOnly,
                                   expires: $0.expiresDate, name: $0.name, value: $0.value)
        }
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
        let current = await cookies()
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
}

#else
import Foundation

/// The default build has no yt-dlp. What the 1.0 engine left in the downloads folder (its cache and its debug
/// log) goes once; a song file waiting there stays for its import.
nonisolated enum YTDLPImport {
    static func removeLeftovers() {
        let dir = ImportStaging.downloadsDirectory
        for name in ["cache", "last-error.log"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}
#endif
