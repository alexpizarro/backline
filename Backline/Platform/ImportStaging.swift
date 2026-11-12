import Foundation

/// Backline's own temporary files for an import: recordings and link downloads live in the app's container
/// and are deleted once split. Anything else is the person's own file and is never deleted (iOS
/// `ImportStaging`; the Mac opens a picked file in place, so there is no Imports copy).
nonisolated enum ImportStaging {
    private static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Backline", isDirectory: true)
    }
    static var recordingsDirectory: URL { support.appendingPathComponent("Recordings", isDirectory: true) }
    static var downloadsDirectory: URL { support.appendingPathComponent("Downloads", isDirectory: true) }

    /// True only for a file inside one of Backline's own folders (a real path prefix, not a name that
    /// merely contains "/Backline/Recordings/").
    static func isOwned(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        return [recordingsDirectory, downloadsDirectory].contains { p.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    /// The file's name as the person knows it: no internal UUID prefix, underscores as spaces.
    static func displayName(for url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if let r = name.range(of: "^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}-", options: .regularExpression) { name.removeSubrange(r) }
        return name.replacingOccurrences(of: "_", with: " ")
    }

    /// At launch, before anything downloads: a link's download that no import is waiting for (its split failed
    /// and the person moved on, or it was a song already in the Library) is removed, as iOS does. `keeping`: the
    /// files of imports the last run didn't finish (`WorkJournal.Recovery.keepFiles`), offered with Try again.
    /// `cache` is the yt-dlp build's own cache. Recordings have their own rule (`RecordingTrimmer.purgeStale`).
    /// `keepAll`: the journal couldn't be read, so which files it named isn't known; none is deleted.
    static func cleanUpDownloads(keeping: Set<String>, keepAll: Bool = false, in dir: URL = downloadsDirectory) {
        guard !keepAll else { return }
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name != "cache" {
            let u = dir.appendingPathComponent(name)
            if keeping.contains(u.standardizedFileURL.path) { continue }
            try? fm.removeItem(at: u)
        }
    }

    /// A deleted song's folder is renamed to `tmp/deleting-<uuid>` and removed off the main thread; a run that
    /// ended first leaves it there (release review ios-storage#3). The launch and Reset remove it.
    static let deletingPrefix = "deleting-"

    /// Removes deleted songs' folders a run left in `tmp`. Off the main thread: each can be 100 MB or more.
    static func removeDeletedSongs(in tmp: URL = FileManager.default.temporaryDirectory) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix(deletingPrefix) {
            try? fm.removeItem(at: tmp.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// Removes a recording or download once it has been split (never a user's own file).
    static func discard(_ url: URL) {
        guard isOwned(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Keeps the Mac awake and out of App Nap while a song is being split (iOS `ImportKeepAwake`): a covered window
/// or an idle Mac would otherwise slow the split down or stop it until the Mac wakes. Held for the length of an
/// import, from its start to its end, whatever the end.
@MainActor
enum ImportKeepAwake {
    private static var activity: NSObjectProtocol?
    #if DEBUG
    /// Tests: how many imports have held it.
    static var timesHeld = 0
    #endif

    static var isHeld: Bool { activity != nil }

    static func begin() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "Splitting a song")
        #if DEBUG
        timesHeld += 1
        #endif
    }

    static func end() {
        guard let a = activity else { return }
        ProcessInfo.processInfo.endActivity(a)
        activity = nil
    }
}
