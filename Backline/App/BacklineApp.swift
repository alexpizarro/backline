import BacklineKit
import AppKit
import SwiftUI

@main
struct BacklineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    init() {
        // A reset the app didn't live to finish (R01c) is finished before anything loads; only ever inside
        // this build's own sandbox container.
        if ResetBackline.isInOwnContainer {
            ResetBackline.finishPendingIfNeeded()
            // Core ML's compiled copies of the last build's models, before any model is created (D6).
            CoreMLCache.clearIfStale()
            // The downloaded models stay out of Time Machine; the songs stay in it (D5, Mac: models only).
            BacklineFolders.ensureExcludedFromBackup()
            // What the last run was doing when it ended (D20 d): an import is kept to try again, a pass counts a
            // failure, an interrupted lead refinement swap is finished. Before the sweep, which must keep that
            // import's folder.
            let recovered = WorkJournal.shared.recoverAtLaunch(store: SongStore.shared)
            // What an interrupted session left that nothing can reach: an import stopped before its record, other
            // songs' cleaner checkpoints, a half-unpacked model. Nothing is importing or downloading yet.
            SongStore.shared.sweepLeftovers(keeping: recovered.keepSongs)
            // Link downloads nothing is waiting for; an unfinished import's file stays for Try again.
            ImportStaging.cleanUpDownloads(keeping: recovered.keepFiles, keepAll: recovered.journalUnreadable)
            // Deleted songs a run didn't live to remove (ios-storage#3), off the main thread.
            Task.detached(priority: .utility) { ImportStaging.removeDeletedSongs() }
        }
        // The system's own crash and hang reports, written to the app's log (D20 f). Nothing leaves the Mac.
        SystemDiagnostics.start()
        _model = State(initialValue: AppModel())
        // Running normally from here until the person quits: a pass that ends before then is its failure.
        WorkJournal.shared.setInFront(true)
    }

    var body: some Scene {
        Window("Backline", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: WindowLimits.minContentWidth, minHeight: WindowLimits.minHeight)
                .onAppear {
                    delegate.model = model
                    #if DEBUG
                    Snapshotter.openWindow = { openWindow(id: $0) }
                    Snapshotter.dismissWindow = { dismissWindow(id: $0) }
                    Snapshotter.run(model: model)
                    #endif
                }
                .modifier(ChosenLook())
        }
        .defaultSize(width: 1200, height: 780)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowResizability(.contentMinSize)
        .commands { BacklineCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .modifier(ChosenLook())
        }

        Window("Backline Help", id: "help") {
            HelpView()
                .environment(model)
                .modifier(ChosenLook())
        }
        .defaultSize(width: 860, height: 640)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var keys: KeyboardRouter?
    var model: AppModel? {
        didSet {
            // One keyboard router for the app's lifetime (not per window appearance).
            if keys == nil, let model { keys = KeyboardRouter(model: model) }
            flushPending()
        }
    }
    private var pending: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        FontLoader.registerBundledFonts()
        YouTubeImport.cleanUp()
        YouTubeSignIn.cleanUp()
        #if !BACKLINE_YTDLP
        YTDLPImport.removeLeftovers()
        #endif
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        pending.append(contentsOf: urls)
        flushPending()
    }

    private func flushPending() {
        guard let model, let url = pending.first else { return }
        pending.removeAll()
        model.open(url)
    }

    /// Quit when the main window closes, but not while practising in the mini player.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(model?.isMiniPlayer ?? false)
    }

    /// Clicking the Dock icon returns from the mini player to the full window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if model?.isMiniPlayer == true { model?.toggleMiniPlayer(); return false }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.persistCurrent(synchronously: true)
        // Quitting: a pass cut off now is not its failure at the next launch (D20 d).
        WorkJournal.shared.setInFront(false)
    }

    /// What Quit asks first, or nil to quit at once: an export, an import or a recording in progress is never
    /// cut off without a word (a live take can't be made again).
    @MainActor static func quitQuestion(_ model: AppModel) -> String? {
        if model.isExporting { return "Backline is still saving a track." }
        if model.screen == .analyzing { return "A song is still being split." }
        if model.recordingUnderWay { return "A song is still being recorded." }
        return nil
    }

    /// Don't silently kill an export, an import or a recording in progress.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, let question = Self.quitQuestion(model) else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = "If you quit now it won't be finished."
        alert.addButton(withTitle: "Keep Working")
        alert.addButton(withTitle: "Quit Anyway")
        if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        model.cancelImport()
        return .terminateNow
    }
}

