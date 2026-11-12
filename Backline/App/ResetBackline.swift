import Foundation
import Synchronization

/// Reset Backline (R01c; plan and rollback in `docs/reset.md`): the file side. Deletes only an explicit list of
/// Backline's own paths inside its sandbox container, never follows a symlink out of it, and finishes an
/// interrupted reset at the next launch from a marker. The app side (stopping work, rebuilding state,
/// Welcome) is `AppModel.resetBackline`. Ported from iOS `App/ResetBackline.swift` with the Mac's locations.
nonisolated enum ResetBackline {
    /// Kill switch: when false the Settings row is hidden.
    static let isEnabled = true

    // MARK: Epoch

    /// Bumped at the start of every reset. Work captures it when it starts; once it has changed, the work
    /// stops (its `isCancelled` says so) and its completion changes nothing.
    private static let epochValue = Atomic<Int>(0)
    static var epoch: Int { epochValue.load(ordering: .acquiring) }
    static func isCurrent(_ e: Int) -> Bool { epoch == e }
    @discardableResult static func bumpEpoch() -> Int {
        lastResetValue.withLock { $0 = Date() }
        return epochValue.add(1, ordering: .acquiringAndReleasing).newValue
    }
    private static let lastResetValue = Mutex(Date.distantPast)
    /// When the last reset started: a song saved before it is old state.
    static var lastReset: Date { lastResetValue.withLock { $0 } }

    // MARK: Locations

    /// Everything Reset removes, in order. `move` paths go to the trash in one rename each; `delete` paths
    /// are removed in place (the Mac has none today: there is no App Group).
    struct Locations: Sendable {
        var move: [URL]
        var delete: [URL]
        /// `tmp` children whose names start with one of these are Backline's scratch files.
        var tmp: URL?
        var tmpPrefixes: [String] = []
        /// Where trashed folders go, then emptied.
        var trashRoot: URL
        /// Written before the first move, removed after the last step.
        var marker: URL
        /// Made again, empty and excluded from backup, once everything is gone (D5): the next model written there
        /// must not bring the folder back into Time Machine.
        var recreateExcludedFromBackup: [URL] = []
    }

    /// The Mac app is sandboxed, so every one of these is inside its own container
    /// (`~/Library/Containers/<bundle id>/Data`). A Debug build has its own bundle id (D15), so a reset run
    /// from Xcode or the harness never reaches the installed app's library.
    static func live(bundleID: String? = Bundle.main.bundleIdentifier) -> Locations {
        let fm = FileManager.default
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let tmp = fm.temporaryDirectory
        var move = [
            // One rename takes songs, staging, recordings, link downloads (and their cache) and the models.
            support.appendingPathComponent("Backline", isDirectory: true),
            caches.appendingPathComponent("Backline", isDirectory: true),           // cleaner checkpoints
            caches.appendingPathComponent("links", isDirectory: true),              // the link engine's player scripts
            caches.appendingPathComponent("models-manifest.json"),
            library.appendingPathComponent("Logs/Backline.log"),
        ]
        // Core ML's compiled models (D6): they only grow, and after a reset they belong to deleted downloads.
        move += CoreMLCache.folders(caches: caches, bundleID: bundleID)
        return Locations(
            move: move,
            delete: [],
            tmp: tmp,
            // CFNetworkDownload_*: partial downloads URLSession left behind. yt-cookies: a signed-in link
            // download's temporary cookie file. deleting-*: deleted songs a run didn't live to remove.
            tmpPrefixes: ["Exports", "BacklineModelCache", "model-", "link-smoke", "models-debug", "CFNetworkDownload_",
                          "yt-cookies", ImportStaging.deletingPrefix],
            trashRoot: tmp.appendingPathComponent("Reset", isDirectory: true),
            marker: library.appendingPathComponent("backline-reset-pending"),
            recreateExcludedFromBackup: [support.appendingPathComponent("Backline/Models", isDirectory: true)]
        )
    }

    // MARK: Files

    /// Writes the marker, moves every path to a fresh trash folder, deletes the in-place items and
    /// Backline's `tmp` files. Returns what couldn't be removed (logged by the caller).
    @discardableResult
    static func removeFiles(_ loc: Locations, fm: FileManager = .default) -> [String] {
        var failures: [String] = []
        try? fm.createDirectory(at: loc.marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: loc.marker.path, contents: Data())
        let trash = loc.trashRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: trash, withIntermediateDirectories: true)
        for (i, url) in loc.move.enumerated() where exists(url, fm: fm) {
            // A symlink is removed as a link; a file or folder is moved whole (one rename, instant).
            if isSymlink(url, fm: fm) {
                if (try? fm.removeItem(at: url)) == nil { failures.append(url.lastPathComponent) }
                continue
            }
            let dest = trash.appendingPathComponent("\(i)-\(url.lastPathComponent)")
            if (try? fm.moveItem(at: url, to: dest)) == nil, (try? fm.removeItem(at: url)) == nil {
                failures.append(url.lastPathComponent)
            }
        }
        for url in loc.delete where exists(url, fm: fm) {
            if (try? fm.removeItem(at: url)) == nil { failures.append(url.lastPathComponent) }
        }
        if let tmp = loc.tmp {
            let names = (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? []
            for name in names where loc.tmpPrefixes.contains(where: { name.hasPrefix($0) }) {
                let url = tmp.appendingPathComponent(name)
                if (try? fm.removeItem(at: url)) == nil { failures.append(name) }
            }
        }
        for url in loc.recreateExcludedFromBackup { BacklineFolders.ensureExcludedFromBackup(url, fm: fm) }
        return failures
    }

    /// Removes the marker: the reset is complete.
    static func finish(_ loc: Locations, fm: FileManager = .default) {
        try? fm.removeItem(at: loc.marker)
    }

    /// Deletes every trash folder (slow for gigabytes of songs: off the main thread).
    static func emptyTrash(_ loc: Locations, fm: FileManager = .default) {
        try? fm.removeItem(at: loc.trashRoot)
    }

    /// At launch, before anything loads: a marker means the last reset was interrupted. Finish it (files,
    /// then defaults), then empty any trash. True when a reset was finished.
    @discardableResult
    static func finishPendingIfNeeded(_ loc: Locations = live(), defaults: UserDefaults = .standard,
                                      domain: String? = Bundle.main.bundleIdentifier, fm: FileManager = .default) -> Bool {
        defer { emptyTrash(loc, fm: fm) }
        guard fm.fileExists(atPath: loc.marker.path) else { return false }
        removeFiles(loc, fm: fm)
        clearDefaults(defaults, domain: domain)
        finish(loc, fm: fm)
        return true
    }

    /// Every key the app stored, as if just installed.
    static func clearDefaults(_ defaults: UserDefaults, domain: String?) {
        if let domain { defaults.removePersistentDomain(forName: domain) }
        for key in defaults.dictionaryRepresentation().keys where !key.hasPrefix("Apple") && !key.hasPrefix("NS") && !key.hasPrefix("AK") {
            defaults.removeObject(forKey: key)
        }
    }

    private static func exists(_ url: URL, fm: FileManager) -> Bool {
        (try? fm.attributesOfItem(atPath: url.path)) != nil
    }

    private static func isSymlink(_ url: URL, fm: FileManager) -> Bool {
        (try? fm.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType == .typeSymbolicLink
    }
}
