import CLame
import Foundation

public enum Mp3Error: LocalizedError {
    case initFailed
    case encodeFailed(Int32)
    public var errorDescription: String? {
        switch self {
        case .initFailed: "Couldn't make the MP3. Try WAV or AIFF."
        case .encodeFailed(let code): "Couldn't make the MP3 (code \(code)). Try WAV or AIFF."
        }
    }
}

/// VBR MP3 (about V0) from planar float stereo, with an ID3 tag and the Xing/LAME header so players show
/// the right duration.
public final class Mp3Encoder {
    private var gf: OpaquePointer?
    private var out = [UInt8](repeating: 0, count: 1 << 17)

    public init(sampleRate: Int, title: String, artist: String) throws {
        guard let gf = lame_init() else { throw Mp3Error.initFailed }
        self.gf = gf
        lame_set_in_samplerate(gf, Int32(sampleRate))
        lame_set_num_channels(gf, 2)
        lame_set_VBR(gf, vbr_mtrh)
        lame_set_VBR_quality(gf, 0.5)       // ≈ V0
        lame_set_quality(gf, 2)
        id3tag_init(gf)
        id3tag_add_v2(gf)
        title.withCString { id3tag_set_title(gf, $0) }
        artist.withCString { id3tag_set_artist(gf, $0) }
        guard lame_init_params(gf) >= 0 else { throw Mp3Error.initFailed }
    }

    deinit { if let gf { lame_close(gf) } }

    /// The ID3v2 tag, written first.
    public func id3v2Header() -> Data {
        let size = lame_get_id3v2_tag(gf, nil, 0)
        guard size > 0 else { return Data() }
        var buf = [UInt8](repeating: 0, count: size)
        let n = buf.withUnsafeMutableBufferPointer { lame_get_id3v2_tag(gf, $0.baseAddress, $0.count) }
        return Data(buf[0..<min(n, size)])
    }

    public func encode(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) throws -> Data {
        let n = out.withUnsafeMutableBufferPointer {
            lame_encode_buffer_ieee_float(gf, left, right, Int32(frames), $0.baseAddress, Int32($0.count))
        }
        if n < 0 { throw Mp3Error.encodeFailed(n) }
        return Data(out[0..<Int(n)])
    }

    public func finish() -> Data {
        let n = out.withUnsafeMutableBufferPointer { lame_encode_flush(gf, $0.baseAddress, Int32($0.count)) }
        return n > 0 ? Data(out[0..<Int(n)]) : Data()
    }

    /// The Xing/LAME frame that replaces the first frame of the finished file.
    public func infoTag() -> Data {
        var tag = [UInt8](repeating: 0, count: 8192)
        let n = tag.withUnsafeMutableBufferPointer { lame_get_lametag_frame(gf, $0.baseAddress, $0.count) }
        return n > 0 && n <= tag.count ? Data(tag[0..<n]) : Data()
    }
}
