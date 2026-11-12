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

    /// Verifies the practice modes on a real song: one screenshot per mode, a dance session (Listen for,
    /// an 8-count loop, counts while playing) and a Beats bar loop. The song's settings are put back after.
    static func modeShots(model: AppModel, rec: SongRecord, dir: URL) async {
        let originalMode = model.appMode
        model.select(rec)
        var waited = 0.0
        while model.song?.id != rec.id && waited < 30 { try? await Task.sleep(for: .seconds(0.2)); waited += 0.2 }
        try? await Task.sleep(for: .seconds(1.0))
        let saved = model.settings
        var log = "song=\(rec.title) bpm=\(rec.analysis.bpm) stems=\(model.stems.map(\.rawValue))\n"

        // Seek before the first Play must stick (it used to snap back to 0:00).
        model.seek(to: 60)
        try? await Task.sleep(for: .seconds(0.5))
        log += String(format: "seekBeforePlay: asked 60.0, shows %.2f\n", model.position)

        for m in PracticeMode.allCases {
            model.setMode(m)
            try? await Task.sleep(for: .seconds(0.8))
            capture(dir.appendingPathComponent("mode-\(m.rawValue).png"))
            log += "\(m.rawValue): removed=\(model.settings.removed.map(\.rawValue).sorted()) style=\(model.settings.danceStyle?.rawValue ?? "-") tempoScale=\(model.settings.tempoScale) labels=\(model.stems.map { model.label($0) })\n"
        }

        model.setMode(.dance)
        model.settings.countIn = false
        model.seek(to: 60)
        if let k = model.danceListenParts.first { model.toggleSpotlight(k) }
        model.clearOne()
        try? await Task.sleep(for: .seconds(0.4))
        capture(dir.appendingPathComponent("dance-tap-prompt.png"))
        model.setOneHere()
        model.loopCounts(8)
        model.togglePlay()
        try? await Task.sleep(for: .seconds(2.2))
        capture(dir.appendingPathComponent("dance-playing.png"))
        log += "dance: count=\(model.currentCount.map(String.init) ?? "-") loopCounts=\(model.loopCountLength.map(String.init) ?? "-") spotlight=\(model.settings.spotlight?.rawValue ?? "-") gains=\(model.stems.map { String(format: "%.2f", model.trackGain($0)) })\n"
        model.togglePlay()

        model.setMode(.beats)
        model.seek(to: 75)
        model.loopBars(2)
        try? await Task.sleep(for: .seconds(0.6))
        capture(dir.appendingPathComponent("beats-loop.png"))
        if model.musicCanOpen {
            model.toggleMusicOpen()
            try? await Task.sleep(for: .seconds(0.6))
            capture(dir.appendingPathComponent("beats-music-open.png"))
            log += "beats music open rows=\(model.rows.map { model.label($0.kind) })\n"
            model.toggleMusicOpen()
        }
        log += String(format: "beats: loopBars=%@ loop=%.2f-%.2f\n", model.loopBarCount.map(String.init) ?? "-",
                      model.loopRange?.lowerBound ?? -1, model.loopRange?.upperBound ?? -1)

        if CommandLine.arguments.contains("--wait-drums") {
            // Beats asks for the kit parts; wait for the background split and the engine reload.
            model.setMode(.beats)
            let t0 = Date()
            var w = 0.0
            while (model.song?.drumSplit == nil || !model.loadedTracks.contains(.kick)) && w < 300 {
                try? await Task.sleep(for: .seconds(0.5)); w += 0.5
                if Int(w * 2) % 20 == 0, let p = model.drumSplitProgress { log += String(format: "  split %.0f%% at %.0fs\n", p * 100, w) }
            }
            log += String(format: "drum split: %@ in %.1fs; engine tracks=%@\n", model.song?.drumSplit?.method ?? "none",
                          Date().timeIntervalSince(t0), model.loadedTracks.map(\.rawValue).description)
            log += "beats rows=\(model.rows.map { "\(model.label($0.kind))[\($0.leaves.map(\.rawValue).joined(separator: "+"))]" })\n"
            try? await Task.sleep(for: .seconds(0.8))
            capture(dir.appendingPathComponent("beats-kit.png"))
            model.loopBars(2)
            model.settings.countIn = false
            model.toggle(.kick)
            model.togglePlay()
            try? await Task.sleep(for: .seconds(1.5))
            log += "beats play (kick off): position=\(String(format: "%.2f", model.position)) gains=\(model.exportGains().map { String(format: "%.2f", $0) })\n"
            model.togglePlay()
            model.setMode(.dance)
            model.setDanceStyle(.bachata)
            log += "dance bachata rows=\(model.rows.map { "\(model.label($0.kind))[\($0.leaves.map(\.rawValue).joined(separator: "+"))]" })\n"
            try? await Task.sleep(for: .seconds(0.6))
            capture(dir.appendingPathComponent("dance-kit.png"))
            model.setMode(.play)
            log += "play rows=\(model.rows.map { "\(model.label($0.kind))[\($0.leaves.map(\.rawValue).joined(separator: "+"))]" })\n"
        }

        model.settings = saved
        model.appMode = originalMode
        model.persistCurrent(synchronously: true)
        try? log.write(to: dir.appendingPathComponent("modes.txt"), atomically: true, encoding: .utf8)
    }

    /// One pasted link, screen by screen: `link-1-getting.png` at once, then whichever sheet or screen it reaches
    /// (`link-picker`, `link-ask`, `link-others` after "Not this" or "Wrong song?", `link-another-way`, `link-failed`),
    /// and `link.txt` with what happened. With `--spotify-stub` nothing is fetched; a match stops before the download.
    static func linkShots(model: AppModel, text: String, dir: URL) async {
        var log = "openText=\(model.openText(text)) screen=\(model.screen)\n"
        try? await Task.sleep(for: .seconds(0.8))
        capture(dir.appendingPathComponent("link-1-getting.png"))
        var waited = 0.0
        var shotAnotherWay = false
        while waited < 60 {
            try? await Task.sleep(for: .seconds(0.25)); waited += 0.25
            if model.tryingAnotherWay && !shotAnotherWay {
                shotAnotherWay = true
                try? await Task.sleep(for: .seconds(0.5))
                capture(dir.appendingPathComponent("link-another-way.png"))
            }
            if model.spotify.picker != nil {
                try? await Task.sleep(for: .seconds(0.8))
                capture(dir.appendingPathComponent("link-picker.png"))
                log += "picker tracks=\(model.spotify.picker?.list.tracks.map(\.title) ?? [])\n"
                break
            }
            if let ask = model.spotify.ask {
                try? await Task.sleep(for: .seconds(0.8))
                capture(dir.appendingPathComponent("link-ask.png"))
                log += "ask \(ask.choice.candidate.videoID) gap=\(ask.choice.gap)\n"
                model.refuseSpotifyCandidate(ask)
                try? await Task.sleep(for: .seconds(1.0))
                if model.spotify.others != nil { capture(dir.appendingPathComponent("link-others.png")) }
                log += "after Not this: others=\(model.spotify.others?.choices.count ?? 0)\n"
                break
            }
            if !model.spotify.finding, model.spotify.matched != nil {
                try? await Task.sleep(for: .seconds(0.8))
                capture(dir.appendingPathComponent("link-2-matched.png"))
                log += "matched \(model.spotify.matched?.result.best?.candidate.videoID ?? "-") title=\(model.importTitle) artist=\(model.importArtist)\n"
                model.showOtherSpotifyCandidates()
                try? await Task.sleep(for: .seconds(1.0))
                capture(dir.appendingPathComponent("link-others.png"))
                log += "wrong song: others=\(model.spotify.others?.choices.map(\.candidate.videoID) ?? [])\n"
                break
            }
            if case .failed(let m) = model.screen {
                try? await Task.sleep(for: .seconds(2.0))
                // A window that is covered (other apps in front, a locked screen) never finishes SwiftUI's
                // transitions, so the screen that is leaving stays drawn: put the failure back without one.
                if NSApp.windows.first(where: { $0.isVisible && !($0 is MiniPanel) })?.occlusionState.contains(.visible) == false {
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { model.screen = .empty }
                    try? await Task.sleep(for: .seconds(0.3))
                    withTransaction(t) { model.screen = .failed(m) }
                    try? await Task.sleep(for: .seconds(0.5))
                }
                capture(dir.appendingPathComponent("link-failed.png"))
                log += "failed: \(m)\n"
                break
            }
            if model.screen != .analyzing { break }
        }
        log += "end screen=\(model.screen) toast=\(model.toast?.text ?? "-") after \(waited) s\n"
        try? log.write(to: dir.appendingPathComponent("link.txt"), atomically: true, encoding: .utf8)
        model.dismissSpotifySheet()
        model.cancelImport()
    }

    static func run(model: AppModel) {
        guard let dir = outputDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Snapshot runs skip the first-launch welcome unless they're capturing it.
        if !CommandLine.arguments.contains("--help-shots") { model.showWelcome = false }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            #if BACKLINE_YTDLP
            if CommandLine.arguments.contains("--qjs-probe") {
                // Runs the sandboxed helper with a player client that needs the JS challenge solver.
                let helper = YTDLPImport.helperURL!, qjs = YTDLPImport.jsRuntimeURL!
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
            #endif
            if CommandLine.arguments.contains("--library-shot") {
                // What the launch made of the last run (D20 d): the Library's unfinished rows and the journal.
                await model.libraryReady()
                if !CommandLine.arguments.contains("--background") { await bringToFront() }
                try? await Task.sleep(for: .seconds(0.8))
                capture(dir.appendingPathComponent("library.png"))
                let j = WorkJournal.shared.snapshot
                let lines = model.unfinishedImports.map { "unfinished \($0.id) title=\($0.entry.title) stage=\($0.entry.stage) "
                    + "staged=\($0.entry.staged) external=\($0.entry.external ?? "-") bookmark=\($0.entry.bookmark != nil) "
                    + "line=\(AppModel.unfinishedLine($0))" }
                    + ["running=\(j.running?.id ?? "-") passes=\(j.passes.count) failures=\(j.failures)"]
                try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("journal.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            if CommandLine.arguments.contains("--carry-on-unfinished") {
                // R3: a click on the unfinished song carries on its split from the checkpoint and opens the song.
                await model.libraryReady()
                var lines: [String] = []
                if let u = model.unfinishedImports.first {
                    let t0 = Date()
                    lines.append("unfinished \(u.id) line=\(AppModel.unfinishedLine(u))")
                    lines.append("checkpoint before: \(FileManager.default.fileExists(atPath: PassCheckpoints.directory(.importSplit, u.id).path))")
                    model.retryUnfinished(u)
                    for _ in 0..<2400 where model.screen != .mixer {
                        if case .failed = model.screen { break }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    lines.append("screen=\(model.screen == .mixer ? "mixer" : "not mixer") song=\(model.song?.id ?? "-") after \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
                    lines.append("checkpoint after: \(FileManager.default.fileExists(atPath: PassCheckpoints.directory(.importSplit, u.id).path))")
                    lines.append("unfinished rows left: \(model.unfinishedImports.count)")
                } else {
                    lines.append("no unfinished import")
                }
                try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("carry-on.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            if CommandLine.arguments.contains("--time-import"), let song = songArg {
                // Wall-clock time from "open" to the mixer, with the phase breakdown.
                let t0 = Date(); var marks: [String] = []; var last = -1
                model.open(song)
                while model.screen != .mixer {
                    if case .failed = model.screen { break }
                    if model.importProgress.phase != last { last = model.importProgress.phase; marks.append("phase \(last) at \(String(format: "%.1f", Date().timeIntervalSince(t0)))s") }
                    try? await Task.sleep(for: .milliseconds(5))
                }
                marks.append("mixer at \(String(format: "%.3f", Date().timeIntervalSince(t0)))s split=\(model.song?.guitarSplit?.method ?? "-")")
                try? marks.joined(separator: "\n").write(to: dir.appendingPathComponent("timing.txt"), atomically: true, encoding: .utf8)
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
                // Start a real download, cancel at 30 %: must throw CancellationError quickly and leave no
                // files for that video behind. (The Swift engine gets this video in about a second, so a
                // cancel after a fixed time would come too late.)
                let video = YouTubeImport.parse("https://www.youtube.com/watch?v=CD-E-LDc384")!
                let flag = CancelFlag()
                let t0 = Date()
                var result = ""
                do { _ = try await YouTubeImport.download(video, progress: { if $0 >= 0.3 { flag.set() } }, isCancelled: { flag.value }); result = "finished (not cancelled)" }
                catch is CancellationError { result = "cancelled" }
                catch { result = "error: \(error.localizedDescription)" }
                let left = ((try? FileManager.default.contentsOfDirectory(atPath: ImportStaging.downloadsDirectory.path)) ?? []).filter { $0.hasPrefix(video.id) }
                try? "\(result) in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s leftovers=\(left)".write(to: dir.appendingPathComponent("cancel.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            if CommandLine.arguments.contains("--cookie-probe") {
                await cookieProbe(dir: dir)
                NSApp.terminate(nil)
                return
            }
            if CommandLine.arguments.contains("--readme-shots") {
                // --store-shots: the Mac App Store's size. The whole window, title bar included, is 1280 x 800
                // points (2560 x 1600 pixels on a Retina screen; 1440 x 900 doesn't fit beside the Dock on a 14-inch screen), in front so the Metal views draw, with the
                // Library beside the player.
                let store = CommandLine.arguments.contains("--store-shots")
                if store, let w = NSApp.windows.first(where: { $0.isVisible && !($0 is MiniPanel) }) {
                    await bringToFront()
                    let visible = (w.screen ?? NSScreen.main)?.visibleFrame ?? .zero
                    w.setFrame(NSRect(x: visible.minX + 20, y: visible.maxY - 800, width: 1280, height: 800), display: true)
                    try? await Task.sleep(for: .seconds(0.8))
                }
                await readmeShots(model: model, dir: dir, keepSidebar: store)
                NSApp.terminate(nil)
                return
            }
            if CommandLine.arguments.contains("--sheet-shots") {
                await sheetShots(model: model, dir: dir)
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
            if await extraPartsRun(model: model, dir: dir) { NSApp.terminate(nil); return }
            // --wait-models: let the background model downloads run, then report what got installed.
            if CommandLine.arguments.contains("--wait-models") {
                let t0 = Date()
                try? await Task.sleep(for: .seconds(6))
                while model.modelDownloadTask != nil && Date().timeIntervalSince(t0) < 900 {
                    try? await Task.sleep(for: .seconds(1))
                }
                let installed = ModelDownloads.assets.filter(ModelDownloads.isInstalled).map(\.name)
                try? String(format: "installed=%@ missing=%@ after %.1fs\n", installed.description,
                            ModelDownloads.missing.map(\.name).description, Date().timeIntervalSince(t0))
                    .write(to: dir.appendingPathComponent("models.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            // --open-title <text> --modes: a library song in Play, Dance and Beats (settings restored after).
            if let i = CommandLine.arguments.firstIndex(of: "--open-title"), i + 1 < CommandLine.arguments.count,
               let rec = model.library.first(where: { $0.title.localizedCaseInsensitiveContains(CommandLine.arguments[i + 1]) }) {
                await modeShots(model: model, rec: rec, dir: dir)
                NSApp.terminate(nil)
                return
            }
            // --link <text> [--spotify-stub match|ask|none|playlist] [--song-service-stub fail]: a pasted link's
            // screens and sheets (paritymac WP2), without splitting.
            if let i = CommandLine.arguments.firstIndex(of: "--link"), i + 1 < CommandLine.arguments.count {
                await linkShots(model: model, text: CommandLine.arguments[i + 1], dir: dir)
                NSApp.terminate(nil)
                return
            }
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
                    try? "title=\(s.title) artist=\(s.artist ?? "-") source=\(s.sourceName) stems=\(model.stems.map(\.rawValue)) removed=\(model.settings.removed.map(\.rawValue)) bpm=\(s.analysis.bpm) split=\(s.guitarSplit?.method ?? "none") downloadsLeft=\((try? FileManager.default.contentsOfDirectory(atPath: ImportStaging.downloadsDirectory.path)) ?? [])"
                        .write(to: dir.appendingPathComponent("status.txt"), atomically: true, encoding: .utf8)
                }
                NSApp.terminate(nil)
                return
            }
            if let song = songArg {
                var metalLog = ""
                // A covered window draws no Metal frames (the scheduler skips what can't be seen), so the
                // captures of the player are taken with the window in front; --background keeps it behind.
                if !CommandLine.arguments.contains("--background") { await bringToFront() }
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
                metalLog += "at 3-mixer:\n" + WaveformScheduler.shared.debugReport() + "\n"
                try? metalLog.write(to: dir.appendingPathComponent("metal.txt"), atomically: true, encoding: .utf8)
                if CommandLine.arguments.contains("--wait-hq") {
                    // The cleaner pass runs after the song opens; wait for it, then for the drum kit in Beats.
                    var log = "opened: separator=\(model.song?.separator ?? "htdemucs") original=\(model.song.flatMap { $0.originalFile ?? ($0.originalScale != nil ? "original.caf" : nil) } ?? "none") stems=\(model.stems.map(\.rawValue))\n"
                    let t0 = Date()
                    while (model.song?.separator == nil || model.pendingRecord != nil) && Date().timeIntervalSince(t0) < 900 {
                        try? await Task.sleep(for: .seconds(1))
                        if let p = model.hqProgress, Int(Date().timeIntervalSince(t0)) % 15 == 0 { log += String(format: "  cleaner %.0f%% at %.0fs\n", p * 100, Date().timeIntervalSince(t0)) }
                    }
                    log += String(format: "cleaner parts: %@ in %.1fs, stems=%@ split=%@\n", model.song?.separator ?? "none",
                                  Date().timeIntervalSince(t0), model.stems.map(\.rawValue).description, model.song?.guitarSplit?.method ?? "-")
                    capture(dir.appendingPathComponent("3b-cleaner.png"))
                    model.setMode(.beats)
                    let t1 = Date()
                    while model.song?.drumSplit == nil || !model.loadedTracks.contains(.kick) {
                        if Date().timeIntervalSince(t1) > 600 { break }
                        try? await Task.sleep(for: .seconds(1))
                    }
                    log += String(format: "drum kit: %@ in %.1fs, rows=%@\n", model.song?.drumSplit?.method ?? "none",
                                  Date().timeIntervalSince(t1), model.rows.map { model.label($0.kind) }.description)
                    capture(dir.appendingPathComponent("3c-beats.png"))
                    model.setMode(.play)
                    try? log.write(to: dir.appendingPathComponent("hq.txt"), atomically: true, encoding: .utf8)
                }
                if CommandLine.arguments.contains("--countin") {
                    model.settings.countIn = true
                    model.togglePlay()
                    for _ in 0..<40 where model.countInBeat == 0 { try? await Task.sleep(for: .seconds(0.05)) }
                    try? await Task.sleep(for: .seconds(0.25))
                    capture(dir.appendingPathComponent("4b-countin.png"))
                    model.togglePlay()
                    try? await Task.sleep(for: .seconds(0.4))
                }
                if CommandLine.arguments.contains("--zoom") {
                    // The Map zoomed to a quarter of the song with a loop, and the section strip over it (WP5).
                    let whole = MapWindow.whole(model.duration)
                    model.setLoop(start: model.duration * 0.35, end: model.duration * 0.45)
                    model.mapWindow = whole.zoomed(length: model.duration / 4, keeping: model.duration * 0.4, atX: 0.5, width: 1)
                    try? await Task.sleep(for: .seconds(0.8))
                    capture(dir.appendingPathComponent("4c-zoomed.png"))
                    model.mapWindow = whole
                    model.updateSettings { $0.loopEnabled = false }
                    try? await Task.sleep(for: .seconds(0.4))
                }
                if !CommandLine.arguments.contains("--no-play") {
                    let before = model.position
                    model.settings.countIn = false
                    model.togglePlay()
                    try? await Task.sleep(for: .seconds(2.5))
                    capture(dir.appendingPathComponent("4-playing.png"))
                    metalLog += "at 4-playing:\n" + WaveformScheduler.shared.debugReport() + "\n"
                    try? metalLog.write(to: dir.appendingPathComponent("metal.txt"), atomically: true, encoding: .utf8)
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
                        let gains = model.exportGains()
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
                    if !CommandLine.arguments.contains("--background") { await bringToFront() }
                    for _ in 0..<6 { try? await Task.sleep(for: .seconds(0.3)); window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
                    capture(dir.appendingPathComponent("7-narrow.png"))
                    metalLog += "at 7-narrow:\n" + WaveformScheduler.shared.debugReport() + "\n"
                    window.setFrame(original, display: true)
                    try? await Task.sleep(for: .seconds(0.5))
                }
                model.toggleMiniPlayer()
                try? await Task.sleep(for: .seconds(1.2))
                if let mini = NSApp.windows.first(where: { $0.isVisible && $0 is MiniPanel }) {
                    captureWindow(mini, to: dir.appendingPathComponent("8-mini.png"))
                    metalLog += "at 8-mini:\n" + WaveformScheduler.shared.debugReport() + "\n"
                    try? metalLog.write(to: dir.appendingPathComponent("metal.txt"), atomically: true, encoding: .utf8)
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

#if BACKLINE_YTDLP
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
            let r = try await YTDLPImport.download(video, cookieFile: file, progress: { _ in }, isCancelled: { false })
            log += "download ok title=\(r.title ?? "-")\n"
            try? FileManager.default.removeItem(at: r.file)
        } catch { log += "download error: \(error.localizedDescription)\n" }
        await YouTubeSignIn.finish(cookieFile: file)
        log += "cookieFile deleted=\(!FileManager.default.fileExists(atPath: file.path))\n"
        let ytlog = (try? String(contentsOf: ImportStaging.downloadsDirectory.appendingPathComponent("last-error.log"), encoding: .utf8)) ?? ""
        log += "log mentions cookie value=\(ytlog.contains("backline-probe")) signedInFlag=\(ytlog.contains("signedIn=true"))\n"
        await YouTubeSignIn.signOut()
        let left = await YouTubeSignIn.cookies()
        log += "after signOut cookies=\(left.count) signedIn=\(YouTubeSignIn.isSignedIn)\n"
        write(log, dir)
    }

#else
    /// End-to-end check of the sign-in cookie path without a real Google account: plant a fake YouTube
    /// login cookie in the private store, read it back as the engine does, download a video with it (the
    /// engine goes anonymous first and sends the session only when YouTube asks), then sign out and confirm
    /// the store is empty. Writes cookie-probe.txt (no values).
    static func cookieProbe(dir: URL) async {
        var log = ""
        let fake = HTTPCookie(properties: [.domain: ".youtube.com", .path: "/", .name: "LOGIN_INFO",
                                           .value: "backline-probe", .secure: "TRUE",
                                           .expires: Date().addingTimeInterval(3600)])!
        await YouTubeSignIn.store.httpCookieStore.setCookie(fake)
        await YouTubeSignIn.refreshStatus()
        log += "signedIn(after plant)=\(YouTubeSignIn.isSignedIn)\n"
        let cookies = await YouTubeSignIn.cookies()
        let jar = YouTubeCookies(cookies)
        log += "jar cookies=\(jar.entries.map { "\($0.domain)/\($0.name)" }) signedIn=\(jar.isSignedIn) "
            + "header for youtube.com=\(jar.header(for: URL(string: "https://www.youtube.com/")!) != nil) "
            + "header for example.com=\(jar.header(for: URL(string: "https://example.com/")!) != nil)\n"
        let video = YouTubeImport.parse("https://youtu.be/2pXa5jzaOBg")!
        do {
            let r = try await YouTubeImport.download(video, cookies: cookies, progress: { _ in }, isCancelled: { false })
            log += "download ok title=\(r.title ?? "-") client=\(r.clientID ?? "-")\n"
            try? FileManager.default.removeItem(at: r.file)
        } catch { log += "download error: \(error.localizedDescription)\n" }
        await YouTubeSignIn.signOut()
        let left = await YouTubeSignIn.cookies()
        log += "after signOut cookies=\(left.count) signedIn=\(YouTubeSignIn.isSignedIn)\n"
        write(log, dir)
    }

#endif
    nonisolated final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock(); private var v = false
        func set() { lock.withLock { v = true } }
        var value: Bool { lock.withLock { v } }
    }

    private static func write(_ s: String, _ dir: URL) {
        try? s.write(to: dir.appendingPathComponent("cookie-probe.txt"), atomically: true, encoding: .utf8)
    }

    /// Welcome cards, every Help page, the sign-in window and the "needs sign-in" error screen.
    /// `Backline --snapshot <dir> --readme-shots`: every picture in the README, from the real app, using
    /// Kevin MacLeod's demo songs in the library (the library list is hidden so nothing personal shows).
    ///   play.png · dance.png · beats.png · dance-count-in.png · mini-player.png · install-welcome.png
    static func readmeShots(model: AppModel, dir: URL, keepSidebar: Bool = false) async {
        let originalMode = model.appMode
        model.showSidebar = keepSidebar
        func open(_ title: String) async -> SongRecord? {
            guard let rec = model.library.first(where: { $0.title.localizedCaseInsensitiveContains(title) }) else { return nil }
            model.select(rec)
            var waited = 0.0
            while model.song?.id != rec.id && waited < 30 { try? await Task.sleep(for: .seconds(0.2)); waited += 0.2 }
            try? await Task.sleep(for: .seconds(1.2))
            return rec
        }
        var log = ""

        // Play: the lead guitar is out, and a section is looping.
        if await open("Volitile") != nil {
            model.setMode(.play)
            model.settings.removed = [.leadGuitar]
            model.settings.countIn = true
            if let s = model.sections.dropFirst(2).first { model.loopSection(s) }
            try? await Task.sleep(for: .seconds(0.9))
            capture(dir.appendingPathComponent("play.png"))
            // The floating glass panel doesn't render into a bitmap capture, so the mini player view is drawn
            // straight from SwiftUI, on the Backline dark colour, with the solid (non-glass) background.
            GlassSurfaceOverride.forceSolid = true
            let mini = MiniPlayerView()
                .environment(model)
                .frame(width: 440)
                .padding(18)
                .background(Theme.bg)
            let renderer = ImageRenderer(content: mini)
            renderer.scale = 2
            if let cg = renderer.cgImage {
                let rep = NSBitmapImageRep(cgImage: cg)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent("mini-player.png"))
                    log += "mini rendered \(cg.width)x\(cg.height)\n"
                }
            }
            GlassSurfaceOverride.forceSolid = false
            log += "play ok\n"
        } else { log += "missing Volitile\n" }

        // Dance: bachata, tap on the 1 already done, Listen for a part, an eight looping.
        if await open("Big Rock") != nil {
            model.setMode(.dance)
            model.setDanceStyle(.bachata)
            var w = 0.0   // the kit split makes the bongó / güira rows
            while (model.song?.drumSplit == nil || !model.loadedTracks.contains(.kick)) && w < 240 {
                try? await Task.sleep(for: .seconds(0.5)); w += 0.5
            }
            model.seek(to: 52)
            model.setOneHere()
            if let k = model.danceListenParts.first(where: { $0 == .snare || $0 == .hats || $0 == .drums }) { model.toggleSpotlight(k) }
            model.loopCounts(8)
            model.settings.countIn = true
            model.seek(to: model.loopRange?.lowerBound ?? 52)
            try? await Task.sleep(for: .seconds(0.6))
            // Count-in: 5, 6, 7, 8.
            model.togglePlay()
            for _ in 0..<60 where model.countInBeat < 2 { try? await Task.sleep(for: .seconds(0.05)) }
            capture(dir.appendingPathComponent("dance-count-in.png"))
            for _ in 0..<80 where model.countInBeat > 0 || !model.isPlaying { try? await Task.sleep(for: .seconds(0.05)) }
            try? await Task.sleep(for: .seconds(0.9))
            capture(dir.appendingPathComponent("dance.png"))
            model.togglePlay()
            log += "dance ok rows=\(model.rows.map { model.label($0.kind) })\n"
        } else { log += "missing Big Rock\n" }

        // Beats: vocals off, the kit split, a 2-bar loop.
        if await open("Metalmania") != nil {
            model.setMode(.beats)
            var w = 0.0
            while (model.song?.drumSplit == nil || !model.loadedTracks.contains(.kick)) && w < 240 {
                try? await Task.sleep(for: .seconds(0.5)); w += 0.5
            }
            model.seek(to: 40)
            model.setOneHere()
            model.loopBars(2)
            try? await Task.sleep(for: .seconds(0.8))
            capture(dir.appendingPathComponent("beats.png"))
            log += "beats ok rows=\(model.rows.map { model.label($0.kind) })\n"
        } else { log += "missing Metalmania\n" }

        // First run.
        model.setMode(.play)
        model.showWelcome = true
        try? await Task.sleep(for: .seconds(0.9))
        if let sheet = NSApp.windows.first(where: { $0.isVisible && !($0 is MiniPanel) })?.attachedSheet {
            captureWindow(sheet, to: dir.appendingPathComponent("install-welcome.png"))
        }
        model.showWelcome = false
        model.appMode = originalMode
        model.showSidebar = true
        try? log.write(to: dir.appendingPathComponent("readme-shots.txt"), atomically: true, encoding: .utf8)
    }

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

    /// `--sheet-shots --song <file>` (run it with `-appearance light` or `dark`): every Help page, Welcome,
    /// Save a backing track, and Record with each of its two choices, as the person sees them in that look.
    /// Nothing is downloaded and the microphone is never asked for.
    static func sheetShots(model: AppModel, dir: URL) async {
        var log = "look=\(AppearanceMode.saved.rawValue)\n"
        func sheet(_ name: String) {
            if let s = NSApp.windows.first(where: { $0.isVisible && !($0 is MiniPanel) && $0.attachedSheet != nil })?.attachedSheet {
                captureWindow(s, to: dir.appendingPathComponent(name))
                log += "\(name) \(Int(s.frame.width))x\(Int(s.frame.height))\n"
            } else { log += "\(name) missing\n" }
        }
        if let song = songArg {
            model.open(song)
            var waited = 0.0
            while model.screen != .mixer && waited < 300 {
                try? await Task.sleep(for: .seconds(0.5)); waited += 0.5
                if case .failed(let m) = model.screen { log += "open failed: \(m)\n"; break }
            }
            try? await Task.sleep(for: .seconds(1))
            capture(dir.appendingPathComponent("s0-mixer.png"))
            model.openExport()
            try? await Task.sleep(for: .seconds(0.8))
            sheet("s2-export.png")
            model.exportSheet = false
            try? await Task.sleep(for: .seconds(0.6))
        }
        model.showWelcome = true
        try? await Task.sleep(for: .seconds(0.8))
        sheet("s1-welcome.png")
        model.showWelcome = false
        try? await Task.sleep(for: .seconds(0.6))
        for source in ["app", "microphone"] {
            UserDefaults.standard.set(source, forKey: "recordSource")
            model.recordSheet = true
            try? await Task.sleep(for: .seconds(1.2))
            sheet("s3-record-\(source).png")
            model.recordSheet = false
            try? await Task.sleep(for: .seconds(0.6))
        }
        UserDefaults.standard.removeObject(forKey: "recordSource")
        for (i, t) in HelpTopic.allCases.enumerated() {
            model.helpTopic = t
            openWindow?("help")
            try? await Task.sleep(for: .seconds(i == 0 ? 1.2 : 0.5))
            if let w = NSApp.windows.first(where: { $0.title == "Backline Help" && $0.isVisible }) {
                captureWindow(w, to: dir.appendingPathComponent(String(format: "h%02d-%@.png", i + 1, t.rawValue)))
            } else { log += "help \(t.rawValue) missing\n" }
        }
        dismissWindow?("help")
        log += "help pages=\(HelpContent.pages.count) first=\(HelpContent.pages[0].steps[0].text)\n"
        try? log.write(to: dir.appendingPathComponent("sheets.txt"), atomically: true, encoding: .utf8)
    }

    /// Puts the main window in front of every other app's, so it can be seen and its Metal views draw.
    static func bringToFront() async {
        NSApp.unhide(nil)
        NSApp.activate()
        if let w = NSApp.windows.first(where: { $0.isVisible && !($0 is MiniPanel) }) {
            // Above other apps' windows for the rest of the run, so a window someone else brings forward
            // can't cover it between captures.
            w.level = .floating
            w.orderFrontRegardless()
            w.makeKey()
        }
        for _ in 0..<20 where NSApp.windows.first(where: { $0.isVisible && !($0 is MiniPanel) })?.occlusionState.contains(.visible) == false {
            try? await Task.sleep(for: .seconds(0.1))
        }
    }

    static func captureWindow(_ window: NSWindow, to url: URL) {
        // A borderless panel (the mini player) has no frame view worth drawing: its content is the picture.
        let frameView = window is MiniPanel ? nil : window.contentView?.superview
        guard let view = frameView ?? window.contentView,
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
