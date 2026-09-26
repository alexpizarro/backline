import AVFoundation
import Accelerate
import BacklineKit
import CryptoKit
import Foundation

/// On-disk library: `~/Library/Application Support/Backline/Songs/<id>/`
///   song.json · <stem>.caf (16-bit ALAC stems) · artwork
nonisolated struct SongStore: Sendable {
    let root: URL

    static let shared: SongStore = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = base.appendingPathComponent("Backline/Songs", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return SongStore(root: root)
    }()

    func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    func stemURL(_ id: String, _ kind: StemKind) -> URL { folder(id).appendingPathComponent("\(SongRecord.fileStem(kind)).caf") }
    func mixURL(_ rec: SongRecord, _ kind: StemKind) -> URL {
        folder(rec.id).appendingPathComponent("\(rec.mixFileStem(kind)).caf")
    }
    func otherSplitURL(_ id: String) -> URL { folder(id).appendingPathComponent("other-split.caf") }
    func artworkURL(_ id: String) -> URL { folder(id).appendingPathComponent("artwork") }
    func recordURL(_ id: String) -> URL { folder(id).appendingPathComponent("song.json") }

    func loadAll() -> [SongRecord] {
        let fm = FileManager.default
        guard let ids = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        let dec = JSONDecoder()
        return ids.compactMap { id in
            guard let data = try? Data(contentsOf: recordURL(id)),
                  let rec = try? dec.decode(SongRecord.self, from: data),
                  rec.stems.allSatisfy({ fm.fileExists(atPath: stemURL(id, $0).path) }) else { return nil }
            var r = rec
            // A split whose files went missing is dropped rather than hiding the song.
            if let gs = r.guitarSplit,
               ![StemKind.leadGuitar, .rhythmGuitar].allSatisfy({ fm.fileExists(atPath: stemURL(id, $0).path) })
                || (gs.otherAdjusted && !fm.fileExists(atPath: otherSplitURL(id).path)) {
                r.guitarSplit = nil
            }
            return r
        }
        .sorted { $0.lastOpened > $1.lastOpened }
    }

    func save(_ rec: SongRecord) throws {
        try FileManager.default.createDirectory(at: folder(rec.id), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try enc.encode(rec).write(to: recordURL(rec.id), options: .atomic)
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: folder(id))
    }

    func artwork(_ id: String) -> Data? { try? Data(contentsOf: artworkURL(id)) }

    /// Stable id from file content (so re-importing the same song reopens it instantly).
    static func contentID(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Stem files

    /// Writes a stem losslessly (Apple Lossless, 16-bit, ~50 % of PCM; near-silent stems shrink to almost nothing).
    func writeStem(_ audio: StereoAudio, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: audio.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitDepthHintKey: 16,
        ]
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: audio.sampleRate, channels: 2, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 1 << 18
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(chunk))!
        var pos = 0
        while pos < audio.frameCount {
            let n = min(chunk, audio.frameCount - pos)
            audio.left.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress! + pos, count: n) }
            audio.right.withUnsafeBufferPointer { buf.floatChannelData![1].update(from: $0.baseAddress! + pos, count: n) }
            buf.frameLength = AVAudioFrameCount(n)
            try file.write(from: buf)
            pos += n
        }
    }

    /// Reads a stem straight into the engine's channel buffers.
    func readStem(_ url: URL, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, capacity: Int) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 1 << 18
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunk))!
        var pos = 0
        while pos < capacity {
            try file.read(into: buf, frameCount: AVAudioFrameCount(min(chunk, capacity - pos)))
            let n = Int(buf.frameLength)
            if n == 0 { break }
            let ch = buf.floatChannelData!
            (left + pos).update(from: ch[0], count: n)
            (right + pos).update(from: file.processingFormat.channelCount > 1 ? ch[1] : ch[0], count: n)
            pos += n
        }
    }

    static func frameCount(of url: URL) -> Int {
        (try? AVAudioFile(forReading: url).length).map(Int.init) ?? 0
    }
}

nonisolated enum Peaks {
    /// Max-abs of the mono mix per bucket, normalised to the loudest stem later.
    static func compute(_ a: StereoAudio, buckets: Int = 1600) -> [Float] {
        let n = a.frameCount
        guard n > 0 else { return [Float](repeating: 0, count: buckets) }
        var out = [Float](repeating: 0, count: buckets)
        a.left.withUnsafeBufferPointer { l in
            a.right.withUnsafeBufferPointer { r in
                for b in 0..<buckets {
                    let s = b * n / buckets, e = max(s + 1, (b + 1) * n / buckets)
                    var ml: Float = 0, mr: Float = 0
                    vDSP_maxmgv(l.baseAddress! + s, 1, &ml, vDSP_Length(e - s))
                    vDSP_maxmgv(r.baseAddress! + s, 1, &mr, vDSP_Length(e - s))
                    out[b] = max(ml, mr)
                }
            }
        }
        return out
    }

    /// Resamples to `count` bars by taking the max of each span.
    static func resample(_ p: [Float], to count: Int) -> [Float] {
        guard count > 0, !p.isEmpty else { return [] }
        return (0..<count).map { i in
            let s = i * p.count / count, e = max(s + 1, (i + 1) * p.count / count)
            return p[s..<min(e, p.count)].max() ?? 0
        }
    }
}
