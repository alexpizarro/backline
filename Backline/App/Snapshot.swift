import BacklineKit
#if DEBUG
import AppKit
import SwiftUI

/// Debug-only visual verification: `Backline --snapshot <dir> [--song <file>]` renders each screen of the
/// real window to PNGs (via the window's own backing store, so no Screen Recording permission is needed).
@MainActor
enum Snapshotter {
    static var outputDir: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }

    static var songArg: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--song"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }

    /// Set by the app so the harness can open/close scenes (mini player).
    static var openWindow: ((String) -> Void)?
    static var dismissWindow: ((String) -> Void)?

    static func run(model: AppModel) {
        guard let dir = outputDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Snapshot runs skip the first-launch welcome unless they're capturing it.
        if !CommandLine.arguments.contains("--help-shots") { model.showWelcome = false }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if CommandLine.arguments.contains("--qjs-probe") {
                // Runs the sandboxed helper with a player client that needs the JS challenge solver.
                let helper = YouTubeImport.helperURL!, qjs = YouTubeImport.jsRuntimeURL!
                let p = Process()
                p.executableURL = helper
                p.arguments = ["--ignore-config", "--no-plugin-dirs", "--no-cookies-from-browser", "--no-cookies",
                               "--no-js-runtimes", "--js-runtimes", "quickjs:\(qjs.path)",
                               "--extractor-args", "youtube:player_client=mweb", "-v", "--skip-download",
                               "--print", "%(id)s", "--cache-dir", FileManager.default.temporaryDirectory.appendingPathComponent("qjs-cache").path,
                               "https://www.youtube.com/watch?v=CD-E-LDc384"]
                p.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "TMPDIR": FileManager.default.temporaryDirectory.path]
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
                try? p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let lines = (String(data: data, encoding: .utf8) ?? "").split(separator: "\n")
                    .filter { $0.contains("JS runtimes") || $0.contains("Solving JS") || $0.contains("Running QuickJS") || $0.contains("ERROR") || $0.contains("failed") }
                try? ("exit \(p.terminationStatus)\n" + lines.joined(separator: "\n")).write(to: dir.appendingPathComponent("qjs.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            if CommandLine.arguments.contains("--add-empty") {
                // From the start screen (no song open), "+ Add song" must show the choice sheet, not a file dialog.
                try? await Task.sleep(for: .seconds(0.5))
                model.addSong()
                try? await Task.sleep(for: .seconds(0.8))
                let panelOpen = NSApp.windows.contains { $0 is NSOpenPanel && $0.isVisible }
                try? "sheet=\(model.addSongSheet) filePanel=\(panelOpen)".write(to: dir.appendingPathComponent("add-empty.txt"), atomically: true, encoding: .utf8)
                capture(dir.appendingPathComponent("add-empty.png"))
                NSApp.terminate(nil)
                return
            }
            if CommandLine.arguments.contains("--signin-probe") {
                if CommandLine.arguments.contains("--add-sheet") {
                    if let song = songArg { model.open(song) }
                    for _ in 0..<240 where model.screen != .mixer { try? await Task.sleep(for: .seconds(0.5)) }
                    try? await Task.sleep(for: .seconds(0.8))
                    model.addSong()
                    try? await Task.sleep(for: .seconds(0.8))
                    capture(dir.appendingPathComponent("add-sheet.png"))
                    model.addSongSheet = false
                    try? await Task.sleep(for: .seconds(0.5))
                }
                // Opens the sign-in window with whatever session exists and records what the page shows
                // over time (URL, title, text, state) — used to reproduce "blank white window after sign-in".
                model.youTubeSignInSheet = true
                var log = ""
                if CommandLine.arguments.contains("--fake-passkey") {
                    // Simulates Google's page asking for a passkey (the call fails in an app's web view, as
                    // with a real passkey account). The banner must appear.
                    try? await Task.sleep(for: .seconds(5))
                    if let web = SignInWebView.debugLastWebView {
                        // Page-world call, like Google's own script (user scripts run in the page world).
                        do {
                            _ = try await web.callAsyncJavaScript("navigator.credentials.get({publicKey:{challenge:new Uint8Array(32),rpId:'google.com'}}).catch(e=>0); return 1;",
                                                                   arguments: [:], in: nil, contentWorld: .page)
                        } catch { log += "fake passkey JS error: \(error)\n" }
                    }
                    try? await Task.sleep(for: .seconds(1.2))
                    if let web = SignInWebView.debugLastWebView {
                        let diag = (try? await web.callAsyncJavaScript("return String(navigator.credentials && navigator.credentials.get).slice(0,80) + ' | handler=' + typeof (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.passkey);",
                                                                        arguments: [:], in: nil, contentWorld: .page)) as? String
                        log += "hook diag: \(diag ?? "nil")\n"
                    }
                    log += "passkey banner test: page=\(SignInWebView.debugLastWebView?.url?.path ?? "-")\n"
                    capture(dir.appendingPathComponent("signin-passkey.png"))
                }
                if CommandLine.arguments.contains("--plant-login") {
                    // Simulates Google finishing sign-in while the page is mid-redirect: the cookie arrives,
                    // the window must switch to "You're signed in" within a second.
                    try? await Task.sleep(for: .seconds(3))
                    let fake = HTTPCookie(properties: [.domain: ".youtube.com", .path: "/", .name: "LOGIN_INFO",
                                                       .value: "backline-probe", .secure: "TRUE",
                                                       .expires: Date().addingTimeInterval(600)])!
                    let t0 = Date()
                    await YouTubeSignIn.store.httpCookieStore.setCookie(fake)
                    for _ in 0..<40 where !YouTubeSignIn.isSignedIn { try? await Task.sleep(for: .milliseconds(50)) }
                    log += "planted login cookie → signedIn=\(YouTubeSignIn.isSignedIn) after \(String(format: "%.2f", Date().timeIntervalSince(t0)))s\n"
                    try? await Task.sleep(for: .seconds(0.6))
                    capture(dir.appendingPathComponent("signin-after-login.png"))
                }
                for i in 0..<8 {
                    try? await Task.sleep(for: .seconds(2))
                    if let web = SignInWebView.debugLastWebView {
                        let text = (try? await web.evaluateJavaScript("document.body ? document.body.innerText.slice(0, 300) : '(no body)'") as? String) ?? "?"
                        let bg = (try? await web.evaluateJavaScript("getComputedStyle(document.body).backgroundColor") as? String) ?? "?"
                        log += "t=\((i + 1) * 2)s host=\(web.url?.host ?? "-") path=\(web.url?.path ?? "-") loading=\(web.isLoading) bg=\(bg) text=\(text.replacingOccurrences(of: "\n", with: " | ").prefix(160))\n"
                        if i == 3, let img = try? await web.takeSnapshot(configuration: nil), let tiff = img.tiffRepresentation,
                           let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: dir.appendingPathComponent("signin-page.png"))
                        }
                    }
                    capture(dir.appendingPathComponent("signin-\(i).png"))
                    if i == 3 { break }
                }
                try? log.write(to: dir.appendingPathComponent("signin.txt"), atomically: true, encoding: .utf8)
                if CommandLine.arguments.contains("--fresh-signin") { await YouTubeSignIn.signOut() }
                NSApp.terminate(nil)
                return
            }
            if CommandLine.arguments.contains("--cancel-probe") {
                // Start a real download, cancel after 1.5 s: must throw CancellationError quickly and
                // leave no files for that video behind.
                let video = YouTubeImport.parse("https://www.youtube.com/watch?v=CD-E-LDc384")!
                let flag = CancelFlag()
                let t0 = Date()
                Task { try? await Task.sleep(for: .seconds(1.5)); flag.set() }
                var result = ""
                do { _ = try await YouTubeImport.download(video, progress: { _ in }, isCancelled: { flag.value }); result = "finished (not cancelled)" }
                catch is CancellationError { result = "cancelled" }
                catch { result = "error: \(error.localizedDescription)" }
                let left = ((try? FileManager.default.contentsOfDirectory(atPath: YouTubeImport.downloadsDirectory.path)) ?? []).filter { $0.hasPrefix(video.id) }
                try? "\(result) in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s leftovers=\(left)".write(to: dir.appendingPathComponent("cancel.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            if CommandLine.arguments.contains("--cookie-probe") {
                await cookieProbe(dir: dir)
                NSApp.terminate(nil)
                return
            }
            if CommandLine.arguments.contains("--help-shots") {
                await helpShots(model: model, dir: dir)
                NSApp.terminate(nil)
                return
            }
            // Optional window size: --win 700x560 (responsive layout checks).
            if let i = CommandLine.arguments.firstIndex(of: "--win"), i + 1 < CommandLine.arguments.count {
                let parts = CommandLine.arguments[i + 1].split(separator: "x").compactMap { Double($0) }
                if parts.count == 2, let w = NSApp.windows.first(where: { $0.isVisible && !($0 is MiniPanel) }) {
                    w.setContentSize(NSSize(width: parts[0], height: parts[1]))
                    try? await Task.sleep(for: .seconds(0.6))
                }
            }
            capture(dir.appendingPathComponent("1-empty.png"))
            if let i = CommandLine.arguments.firstIndex(of: "--youtube"), i + 1 < CommandLine.arguments.count,
               let video = YouTubeImport.parse(CommandLine.arguments[i + 1]) {
                model.openYouTube(video)
                try? await Task.sleep(for: .seconds(2))
                capture(dir.appendingPathComponent("2-downloading.png"))
                var waited = 0.0
                while model.screen != .mixer && waited < 240 {
                    try? await Task.sleep(for: .seconds(0.5)); waited += 0.5
                    if case .failed(let m) = model.screen {
                        try? "failed: \(m)".write(to: dir.appendingPathComponent("status.txt"), atomically: true, encoding: .utf8)
                        break
                    }
                }
                try? await Task.sleep(for: .seconds(1.0))
                capture(dir.appendingPathComponent("3-mixer.png"))
                if let s = model.song {
                    try? "title=\(s.title) artist=\(s.artist ?? "-") source=\(s.sourceName) stems=\(model.stems.map(\.rawValue)) removed=\(model.settings.removed.map(\.rawValue)) bpm=\(s.analysis.bpm) split=\(s.guitarSplit?.method ?? "none") downloadsLeft=\((try? FileManager.default.contentsOfDirectory(atPath: YouTubeImport.downloadsDirectory.path)) ?? [])"
                        .write(to: dir.appendingPathComponent("status.txt"), atomically: true, encoding: .utf8)
                }
                NSApp.terminate(nil)
                return
            }
            if let song = songArg {
                model.open(song)
                try? await Task.sleep(for: .seconds(1.2))
                capture(dir.appendingPathComponent("2-analyzing.png"))
                var waited = 0.0
                while model.screen != .mixer && waited < 180 {
                    try? await Task.sleep(for: .seconds(0.5)); waited += 0.5
                    if case .failed = model.screen { break }
                }
                try? await Task.sleep(for: .seconds(1.0))
                capture(dir.appendingPathComponent("3-mixer.png"))
                if CommandLine.arguments.contains("--countin") {
                    model.settings.countIn = true
                    model.togglePlay()
                    for _ in 0..<40 where model.countInBeat == 0 { try? await Task.sleep(for: .seconds(0.05)) }
                    try? await Task.sleep(for: .seconds(0.25))
                    capture(dir.appendingPathComponent("4b-countin.png"))
                    model.togglePlay()
                    try? await Task.sleep(for: .seconds(0.4))
                }
                if !CommandLine.arguments.contains("--no-play") {
                    let before = model.position
                    model.settings.countIn = false
                    model.togglePlay()
                    try? await Task.sleep(for: .seconds(2.5))
                    capture(dir.appendingPathComponent("4-playing.png"))
                    let after = model.position
                    model.togglePlay()
                    try? "played \(before) -> \(after) playing=\(model.isPlaying)\n".write(
                        to: dir.appendingPathComponent("play.txt"), atomically: true, encoding: .utf8)
                    // Stretch + pitch while playing.
                    model.settings.speed = 70
                    model.settings.pitch = -2
                    model.togglePlay()
                    try? await Task.sleep(for: .seconds(2.0))
                    let after2 = model.position
                    model.togglePlay()
                    try? "played \(before) -> \(after) ; stretched -> \(after2)\n".write(
                        to: dir.appendingPathComponent("play.txt"), atomically: true, encoding: .utf8)
                    model.settings.speed = 100
                    model.settings.pitch = 0
                    model.settings.countIn = true
                }
                if let song = model.song {
                    var report = ""
                    for fmt in [ExportFormat.wav, .mp3, .aiff] {
                        let outDir = dir.appendingPathComponent("elsewhere", isDirectory: true)
                        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
                        let url = outDir.appendingPathComponent("export-test.\(fmt.fileExtension)")
                        let gains: [Float] = model.stems.map { k in
                            model.isAudible(k) ? AppModel.gain(forVolume: model.settings.volume(k)) / max(song.storageScale[k.rawValue] ?? 1, 1e-6) : 0
                        }
                        let job = ExportJob(settings: .init(gains: gains, rate: 0.8, semitones: -1), format: fmt,
                                            url: url, title: song.title, artist: song.artist)
                        let engine = model.engine
                        let t0 = Date()
                        let r = await Task.detached { Result { try Exporter.run(job, engine: engine) { _ in } } }.value
                        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                        report += "\(fmt.rawValue): \(r) \(size) bytes in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s\n"
                    }
                    try? report.write(to: dir.appendingPathComponent("export.txt"), atomically: true, encoding: .utf8)
                }
                model.openExport()
                try? await Task.sleep(for: .seconds(0.8))
                capture(dir.appendingPathComponent("5-export.png"))
                model.exportSheet = false
                try? await Task.sleep(for: .seconds(0.5))
                model.showToast(.init(text: "Saved to Music › Backline", url: URL(fileURLWithPath: "/tmp")))
                try? await Task.sleep(for: .seconds(0.6))
                capture(dir.appendingPathComponent("6-toast.png"))
                // Narrow window (responsive layout) and the mini player.
                if let window = NSApp.windows.first(where: { $0.isVisible && !$0.title.contains("Mini") }) {
                    let original = window.frame
                    window.setFrame(NSRect(x: original.minX, y: original.minY, width: WindowLimits.minContentWidth, height: WindowLimits.minHeight), display: true, animate: false)
                    for _ in 0..<6 { try? await Task.sleep(for: .seconds(0.3)); window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
                    capture(dir.appendingPathComponent("7-narrow.png"))
                    window.setFrame(original, display: true)
                    try? await Task.sleep(for: .seconds(0.5))
                }
                model.toggleMiniPlayer()
                try? await Task.sleep(for: .seconds(1.2))
                if let mini = NSApp.windows.first(where: { $0.isVisible && $0 is MiniPanel }) {
                    captureWindow(mini, to: dir.appendingPathComponent("8-mini.png"))
                    try? "mini frame \(mini.frame) level \(mini.level.rawValue)\n".write(
                        to: dir.appendingPathComponent("mini.txt"), atomically: true, encoding: .utf8)
                }
                model.toggleMiniPlayer()
                if let s = model.song {
                    let status = """
                    title=\(s.title) stems=\(s.stems.map(\.rawValue)) bpm=\(s.analysis.bpm) key=\(s.analysis.key ?? "-")
                    sections=\(s.analysis.sections.map { "\($0.label)@\(Int($0.start))" })
                    loop=\(String(describing: model.loopRange)) removed=\(model.settings.removed.map(\.rawValue))
                    position=\(model.position)
                    """
                    try? status.write(to: dir.appendingPathComponent("status.txt"), atomically: true, encoding: .utf8)
                }
            }
            NSApp.terminate(nil)
        }
    }

    /// End-to-end check of the sign-in cookie path without a real Google account: plant a fake YouTube
    /// login cookie in the private store, export it, run the sandboxed yt-dlp with it, confirm the file is
    /// deleted afterwards, then sign out and confirm the store is empty. Writes cookie-probe.txt (no values).
    static func cookieProbe(dir: URL) async {
        var log = ""
        let fake = HTTPCookie(properties: [.domain: ".youtube.com", .path: "/", .name: "LOGIN_INFO",
                                           .value: "backline-probe", .secure: "TRUE",
                                           .expires: Date().addingTimeInterval(3600)])!
        await YouTubeSignIn.store.httpCookieStore.setCookie(fake)
        log += "store cookies=\(await YouTubeSignIn.store.httpCookieStore.allCookies().map { "\($0.domain)/\($0.name)" })\n"
        await YouTubeSignIn.refreshStatus()
        log += "signedIn(after plant)=\(YouTubeSignIn.isSignedIn)\n"
        guard let file = await YouTubeSignIn.writeCookieFile() else { log += "writeCookieFile=nil\n"; write(log, dir); return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        log += "cookieFile perms=\(String(format: "%o", (attrs?[.posixPermissions] as? Int) ?? 0)) lines=\((try? String(contentsOf: file, encoding: .utf8))?.split(separator: "\n").filter { !$0.hasPrefix("# ") && !$0.isEmpty }.count ?? -1)\n"
        let video = YouTubeImport.parse("https://youtu.be/2pXa5jzaOBg")!
        do {
            let r = try await YouTubeImport.download(video, cookieFile: file, progress: { _ in }, isCancelled: { false })
            log += "download ok title=\(r.title ?? "-")\n"
            try? FileManager.default.removeItem(at: r.file)
        } catch { log += "download error: \(error.localizedDescription)\n" }
        await YouTubeSignIn.finish(cookieFile: file)
        log += "cookieFile deleted=\(!FileManager.default.fileExists(atPath: file.path))\n"
        let ytlog = (try? String(contentsOf: YouTubeImport.downloadsDirectory.appendingPathComponent("last-error.log"), encoding: .utf8)) ?? ""
        log += "log mentions cookie value=\(ytlog.contains("backline-probe")) signedInFlag=\(ytlog.contains("signedIn=true"))\n"
        await YouTubeSignIn.signOut()
        let left = await YouTubeSignIn.cookies()
        log += "after signOut cookies=\(left.count) signedIn=\(YouTubeSignIn.isSignedIn)\n"
        write(log, dir)
    }

    nonisolated final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock(); private var v = false
        func set() { lock.withLock { v = true } }
        var value: Bool { lock.withLock { v } }
    }

    private static func write(_ s: String, _ dir: URL) {
        try? s.write(to: dir.appendingPathComponent("cookie-probe.txt"), atomically: true, encoding: .utf8)
    }

    /// Welcome cards, every Help page, the sign-in window and the "needs sign-in" error screen.
    static func helpShots(model: AppModel, dir: URL) async {
        model.showWelcome = true
        try? await Task.sleep(for: .seconds(0.8))
        capture(dir.appendingPathComponent("h0-welcome.png"))
        if let sheet = NSApp.windows.first(where: { $0.isVisible && !($0 is MiniPanel) })?.attachedSheet {
            captureWindow(sheet, to: dir.appendingPathComponent("h0-welcome-only.png"))
        }
        model.showWelcome = false
        try? await Task.sleep(for: .seconds(0.6))
        for (i, t) in HelpTopic.allCases.enumerated() {
            model.helpTopic = t
            openWindow?("help")
            try? await Task.sleep(for: .seconds(i == 0 ? 1.2 : 0.5))
            if let w = NSApp.windows.first(where: { $0.title == "Backline Help" && $0.isVisible }) {
                captureWindow(w, to: dir.appendingPathComponent(String(format: "h%02d-%@.png", i + 1, t.rawValue)))
            }
        }
        dismissWindow?("help")
        try? await Task.sleep(for: .seconds(0.4))
        withAnimation { model.screen = .failed(YouTubeImport.signInMessage) }
        try? await Task.sleep(for: .seconds(0.8))
        capture(dir.appendingPathComponent("h20-needs-signin.png"))
        model.youTubeSignInSheet = true
        try? await Task.sleep(for: .seconds(6))
        capture(dir.appendingPathComponent("h21-signin-sheet.png"))
        if let web = SignInWebView.debugLastWebView {
            let title = (try? await web.evaluateJavaScript("document.title") as? String) ?? "?"
            let host = web.url?.host ?? "?"
            try? "host=\(host) title=\(title) loading=\(web.isLoading)".write(to: dir.appendingPathComponent("signin.txt"), atomically: true, encoding: .utf8)
            if let img = try? await web.takeSnapshot(configuration: nil), let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("h22-signin-page.png"))
            }
        }
        model.youTubeSignInSheet = false
        withAnimation { model.screen = .empty }
        try? await Task.sleep(for: .seconds(0.6))
        capture(dir.appendingPathComponent("h23-empty.png"))
    }

    static func captureWindow(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: url) }
    }

    static func capture(_ url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && !($0 is MiniPanel) }) else { return }
        // Include any attached sheet.
        let target = window.attachedSheet ?? window
        _ = target
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        var image = rep
        if let sheet = window.attachedSheet, let sv = sheet.contentView,
           let srep = sv.bitmapImageRepForCachingDisplay(in: sv.bounds) {
            sv.cacheDisplay(in: sv.bounds, to: srep)
            // Composite sheet centred at the top of the window.
            let size = bounds.size
            let composed = NSImage(size: size)
            composed.lockFocus()
            rep.draw(in: NSRect(origin: .zero, size: size))
            NSColor(white: 0.03, alpha: 0.55).setFill()
            NSRect(origin: .zero, size: size).fill(using: .sourceOver)
            let sw = sv.bounds.width, sh = sv.bounds.height
            srep.draw(in: NSRect(x: (size.width - sw) / 2, y: size.height - 44 - sh, width: sw, height: sh))
            composed.unlockFocus()
            if let tiff = composed.tiffRepresentation, let r = NSBitmapImageRep(data: tiff) { image = r }
        }
        if let data = image.representation(using: .png, properties: [:]) { try? data.write(to: url) }
    }
}
#endif
