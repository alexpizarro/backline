import Foundation

/// Core ML's compiled-model cache (D6; storage.md F3, size.md S3). Core ML writes a specialised copy of every
/// model it loads, per compute unit, to `Library/Caches/…/com.apple.e5rt.e5bundlecache`, keyed by the model's
/// location and hash. Nothing ever removes the old entries: each app update installs the bundle at a new
/// path, so every build adds a fresh set (about 150 MB per big model) beside the last one.
///
/// So the cache is cleared at launch whenever the build changes, before any model exists (the next load of
/// each model is slower once while Core ML rebuilds it), and when a downloaded model was replaced by a new
/// version. Reset removes it with everything else (`ResetBackline.live`).
nonisolated enum CoreMLCache {
    /// The build that last launched; a different one clears the cache.
    static let buildKey = "coreMLCacheBuild"
    /// Set when a downloaded model was replaced by another version: its old compiled copy is dead weight,
    /// but it may still be in use this session, so it goes at the next launch.
    static let clearRequestedKey = "coreMLCacheClearRequested"

    static let folderName = "com.apple.e5rt.e5bundlecache"

    /// Where Core ML puts it: `Caches/<bundle id>/…` on iOS, and `Caches/…` directly (seen on the Mac).
    static func folders(caches: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0],
                        bundleID: String? = Bundle.main.bundleIdentifier) -> [URL] {
        var out = [caches.appendingPathComponent(folderName, isDirectory: true)]
        if let bundleID {
            out.append(caches.appendingPathComponent(bundleID, isDirectory: true).appendingPathComponent(folderName, isDirectory: true))
        }
        return out
    }

    static var currentBuild: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// At launch, before any `MLModel` is created: clears the cache when the build changed since the last
    /// launch (a first launch counts: 1.0 never recorded one) or a model was replaced. True when it cleared.
    @discardableResult
    static func clearIfStale(build: String = currentBuild, defaults: UserDefaults = .standard,
                             folders: [URL] = folders(), fm: FileManager = .default) -> Bool {
        let requested = defaults.bool(forKey: clearRequestedKey)
        guard requested || defaults.string(forKey: buildKey) != build else { return false }
        for url in folders { try? fm.removeItem(at: url) }
        defaults.set(build, forKey: buildKey)
        defaults.removeObject(forKey: clearRequestedKey)
        return true
    }

    /// A downloaded model was replaced: clear the cache at the next launch, when nothing has it loaded.
    static func requestClear(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: clearRequestedKey)
    }
}
