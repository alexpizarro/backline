import AppleArchive
import BacklineKit
import CryptoKit
import Foundation
import OSLog
import QuartzCore
import SwiftUI
import Synchronization
import System

nonisolated let modelLog = Logger(subsystem: "com.alexpizarro.backline", category: "models")

#if DEBUG
/// Test runs also write the download log to tmp/models-debug.txt (the unified log drops sandboxed debug lines).
nonisolated func modelTrace(_ s: String) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("models-debug.txt")
    let line = Data("\(Date()) \(s)\n".utf8)
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
    else { try? line.write(to: url) }
}
#else
nonisolated func modelTrace(_ s: String) {}
#endif

/// A Core ML model too big to ship inside the download. It is fetched once from the public repo's
/// "models" release, checked against its SHA-256, unpacked (Apple Archive) and installed in
/// Application Support/Backline/Models. Until it arrives the app uses its built-in models.
nonisolated struct ModelAsset: Sendable {
    let name: String          // compiled folder name, without .mlmodelc
    let file: String          // release asset (Apple Archive of the .mlmodelc contents)
    let sha256: String
    let bytes: Int64
}

nonisolated enum ModelDownloads {
    /// The user's answer (R01b): nothing is fetched before a click next to the size. Download on the extra
    /// parts row (V01) and Settings ▸ Models ▸ Download Now are both a yes; Cancel on the row puts it back to
    /// `unasked`, so the row offers again. `no` is only left over from Mac 1.0's "Not now" card: the row asks
    /// again, because one no shouldn't hide the offer forever.
    enum Consent: String, Sendable { case unasked, yes, no }
    static let consentKey = "modelDownloadConsent"
    static var consent: Consent {
        get { Consent(rawValue: UserDefaults.standard.string(forKey: consentKey) ?? "") ?? .unasked }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: consentKey) }
    }

    /// Bumped when Cancel takes the yes back. Work from an earlier run installs nothing and writes no
    /// state, so a new Download starts clean even while the cancelled download is still unwinding.
    private static let runValue = Atomic<Int>(0)
    static var run: Int { runValue.load(ordering: .acquiring) }
    static func isCurrentRun(_ r: Int) -> Bool { run == r }
    static func bumpRun() { runValue.add(1, ordering: .acquiringAndReleasing) }

    /// Model requests started in this run (the R01b check that a fresh install fetches nothing unasked).
    static let requests = RequestCounter()

    final class RequestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    static let base: URL = {
        #if DEBUG
        // Tests can point at a local copy: --models-base 127.0.0.1:8799 (no scheme: macOS opens a URL-looking
        // launch argument as a link and then skips the main window).
        if let i = CommandLine.arguments.firstIndex(of: "--models-base"), i + 1 < CommandLine.arguments.count,
           let u = URL(string: "http://\(CommandLine.arguments[i + 1])/") { return u }
        #endif
        return URL(string: "https://github.com/alexpizarro/backline/releases/download/models-1/")!
    }()

    /// Cleaner parts first: it helps every mode. The drum kit only matters in Beats and Dance.
    static let assets: [ModelAsset] = {
        #if DEBUG
        // The harness drives the whole download, not a pretended one: two 10 KB archives from the test
        // fixtures, with their own pinned hashes, under names no real model uses (so a test install never
        // stands in for a real model and the background passes stay off).
        if CommandLine.arguments.contains("--models-tiny") { return testAssets }
        #endif
        return [
            ModelAsset(name: CleanerPartsJob.modelName, file: "BSRoformerSW-fp16-1.aar",
                       sha256: "74fe971df15e20d62e63c0839aca699785a31232b931c63efa3539e0da2836f6", bytes: 344_259_466),
            ModelAsset(name: DrumSeparator.modelName, file: "DrumSepMDX23C-fp16-1.aar",
                       sha256: "d9fb411140f10c8a43021968e1259b200f30b57165329b638eaee2e2a8fc5c16", bytes: 202_873_466),
        ]
    }()

    #if DEBUG
    /// `--models-tiny` with `--models-base <host:port>` serving `BacklineTests/Fixtures/models`.
    static let testAssets: [ModelAsset] = [
        ModelAsset(name: "TestModelA", file: "TestModelA-1.aar",
                   sha256: "0fd9c05b7fb061d142c5322b252ba672e5e45227cc3d45f2fe16df3e0a3198fa", bytes: 9_988),
        ModelAsset(name: "TestModelB", file: "TestModelB-1.aar",
                   sha256: "b48328e87fcc66ab45683ee4b0bdd18c8d57c96cf70a0baf6e5b8ef8d1f569b2", bytes: 9_988),
    ]

    /// `--forget-models`: removes only what `--models-tiny` installed, so a harness run starts from the offer
    /// every time. A real model this Mac downloaded is left alone.
    static func forgetTestModels() {
        let fm = FileManager.default
        for a in testAssets {
            try? fm.removeItem(at: ModelStore.directory.appendingPathComponent("\(a.name).mlmodelc", isDirectory: true))
            try? fm.removeItem(at: markerURL(a))
        }
    }
    #endif

    static func markerURL(_ a: ModelAsset) -> URL { ModelStore.directory.appendingPathComponent("\(a.name).sha256") }

    #if DEBUG
    /// How many times the installed models or the free space were looked up on disk from the main thread
    /// (UIP-02: a test checks the extra parts row never does; lookups off the main thread aren't counted).
    static let diskLookups = Atomic<Int>(0)
    #endif

    /// True when this exact version of the model is installed.
    static func isInstalled(_ a: ModelAsset) -> Bool {
        #if DEBUG
        if Thread.isMainThread { diskLookups.add(1, ordering: .relaxed) }
        #endif
        return ModelStore.url(a.name) != nil
            && (try? String(contentsOf: markerURL(a), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == a.sha256
    }

    static var missing: [ModelAsset] { assets.filter { !isInstalled($0) } }

    /// Whether a download may start: Download on the row or in Settings (`force`), or a yes, and something
    /// to fetch.
    static func mayStart(force: Bool, consent: Consent, missing: Bool) -> Bool {
        missing && (force || consent == .yes)
    }

    /// The model's own file on the built-in host (GitHub), the last resort.
    static func fallbackURL(_ a: ModelAsset) -> URL { base.appendingPathComponent(a.file) }

    // MARK: Room on the Mac

    /// Free bytes an install needs: the archive, the model unpacked beside it, Core ML's compiled cache,
    /// and 500 MB left over so the disk isn't pushed to its limit by a download it asked for. One rule,
    /// used both by `install` and by the extra parts row before it offers Download (V01).
    static func spaceNeeded(_ a: ModelAsset) -> Int64 { a.bytes * 3 + 500_000_000 }

    /// Free bytes where the models go, or nil when the volume won't say (then nothing is refused).
    static func freeSpace() -> Int64? {
        #if DEBUG
        if Thread.isMainThread { diskLookups.add(1, ordering: .relaxed) }
        #endif
        let fm = FileManager.default
        // The models folder may not exist yet: ask the nearest folder that does.
        var dir = ModelStore.directory
        while !fm.fileExists(atPath: dir.path), dir.pathComponents.count > 1 { dir = dir.deletingLastPathComponent() }
        return (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    /// The most any still-missing model needs, so the row's figure is the one that would refuse it.
    static func spaceNeededForMissing(_ missing: [ModelAsset]) -> Int64 {
        missing.map(spaceNeeded).max() ?? 0
    }

    /// Whether every missing model has room right now.
    static func hasSpaceForMissing(_ missing: [ModelAsset], free: Int64? = freeSpace()) -> Bool {
        guard let free, !missing.isEmpty else { return true }
        return free > spaceNeededForMissing(missing)
    }

    /// Downloads, checks and installs one model, trying the manifest's mirrors and then GitHub (R01d). Safe
    /// to call again after a failure.
    /// `isCurrent` false (a reset or Cancel came) stops it before anything is unpacked or marked installed.
    static func install(_ a: ModelAsset, manifest: ModelManifest.Document? = nil,
                        isCurrent: @escaping @Sendable () -> Bool = { true },
                        progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !ModelManifest.isWithdrawn(a, in: manifest) else { throw ModelError.withdrawn }
        let fm = FileManager.default
        BacklineFolders.ensureExcludedFromBackup()          // D5: the models are never backed up
        try fm.createDirectory(at: ModelStore.directory, withIntermediateDirectories: true)
        guard hasSpaceForMissing([a], free: freeSpace() ?? .max) else { throw CocoaError(.fileWriteOutOfSpace) }

        // Each source in turn: a refused, oversized or wrong file moves on to the next.
        var file: URL?
        var lastError: Error = CocoaError(.fileReadCorruptFile)
        for source in ModelManifest.sources(for: a, in: manifest, fallback: fallbackURL(a)) {
            guard isCurrent() else { throw CancellationError() }
            modelLog.notice("download \(a.file, privacy: .public) from \(source.host ?? "?", privacy: .public)")
            modelTrace("start \(a.file) from \(source.host ?? "?")")
            AppLog.note("model \(a.name): downloading from \(source.host ?? "?")")
            do {
                let got = try await Downloader.shared.fetch(source, maxBytes: a.bytes, progress: { progress(0.95 * $0) })
                if try sha256(of: got) == a.sha256 { file = got; break }
                try? fm.removeItem(at: got)
                lastError = CocoaError(.fileReadCorruptFile)
                AppLog.note("model \(a.name): wrong file from \(source.host ?? "?")")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                AppLog.note("model \(a.name): \(source.host ?? "?") failed (\((error as NSError).code))")
            }
        }
        guard let file else { throw lastError }
        // A safety net for the paths that leave before the archive is unpacked; the usual way out deletes
        // it the moment `extract` is done, so the archive and the unpacked model are never both lying around
        // while the folders are swapped.
        defer { try? fm.removeItem(at: file) }
        guard isCurrent() else { throw CancellationError() }
        modelLog.notice("download \(a.file, privacy: .public) finished, sha256 ok")
        modelTrace("finished \(a.file) sha ok")

        // Unpack beside the final place, then swap it in, so a half-unpacked model is never used.
        let staging = ModelStore.directory.appendingPathComponent(".\(a.name)-unpack", isDirectory: true)
        let target = ModelStore.directory.appendingPathComponent("\(a.name).mlmodelc", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try extract(file, to: staging)
        try? fm.removeItem(at: file)
        guard isCurrent() else { try? fm.removeItem(at: staging); throw CancellationError() }
        try? fm.removeItem(at: markerURL(a))
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: staging)
            // Another version of the model: Core ML's compiled copy of the old one goes at the next launch (D6).
            CoreMLCache.requestClear()
        } else {
            try fm.moveItem(at: staging, to: target)
        }
        guard isCurrent() else { throw CancellationError() }
        try a.sha256.write(to: markerURL(a), atomically: true, encoding: .utf8)
        progress(1)
    }

    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func extract(_ archive: URL, to dir: URL) throws {
        guard let read = ArchiveByteStream.fileStream(path: FilePath(archive.path), mode: .readOnly, options: [],
                                                      permissions: FilePermissions(rawValue: 0o644)) else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { try? read.close() }
        guard let decompress = ArchiveByteStream.decompressionStream(readingFrom: read) else { throw CocoaError(.fileReadCorruptFile) }
        defer { try? decompress.close() }
        guard let decode = ArchiveStream.decodeStream(readingFrom: decompress) else { throw CocoaError(.fileReadCorruptFile) }
        defer { try? decode.close() }
        guard let extract = ArchiveStream.extractStream(extractingTo: FilePath(dir.path),
                                                        flags: [.ignoreOperationNotPermitted]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? extract.close() }
        _ = try ArchiveStream.process(readingFrom: decode, writingTo: extract)
    }
}

/// Why a model can't be downloaded right now.
nonisolated enum ModelError: Error, Equatable {
    /// The manifest withdrew this file (licence or a problem with it).
    case withdrawn
    /// The server sent (or announced) more bytes than the model has: a wrong URL.
    case tooLarge
}

/// Model downloads on an ordinary session: the Mac app keeps running, so there is no background session.
/// A dropped connection is picked up where it stopped (up to four tries); a refused host, a wrong file or
/// Cancel moves on at once. `reset` (Cancel on the row, Reset Backline) stops every transfer.
nonisolated final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = Downloader()

    private struct Waiting {
        let continuation: CheckedContinuation<URL, Error>
        let progress: @Sendable (Double) -> Void
        let maxBytes: Int64
    }

    private let lock = NSLock()
    /// Keyed by the task's identifier.
    private var waiting: [Int: Waiting] = [:]
    /// Bumped by `reset`: a fetch from before it doesn't try again.
    private var generation = 0
    private var session: URLSession!
    /// The session's settings (tests read the idle limit).
    var configuration: URLSessionConfiguration { session.configuration }

    /// Seconds a download may go with nothing arriving before that source fails, so `install` moves on to the
    /// next one and the row can offer Try again instead of waiting (release 1.1, as on iOS). It is the session's
    /// idle limit: a host that refuses fails at once, one that answers and then sends nothing fails after this.
    static let stallLimit: TimeInterval = 15

    private override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Self.stallLimit
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func fetch(_ url: URL, maxBytes: Int64, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        ModelDownloads.requests.add()
        let gen = lock.withLock { generation }
        var resume: Data?
        for attempt in 0..<4 {
            do {
                return try await one(url, resume: resume, maxBytes: maxBytes, progress: progress)
            } catch {
                // Only a dropped connection with something to pick up from is tried again.
                let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                guard let data, attempt < 3, !Task.isCancelled, lock.withLock({ generation }) == gen else {
                    if lock.withLock({ generation }) != gen || Task.isCancelled { throw CancellationError() }
                    throw error
                }
                resume = data
                modelTrace("dropped, resuming (try \(attempt + 2))")
                try await Task.sleep(for: .seconds(Double(2 << attempt)))
            }
        }
        throw URLError(.cannotLoadFromNetwork)
    }

    private final class TaskBox: @unchecked Sendable {
        let lock = NSLock()
        var task: URLSessionDownloadTask?
        var cancelled = false
    }

    private func one(_ url: URL, resume: Data?, maxBytes: Int64, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                let task = resume.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
                lock.withLock { waiting[task.taskIdentifier] = Waiting(continuation: c, progress: progress, maxBytes: maxBytes) }
                let cancelled = box.lock.withLock { () -> Bool in
                    box.task = task
                    return box.cancelled
                }
                if cancelled { complete(task.taskIdentifier, .failure(CancellationError())); task.cancel(); return }
                task.resume()
            }
        } onCancel: {
            let task = box.lock.withLock { () -> URLSessionDownloadTask? in
                box.cancelled = true
                return box.task
            }
            if let task { complete(task.taskIdentifier, .failure(CancellationError())); task.cancel() }
        }
    }

    /// More than the model's size, written or announced.
    static func exceeds(_ maxBytes: Int64, written: Int64, expected: Int64) -> Bool {
        written > maxBytes || expected > maxBytes
    }

    /// Reset Backline, and Cancel on the extra parts row: stops every model download.
    func reset() async {
        let pending = lock.withLock { () -> [CheckedContinuation<URL, Error>] in
            generation += 1
            let c = waiting.values.map(\.continuation)
            waiting = [:]
            return c
        }
        for task in await session.allTasks { task.cancel() }
        for c in pending { c.resume(throwing: CancellationError()) }
    }

    /// The first answer for a task wins; later ones (a cancel after the file arrived) are dropped.
    private func complete(_ id: Int, _ result: Result<URL, Error>) {
        let w = lock.withLock { waiting.removeValue(forKey: id) }
        guard let w else {
            if case .success(let file) = result { try? FileManager.default.removeItem(at: file) }
            return
        }
        w.continuation.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        modelTrace("didFinishDownloadingTo status=\((downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1)")
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            complete(downloadTask.taskIdentifier, .failure(URLError(.badServerResponse)))
            return
        }
        // The temporary file is deleted when this returns: move it somewhere ours first.
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("model-\(UUID().uuidString).aar")
        do {
            try FileManager.default.moveItem(at: location, to: dst)
            complete(downloadTask.taskIdentifier, .success(dst))
        } catch {
            complete(downloadTask.taskIdentifier, .failure(error))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let w = lock.withLock({ waiting[downloadTask.taskIdentifier] }) else { return }
        if Self.exceeds(w.maxBytes, written: totalBytesWritten, expected: totalBytesExpectedToWrite) {
            complete(downloadTask.taskIdentifier, .failure(ModelError.tooLarge))
            downloadTask.cancel()
            return
        }
        guard totalBytesExpectedToWrite > 0 else { return }
        w.progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        modelLog.notice("task complete, error: \(error.map { String(describing: $0) } ?? "none", privacy: .public)")
        modelTrace("task complete error=\(error.map { String(describing: $0) } ?? "none")")
        if let error { complete(task.taskIdentifier, .failure(error)) }
    }
}

