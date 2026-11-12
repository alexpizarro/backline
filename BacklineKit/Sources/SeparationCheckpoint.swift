import Foundation

/// Lets a long separation pass carry on where it stopped instead of starting again.
///
/// Overlap-add separators process the track in chunks that start `step` samples apart. Once the chunk at
/// `offset` is done, no later chunk touches anything before `offset + step`, so those samples are final.
/// They are appended to one raw float file per output channel as they become final. A later run with the
/// same `key` loads that prefix and only recomputes the chunk that straddles its end.
///
/// The files hold final values (accumulated output divided by the window sum), so a resumed run reproduces
/// an uninterrupted one exactly when the model is deterministic.
public struct SeparationCheckpoint: Sendable {
    public let directory: URL
    /// Identifies the input and the model. A checkpoint written under another key is discarded.
    public let key: String

    public init(directory: URL, key: String) {
        self.directory = directory
        self.key = key
    }

    public func discard() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// How a pass turns what it accumulated into final samples. The checkpoint writes them with the same arithmetic, so
/// that a resumed run gives exactly the samples an uninterrupted one does.
enum CheckpointScale {
    /// `accumulated / weight` where the weight is above zero (`RoformerSeparator`, `LeadSeparator`).
    case divide
    /// `accumulated * (1 / weight)` where the weight is above `floor`, else zero (`DrumSeparator`).
    case reciprocal(above: Float)
    /// The accumulated samples as they are, with the weights in one more file, for a pass whose own division
    /// can't be repeated piece by piece with the same rounding (`DemucsSeparator`'s `vDSP_svdiv`): the pass puts
    /// both back and divides the whole song as an uninterrupted run does.
    case raw
}

/// The open files of a checkpoint during one run.
final class CheckpointWriter {
    private struct State: Codable, Equatable {
        var key: String
        var total: Int
        var step: Int
        var channels: Int
    }

    private let handles: [FileHandle]
    private let urls: [URL]
    private let scale: CheckpointScale
    /// Samples `[0, resumeFrom)` are final and on disk.
    let resumeFrom: Int
    private(set) var written: Int

    /// Opens (or starts) the checkpoint for a pass over `total` padded samples. Throws only when the
    /// directory cannot be written, in which case the caller runs without one.
    init(_ cp: SeparationCheckpoint, total: Int, step: Int, channels: Int, scale: CheckpointScale = .divide) throws {
        self.scale = scale
        let fm = FileManager.default
        let state = State(key: cp.key, total: total, step: step, channels: channels)
        let stateURL = cp.directory.appendingPathComponent("state.json")
        // `raw` keeps the weights too, after the channels.
        let files: Int
        if case .raw = scale { files = channels + 1 } else { files = channels }
        urls = (0..<files).map { cp.directory.appendingPathComponent("ch\($0).f32") }

        var resume = 0
        let sizes = urls.map { (try? fm.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? 0 }
        if let data = try? Data(contentsOf: stateURL), let old = try? JSONDecoder().decode(State.self, from: data),
           old == state, sizes.allSatisfy({ $0 <= total * MemoryLayout<Float>.size }) {
            // A run can die between two channel writes: keep only what every channel has, on a chunk boundary.
            // A file longer than the pass makes isn't this pass's: then everything starts again (the else below).
            let lengths = sizes.map { $0 / MemoryLayout<Float>.size }
            let common = lengths.min() ?? 0
            resume = min(total, common == total ? total : (common / step) * step)
        } else {
            try? fm.removeItem(at: cp.directory)
            try fm.createDirectory(at: cp.directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        }
        for url in urls where !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        }
        var opened: [FileHandle] = []
        for url in urls {
            let h = try FileHandle(forUpdating: url)
            try h.truncate(atOffset: UInt64(resume * MemoryLayout<Float>.size))
            try h.seekToEnd()
            opened.append(h)
        }
        handles = opened
        resumeFrom = resume
        written = resume
    }

    deinit { for h in handles { try? h.close() } }

    /// Reads the final prefix into the start of each channel buffer.
    func loadPrefix(into channels: inout [[Float]]) throws {
        guard resumeFrom > 0 else { return }
        for k in channels.indices where k < urls.count { try read(urls[k], into: &channels[k]) }
    }

    private func read(_ url: URL, into buffer: inout [Float]) throws {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        guard buffer.count >= resumeFrom, let data = try h.read(upToCount: resumeFrom * MemoryLayout<Float>.size),
              data.count == resumeFrom * MemoryLayout<Float>.size else { throw CocoaError(.fileReadCorruptFile) }
        buffer.withUnsafeMutableBytes { dst in data.copyBytes(to: dst) }
    }

    /// Opens `checkpoint` for a pass, or nil (the pass runs without one) when there is none or it can't be written.
    static func open(_ checkpoint: SeparationCheckpoint?, total: Int, step: Int, channels: Int,
                     scale: CheckpointScale) -> CheckpointWriter? {
        checkpoint.flatMap { try? CheckpointWriter($0, total: total, step: step, channels: channels, scale: scale) }
    }

    /// For a pass that recomputed the chunks reaching past the prefix from nothing (`firstChunk`): puts the kept
    /// samples back over `[0, resumeFrom)` of each channel, as the last step before the pass divides by its weights:
    /// final samples with a weight of 1, or (`raw`) the accumulated samples with their own weights. The chunks after
    /// the prefix were added up exactly as in an uninterrupted run (the same calls on the same addresses), so the
    /// result is the same sample for sample.
    func restorePrefix(into channels: inout [[Float]], weight: inout [Float]) throws {
        guard resumeFrom > 0 else { return }
        try loadPrefix(into: &channels)
        if case .raw = scale, let last = urls.last {
            try read(last, into: &weight)
        } else {
            weight.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 1, count: resumeFrom) }
        }
    }

    /// The first of `offsets` (chunk starts, ascending, each chunk `length(offset)` samples long) that a run resuming
    /// at `resumeFrom` must compute again: the first chunk that reaches past the kept prefix. `offsets.count` when
    /// none does (the prefix is the whole pass).
    static func firstChunk(_ offsets: [Int], resumeFrom: Int, length: (Int) -> Int) -> Int {
        offsets.firstIndex { $0 + length($0) > resumeFrom } ?? offsets.count
    }

    /// Appends final samples `[written, upTo)` for each channel, made from `accumulated` and `weight` as `scale` says.
    func append(upTo end: Int, accumulated: [[Float]], weight: [Float]) throws {
        guard end > written else { return }
        let count = end - written
        var scratch = [Float](repeating: 0, count: count)
        for (k, h) in handles.enumerated() {
            switch scale {
            case .divide:
                for i in 0..<count {
                    let w = weight[written + i]
                    scratch[i] = w > 0 ? accumulated[k][written + i] / w : 0
                }
            case .reciprocal(let floor):
                for i in 0..<count {
                    let w = weight[written + i]
                    scratch[i] = w > floor ? accumulated[k][written + i] * (1 / w) : 0
                }
            case .raw:
                let src = k < accumulated.count ? accumulated[k] : weight
                src.withUnsafeBufferPointer { s in
                    scratch.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: s.baseAddress! + written, count: count) }
                }
            }
            try scratch.withUnsafeBytes { try h.write(contentsOf: Data($0)) }
        }
        written = end
    }
}
