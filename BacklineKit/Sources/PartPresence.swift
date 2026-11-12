import Accelerate
import Foundation

/// How much a separated part is really in the song, measured against the whole mix (U03,
/// `docs/release/part-detection.md`). Separation models always output every part, so a song with no
/// guitar still gets a guitar part made of near-silence or of other instruments' bleed.
public struct PartLevel: Codable, Hashable, Sendable {
    /// Whole-song level of the part against the mix, dB.
    public var share: Float
    /// Share of half-second frames (where the mix is above −50 dBFS) in which the part is within 20 dB of the mix.
    public var active: Float
    /// The part's level against the mix in its loudest 5 % of those frames, dB.
    public var peak: Float

    public init(share: Float, active: Float, peak: Float) {
        self.share = share; self.active = active; self.peak = peak
    }
}

public enum PartPresence {
    // Trial thresholds from 7 measured songs: the highest fake part scored active 0.14, the lowest real one 0.20.
    public static let presentActive: Float = 0.18
    public static let presentPeak: Float = -12
    /// After a lead/rhythm split, each half must be at least this active or the split is dropped.
    public static let splitHalfActive: Float = 0.15
    /// Below this whole-song level a guitar is folded into Other (silent, not just quiet).
    public static let silentShare: Float = -40
    /// Half a second at 44.1 kHz.
    public static let frame = 22_050
    static let mixFloorDB: Float = -50
    static let withinDB: Float = -20

    public static func isPresent(_ l: PartLevel) -> Bool { l.active >= presentActive || l.peak >= presentPeak }

    /// Mean square of both channels over `range`.
    public static func meanSquare(_ a: StereoAudio, _ range: Range<Int>) -> Float {
        guard !range.isEmpty else { return 0 }
        var l: Float = 0, r: Float = 0
        a.left.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress! + range.lowerBound, 1, &l, vDSP_Length(range.count)) }
        a.right.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress! + range.lowerBound, 1, &r, vDSP_Length(range.count)) }
        return (l + r) / 2
    }

    /// Per-frame mean squares of a whole part (the shape `level(part:mix:)` works on).
    public static func frames(_ a: StereoAudio) -> [Float] {
        stride(from: 0, to: a.frameCount, by: frame).compactMap { s in
            let c = min(frame, a.frameCount - s)
            return c >= frame / 4 ? meanSquare(a, s..<(s + c)) : nil
        }
    }

    /// Whether the part is active in each frame: the mix above −50 dBFS and the part within 20 dB of it.
    public static func activeFrames(part: [Float], mix: [Float]) -> [Bool] {
        (0..<min(part.count, mix.count)).map { isActive(part: part[$0], mix: mix[$0]) }
    }

    public static func isActive(part: Float, mix: Float) -> Bool {
        let m = 10 * log10(max(mix, 1e-20))
        return m >= mixFloorDB && 10 * log10(max(part, 1e-20)) - m >= withinDB
    }

    public static func measure(part: StereoAudio, mix: StereoAudio) -> PartLevel {
        level(part: frames(part), mix: frames(mix))
    }

    /// The level of a part from its per-frame mean squares and the mix's (same frames). Works on numbers
    /// streamed from disk too, so a stored song can be measured without loading it whole.
    public static func level(part: [Float], mix: [Float]) -> PartLevel {
        let n = min(part.count, mix.count)
        guard n > 0 else { return PartLevel(share: -120, active: 0, peak: -120) }
        func db(_ x: Float) -> Float { 10 * log10(max(x, 1e-20)) }
        let share = db(part[..<n].reduce(0, +)) - db(mix[..<n].reduce(0, +))
        var diffs: [Float] = []
        diffs.reserveCapacity(n)
        for i in 0..<n where db(mix[i]) >= mixFloorDB {
            diffs.append(db(part[i]) - db(mix[i]))
        }
        guard !diffs.isEmpty else { return PartLevel(share: share, active: 0, peak: -120) }
        let active = Float(diffs.filter { $0 >= withinDB }.count) / Float(diffs.count)
        diffs.sort()
        let peak = diffs[min(diffs.count - 1, Int((Float(diffs.count - 1) * 0.95).rounded()))]
        return PartLevel(share: share, active: active, peak: peak)
    }
}