/// Download progress for the screen (UIP-02). The session calls back every 16 to 64 KB, thousands of times
/// for one model, and each call used to hop to the main actor and redraw the Player. The row only needs a new
/// figure when the whole percent changes, and never more than four times a second; the end always gets through.
nonisolated final class ProgressThrottle: Sendable {
    private let last = Mutex<(percent: Int, at: TimeInterval)>((-1, -.infinity))
    let interval: TimeInterval

    init(interval: TimeInterval = 0.25) { self.interval = interval }

    func shouldPublish(_ fraction: Double, now: TimeInterval = CACurrentMediaTime()) -> Bool {
        let percent = Int((min(1, max(0, fraction)) * 100).rounded(.down))
        return last.withLock { l in
            if fraction >= 1, l.percent < 100 { l = (100, now); return true }
            guard percent != l.percent, now - l.at >= interval else { return false }
            l = (percent, now)
            return true
        }
    }
}

extension AppModel {
    /// Fetches any missing big models, one at a time, then starts the work they unlock. Only after a click
    /// next to the size (R01b): `force` is that click (Download on the extra parts row, or Settings ▸ Models
    /// ▸ Download Now), and it is a yes.
    func startModelDownloads(force: Bool = false) {
        guard !resetting else { return }
        let missing = ModelDownloads.missing
        guard ModelDownloads.mayStart(force: force, consent: ModelDownloads.consent, missing: !missing.isEmpty),
              modelDownloadTask == nil else { return }
        if force { ModelDownloads.consent = .yes }
        let extras = ExtraParts.shared
        extras.apply(missing: missing, hasSpace: extras.hasSpace)
        extras.begin(missing)
        let epoch = ResetBackline.epoch
        let run = ModelDownloads.run
        // A reset, or Cancel, and this run installs nothing and writes no state.
        let isCurrent: @Sendable () -> Bool = { ResetBackline.isCurrent(epoch) && ModelDownloads.isCurrentRun(run) }
        modelDownloadTask = Task { [weak self] in
            if !force { try? await Task.sleep(for: .seconds(4)) }       // let the window and the first split come first
            guard isCurrent() else { return }
            // Where the files are this time (R01d): only now, after the user said yes.
            let manifest = await ModelManifest.current()
            guard isCurrent() else { return }
            self?.withdrawnModels = Set(ModelDownloads.assets.filter { ModelManifest.isWithdrawn($0, in: manifest) }.map(\.name))
            for asset in ModelDownloads.missing where !ModelManifest.isWithdrawn(asset, in: manifest) {
                guard isCurrent(), ModelDownloads.consent == .yes else { return }
                self?.downloadingModel = asset.name
                self?.modelDownloadProgress = 0
                extras.startAsset(asset)
                let throttle = ProgressThrottle()
                let ok = await Task.detached(priority: .utility) { [weak self] in
                    (try? await ModelDownloads.install(asset, manifest: manifest, isCurrent: isCurrent, progress: { p in
                        guard throttle.shouldPublish(p) else { return }
                        Task { @MainActor in
                            guard isCurrent() else { return }
                            self?.modelDownloadProgress = p
                            extras.advance(asset, fraction: p)
                        }
                    })) != nil
                }.value
                guard let self, isCurrent() else { return }
                self.downloadingModel = nil
                self.modelDownloadProgress = nil
                modelLog.notice("install \(asset.name, privacy: .public): \(ok ? "ok" : "failed", privacy: .public)")
                modelTrace("install \(asset.name) ok=\(ok)")
                // Installed or not, the row's answer comes from the disk again (UIP-02).
                extras.refresh()
                if ok {
                    extras.finishAsset(asset)
                    // The row stays for the kit split when this song and mode will get one (V01).
                    if ModelDownloads.missing.isEmpty { self.extraPartsDownloadFinished() }
                    self.ensureCleanerParts()
                    self.ensureDrumSplit()
                } else {
                    // Offline, out of space or a bad file: the row says so and offers Try again (V01).
                    extras.fail()
                    break
                }
            }
            guard isCurrent() else { return }
            self?.modelDownloadTask = nil
        }
    }

    /// Cancel on the extra parts row: takes the yes back, stops the transfers and shows the offer again.
    /// Nothing half-installed is left behind: `install` writes the `.sha256` marker last, and without it
    /// `ModelStore.url` doesn't see the model.
    func cancelModelDownloads() {
        ModelDownloads.consent = .unasked
        ModelDownloads.bumpRun()
        let running = modelDownloadTask
        modelDownloadTask = nil
        running?.cancel()
        downloadingModel = nil
        modelDownloadProgress = nil
        ExtraParts.shared.cancelled()
        ExtraParts.shared.refresh()
        AppLog.note("models: download cancelled")
        Task { await Downloader.shared.reset() }
    }
}
