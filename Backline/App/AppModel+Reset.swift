import AppKit
import BacklineKit
import Foundation
import Synchronization
import WebKit

// MARK: - Reset Backline (R01c, docs/reset.md)

extension AppModel {
    /// Why Reset can't run right now, or nil.
    var resetBlockedReason: String? {
        if isExporting { return "Still saving…" }
        if recordSheet { return "Stop the recording first." }
        if !ResetBackline.isInOwnContainer { return "Reset works only in Backline's own folder." }
        return nil
    }

    /// Deletes everything Backline keeps and starts it like new: quiet every piece of work, wait for it to
    /// stop, delete once, clear the system stores and the defaults, then Welcome. Ported from iOS
    /// `AppModel.resetBackline`, with the Mac's windows in place of the phone's sheets.
    func resetBackline() async {
        guard ResetBackline.isEnabled, !resetting else { return }
        if let reason = resetBlockedReason { showToast(Toast(text: reason, isError: true)); return }
        AppLog.note("reset: started")

        // 1. Quiet, synchronously: nothing awaits until every way back in is shut.
        ResetBackline.bumpEpoch()
        resetting = true
        persistCurrent()            // while resetting this only cancels the pending save; nothing is written
        let running: [Task<Void, Never>] = [importTask, hqJob, drumJob, leadJob, modelDownloadTask, compactJob].compactMap { $0 }
        compactCancel?.value = true
        cancelBox.value = true
        importTask?.cancel()
        hqCancel?.value = true
        drumCancel?.value = true
        leadCancel?.value = true
        modelDownloadTask?.cancel()
        ModelDownloads.bumpRun()
        engineFill?.cancel()
        loadGeneration += 1
        pendingRecord = nil
        pendingLevels = nil
        pendingTrackReload = false
        engine.pause()
        isPlaying = false
        song = nil
        if isMiniPlayer { toggleMiniPlayer() }
        exportSheet = false; recordSheet = false; addSongSheet = false; youTubeSignInSheet = false; showWelcome = false
        // The Settings window the reset was started from.
        for window in NSApp.windows where window.identifier?.rawValue.contains("Settings") == true || window.title.contains("Settings") {
            window.close()
        }

        // 2. Wait a little for the cancelled work to stop, then for the engine to be free. A pass loading its
        // model can take a while; Reset doesn't wait for that: late work sees the new epoch, changes nothing,
        // and removes what it wrote under its own id.
        await Self.waitForAll(running, upTo: .seconds(15))
        await engineGate.acquire()
        await engineGate.release()

        // 3. Delete once (marker first, so an interrupted reset finishes at the next launch).
        let locations = ResetBackline.live()
        let failures = await Task.detached(priority: .userInitiated) { ResetBackline.removeFiles(locations) }.value
        if !failures.isEmpty { AppLog.note("reset: could not remove \(failures.count) items") }

        // 4. The system stores, through their APIs.
        await Downloader.shared.reset()
        URLCache.shared.removeAllCachedResponses()
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        // Held for the whole call: the async form on a temporary store crashed when WebKit answered (iOS).
        let web = WKWebsiteDataStore.default()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            web.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { c.resume() }
        }
        withExtendedLifetime(web) {}
        await YouTubeSignIn.signOut()
        SeparationService.shared.forget()
        // The journal's file went with Application Support/Backline; what it held in memory goes too.
        WorkJournal.shared.forget()
        AppLog.reset()

        // 5. In memory, then the defaults last (in-memory resets write keys of their own).
        forgetStoppedWork()
        library = []
        settings = SongSettings()
        appMode = .play
        screen = .empty
        toast = nil
        importTitle = ""; importArtist = ""; importArtwork = nil
        importTitleOverride = nil; importArtistOverride = nil; importSourceOverride = nil; importArtworkOverride = nil
        lastImportURL = nil; lastYouTube = nil; lastLink = nil
        downloadingFromYouTube = false; tryingAnotherWay = false
        forgetPreparing()
        hqProgress = nil; drumSplitProgress = nil; downloadingModel = nil; modelDownloadProgress = nil
        drumSplitFailedFor = nil; leadRefineFailedFor = nil; forceTrackReload = false; loadedTracks = []; loadingSongID = nil; openFailure = nil
        loadedFormatGains = [:]
        unfinishedImports = []; heldBackPasses = []
        withdrawnModels = []
        ExtraParts.shared.reset()
        artwork = nil
        ResetBackline.clearDefaults(.standard, domain: Bundle.main.bundleIdentifier)
        ResetBackline.finish(locations)
        Task.detached(priority: .utility) { ResetBackline.emptyTrash(locations) }
        AppLog.note("reset: done")

