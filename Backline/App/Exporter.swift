import AVFoundation
import BacklineKit
import Darwin
import Foundation

nonisolated struct ExportJob: Sendable {
    var settings: PlaybackEngine.ExportSettings
    var format: ExportFormat
    var url: URL
    var title: String
    var artist: String?
}

nonisolated enum ExportError: LocalizedError {
    case mp3Unavailable
    case encoder(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .mp3Unavailable: "Backline can't make MP3 files right now. Try WAV or AIFF."
        case .encoder(let m): m
        case .cancelled: "Cancelled"
        }
    }
}

nonisolated enum Exporter {
    /// Offline render of the current mix (mute/solo/volume/speed/pitch; loop ignored) to `job.url`.
    static func run(_ job: ExportJob, engine: PlaybackEngine, progress: @escaping @Sendable (Double) -> Void) throws {
        let total = max(1, engine.exportLength(job.settings))
        // A sandboxed save panel grants access to the chosen file only, not its folder, so the scratch
        // file goes in the system's item-replacement directory for that volume (always writable).
        let fm = FileManager.default
        let scratch = (try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: job.url, create: true))
            ?? fm.temporaryDirectory
        let tmp = scratch.appendingPathComponent("\(UUID().uuidString).\(job.format.fileExtension)")
        defer {
            try? fm.removeItem(at: tmp)
            if scratch != fm.temporaryDirectory { try? fm.removeItem(at: scratch) }
        }
        switch job.format {
        case .wav, .aiff: try writePCM(job, engine: engine, to: tmp, total: total, progress: progress)
        case .mp3: try writeMP3(job, engine: engine, to: tmp, total: total, progress: progress)
        }
        if FileManager.default.fileExists(atPath: job.url.path) {
            _ = try FileManager.default.replaceItemAt(job.url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: job.url)
        }
    }

    private static func writePCM(_ job: ExportJob, engine: PlaybackEngine, to url: URL, total: Int64,
                                 progress: @escaping @Sendable (Double) -> Void) throws {
        let sr = engine.sampleRate
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: job.format == .aiff,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 2, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4096)!
        var written: Int64 = 0
        var writeError: Error?
        engine.export(job.settings) { l, r, n in
            buf.floatChannelData![0].update(from: l, count: n)
            buf.floatChannelData![1].update(from: r, count: n)
            buf.frameLength = AVAudioFrameCount(n)
            do { try file.write(from: buf) } catch { writeError = error; return false }
            written += Int64(n)
            if written % (1 << 16) < Int64(n) { progress(Double(written) / Double(total)) }
            return true
        }
        if let writeError { throw writeError }
        progress(1)
    }

    // MARK: MP3 via LAME (LGPL, loaded dynamically from the app bundle so it stays user-replaceable)

    private typealias LameInit = @convention(c) () -> OpaquePointer?
    private typealias LameSetInt = @convention(c) (OpaquePointer?, Int32) -> Int32
    private typealias LameInitParams = @convention(c) (OpaquePointer?) -> Int32
    private typealias LameEncodeFloat = @convention(c) (OpaquePointer?, UnsafePointer<Float>?, UnsafePointer<Float>?, Int32,
                                                         UnsafeMutablePointer<UInt8>?, Int32) -> Int32
    private typealias LameFlush = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt8>?, Int32) -> Int32
    private typealias LameClose = @convention(c) (OpaquePointer?) -> Int32
    private typealias LameTag = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt8>?, Int) -> Int
    private typealias Id3Init = @convention(c) (OpaquePointer?) -> Void
    private typealias Id3SetStr = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Void

    /// Only the copy bundled inside Backline — never a system or Homebrew install, so the app is
    /// self-contained and can't be affected by (or affect) other software on the Mac.
    private static func lameHandle() -> UnsafeMutableRawPointer? {
        guard let p = Bundle.main.privateFrameworksURL?.appendingPathComponent("libmp3lame.0.dylib").path else { return nil }
        return dlopen(p, RTLD_NOW | RTLD_LOCAL)
    }

    private static func sym<T>(_ h: UnsafeMutableRawPointer, _ name: String, as: T.Type) throws -> T {
        guard let s = dlsym(h, name) else { throw ExportError.mp3Unavailable }
        return unsafeBitCast(s, to: T.self)
    }

    static var mp3Available: Bool { lameHandle() != nil }

    private static func writeMP3(_ job: ExportJob, engine: PlaybackEngine, to url: URL, total: Int64,
                                 progress: @escaping @Sendable (Double) -> Void) throws {
        guard let h = lameHandle() else { throw ExportError.mp3Unavailable }
        let lameInit = try sym(h, "lame_init", as: LameInit.self)
        let setInSR = try sym(h, "lame_set_in_samplerate", as: LameSetInt.self)
        let setChannels = try sym(h, "lame_set_num_channels", as: LameSetInt.self)
        let setVBR = try sym(h, "lame_set_VBR", as: LameSetInt.self)
        let setVBRq = try sym(h, "lame_set_VBR_quality" , as: (@convention(c) (OpaquePointer?, Float) -> Int32).self)
        let setQuality = try sym(h, "lame_set_quality", as: LameSetInt.self)
        let initParams = try sym(h, "lame_init_params", as: LameInitParams.self)
        let encode = try sym(h, "lame_encode_buffer_ieee_float", as: LameEncodeFloat.self)
        let flush = try sym(h, "lame_encode_flush", as: LameFlush.self)
        let close = try sym(h, "lame_close", as: LameClose.self)
        let getTag = try sym(h, "lame_get_lametag_frame", as: LameTag.self)
        let id3Init = try sym(h, "id3tag_init", as: Id3Init.self)
        let id3Title = try sym(h, "id3tag_set_title", as: Id3SetStr.self)
        let id3Artist = try sym(h, "id3tag_set_artist", as: Id3SetStr.self)

        guard let gf = lameInit() else { throw ExportError.encoder("Couldn't make the MP3. Try WAV or AIFF.") }
        defer { _ = close(gf) }
        _ = setInSR(gf, Int32(engine.sampleRate))
        _ = setChannels(gf, 2)
        _ = setVBR(gf, 4)            // vbr_mtrh (the default VBR mode)
        _ = setVBRq(gf, 0.5)         // ≈ V0, ~245 kbps
        _ = setQuality(gf, 2)
        id3Init(gf)
        job.title.withCString { id3Title(gf, $0) }
        (job.artist ?? "Backline").withCString { id3Artist(gf, $0) }
        guard initParams(gf) >= 0 else { throw ExportError.encoder("Couldn't make the MP3. Try WAV or AIFF.") }

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }
        var out = [UInt8](repeating: 0, count: 1 << 16)
        var written: Int64 = 0
        var failure: Error?
        engine.export(job.settings) { l, r, n in
            let bytes = out.withUnsafeMutableBufferPointer { encode(gf, l, r, Int32(n), $0.baseAddress, Int32($0.count)) }
            if bytes < 0 { failure = ExportError.encoder("Couldn't make the MP3 (code \(bytes)). Try WAV or AIFF."); return false }
            if bytes > 0 { fh.write(Data(out[0..<Int(bytes)])) }
            written += Int64(n)
            if written % (1 << 16) < Int64(n) { progress(Double(written) / Double(total)) }
            return true
        }
        if let failure { throw failure }
        let tail = out.withUnsafeMutableBufferPointer { flush(gf, $0.baseAddress, Int32($0.count)) }
        if tail > 0 { fh.write(Data(out[0..<Int(tail)])) }
        // Xing/LAME tag so players show the right duration for VBR.
        var tag = [UInt8](repeating: 0, count: 4096)
        let tagLen = tag.withUnsafeMutableBufferPointer { getTag(gf, $0.baseAddress, $0.count) }
        if tagLen > 0 && tagLen <= tag.count {
            // The tag replaces the first frame after the ID3v2 header.
            try? fh.synchronize()
            if let data = try? Data(contentsOf: url), let offset = firstFrameOffset(data) {
                try fh.seek(toOffset: UInt64(offset))
                fh.write(Data(tag[0..<tagLen]))
            }
        }
        progress(1)
    }

    /// Byte offset of the first MPEG frame (after an optional ID3v2 tag).
    private static func firstFrameOffset(_ d: Data) -> Int? {
        var i = 0
        if d.count > 10, d[0] == 0x49, d[1] == 0x44, d[2] == 0x33 {
            let size = (Int(d[6]) << 21) | (Int(d[7]) << 14) | (Int(d[8]) << 7) | Int(d[9])
            i = 10 + size
        }
        while i + 1 < d.count {
            if d[i] == 0xFF && (d[i + 1] & 0xE0) == 0xE0 { return i }
            i += 1
        }
        return nil
    }
}
