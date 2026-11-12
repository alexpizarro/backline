import BacklineKit
#if DEBUG
import AppKit
import SwiftUI

/// Harness runs for the extra parts row and Settings (WP4, WP7). Debug only, and only in the build's own
/// container (D15). With the tiny test models nothing real is ever downloaded:
///
///     scripts/snap.sh rows <song> --no-play --extra-parts-flow --models-tiny --models-base 127.0.0.1:<port> --forget-models
///     scripts/snap.sh settings <song> --settings-shot [-appearance light|dark]
///
/// `--extra-parts-flow` opens the song, then shoots the row's offer, opened details, the download, its end,
/// a cancelled download and the finished one, and writes what it saw to rows.txt. With a `--models-base` port
/// nothing listens on, the last step shows the failed state instead. One state alone, with nothing started:
/// `--extra-parts-state offer|downloading|splitting|no-space|failed` (plus `--extra-parts-open`).
@MainActor
extension Snapshotter {
    /// True when it handled the run (the caller quits).
    static func extraPartsRun(model: AppModel, dir: URL) async -> Bool {
        let args = CommandLine.arguments
        if args.contains("--forget-models") { ModelDownloads.forgetTestModels() }
        if args.contains("--settings-shot") {
            await openSongIfAsked(model: model)
            await settingsShots(model: model, dir: dir)
            return true
        }
        if args.contains("--reset-probe") {
            // Reset Backline end to end, in this build's own container only (the reset refuses anywhere else).
            await openSongIfAsked(model: model)
            let fm = FileManager.default
            let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Backline")
            var log = "before: songs=\(model.library.count) support=\(fm.fileExists(atPath: support.path)) "
                + "container=\(ResetBackline.isInOwnContainer) home=\(NSHomeDirectory())\n"
            await model.resetBackline()
            try? await Task.sleep(for: .seconds(0.5))
            capture(dir.appendingPathComponent("reset-welcome.png"))
            log += "after: songs=\(model.library.count) support=\(fm.fileExists(atPath: support.path)) "
                + "screen=\(model.screen) welcome=\(model.showWelcome) consent=\(ModelDownloads.consent.rawValue) "
                + "marker=\(fm.fileExists(atPath: ResetBackline.live().marker.path)) loadAll=\(model.store.loadAll().count)\n"
            try? log.write(to: dir.appendingPathComponent("reset.txt"), atomically: true, encoding: .utf8)
            return true
        }
        guard args.contains("--extra-parts-flow") else { return false }
        await openSongIfAsked(model: model)
        var log = "consent=\(ModelDownloads.consent.rawValue) requests=\(ModelDownloads.requests.value) "
            + "missing=\(ModelDownloads.missing.map(\.name))\n"
        func note(_ tag: String) {
            let o = model.extraPartsOffer
            log += "\(tag): state=\(o.map { "\($0.state)" } ?? "none") title=\(o?.title ?? "-") line=\(o?.offerLine ?? "-") "
                + "consent=\(ModelDownloads.consent.rawValue) requests=\(ModelDownloads.requests.value)\n"
        }
        // Nothing is fetched before a click (R01b): the song is open and the row offers, but no request went out.
        note("offer")
        capture(dir.appendingPathComponent("row-1-offer.png"))
        for m in [PracticeMode.beats, .dance] {
            model.setMode(m)
            if m == .dance { model.setDanceStyle(.bachata) }
            try? await Task.sleep(for: .seconds(0.6))
            note("offer-\(m.rawValue)")
            capture(dir.appendingPathComponent("row-1-offer-\(m.rawValue).png"))
        }
        model.setMode(.play)
        try? await Task.sleep(for: .seconds(0.4))

        // Cancel straight after Download: the offer comes back and nothing is installed.
        model.downloadExtraParts()
        try? await Task.sleep(for: .seconds(0.3))
        note("downloading")
        capture(dir.appendingPathComponent("row-2-downloading.png"))
        model.cancelModelDownloads()
        try? await Task.sleep(for: .seconds(0.6))
        note("cancelled")
        capture(dir.appendingPathComponent("row-3-cancelled.png"))

        // Download for real (from the local server): the row goes, one toast.
        model.downloadExtraParts()
        let t0 = Date()
        while model.modelDownloadTask != nil, Date().timeIntervalSince(t0) < 30 { try? await Task.sleep(for: .seconds(0.1)) }
        try? await Task.sleep(for: .seconds(0.4))
        note("downloaded")
        log += "installed=\(ModelDownloads.assets.filter(ModelDownloads.isInstalled).map(\.name)) toast=\(model.toast?.text ?? "-")\n"
        capture(dir.appendingPathComponent("row-4-done.png"))

        try? log.write(to: dir.appendingPathComponent("rows.txt"), atomically: true, encoding: .utf8)
        ModelDownloads.forgetTestModels()
        return true
    }

    private static func openSongIfAsked(model: AppModel) async {
        guard let song = songArg else { return }
        model.open(song)
        var waited = 0.0
        while model.screen != .mixer && waited < 180 {
            try? await Task.sleep(for: .seconds(0.5)); waited += 0.5
            if case .failed = model.screen { break }
        }
        try? await Task.sleep(for: .seconds(1.0))
    }

    /// Settings, both tabs, each in a window of its own (the Settings scene can't be opened from code
    /// reliably), drawn in the chosen look.
    private static func settingsShots(model: AppModel, dir: URL) async {
        let look = UserDefaults.standard.string(forKey: AppearanceMode.defaultsKey) ?? "auto"
        let tabs: [(String, AnyView)] = [
            ("general", AnyView(GeneralSettings(showModels: {}))),
            ("models", AnyView(ModelsView().frame(width: 480).fixedSize())),
        ]
        for (name, view) in tabs {
            let host = NSHostingView(rootView: view.environment(model).modifier(ChosenLook()))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Settings"
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.setContentSize(host.fittingSize)
            window.orderFront(nil)
            try? await Task.sleep(for: .seconds(1.2))
            captureWindow(window, to: dir.appendingPathComponent("settings-\(name)-\(look).png"))
            log(dir, "settings \(name): \(Int(host.fittingSize.width))x\(Int(host.fittingSize.height))")
            window.close()
        }
    }

    private static func log(_ dir: URL, _ line: String) {
        let url = dir.appendingPathComponent("settings.txt")
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (old + line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
#endif
