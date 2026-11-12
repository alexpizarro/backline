import Foundation

/// Downloads a link to a music or video file (R01a): one `URLSession` download with a 20 s idle timeout and a
/// 1 GB cap that stops it as soon as it is passed. The file is kept only when the server says it is audio or
/// video (or a generic binary with a music or video extension), and lands in `ImportStaging.downloadsDirectory`
/// named after the link's file so the song gets a sensible title.
nonisolated enum FileLinkDownload {
    static let maxBytes: Int64 = 1 << 30
    static let timeout: TimeInterval = 20

    enum Failure: LocalizedError, Equatable {
        /// The server sent something that isn't music or video.
        case notMedia
        /// The server sent a web page: a share page, not the file. Trying again would get the same page (L7).
        case webPage
        case tooLarge
        case network

        var errorDescription: String? {
            switch self {
            case .notMedia: "Can't get a song from this link."
            case .webPage: FileLinkDownload.webPageMessage
            case .tooLarge: "Too big to split."
            case .network: "Can't connect. Check your internet."
            }
        }
    }

    /// The failure screen offers another song for this one, not Try again (L7).
    static let webPageMessage = "This link opens a web page, not a file. Copy the file's download link."

    /// Audio or video by its MIME type, or a generic binary whose link ends in a music or video extension.
    static func isMedia(mimeType: String?, url: URL) -> Bool {
        let m = (mimeType ?? "").lowercased()
        if m.hasPrefix("audio/") || m.hasPrefix("video/") { return true }
        let generic = m.isEmpty || m == "application/octet-stream" || m == "binary/octet-stream"
        return generic && WebLink.fileExtensions.contains(url.pathExtension.lowercased())
    }

    static func isWebPage(mimeType: String?) -> Bool {
        let m = (mimeType ?? "").lowercased()
        return m.hasPrefix("text/html") || m.hasPrefix("application/xhtml")
    }

    /// A file-sharing service's share link (`…/song.mp3?…&dl=0`) opens its preview page; `dl=1` is the same link's
    /// documented direct-download form. Only that query item, and only on that service's hosts, is changed.
    static func directForm(_ url: URL) -> URL {
        guard let host = url.host?.lowercased(), host == "dropbox.com" || host.hasSuffix(".dropbox.com"),
              var c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = c.percentEncodedQueryItems, items.contains(where: { $0.name == "dl" && $0.value == "0" }) else { return url }
        c.percentEncodedQueryItems = items.map { $0.name == "dl" && $0.value == "0" ? URLQueryItem(name: "dl", value: "1") : $0 }
        return c.url ?? url
    }

    /// Downloads `url` into `directory` and returns the saved file.
    static func download(_ url: URL, into directory: URL, configuration: URLSessionConfiguration = .ephemeral,
                         progress: @escaping @Sendable (Double) -> Void,
                         isCancelled: @escaping @Sendable () -> Bool) async throws -> URL {
        let link = directForm(url)
        let (temp, response) = try await transfer(URLRequest(url: link), configuration: configuration, timeout: timeout,
                                                  maxBytes: maxBytes, progress: progress, isCancelled: isCancelled)
        defer { try? FileManager.default.removeItem(at: temp) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw Failure.notMedia }
        guard isMedia(mimeType: response.mimeType, url: response.url ?? link) else {
            throw isWebPage(mimeType: response.mimeType) ? Failure.webPage : Failure.notMedia
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = (url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)
            .replacingOccurrences(of: "/", with: "_")
        let ext = url.pathExtension.isEmpty ? (response.suggestedFilename.map { ($0 as NSString).pathExtension } ?? "m4a") : ""
        let dest = directory.appendingPathComponent(UUID().uuidString + "-" + name + (ext.isEmpty ? "" : "." + ext))
        try FileManager.default.moveItem(at: temp, to: dest)
        progress(1)
        return dest
    }

    /// One download task straight to a temporary file of our own, with progress at most once per percent, the
    /// size cap, and a cancel that lands at once: a cancelled task stops the transfer even while the server sends
    /// nothing (L7). Throws `CancellationError`, `Failure.tooLarge` or `Failure.network`; the caller deletes the file.
    static func transfer(_ request: URLRequest, configuration: URLSessionConfiguration, timeout: TimeInterval, maxBytes: Int64,
                         progress: @escaping @Sendable (Double) -> Void,
                         isCancelled: @escaping @Sendable () -> Bool) async throws -> (URL, URLResponse) {
        if Task.isCancelled || isCancelled() { throw CancellationError() }
        let config = configuration
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        let job = Job(maxBytes: maxBytes, progress: RangedDownload.ProgressReporter(progress), isCancelled: isCancelled)
        let session = URLSession(configuration: config, delegate: job, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await job.run(session.downloadTask(with: request))
    }

    /// One download: reports progress, enforces the cap and the cancel check, and hands back the file.
    private final class Job: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let maxBytes: Int64
        let progress: RangedDownload.ProgressReporter
        let isCancelled: @Sendable () -> Bool
        private let lock = NSLock()
        private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
        private var failure: Error?
        private var task: URLSessionDownloadTask?
        private var cancelRequested = false

        init(maxBytes: Int64, progress: RangedDownload.ProgressReporter, isCancelled: @escaping @Sendable () -> Bool) {
            self.maxBytes = maxBytes
            self.progress = progress
            self.isCancelled = isCancelled
        }

        func run(_ task: URLSessionDownloadTask) async throws -> (URL, URLResponse) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { c in
                    let cancelNow = lock.withLock { () -> Bool in
                        continuation = c
                        self.task = task
                        return cancelRequested
                    }
                    task.resume()
                    if cancelNow { task.cancel() }
                }
            } onCancel: {
                let task = lock.withLock { () -> URLSessionDownloadTask? in
                    cancelRequested = true
                    if failure == nil { failure = CancellationError() }
                    return self.task
                }
                task?.cancel()
            }
        }

        private func finish(_ result: Result<(URL, URLResponse), Error>) {
            let c = lock.withLock { () -> CheckedContinuation<(URL, URLResponse), Error>? in
                defer { continuation = nil }
                return continuation
            }
            c?.resume(with: result)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if isCancelled() {
                lock.withLock { failure = CancellationError() }
                downloadTask.cancel()
                return
            }
            if totalBytesWritten > maxBytes || totalBytesExpectedToWrite > maxBytes {
                lock.withLock { failure = Failure.tooLarge }
                downloadTask.cancel()
                return
            }
            if totalBytesExpectedToWrite > 0 { progress.report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // The file at `location` is gone once this returns: move it somewhere of our own first.
            let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                if let stored = lock.withLock({ failure }) { throw stored }
                try FileManager.default.moveItem(at: location, to: keep)
                guard let response = downloadTask.response else { throw Failure.network }
                finish(.success((keep, response)))
            } catch {
                try? FileManager.default.removeItem(at: keep)
                finish(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error else { return }
            let stored = lock.withLock { failure }
            if let stored { finish(.failure(stored)); return }
            if (error as? URLError)?.code == .cancelled { finish(.failure(CancellationError())); return }
            finish(.failure(Failure.network))
        }
    }
}
