import AppleArchive
import BacklineKit
import CryptoKit
import Foundation
import OSLog
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
    static let assets: [ModelAsset] = [
        ModelAsset(name: CleanerPartsJob.modelName, file: "BSRoformerSW-fp16-1.aar",
                   sha256: "74fe971df15e20d62e63c0839aca699785a31232b931c63efa3539e0da2836f6", bytes: 344_259_466),
        ModelAsset(name: DrumSeparator.modelName, file: "DrumSepMDX23C-fp16-1.aar",
                   sha256: "d9fb411140f10c8a43021968e1259b200f30b57165329b638eaee2e2a8fc5c16", bytes: 202_873_466),
    ]

    static func markerURL(_ a: ModelAsset) -> URL { ModelStore.directory.appendingPathComponent("\(a.name).sha256") }

    /// True when this exact version of the model is installed.
    static func isInstalled(_ a: ModelAsset) -> Bool {
        ModelStore.url(a.name) != nil
            && (try? String(contentsOf: markerURL(a), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == a.sha256
    }

    static var missing: [ModelAsset] { assets.filter { !isInstalled($0) } }

    /// Downloads, checks and installs one model. Safe to call again after a failure.
    static func install(_ a: ModelAsset, progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: ModelStore.directory, withIntermediateDirectories: true)
        let free = (try? ModelStore.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
        guard free > a.bytes * 3 + 500_000_000 else { throw CocoaError(.fileWriteOutOfSpace) }

        modelLog.notice("download \(a.file, privacy: .public) starting")
        modelTrace("start \(a.file)")
        let file = try await Downloader().fetch(base.appendingPathComponent(a.file), progress: { progress(0.95 * $0) })
        defer { try? fm.removeItem(at: file) }
        let got = try sha256(of: file)
        modelLog.notice("download \(a.file, privacy: .public) finished, sha256 \(got == a.sha256 ? "ok" : "MISMATCH", privacy: .public)")
        modelTrace("finished \(a.file) sha ok=\(got == a.sha256)")
        guard got == a.sha256 else { throw CocoaError(.fileReadCorruptFile) }

        // Unpack beside the final place, then swap it in, so a half-unpacked model is never used.
        let staging = ModelStore.directory.appendingPathComponent(".\(a.name)-unpack", isDirectory: true)
        let target = ModelStore.directory.appendingPathComponent("\(a.name).mlmodelc", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try extract(file, to: staging)
        try? fm.removeItem(at: markerURL(a))
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: target)
        }
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

/// One download at a time with progress, resuming after a dropped connection (up to 4 tries).
nonisolated final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var onProgress: (@Sendable (Double) -> Void)?
    private var session: URLSession!

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func fetch(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        defer { session.finishTasksAndInvalidate() }
        var resume: Data?
        for attempt in 0..<4 {
            do {
                return try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                    lock.withLock { continuation = c; onProgress = progress }
                    let task = resume.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
                    task.resume()
                }
            } catch {
                resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                if attempt == 3 { throw error }
                try await Task.sleep(for: .seconds(Double(2 << attempt)))
            }
        }
        throw URLError(.cannotLoadFromNetwork)
    }

    private func finish(_ r: Result<URL, Error>) {
        let c = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            defer { continuation = nil }
            return continuation
        }
        c?.resume(with: r)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        modelTrace("didFinishDownloadingTo status=\((downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1)")
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        // The temporary file is deleted when this returns: move it somewhere ours first.
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("model-\(UUID().uuidString).aar")
        do {
            try FileManager.default.moveItem(at: location, to: dst)
            finish(.success(dst))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = lock.withLock { onProgress }
        p?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        modelLog.notice("task complete, error: \(error.map { String(describing: $0) } ?? "none", privacy: .public)")
        modelTrace("task complete error=\(error.map { String(describing: $0) } ?? "none")")
        if let error { finish(.failure(error)) }
    }
}

extension AppModel {
    /// Fetches any missing big models in the background, one at a time, then starts the work they unlock.
    func startModelDownloads() {
        guard modelDownloadTask == nil, !ModelDownloads.missing.isEmpty else { return }
        modelDownloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))       // let the window and the first split come first
            for asset in ModelDownloads.missing {
                await MainActor.run { self?.downloadingModel = asset.name; self?.modelDownloadProgress = 0 }
                let ok = await Task.detached(priority: .utility) { [weak self] in
                    (try? await ModelDownloads.install(asset, progress: { p in
                        Task { @MainActor in self?.modelDownloadProgress = p }
                    })) != nil
                }.value
                guard let self else { return }
                self.downloadingModel = nil
                self.modelDownloadProgress = nil
                modelLog.notice("install \(asset.name, privacy: .public): \(ok ? "ok" : "failed", privacy: .public)")
                modelTrace("install \(asset.name) ok=\(ok)")
                if ok {
                    self.ensureCleanerParts()
                    self.ensureDrumSplit()
                } else {
                    break      // offline or a bad file: try again next time Backline opens
                }
            }
            self?.modelDownloadTask = nil
        }
    }
}
