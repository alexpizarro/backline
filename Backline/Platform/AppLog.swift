import Foundation

/// A small diagnostics log the app keeps for itself, in Release too (owner's bug report, 22 Oct): how long
/// each import step took, when background passes start and stop, and whether Play really started the
/// sound. Song ids and timings only, never titles, links or anything from an account. It stays on the
/// device in `Library/Logs/Backline.log` (about 512 KB, the older half dropped when full), where it can be
/// read back with `devicectl device copy from` without touching anything else.
nonisolated enum AppLog {
    static let maxBytes = 512 << 10

    private static let queue = DispatchQueue(label: "com.alexpizarro.backline.log", qos: .utility)
    /// Used only on `queue`.
    nonisolated(unsafe) private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static var url: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true).appendingPathComponent("Backline.log")
    }

    /// Appends one line, off the calling thread.
    static func note(_ line: String) {
        let now = Date()
        // Lines from before a reset are dropped, so old song ids don't come back (review finding 14).
        let epoch = ResetBackline.epoch
        queue.async {
            guard ResetBackline.isCurrent(epoch) else { return }
            append(stamp.string(from: now) + " " + line + "\n")
        }
    }

    /// Reset: the log goes, after every line already queued.
    static func reset() {
        queue.sync { try? FileManager.default.removeItem(at: url) }
    }

    private static func append(_ text: String) {
        let fm = FileManager.default
        let file = url
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: file.path)[.size]) as? Int, size > maxBytes,
           let data = try? Data(contentsOf: file) {
            // Keep the newer half, from the start of a line.
            let tail = data.suffix(maxBytes / 2)
            let start = tail.firstIndex(of: 0x0A).map { tail.index(after: $0) } ?? tail.startIndex
            try? Data(tail[start...]).write(to: file, options: .atomic)
        }
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Waits for pending lines (tests).
    static func flush() { queue.sync {} }
}
