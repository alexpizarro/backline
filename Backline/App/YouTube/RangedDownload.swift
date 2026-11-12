import Foundation

/// Downloads one googlevideo stream in `Range:` chunks. YouTube throttles a single unbounded request to a
/// trickle but serves ~10 MB ranges at full speed, which is also how its own player fetches. Bytes go
/// straight to disk as they arrive, so a dropped connection resumes from what is already there.
nonisolated enum RangedDownload {
    static let chunkSize = 10 << 20

    enum Failure: Error, Equatable {
        /// The URL was refused: expired, wrong network, or YouTube wants a PO token for it. A fresh URL may work.
        case forbidden
        case http(Int)
        case tooLarge
        /// The first bytes aren't an MP4 file.
        case notAudio
        case truncated
    }

    /// `bytes 0-1023/2645256` → 2645256
    static func contentRangeTotal(_ header: String?) -> Int? {
        guard let header, let slash = header.lastIndex(of: "/") else { return nil }
        return Int(header[header.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    /// The byte ranges that cover `total` bytes.
    static func ranges(total: Int, chunkSize: Int = chunkSize) -> [ClosedRange<Int>] {
        guard total > 0, chunkSize > 0 else { return [] }
        return stride(from: 0, to: total, by: chunkSize).map { $0...min($0 + chunkSize, total) - 1 }
    }

    static func isTransient(_ error: URLError) -> Bool {
        [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost,
         .notConnectedToInternet, .secureConnectionFailed, .resourceUnavailable].contains(error.code)
    }

    /// Receives one chunk and writes it to disk as it arrives.
    private final class Sink: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let handle: FileHandle
        private let isCancelled: @Sendable () -> Bool
        private let onWrite: @Sendable (Int) -> Void
        private let lock = NSLock()
        private var _written: Int
        private var _status = 0
        private var _contentRange: String?
        private var _expectedLength: Int64 = -1
        private var _badHeader = false
        private var _writeError: Error?
        private var checkedHeader: Bool
        private var failed = false
        private let acceptsFullBody: Bool
        private var continuation: CheckedContinuation<Void, Error>?
        private var task: URLSessionDataTask?
        private var cancelRequested = false

        init(handle: FileHandle, written: Int, acceptsFullBody: Bool, isCancelled: @escaping @Sendable () -> Bool, onWrite: @escaping @Sendable (Int) -> Void) {
            self.handle = handle
            _written = written
            checkedHeader = written > 0
            self.acceptsFullBody = acceptsFullBody
            self.isCancelled = isCancelled
            self.onWrite = onWrite
        }

        var written: Int { lock.withLock { _written } }
        var status: Int { lock.withLock { _status } }
        var contentRange: String? { lock.withLock { _contentRange } }
        var expectedLength: Int64 { lock.withLock { _expectedLength } }
        var badHeader: Bool { lock.withLock { _badHeader } }
        var writeError: Error? { lock.withLock { _writeError } }

        /// Runs one request to completion; bytes are written by the delegate callbacks as they arrive.
        func fetch(_ request: URLRequest, in session: URLSession) async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    let task = session.dataTask(with: request)
                    let cancelNow = lock.withLock { () -> Bool in
                        continuation = c
                        self.task = task
                        return cancelRequested
                    }
                    task.resume()
                    if cancelNow { task.cancel() }
                }
            } onCancel: {
                let task = lock.withLock { () -> URLSessionDataTask? in cancelRequested = true; return self.task }
                task?.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let c = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                let c = continuation
                continuation = nil
                return c
            }
            if let error { c?.resume(throwing: error) } else { c?.resume() }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let http = response as? HTTPURLResponse
            lock.withLock {
                _status = http?.statusCode ?? 0
                _contentRange = http?.value(forHTTPHeaderField: "Content-Range")
                _expectedLength = response.expectedContentLength
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard status == 206 || (status == 200 && acceptsFullBody), !failed else { return }
            if isCancelled() { failed = true; dataTask.cancel(); return }
            if !checkedHeader {
                guard data.count >= 8 else { return }
                guard data.dropFirst(4).prefix(4).elementsEqual("ftyp".utf8) else {
                    lock.withLock { _badHeader = true }
                    failed = true
                    dataTask.cancel()
                    return
                }
                checkedHeader = true
            }
            do {
                try handle.write(contentsOf: data)
                let now = lock.withLock { () -> Int in _written += data.count; return _written }
                onWrite(now)
            } catch {
                lock.withLock { _writeError = error }
                failed = true
                dataTask.cancel()
            }
        }
    }

    /// Writes the stream to `file` and returns its size. Throws `CancellationError` when cancelled; the
    /// caller removes the partial file.
    static func run(session: URLSession, url: URL, userAgent: String, knownSize: Int?, maxBytes: Int, to file: URL,
                    progress: @escaping @Sendable (Double) -> Void,
                    isCancelled: @escaping @Sendable () -> Bool) async throws -> Int {
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }

        var total = knownSize
        if let total, total > maxBytes { throw Failure.tooLarge }
        var written = 0
        var failures = 0
        let reporter = ProgressReporter(progress)

        while total == nil || written < total! {
            if Task.isCancelled || isCancelled() { throw CancellationError() }
            let before = written
            let upper = min(written + chunkSize, total ?? .max) - 1
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("bytes=\(written)-\(upper)", forHTTPHeaderField: "Range")
            let sizeForProgress = total
            let sink = Sink(handle: handle, written: written, acceptsFullBody: written == 0, isCancelled: isCancelled) { now in
                if let sizeForProgress { reporter.report(Double(now) / Double(sizeForProgress)) }
            }
            // The delegate sees bytes as they arrive (a per-task delegate wouldn't), so each chunk gets its own session.
            let chunkSession = URLSession(configuration: session.configuration, delegate: sink, delegateQueue: nil)
            defer { chunkSession.finishTasksAndInvalidate() }
            do {
                try await sink.fetch(request, in: chunkSession)
            } catch let error as URLError {
                written = sink.written
                if let e = sink.writeError { throw e }
                if sink.badHeader { throw Failure.notAudio }
                if error.code == .cancelled { throw CancellationError() }
                guard isTransient(error) else { throw error }
                failures += 1
                if failures > 4 { throw error }
                try await Task.sleep(for: .seconds(Double(failures)))
                continue
            }
            written = sink.written
            if let e = sink.writeError { throw e }
            if sink.badHeader { throw Failure.notAudio }

            switch sink.status {
            case 206:
                if let t = contentRangeTotal(sink.contentRange) { total = t }
            case 200 where before == 0:
                // The server ignored Range and sent everything.
                if sink.expectedLength > 0 { total = Int(sink.expectedLength) }
            case 403:
                throw Failure.forbidden
            case 429, 500...599:
                failures += 1
                if failures > 4 { throw Failure.http(sink.status) }
                try await Task.sleep(for: .seconds(Double(failures)))
                continue
            default:
                throw Failure.http(sink.status)
            }
            if let total, total > maxBytes { throw Failure.tooLarge }
            if written == before {
                failures += 1
                if failures > 4 { throw Failure.truncated }
            } else {
                failures = 0
            }
        }
        progress(1)
        return written
    }

    /// Passes progress on at most once per percent (file links and the song service's audio use it too).
    final class ProgressReporter: @unchecked Sendable {
        private let lock = NSLock()
        private var last = -1.0
        private let progress: @Sendable (Double) -> Void
        init(_ progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }
        func report(_ fraction: Double) {
            let f = min(1, fraction)
            let send = lock.withLock { () -> Bool in
                guard f - last >= 0.01 else { return false }
                last = f
                return true
            }
            if send { progress(f) }
        }
    }
}
