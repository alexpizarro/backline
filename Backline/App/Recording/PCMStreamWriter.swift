import AVFoundation
import CoreMedia
import Foundation

/// Streams audio of any PCM format to a 44.1 kHz stereo Float32 CAF on disk, one buffer at a time, with no
/// accumulation (the broadcast extension has about 50 MB). A CAF without a finished header still plays to
/// its last frame, so a killed process loses nothing that was already written.
///
/// Thread model: every call takes `lock`, so the audio queue can append while the UI polls `snapshot`.
/// It does file I/O under the lock, which is fine for the non-real-time queues that feed it (an
/// `AVAudioEngine` tap, ReplayKit's sample queue).
nonisolated final class PCMStreamWriter: @unchecked Sendable {
    enum WriterError: LocalizedError {
        case closed
        case cantConvert
        case badSampleBuffer
        var errorDescription: String? {
            switch self {
            case .closed: "The recording was already closed."
            case .cantConvert: "The sound is in a type Backline can't record."
            case .badSampleBuffer: "The system sent audio Backline couldn't read."
            }
        }
    }

    static let sampleRate = 44_100.0
    static var outputFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
    }

    let url: URL
    private let soundThresholdDB: Float
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var stats = RecordingStats()
    private var meterPeak: Float = 0
    private var meterRMS: Float = 0

    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?
    private var convertedBuffer: AVAudioPCMBuffer?
    private var sampleBufferScratch: AVAudioPCMBuffer?

    init(url: URL, soundThresholdDB: Float) throws {
        self.url = url
        self.soundThresholdDB = soundThresholdDB
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        stats.sampleRate = Self.sampleRate
    }

    // MARK: Appending

    func append(_ buffer: AVAudioPCMBuffer) throws {
        lock.lock(); defer { lock.unlock() }
        try appendLocked(buffer)
    }

    /// For ReplayKit: copies the sample buffer's PCM into a reusable buffer, converts and writes it.
    func append(sampleBuffer sb: CMSampleBuffer) throws {
        lock.lock(); defer { lock.unlock() }
        guard CMSampleBufferIsValid(sb), CMSampleBufferDataIsReady(sb), let desc = CMSampleBufferGetFormatDescription(sb) else {
            throw WriterError.badSampleBuffer
        }
        let n = CMSampleBufferGetNumSamples(sb)
        guard n > 0 else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: desc)
        if sampleBufferScratch == nil || sampleBufferScratch!.format != format || Int(sampleBufferScratch!.frameCapacity) < n {
            sampleBufferScratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(n, 4096)))
        }
        guard let pcm = sampleBufferScratch else { throw WriterError.badSampleBuffer }
        pcm.frameLength = AVAudioFrameCount(n)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: pcm.mutableAudioBufferList)
        guard status == noErr else { throw WriterError.badSampleBuffer }
        try appendLocked(pcm)
    }

    private func appendLocked(_ input: AVAudioPCMBuffer) throws {
        guard let file else { throw WriterError.closed }
        guard input.frameLength > 0 else { return }
        stats.buffersReceived += 1
        let out = try convert(input)
        guard out.frameLength > 0 else { return }
        measure(out)
        try file.write(from: out)
        stats.framesWritten += Int(out.frameLength)
    }

    /// Returns `input` itself when it is already 44.1 kHz stereo Float32 non-interleaved.
    private func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let target = Self.outputFormat
        if input.format.sampleRate == target.sampleRate, input.format.channelCount == 2,
           input.format.commonFormat == .pcmFormatFloat32, !input.format.isInterleaved {
            return input
        }
        if converter == nil || converterSource != input.format {
            guard let c = AVAudioConverter(from: input.format, to: target) else { throw WriterError.cantConvert }
            // Mono plays on both sides; a multichannel interface contributes its first two inputs.
            if input.format.channelCount == 1 { c.channelMap = [0, 0] }
            else if input.format.channelCount > 2 { c.channelMap = [0, 1] }
            c.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            converter = c
            converterSource = input.format
        }
        guard let converter else { throw WriterError.cantConvert }
        let needed = AVAudioFrameCount(Double(input.frameLength) * target.sampleRate / input.format.sampleRate) + 1024
        if convertedBuffer == nil || convertedBuffer!.frameCapacity < needed {
            convertedBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: needed)
        }
        guard let out = convertedBuffer else { throw WriterError.cantConvert }
        out.frameLength = 0
        let feed = OneShot(input)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if let b = feed.take() { outStatus.pointee = .haveData; return b }
            outStatus.pointee = .noDataNow
            return nil
        }
        if status == .error { throw error ?? WriterError.cantConvert }
        return out
    }

    /// The sample-rate converter holds back a few milliseconds of audio until it is told the stream ended.
    private func flushConverter(into file: AVAudioFile) {
        guard let converter, let out = convertedBuffer else { return }
        out.frameLength = 0
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }
        guard status != .error, out.frameLength > 0 else { return }
        measure(out)
        if (try? file.write(from: out)) != nil { stats.framesWritten += Int(out.frameLength) }
    }

    /// Hands the converter its one input buffer exactly once.
    private final class OneShot: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ b: AVAudioPCMBuffer) { buffer = b }
        func take() -> AVAudioPCMBuffer? { defer { buffer = nil }; return buffer }
    }

    private func measure(_ out: AVAudioPCMBuffer) {
        guard let data = out.floatChannelData else { return }
        let frames = Int(out.frameLength)
        let (peak, rms) = AudioLevel.peakAndRMS(channels: [UnsafePointer(data[0]), UnsafePointer(data[1])], frames: frames)
        meterPeak = max(meterPeak, peak)
        meterRMS = rms
        let peakDB = AudioLevel.db(fromLinear: peak)
        if peak > 0 { stats.everNonZero = true }
        stats.loudestPeakDB = max(stats.loudestPeakDB, peakDB)
        if peakDB > soundThresholdDB {
            if stats.firstSoundFrame == nil { stats.firstSoundFrame = stats.framesWritten }
            stats.lastSoundFrame = stats.framesWritten + frames
        }
    }

    // MARK: Reading and closing

    /// The numbers so far. `resetPeak` clears the peak-hold so the next read reports the loudest sample since this one.
    func snapshot(resetPeak: Bool = true) -> RecordingStats {
        lock.lock(); defer { lock.unlock() }
        var s = stats
        s.peakDB = AudioLevel.db(fromLinear: meterPeak)
        s.rmsDB = AudioLevel.db(fromLinear: meterRMS)
        if resetPeak { meterPeak = 0 }
        return s
    }

    /// Closes the file (idempotent) and returns the final numbers.
    @discardableResult
    func finish() -> RecordingStats {
        lock.lock(); defer { lock.unlock() }
        if let f = file {
            flushConverter(into: f)
            f.close()
            file = nil
        }
        var s = stats
        s.peakDB = AudioLevel.db(fromLinear: meterPeak)
        s.rmsDB = AudioLevel.db(fromLinear: meterRMS)
        return s
    }

    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return file != nil }
}
