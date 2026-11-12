import Foundation

/// Wraps AAC frames taken out of an ADTS stream (what YouTube's audio-only HLS segments carry) in an MP4
/// audio file, so `AVAudioFile` can read it. Written front to back: `ftyp`, `mdat`, then `moov`.
nonisolated final class AACFileWriter {
    enum WriteError: Error { case noAudio, tooBig }

    struct Format: Equatable, Sendable {
        var sampleRate: Int
        var channels: Int
        /// 1 = AAC Main, 2 = AAC-LC, …
        var objectType: Int
        var sampleRateIndex: Int
    }

    struct ADTSHeader: Equatable {
        var headerLength: Int
        var frameLength: Int
        var format: Format
    }

    static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
    static let samplesPerFrame = 1024

    private let handle: FileHandle
    private let mdatHeaderOffset: UInt64
    private var pending = [UInt8]()
    private var frameSizes = [UInt32]()
    private var payloadBytes: UInt64 = 0
    private(set) var format: Format?

    var frameCount: Int { frameSizes.count }

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: url)
        var head = Data()
        head.append(Self.box("ftyp", Self.join(Self.ascii("M4A "), Self.be32(0), Self.ascii("M4A "), Self.ascii("mp42"), Self.ascii("isom"))))
        mdatHeaderOffset = UInt64(head.count)
        head.append(Self.join(Self.be32(0), Self.ascii("mdat")))
        try handle.write(contentsOf: head)
    }

    func close() { try? handle.close() }

    // MARK: ADTS

    /// The ADTS header at `offset`, or nil if there isn't a valid one there.
    static func parseADTS(_ b: [UInt8], at offset: Int) -> ADTSHeader? {
        guard offset + 7 <= b.count, b[offset] == 0xFF, b[offset + 1] & 0xF6 == 0xF0 else { return nil }
        let protectionAbsent = b[offset + 1] & 1 == 1
        let objectType = Int(b[offset + 2] >> 6) + 1
        let sfIndex = Int((b[offset + 2] >> 2) & 0x0F)
        guard sfIndex < sampleRates.count else { return nil }
        let channels = Int(((b[offset + 2] & 1) << 2) | (b[offset + 3] >> 6))
        let frameLength = (Int(b[offset + 3] & 3) << 11) | (Int(b[offset + 4]) << 3) | Int(b[offset + 5] >> 5)
        let headerLength = protectionAbsent ? 7 : 9
        guard channels > 0, frameLength > headerLength else { return nil }
        return ADTSHeader(headerLength: headerLength, frameLength: frameLength,
                          format: Format(sampleRate: sampleRates[sfIndex], channels: channels, objectType: objectType,
                                         sampleRateIndex: sfIndex))
    }

    /// Length of an ID3v2 tag that starts at `offset` (0 when there is none).
    static func id3Length(_ b: [UInt8], at offset: Int) -> Int {
        guard offset + 10 <= b.count, b[offset] == 0x49, b[offset + 1] == 0x44, b[offset + 2] == 0x33,
              b[offset + 6] < 0x80, b[offset + 7] < 0x80, b[offset + 8] < 0x80, b[offset + 9] < 0x80 else { return 0 }
        let size = (Int(b[offset + 6]) << 21) | (Int(b[offset + 7]) << 14) | (Int(b[offset + 8]) << 7) | Int(b[offset + 9])
        let footer = b[offset + 5] & 0x10 != 0 ? 10 : 0
        return 10 + size + footer
    }

    /// Takes the next piece of the stream (an HLS segment). Frames that straddle two pieces are kept for the next call.
    func append(_ piece: Data) throws {
        var bytes = pending
        bytes.append(contentsOf: piece)
        var i = 0
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        scan: while i < bytes.count {
            let tag = Self.id3Length(bytes, at: i)
            if tag > 0 {
                if i + tag > bytes.count { break scan }
                i += tag
                continue
            }
            guard let header = Self.parseADTS(bytes, at: i) else {
                if bytes.count - i < 10 { break scan }
                i += 1   // not a frame start: resynchronise
                continue
            }
            if i + header.frameLength > bytes.count { break scan }
            if format == nil { format = header.format }
            let start = i + header.headerLength
            let end = i + header.frameLength
            out.append(contentsOf: bytes[start..<end])
            frameSizes.append(UInt32(end - start))
            i = end
        }
        pending = Array(bytes[i...])
        if !out.isEmpty {
            try handle.write(contentsOf: out)
            payloadBytes += UInt64(out.count)
        }
    }

    /// Patches the `mdat` size and appends the `moov` index. Returns the duration in seconds.
    @discardableResult
    func finish() throws -> Double {
        defer { close() }
        guard let format, !frameSizes.isEmpty else { throw WriteError.noAudio }
        guard payloadBytes + 8 < UInt64(UInt32.max) else { throw WriteError.tooBig }
        try handle.seek(toOffset: mdatHeaderOffset)
        try handle.write(contentsOf: Self.be32(UInt32(payloadBytes + 8)))
        try handle.seekToEnd()
        let chunkOffset = UInt32(mdatHeaderOffset + 8)
        try handle.write(contentsOf: Self.moov(format: format, frameSizes: frameSizes, chunkOffset: chunkOffset))
        return Double(frameSizes.count * Self.samplesPerFrame) / Double(format.sampleRate)
    }

    // MARK: Boxes

    static func moov(format: Format, frameSizes: [UInt32], chunkOffset: UInt32) -> Data {
        let count = UInt32(frameSizes.count)
        let samples = count * UInt32(samplesPerFrame)
        let rate = UInt32(format.sampleRate)
        let matrix: [UInt32] = [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000]

        var mvhd = join(be32(0), be32(0), be32(rate), be32(samples), be32(0x0001_0000), be16(0x0100), be16(0), Data(count: 8))
        for m in matrix { mvhd += be32(m) }
        mvhd += join(Data(count: 24), be32(2))

        var tkhd = join(be32(0), be32(0), be32(1), be32(0), be32(samples), Data(count: 8))
        tkhd += join(be16(0), be16(0), be16(0x0100), be16(0))
        for m in matrix { tkhd += be32(m) }
        tkhd += join(be32(0), be32(0))

        let mdhd = join(be32(0), be32(0), be32(rate), be32(samples), be16(0x55C4), be16(0))
        let hdlr = join(be32(0), ascii("soun"), Data(count: 12), Data("SoundHandler".utf8), Data([0]))
        let dinf = box("dinf", fullBox("dref", join(be32(1), fullBox("url ", flags: 1, Data()))))

        // AudioSpecificConfig: object type (5 bits), rate index (4), channels (4), 3 zero bits.
        let asc = UInt16(format.objectType << 11 | format.sampleRateIndex << 7 | format.channels << 3)
        let decoderSpecific = join(Data([0x05, 0x02]), be16(asc))
        let decoderConfig = join(Data([0x04, UInt8(13 + decoderSpecific.count), 0x40, 0x15, 0, 0, 0]), be32(0), be32(0), decoderSpecific)
        let esDescriptor = join(Data([0x03, UInt8(3 + decoderConfig.count + 3), 0, 0, 0]), decoderConfig, Data([0x06, 0x01, 0x02]))
        let esds = fullBox("esds", esDescriptor)
        let entryHead = join(Data(count: 6), be16(1), Data(count: 8), be16(UInt16(format.channels)), be16(16), be16(0), be16(0))
        let mp4a = box("mp4a", join(entryHead, be32(UInt32(min(format.sampleRate, 65535)) << 16), esds))
        let stsd = fullBox("stsd", join(be32(1), mp4a))
        let stts = fullBox("stts", join(be32(1), be32(count), be32(UInt32(samplesPerFrame))))
        let stsc = fullBox("stsc", join(be32(1), be32(1), be32(count), be32(1)))
        var stszBody = join(be32(0), be32(count))
        stszBody.reserveCapacity(8 + frameSizes.count * 4)
        for size in frameSizes { stszBody += be32(size) }
        let stsz = fullBox("stsz", stszBody)
        let stco = fullBox("stco", join(be32(1), be32(chunkOffset)))
        let stbl = box("stbl", join(stsd, stts, stsc, stsz, stco))
        let minf = box("minf", join(fullBox("smhd", join(be16(0), be16(0))), dinf, stbl))
        let mdia = box("mdia", join(fullBox("mdhd", mdhd), fullBox("hdlr", hdlr), minf))
        let trak = box("trak", join(fullBox("tkhd", flags: 3, tkhd), mdia))
        return box("moov", join(fullBox("mvhd", mvhd), trak))
    }

    fileprivate static func join(_ parts: Data...) -> Data {
        var out = Data()
        for p in parts { out.append(p) }
        return out
    }

    static func box(_ type: String, _ payload: Data) -> Data {
        join(be32(UInt32(8 + payload.count)), ascii(type), payload)
    }

    static func fullBox(_ type: String, flags: UInt32 = 0, _ payload: Data) -> Data {
        box(type, join(be32(flags & 0x00FF_FFFF), payload))
    }

    private static func ascii(_ s: String) -> Data { Data(s.utf8) }
    private static func be32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
    private static func be16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
}
