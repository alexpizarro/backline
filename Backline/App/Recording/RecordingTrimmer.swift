import AVFoundation
import Foundation

/// File work on finished recordings: moving a take out of the App Group, cutting the silence around the
/// song, and scanning a file for where the sound is. Streams in chunks, so a 20-minute take (about 420 MB
/// of Float32) never has to fit in memory.
nonisolated enum RecordingTrimmer {
    enum TrimError: LocalizedError {
        case emptyRange
        var errorDescription: String? { "Nothing to keep." }
    }

    private static let chunk: AVAudioFrameCount = 1 << 16

    /// Keeps only the `range` (seconds) of `url`: the file is rewritten in place (same URL, shorter) and returned.
    /// A range that already covers the whole file leaves it untouched.
    @concurrent
    static func trim(_ url: URL, to range: ClosedRange<Double>) async throws -> URL {
        try trimSync(url, to: range)
    }

    static func trimSync(_ url: URL, to range: ClosedRange<Double>) throws -> URL {
        let src = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = src.processingFormat.sampleRate
        let start = max(0, AVAudioFramePosition((range.lowerBound * rate).rounded(.down)))
        let end = min(src.length, AVAudioFramePosition((range.upperBound * rate).rounded(.up)))
        guard end > start else { throw TrimError.emptyRange }
        if start == 0 && end >= src.length { return url }

        // Written beside the original, then swapped in, so the take keeps its name.
        let dst = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)-trim.caf")
        let out = try AVAudioFile(forWriting: dst, settings: src.fileFormat.settings,
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: src.processingFormat, frameCapacity: chunk) else { throw TrimError.emptyRange }
        src.framePosition = start
        var remaining = end - start
        do {
            while remaining > 0 {
                let n = AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining))
                try src.read(into: buffer, frameCount: n)
                if buffer.frameLength == 0 { break }
                try out.write(from: buffer)
                remaining -= AVAudioFramePosition(buffer.frameLength)
            }
        } catch {
            out.close()
            try? FileManager.default.removeItem(at: dst)
            throw error
        }
        out.close()
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: dst, to: url)
        return url
    }

    /// Where the sound is in `url`: first and last 50 ms block whose peak is above `thresholdDB`, in seconds.
    /// Used when a take has no live statistics (a recovered file).
    static func scan(_ url: URL, thresholdDB: Float) throws -> (first: Double, last: Double, duration: Double)? {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate
        let block = AVAudioFrameCount(rate * 0.05)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: block) else { return nil }
        var position: AVAudioFramePosition = 0
        var first: AVAudioFramePosition?
        var last: AVAudioFramePosition = 0
        while position < file.length {
            try file.read(into: buffer, frameCount: block)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            if let data = buffer.floatChannelData {
                var peak: Float = 0
                for ch in 0..<Int(buffer.format.channelCount) {
                    peak = max(peak, AudioLevel.peakAndRMS(UnsafePointer(data[ch]), count: n).peak)
                }
                if AudioLevel.db(fromLinear: peak) > thresholdDB {
                    if first == nil { first = position }
                    last = position + AVAudioFramePosition(n)
                }
            }
            position += AVAudioFramePosition(n)
        }
        guard let first else { return nil }
        return (Double(first) / rate, Double(last) / rate, Double(file.length) / rate)
    }

    // MARK: App Group → app

    /// Moves a file out of the shared App Group container into the app's own recordings folder, where the
    /// import pipeline uses it in place and deletes it after the split.
    static func adopt(_ source: URL, date: Date = .now) throws -> URL {
        let fm = FileManager.default
        try prepareRecordingsDirectory()
        let dest = newRecordingURL(date: date)
        do { try fm.moveItem(at: source, to: dest) } catch {
            try fm.copyItem(at: source, to: dest)
            try? fm.removeItem(at: source)
        }
        return dest
    }

    /// Creates `directory` (if needed). On iOS it is kept out of iCloud / device backups: a recording is a
    /// temporary working file (up to ~420 MB) that is deleted after the split. On the Mac only the models are
    /// kept out of Time Machine (D5): a take whose split was cut off may be the only copy of it, so the folder
    /// is backed up (and a folder an earlier build marked is put back).
    static func prepareRecordingsDirectory(_ directory: URL = ImportStaging.recordingsDirectory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        #if os(iOS)
        values.isExcludedFromBackup = true
        var url = directory
        #else
        values.isExcludedFromBackup = false
        // A fresh URL: resource values are cached on the URL value that read or set them.
        var url = URL(fileURLWithPath: directory.path, isDirectory: true)
        #endif
        try url.setResourceValues(values)
    }

    /// `Recording 2026-10-17 04-14-05.caf` in the app's recordings folder (the import row shows this name while
    /// the song is being split). A second take in the same second gets a number.
    static func newRecordingURL(date: Date = .now) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let base = "Recording " + f.string(from: date)
        var url = ImportStaging.recordingsDirectory.appendingPathComponent(base + ".caf")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = ImportStaging.recordingsDirectory.appendingPathComponent("\(base) \(n).caf")
            n += 1
        }
        return url
    }

    /// Takes older than a day that nobody imported (a cancelled sheet, a crash) are removed.
    static func purgeStale(in directory: URL?, keeping keep: Set<String> = [], olderThan age: TimeInterval = 24 * 3600) {
        guard let directory else { return }
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-age)
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where !keep.contains(name) {
            let url = directory.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
            if modified < cutoff { try? fm.removeItem(at: url) }
        }
    }
}
