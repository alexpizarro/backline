import Foundation

/// Live numbers about a recording in progress: written by the audio queue, read by the UI (or copied into
/// the broadcast status file). Frame positions are in the 44.1 kHz output file.
nonisolated struct RecordingStats: Equatable, Codable, Sendable {
    var sampleRate: Double = 44_100
    var framesWritten: Int = 0
    /// Audio buffers handed to the writer (a broadcast delivers none while nothing plays).
    var buffersReceived: Int = 0
    /// Loudest sample since the meter was last read (so a 15 Hz UI never misses a short peak).
    var peakDB: Float = AudioLevel.floorDB
    var rmsDB: Float = AudioLevel.floorDB
    var loudestPeakDB: Float = AudioLevel.floorDB
    /// False while every sample so far was exactly zero: a muted source, or protected audio.
    var everNonZero = false
    var firstSoundFrame: Int?
    var lastSoundFrame: Int?

    var seconds: Double { sampleRate > 0 ? Double(framesWritten) / sampleRate : 0 }
    var firstSoundAt: Double? { firstSoundFrame.map { Double($0) / sampleRate } }
    var lastSoundAt: Double? { lastSoundFrame.map { Double($0) / sampleRate } }
    /// Seconds between the first and last audible sample.
    var soundDuration: Double {
        guard let a = firstSoundAt, let b = lastSoundAt else { return 0 }
        return max(0, b - a)
    }
    /// Seconds since the last audible block (0 when nothing has been heard yet).
    var silenceSinceLastSound: Double {
        guard let last = lastSoundAt else { return 0 }
        return max(0, seconds - last)
    }
}

/// What the app tells the user about how the take is going.
nonisolated enum RecordingQuality: Equatable, Sendable {
    /// Nothing audible yet (normal for the first seconds).
    case waitingForSound
    case good
    /// Sound was heard but it is faint: move the phone closer / turn the other app up.
    case faint
    /// Nothing audible after a while although signal is arriving.
    case tooQuiet
    /// Every sample is exactly zero: muted source, blocked or protected audio.
    case silent
}

/// Thresholds and decisions for a take, kept apart from the UI so they can be unit tested.
nonisolated enum RecordingHeuristics {
    /// A block louder than this counts as music rather than room noise (microphone) or silence (other app).
    static let micSoundThresholdDB: Float = -42
    static let appSoundThresholdDB: Float = -50
    /// After this many seconds without a sound above the threshold the take is "too quiet".
    static let tooQuietAfter = 8.0
    /// An app that delivers only zeros for this long is muted or protected.
    static let silentAfter = 5.0
    /// Sound was heard, but the loudest peak is below this once the take has run a while.
    static let faintPeakDB: Float = -24
    static let faintAfter = 15.0
    /// A take shorter than this (first to last sound) isn't a song.
    static let minimumSoundSeconds = 5.0
    /// Lead-in kept before the first sound and tail kept after the last, when trimming.
    static let leadSeconds = 0.4
    static let tailSeconds = 1.5
    static let maxSeconds = 20.0 * 60
    /// A broadcast ends itself after this much silence once a song has played (the app can't stop it).
    static let broadcastAutoStopSilence = 8.0
    static let broadcastAutoStopMinSound = 15.0

    static func quality(_ s: RecordingStats) -> RecordingQuality {
        if s.firstSoundFrame == nil {
            if !s.everNonZero, s.buffersReceived > 0, s.seconds >= silentAfter { return .silent }
            if s.everNonZero, s.seconds >= tooQuietAfter { return .tooQuiet }
            return .waitingForSound
        }
        if s.seconds >= faintAfter, s.loudestPeakDB < faintPeakDB { return .faint }
        return .good
    }

    /// The range of the file to keep, in seconds, or nil when the take holds no usable song.
    static func trimRange(_ s: RecordingStats) -> ClosedRange<Double>? {
        guard let first = s.firstSoundAt, let last = s.lastSoundAt, last - first >= minimumSoundSeconds else { return nil }
        return max(0, first - leadSeconds)...min(s.seconds, last + tailSeconds)
    }
}
