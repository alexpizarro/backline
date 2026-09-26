import AVFoundation
import Foundation

/// Planar stereo float32 audio at a fixed sample rate.
public struct StereoAudio: Sendable {
    public var left: [Float]
    public var right: [Float]
    public let sampleRate: Double

    public init(left: [Float], right: [Float], sampleRate: Double) {
        precondition(left.count == right.count)
        self.left = left
        self.right = right
        self.sampleRate = sampleRate
    }

    public var frameCount: Int { left.count }
    public var duration: TimeInterval { Double(frameCount) / sampleRate }
}

public enum AudioDecodeError: LocalizedError {
    case unsupported(String)
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let ext): return "Backline can't open this file type (\(ext))."
        case .conversionFailed(let m): return "Couldn't read the audio: \(m)"
        }
    }
}

public enum AudioDecoder {
    public static let supportedExtensions: Set<String> = ["mp3", "wav", "wave", "aif", "aiff", "aifc", "m4a", "mp4", "aac", "flac", "caf", "alac"]

    public static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Decodes any Core Audio–readable file to 44.1 kHz stereo float32.
    public static func decode(_ url: URL, sampleRate: Double = 44_100,
                              progress: ((Double) -> Void)? = nil) throws -> StereoAudio {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch {
            throw AudioDecodeError.unsupported(url.pathExtension.uppercased())
        }
        let src = file.processingFormat
        guard let dst = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                      channels: 2, interleaved: false),
              let converter = AVAudioConverter(from: src, to: dst) else {
            throw AudioDecodeError.conversionFailed("the sound is in a type Backline can't use")
        }
        if src.channelCount == 1 {
            // Mono → both channels.
            converter.channelMap = [0, 0]
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering

        let totalIn = file.length
        let estimatedOut = Int(Double(totalIn) * sampleRate / src.sampleRate) + 4096
        var left = [Float](); left.reserveCapacity(estimatedOut)
        var right = [Float](); right.reserveCapacity(estimatedOut)

        let inCap: AVAudioFrameCount = 65_536
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: inCap),
              let outBuf = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: AVAudioFrameCount(Double(inCap) * sampleRate / src.sampleRate) + 1024) else {
            throw AudioDecodeError.conversionFailed("your Mac ran out of memory")
        }
        var readError: Error?
        var eof = false
        while true {
            outBuf.frameLength = 0
            var err: NSError?
            let status = converter.convert(to: outBuf, error: &err) { _, outStatus in
                if eof { outStatus.pointee = .endOfStream; return nil }
                do {
                    try file.read(into: inBuf, frameCount: inCap)
                } catch {
                    readError = error
                    eof = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inBuf.frameLength == 0 {
                    eof = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuf
            }
            if let err { throw AudioDecodeError.conversionFailed(err.localizedDescription) }
            let n = Int(outBuf.frameLength)
            if n > 0, let ch = outBuf.floatChannelData {
                left.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n))
                right.append(contentsOf: UnsafeBufferPointer(start: ch[1], count: n))
            }
            if totalIn > 0 { progress?(min(1, Double(file.framePosition) / Double(totalIn))) }
            if status == .endOfStream || status == .error || (eof && n == 0) { break }
        }
        if let readError, left.isEmpty { throw AudioDecodeError.conversionFailed(readError.localizedDescription) }
        if left.isEmpty { throw AudioDecodeError.conversionFailed("the file has no sound in it") }
        return StereoAudio(left: left, right: right, sampleRate: sampleRate)
    }
}

/// Title / artist / artwork from file metadata (ID3, iTunes, Vorbis comments via AVFoundation).
public struct TrackMetadata: Sendable {
    public var title: String?
    public var artist: String?
    public var artwork: Data?

    public static func load(from url: URL) async -> TrackMetadata {
        let asset = AVURLAsset(url: url)
        var meta = TrackMetadata()
        guard let items = try? await asset.load(.commonMetadata) else { return meta }
        for item in items {
            guard let key = item.commonKey else { continue }
            switch key {
            case .commonKeyTitle: meta.title = try? await item.load(.stringValue)
            case .commonKeyArtist: meta.artist = try? await item.load(.stringValue)
            case .commonKeyArtwork: meta.artwork = try? await item.load(.dataValue)
            default: break
            }
        }
        if meta.title?.trimmingCharacters(in: .whitespaces).isEmpty ?? true { meta.title = nil }
        if meta.artist?.trimmingCharacters(in: .whitespaces).isEmpty ?? true { meta.artist = nil }
        return meta
    }
}
