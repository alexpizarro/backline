import AVFoundation
import Foundation
import ObjCSafe

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
    /// Shorter than this is not a song: random bytes named `.mp3` "decode" to a few milliseconds of fake frames.
    static let minimumSeconds = 1.0

    /// `AVAudioFile` raises Objective-C exceptions for some damaged files (`framePosition`, `length`, `read`)
    /// instead of returning errors, and Swift cannot catch those: every such call goes through `BLTryObjC`.
    static func guarded<T>(_ body: () throws -> T) throws -> T {
        var result: Result<T, Error>?
        var raised: NSError?
        let completed = BLTryObjC({ result = Result { try body() } }, &raised)
        guard completed, let result else {
            throw AudioDecodeError.conversionFailed("the file is damaged (\(raised?.localizedDescription ?? "unreadable"))")
        }
        return try result.get()
    }

    public static let supportedExtensions: Set<String> = ["mp3", "wav", "wave", "aif", "aiff", "aifc", "m4a", "mp4", "aac", "flac", "caf", "alac", "mov", "m4v", "3gp"]

    public static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// The file's length in seconds without decoding it (nil when the file doesn't say).
    public static func duration(of url: URL) async -> Double? {
        guard let d = try? await AVURLAsset(url: url).load(.duration), d.isNumeric, d.seconds > 0 else { return nil }
        return d.seconds
    }

    /// How a file at another sample rate (48 kHz video and recordings) is brought to 44.1 kHz.
    struct Resampler: Equatable {
        var algorithm: String
        var quality: Int
        /// The mastering algorithm at low quality: the fastest setting that keeps everything up to 20 kHz. Against
        /// mastering at max it differs by a signal more than 140 dB below the music up to 20 kHz, and it is about
        /// 6 times faster (Big Rock as 48 kHz AAC, 231 s: 0.5 s against 3.5 s on this Mac). The normal algorithm
        /// is faster still but drops what is above about 17 kHz (64 dB at best up to 20 kHz), and mastering at the
        /// lowest quality also cuts the top (69 dB). AudioDecoderTests holds it to 90 dB.
        static let fast = Resampler(algorithm: AVSampleRateConverterAlgorithm_Mastering, quality: AVAudioQuality.low.rawValue)
        /// The slowest setting, used until 1.1. Kept so the test can compare against it.
        static let mastering = Resampler(algorithm: AVSampleRateConverterAlgorithm_Mastering, quality: AVAudioQuality.max.rawValue)
    }

    /// Decodes any Core Audio–readable file to 44.1 kHz stereo float32.
    public static func decode(_ url: URL, sampleRate: Double = 44_100,
                              progress: ((Double) -> Void)? = nil) throws -> StereoAudio {
        try decode(url, sampleRate: sampleRate, resampler: .fast, progress: progress)
    }

    static func decode(_ url: URL, sampleRate: Double, resampler: Resampler,
                       progress: ((Double) -> Void)?) throws -> StereoAudio {
        let file: AVAudioFile
        do { file = try guarded { try AVAudioFile(forReading: url) } } catch {
            // Video containers (QuickTime .mov, a saved reel) and some MP4s: read the audio track through AVAsset.
            // Its own message wins when it has one ("there is no sound in this file" for a silent video, R05).
            do {
                return try decodeAssetAudio(url, sampleRate: sampleRate, progress: progress)
            } catch let e as AudioDecodeError {
                if case .conversionFailed = e { throw e }
                throw AudioDecodeError.unsupported(url.pathExtension.uppercased())
            } catch {
                throw AudioDecodeError.unsupported(url.pathExtension.uppercased())
            }
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
        converter.sampleRateConverterAlgorithm = resampler.algorithm
        converter.sampleRateConverterQuality = resampler.quality

        let totalIn = try guarded { file.length }
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
                    try guarded { try file.read(into: inBuf, frameCount: inCap) }
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
            if totalIn > 0 { progress?(min(1, Double(try guarded { file.framePosition }) / Double(totalIn))) }
            if status == .endOfStream || status == .error || (eof && n == 0) { break }
        }
        if let readError, left.isEmpty { throw AudioDecodeError.conversionFailed(readError.localizedDescription) }
        if Double(left.count) < minimumSeconds * sampleRate { throw AudioDecodeError.conversionFailed("the file has no sound in it") }
        return StereoAudio(left: left, right: right, sampleRate: sampleRate)
    }
}

extension AudioDecoder {
    /// Decodes the first audio track of any AVFoundation container to 44.1 kHz stereo float32.
    static func decodeAssetAudio(_ url: URL, sampleRate: Double, progress: ((Double) -> Void)?) throws -> StereoAudio {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw AudioDecodeError.conversionFailed("there is no sound in this file")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioDecodeError.conversionFailed("the sound is in a type Backline can't use") }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioDecodeError.conversionFailed(reader.error?.localizedDescription ?? "the file couldn't be read")
        }
        let total = max(asset.duration.seconds, 0.001)
        var left = [Float](), right = [Float]()
        left.reserveCapacity(Int(total * sampleRate) + 4096)
        right.reserveCapacity(Int(total * sampleRate) + 4096)
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            guard status == kCMBlockBufferNoErr else { continue }
            let frames = data.count / 2
            left.append(contentsOf: (0..<frames).lazy.map { data[2 * $0] })
            right.append(contentsOf: (0..<frames).lazy.map { data[2 * $0 + 1] })
            progress?(min(1, Double(left.count) / sampleRate / total))
        }
        if reader.status == .failed { throw AudioDecodeError.conversionFailed(reader.error?.localizedDescription ?? "the file couldn't be read") }
        if Double(left.count) < minimumSeconds * sampleRate { throw AudioDecodeError.conversionFailed("the file has no sound in it") }
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
