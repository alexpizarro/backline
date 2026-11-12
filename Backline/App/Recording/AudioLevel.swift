import Accelerate
import Foundation

/// Level maths shared by the microphone recorder and the broadcast extension. Pure functions, no state.
nonisolated enum AudioLevel {
    /// Digital silence is reported as this instead of -infinity.
    static let floorDB: Float = -120
    /// The meter shows this range; everything quieter sits at the bottom.
    static let meterFloorDB: Float = -60

    /// Linear amplitude (0…1) to dBFS, clamped at `floorDB`.
    static func db(fromLinear x: Float) -> Float {
        guard x > 1e-6 else { return floorDB }
        return max(floorDB, 20 * log10(x))
    }

    static func linear(fromDB db: Float) -> Float { powf(10, db / 20) }

    /// Peak (max |x|) and RMS of a block of samples, in linear amplitude.
    static func peakAndRMS(_ samples: UnsafePointer<Float>, count: Int) -> (peak: Float, rms: Float) {
        guard count > 0 else { return (0, 0) }
        var peak: Float = 0
        var rms: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(count))
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
        return (peak, rms)
    }

    /// Peak and RMS across several channels (the loudest channel wins; RMS is the mean power).
    static func peakAndRMS(channels: [UnsafePointer<Float>], frames: Int) -> (peak: Float, rms: Float) {
        guard frames > 0, !channels.isEmpty else { return (0, 0) }
        var peak: Float = 0
        var power: Float = 0
        for ch in channels {
            let (p, r) = peakAndRMS(ch, count: frames)
            peak = max(peak, p)
            power += r * r
        }
        return (peak, sqrtf(power / Float(channels.count)))
    }

    /// 0…1 position on the meter for a dBFS value, linear in dB between `meterFloorDB` and 0.
    static func meterFraction(db: Float, floor: Float = meterFloorDB) -> Float {
        guard db.isFinite else { return 0 }
        return min(1, max(0, (db - floor) / -floor))
    }
}

/// How a level meter moves: it jumps up quickly and falls back slowly, and a thin marker holds the
/// recent maximum. Time-based, so it looks the same at 60 and 120 Hz.
nonisolated struct MeterBallistics: Equatable {
    var value: Float = 0
    var hold: Float = 0
    private var holdUntil: Double = 0

    static let attackSeconds = 0.025
    static let releaseSeconds = 0.32
    static let holdSeconds = 1.1
    static let holdFallPerSecond: Float = 0.7

    /// Moves toward `target` (0…1) over `dt` seconds. `now` is any monotonic clock in seconds.
    mutating func advance(toward target: Float, dt: Double, now: Double) {
        let tau = target > value ? Self.attackSeconds : Self.releaseSeconds
        let k = Float(1 - exp(-max(0, dt) / tau))
        value += (target - value) * k
        if value >= hold {
            hold = value
            holdUntil = now + Self.holdSeconds
        } else if now > holdUntil {
            hold = max(value, hold - Self.holdFallPerSecond * Float(dt))
        }
    }

    mutating func reset() { self = MeterBallistics() }
}

/// The last N meter readings, newest last. Drives the scrolling bars under the level meter.
nonisolated struct LevelHistory: Equatable {
    private(set) var values: [Float]
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        values = Array(repeating: 0, count: self.capacity)
    }

    mutating func append(_ v: Float) {
        values.removeFirst()
        values.append(min(1, max(0, v)))
    }

    mutating func clear() { values = Array(repeating: 0, count: capacity) }
}
