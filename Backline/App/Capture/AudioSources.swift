import AppKit
import CoreAudio
import Darwin

/// One user-facing app that owns one or more Core Audio client processes
/// (e.g. "Google Chrome" = the browser + its audio-service helper).
nonisolated public struct AudioSource: Identifiable, Sendable, Hashable {
    public var id: String { key }
    public let key: String                 // app bundle id when known, else a path/name key
    public let name: String                // "Spotify", "Google Chrome", "Safari"
    public let appBundleID: String?
    public let appPath: String?            // for NSWorkspace icon
    public var processObjectIDs: [AudioObjectID]
    public var pids: [pid_t]
    public var processBundleIDs: [String]
    public var isPlaying: Bool             // any process has an active output stream (HAL 'piro')
    public let isUserApp: Bool             // lives in a .app with a Dock presence (hide daemons in the UI)
}

/// Permission-free: only reads the HAL process list (kAudioHardwarePropertyProcessObjectList,
/// kAudioProcessPropertyPID / BundleID / IsRunningOutput). No TCC prompt.
nonisolated public enum AudioSourceCatalog {

    /// Whether any of this source's processes currently has output running (re-reads the HAL list).
    public static func isPlaying(_ src: AudioSource) -> Bool {
        (try? sources(includeIdle: false, appsOnly: false))?.contains { $0.id == src.id && $0.isPlaying } ?? false
    }

    public static func sources(includeIdle: Bool = false, appsOnly: Bool = false) throws -> [AudioSource] {
        let me = getpid()
        var groups: [String: AudioSource] = [:]
        for p in try AudioHardwareSystem.shared.processes {
            guard let pid = try? p.pid, pid > 0, pid != me else { continue }
            let playing = (try? p.isRunningOutput) ?? false
            let procBundle = ((try? p.bundleID) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
            let owner = resolveOwner(pid: pid, processBundleID: procBundle)
            var g = groups[owner.key] ?? AudioSource(
                key: owner.key, name: owner.name, appBundleID: owner.bundleID, appPath: owner.path,
                processObjectIDs: [], pids: [], processBundleIDs: [], isPlaying: false, isUserApp: owner.isUserApp)
            g.processObjectIDs.append(p.id)
            g.pids.append(pid)
            if let procBundle { g.processBundleIDs.append(procBundle) }
            g.isPlaying = g.isPlaying || playing
            groups[owner.key] = g
        }
        return groups.values
            .filter { (includeIdle || $0.isPlaying) && (!appsOnly || $0.isUserApp) }
            .sorted { ($0.isPlaying ? 0 : 1, $0.name.lowercased()) < ($1.isPlaying ? 0 : 1, $1.name.lowercased()) }
    }

    /// Match by pid, bundle id or case-insensitive name substring ("spotify", "chrome", "safari").
    public static func find(_ query: String) throws -> AudioSource? {
        let all = try sources(includeIdle: true)
        if let pid = pid_t(query) { return all.first { $0.pids.contains(pid) } }
        let q = query.lowercased()
        return all.first { $0.appBundleID?.lowercased() == q }
            ?? all.first { $0.isPlaying && $0.name.lowercased().contains(q) }
            ?? all.first { $0.name.lowercased().contains(q) }
    }

    // MARK: - Owner resolution (helper process -> user-facing app)

    struct Owner {
        let key: String; let name: String; let bundleID: String?; let path: String?
        var isUserApp = false
    }

    static func isRegularApp(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.activationPolicy == .regular }
    }

    static func resolveOwner(pid: pid_t, processBundleID: String?) -> Owner {
        // 0. XPC helpers (com.apple.WebKit.GPU serves Safari AND every WKWebView app — measured here:
        //    Safari, zoom.us, Outlook, ChatGPT, Ollama, Google Drive each had their own GPU process)
        //    are re-parented to launchd, so ppid is useless. The kernel's "responsible pid" points
        //    at the app that launched them. SPI (libquarantine); resolved with dlsym, optional.
        if let rpid = responsiblePID(pid), rpid != pid, rpid > 1,
           let app = NSRunningApplication(processIdentifier: rpid), let name = app.localizedName {
            return Owner(key: app.bundleIdentifier ?? "pid:\(rpid)", name: name, bundleID: app.bundleIdentifier,
                         path: app.bundleURL?.path, isUserApp: app.activationPolicy == .regular)
        }
        // 1. Helpers inside their parent .app (Chrome/Edge/Spotify/Firefox): outermost .app in the path.
        if let exe = executablePath(pid), let appPath = outermostApp(in: exe) {
            let b = Bundle(path: appPath)
            let name = (b?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (b?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
            return Owner(key: b?.bundleIdentifier ?? appPath, name: name, bundleID: b?.bundleIdentifier, path: appPath,
                         isUserApp: isRegularApp(bundleID: b?.bundleIdentifier))
        }
        // 2. WebKit GPU process with no resolvable owner: keep it separate, never guess "Safari".
        if let bid = processBundleID, bid.hasPrefix("com.apple.WebKit") {
            return Owner(key: "webkit:\(pid)", name: "Web page (Safari or another app)", bundleID: nil, path: nil,
                         isUserApp: true)
        }
        // 3. A regular running app.
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName {
            let key = app.bundleIdentifier ?? "pid:\(pid)"
            return Owner(key: key, name: name, bundleID: app.bundleIdentifier, path: app.bundleURL?.path,
                         isUserApp: app.activationPolicy == .regular)
        }
        // 4. Daemons / CLIs.
        let name = processName(pid).flatMap { $0.isEmpty ? nil : $0 } ?? processBundleID ?? "pid \(pid)"
        return Owner(key: processBundleID ?? "pid:\(pid)", name: name, bundleID: processBundleID, path: nil)
    }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFn: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return nil }                              // RTLD_DEFAULT == (void*)-2 on Darwin
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()
    static func responsiblePID(_ pid: pid_t) -> pid_t? {
        guard let f = responsibleFn else { return nil }
        let r = f(pid)
        return r > 0 ? r : nil
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)          // PROC_PIDPATHINFO_MAXSIZE
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return buf.withUnsafeBufferPointer { String(validatingCString: $0.baseAddress!) }
    }

    static func processName(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return buf.withUnsafeBufferPointer { String(validatingCString: $0.baseAddress!) }
    }

    static func outermostApp(in path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let i = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return parts[...i].joined(separator: "/")
    }
}