        // 6. Welcome, once the windows have closed.
        try? await Task.sleep(for: .seconds(0.9))
        resetting = false
        showWelcome = true
    }

    /// After a reset, the handles of the work it stopped go too. A job that sees the new epoch returns before it
    /// clears its own handle, so without this the next song's lead refinement, kit split, cleaner pass and model
    /// download never started until a relaunch (each waits for its handle to be nil). Late work still changes
    /// nothing: it sees the new epoch.
    func forgetStoppedWork() {
        importTask = nil
        splitRunning = nil
        roomRefused = [:]
        hqJob = nil; hqCancel = nil
        drumJob = nil; drumCancel = nil
        leadJob = nil; leadCancel = nil; leadStoppedForKit = false; leadJobSong = nil; libraryLeadFailed = []
        compactJob = nil; compactCancel = nil; compactVisited = [:]
        modelDownloadTask = nil
    }

    /// Waits for every task, or until `limit`, whichever comes first (awaiting a task's value ignores
    /// cancellation, so a task group alone would wait for the slowest).
    static func waitForAll(_ tasks: [Task<Void, Never>], upTo limit: Duration) async {
        let done = Mutex(false)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resume: @Sendable () -> Void = {
                if done.withLock({ old in defer { old = true }; return !old }) { c.resume() }
            }
            Task { for t in tasks { await t.value }; resume() }
            Task { try? await Task.sleep(for: limit); resume() }
        }
    }

    // MARK: Storage

    /// What Backline takes on this Mac (storage F11), as iOS counts it: the whole container (songs, the
    /// downloaded models, the cleaner's checkpoints, staging and Core ML's compiled cache), with what the songs
    /// and the extra parts take. Off the main thread.
    nonisolated static func storageUse(container: URL = URL(fileURLWithPath: NSHomeDirectory()),
                                       songs: URL = SongStore.shared.root,
                                       models: URL = ModelStore.directory) async -> StorageUse {
        await Task.detached(priority: .utility) {
            StorageUse.measure(container: container, songs: songs, models: models)
        }.value
    }

    /// Bytes on disk under `root`. Symbolic links are not followed (a Mac container links to the person's own
    /// Desktop, Downloads, Music and Pictures, which are not Backline's).
    nonisolated static func directorySize(_ root: URL) -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isSymbolicLinkKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return 0 }
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink == true { continue }      // the enumerator never goes into a link
            total += Int64(v.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// What Backline takes on this Mac, for Settings (storage F11), as iOS shows it.
nonisolated struct StorageUse: Equatable {
    var total: Int64
    var songs: Int64
    var models: Int64

    static func measure(container: URL, songs: URL, models: URL) -> StorageUse {
        StorageUse(total: AppModel.directorySize(container), songs: AppModel.directorySize(songs),
                   models: AppModel.directorySize(models))
    }

    static func format(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    /// "Songs 610 MB · Extra parts 547 MB"; the extra parts only once they are downloaded.
    var detail: String {
        var bits = ["Songs \(Self.format(songs))"]
        if models > 0 { bits.append("Extra parts \(Self.format(models))") }
        return bits.joined(separator: " · ")
    }
}

extension ResetBackline {
    /// True when this process runs in its own sandbox container, where every path in `live()` is Backline's
    /// alone. Reset refuses to run anywhere else.
    static var isInOwnContainer: Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        return NSHomeDirectory().hasSuffix("/Library/Containers/\(id)/Data")
    }
}
