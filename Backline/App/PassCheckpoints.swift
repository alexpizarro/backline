import BacklineKit
import Foundation

/// Where the splitting passes keep their unfinished work (`SeparationCheckpoint`), so a pass that was stopped (the
/// app closed or was closed by iOS, a memory stop, an import) carries on where it stopped the next time it runs:
/// `Caches/Backline/<kind>/<id>`. Caches: the system may clear it, which only costs starting that pass again.
///
/// - the cleaner pass, the kit split and the lead refinement: by song. The cleaner keeps one song's (storage F5).
///   The kit split and the lead refinement keep the song's whose pass runs and the two others written most
///   recently (`kept`), so a song whose kit was stopped by an import still carries on after the new song's kit
///   split; a kit checkpoint is up to about 110 MB a song-minute. They go when the pass lands or fails, when the
///   song is deleted, by Reset, and by the launch sweep for a song no longer in the Library.
/// - the import's six-part split: by the staged file's content id (the song's id to be). It goes when the import
///   finishes, when an unfinished import is removed, by Reset, and by the launch sweep when no journal entry
///   names it.
nonisolated enum PassCheckpoints {
    enum Kind: String, CaseIterable, Sendable {
        case cleaner = "Cleaner", kit = "Kit", lead = "Lead", importSplit = "Import"
    }

    /// `Caches/Backline`, which Reset removes whole.
    static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backline", isDirectory: true)
    }

    static func folder(_ kind: Kind, root: URL = PassCheckpoints.root) -> URL {
        root.appendingPathComponent(kind.rawValue, isDirectory: true)
    }

    static func directory(_ kind: Kind, _ id: String, root: URL = PassCheckpoints.root) -> URL {
        folder(kind, root: root).appendingPathComponent(id, isDirectory: true)
    }

    static func discard(_ kind: Kind, _ id: String, root: URL = PassCheckpoints.root) {
        try? FileManager.default.removeItem(at: directory(kind, id, root: root))
    }

    /// A song that left the Library (or an import that ended) takes all of its checkpoints with it.
    static func discardAll(_ id: String, keepingImport: Bool = false, root: URL = PassCheckpoints.root) {
        for kind in Kind.allCases where !(keepingImport && kind == .importSplit) { discard(kind, id, root: root) }
    }

    /// How many other songs' checkpoints the kit split and the lead refinement keep beside the running one's.
    static let kept = 2

    /// Removes every checkpoint of `kind` except those of `keeping` and the `newest` others written most recently.
    /// Returns the ids removed.
    @discardableResult
    static func dropOthers(_ kind: Kind, keeping: Set<String>, newest: Int = 0, root: URL = PassCheckpoints.root) -> [String] {
        let fm = FileManager.default
        let dir = folder(kind, root: root)
        func written(_ id: String) -> Date {
            // The first channel grows with every chunk; a checkpoint that has none yet counts by its folder.
            let d = dir.appendingPathComponent(id, isDirectory: true)
            for u in [d.appendingPathComponent("ch0.f32"), d] {
                if let date = (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date { return date }
            }
            return .distantPast
        }
        let others = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !keeping.contains($0) }
            .sorted { written($0) > written($1) }
        return others.dropFirst(max(0, newest))
            .filter { (try? fm.removeItem(at: dir.appendingPathComponent($0, isDirectory: true))) != nil }
    }

    /// Free space left beside a new checkpoint: the parts the pass writes at its end must still fit, and the phone
    /// isn't pushed to its limit for something that only saves time.
    static let spaceMargin: Int64 = 1_000_000_000

    /// `checkpoint`, unless it is a new one and the device hasn't room for its `bytes` beside `spaceMargin`: then
    /// nil, and the pass runs without one (as it did before). One already on disk is always used.
    static func ifRoom(_ checkpoint: SeparationCheckpoint, bytes: Double, free: Int64? = freeSpace()) -> SeparationCheckpoint? {
        if FileManager.default.fileExists(atPath: checkpoint.directory.path) { return checkpoint }
        guard let free else { return checkpoint }
        guard Double(free) >= bytes + Double(spaceMargin) else {
            AppLog.note("checkpoint \(checkpoint.directory.deletingLastPathComponent().lastPathComponent): "
                        + "not kept, \(free / 1_048_576) MB free for \(Int(bytes / 1_048_576)) MB")
            return nil
        }
        return checkpoint
    }

    /// Free bytes on the device, or nil when it won't say.
    static func freeSpace() -> Int64? {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return (try? caches.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    /// What a checkpoint of `channels` channels over `frames` samples takes on disk.
    static func bytes(channels: Int, frames: Int) -> Double { Double(channels * frames * MemoryLayout<Float>.size) }

    /// A stored part as a pass's input: its size and modification time. A part written again (by the cleaner pass,
    /// an AAC conversion, a refinement) has another, so a checkpoint made from the old one is not used.
    static func identity(of url: URL) -> String {
        let a = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (a?[.size] as? Int) ?? -1
        let date = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(size)@\(String(format: "%.6f", date))"
    }

    /// The app's build: the models inside the app (lead, six-part) change only with it.
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?" }

    /// A downloaded model's identity: its install marker's checksum, or its name.
    static func downloadedModel(_ name: String, url: URL) -> String {
        let marker = ModelStore.directory.appendingPathComponent("\(name).sha256")
        return (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? url.lastPathComponent
    }
}