enum FontLoader {
    static func registerBundledFonts() {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) else { return }
        for url in urls { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
    }
}

struct BacklineCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Song…") { model.addSong() }.keyboardShortcut("o")
            Button("Record a Song…") { model.recordSheet = true }.keyboardShortcut("r", modifiers: [.command, .shift])
            if YouTubeImport.isEnabled {
                Button("Paste Link") {
                    if !model.openText(NSPasteboard.general.string(forType: .string) ?? "") {
                        model.showToast(.init(text: "Copy a link first.", isError: true))
                    }
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            }
        }
        CommandGroup(after: .importExport) {
            Button("Save Backing Track…") { model.openExport() }
                .keyboardShortcut("e")
                .disabled(model.song == nil)
        }
        CommandMenu("Playback") {
            // Single-key shortcuts are handled by KeyboardRouter (so they never fire while typing);
            // the menu shows them for discoverability.
            Button(model.isPlaying ? "Pause            Space" : "Play              Space") { model.togglePlay() }
                .disabled(model.song == nil)
            Button(model.settings.loopEnabled ? "Turn Loop Off     L" : "Turn Loop On      L") { model.toggleLoop() }
                .disabled(model.song == nil)
            Divider()
            Button("Back One Bar      ←") { model.nudge(bars: -1) }.disabled(model.song == nil)
            Button("Forward One Bar   →") { model.nudge(bars: 1) }.disabled(model.song == nil)
            Button("Back to Loop Start  ↩") { model.seek(to: model.loopRange?.lowerBound ?? 0) }
                .disabled(model.song == nil)
            Divider()
            // Shown in the title only: real key equivalents would steal ⌘-arrows from text fields.
            Button("Slower            ⌘←") { model.stepSpeed(-1) }.disabled(model.song == nil)
            Button("Faster            ⌘→") { model.stepSpeed(1) }.disabled(model.song == nil)
            Button("Pitch Down        ⌘↓") { model.stepPitch(-1) }.disabled(model.song == nil)
            Button("Pitch Up          ⌘↑") { model.stepPitch(1) }.disabled(model.song == nil)
            Button("Reset Speed & Pitch") { model.resetSpeedAndPitch() }
            .keyboardShortcut("0")
            .disabled(model.song == nil)
            Divider()
            Toggle("Count-in          K", isOn: Binding(get: { model.settings.countIn }, set: { model.settings.countIn = $0 }))
                .disabled(model.song == nil)
        }
        CommandMenu("Parts") {
            ForEach(Array(model.stems.enumerated()), id: \.element) { i, k in
                Button("\(model.isOn(k) ? "Remove" : "Bring Back") \(model.label(k))      \(i + 1)") { model.toggle(k) }
            }
            Divider()
            Button("Hear All Parts       R") { model.settings.removed = []; model.settings.solo = nil; model.settings.spotlight = nil }
                .disabled(model.song == nil)
        }
        CommandGroup(after: .windowArrangement) {
            MiniPlayerCommand(model: model)
        }
        CommandGroup(replacing: .help) {
            HelpMenuItems(model: model)
        }
        CommandGroup(after: .sidebar) {
            ForEach(Array(PracticeMode.allCases.enumerated()), id: \.element) { i, m in
                Toggle(m.title, isOn: Binding(get: { model.mode == m }, set: { _ in model.setMode(m) }))
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
            Divider()
            Button(model.showSidebar ? "Hide Library" : "Show Library") {
                withAnimation(.smooth(duration: 0.3)) { model.showSidebar.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
        }
    }
}

/// Help menu: the in-app guide (works offline), plus quick links to the pages people need most.
struct HelpMenuItems: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Backline Help") { model.helpTopic = .start; openWindow(id: "help") }
            .keyboardShortcut("?", modifiers: .command)
        Divider()
        ForEach([HelpTopic.removeLead, .practice, .dance, .beats, .youtube, .record, .troubleshooting], id: \.self) { t in
            Button(HelpContent.page(t).title) { model.helpTopic = t; openWindow(id: "help") }
        }
        Divider()
        Button("Show Welcome Again") { model.showWelcome = true }
    }
}

/// Toggles between the full window and the floating mini player.
struct MiniPlayerCommand: View {
    let model: AppModel
    var body: some View {
        Button(model.isMiniPlayer ? "Show Full Window" : "Mini Player") { model.toggleMiniPlayer() }
            .keyboardShortcut("m", modifiers: [.command, .shift])
    }
}
