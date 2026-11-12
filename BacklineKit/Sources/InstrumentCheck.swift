import AVFoundation
import Foundation
import SoundAnalysis

/// How often Apple's built-in sound classifier (`.version1`) hears guitar and keys: the share of 3 s windows
/// (50 % overlap) in which any label of the family scores at least 0.3 (U06, `docs/release/part-detection.md`).
public struct InstrumentShares: Codable, Hashable, Sendable {
    public var guitar: Float
    public var keys: Float
    public init(guitar: Float, keys: Float) { self.guitar = guitar; self.keys = keys }
}

/// Feeds audio to the classifier as it arrives (whole songs never need to be in memory) and counts windows.
public final class InstrumentListener: @unchecked Sendable {
    static let guitarLabels = ["guitar", "electric_guitar", "acoustic_guitar", "guitar_strum", "guitar_tapping",
                               "steel_guitar_slide_guitar"]
    static let keysLabels = ["piano", "electric_piano", "keyboard_musical", "synthesizer", "organ", "electronic_organ",
                             "hammond_organ", "harpsichord"]
    static let threshold = 0.3

    private final class Counter: NSObject, SNResultsObserving {
        let lock = NSLock()
        var windows = 0, guitar = 0, keys = 0
        let g: [String], k: [String]
        init(_ g: [String], _ k: [String]) { self.g = g; self.k = k }
        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let c = result as? SNClassificationResult else { return }
            func heard(_ labels: [String]) -> Bool {
                labels.contains { (c.classification(forIdentifier: $0)?.confidence ?? 0) >= InstrumentListener.threshold }
            }
            lock.withLock {
                windows += 1
                if heard(g) { guitar += 1 }
                if heard(k) { keys += 1 }
            }
        }
    }

    private let analyzer: SNAudioStreamAnalyzer
    private let counter: Counter
    private let format: AVAudioFormat
    private var position: AVAudioFramePosition = 0

    public init(sampleRate: Double = 44_100) throws {
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: 3, preferredTimescale: 48_000)
        request.overlapFactor = 0.5
        let known = Set(request.knownClassifications)
        counter = Counter(Self.guitarLabels.filter(known.contains), Self.keysLabels.filter(known.contains))
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        analyzer = SNAudioStreamAnalyzer(format: format)
        try analyzer.add(request, withObserver: counter)
    }

    /// Adds `count` frames (mixed to mono); stretches fed one after another are heard as one stream.
    public func feed(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int, gain: Float = 1) {
        guard count > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        buf.frameLength = AVAudioFrameCount(count)
        let out = buf.floatChannelData![0]
        for i in 0..<count { out[i] = (left[i] + right[i]) * 0.5 * gain }
        analyzer.analyze(buf, atAudioFramePosition: position)
        position += AVAudioFramePosition(count)
    }

    public func feed(_ a: StereoAudio, frames: Range<Int>) {
        a.left.withUnsafeBufferPointer { l in
            a.right.withUnsafeBufferPointer { r in
                feed(left: l.baseAddress! + frames.lowerBound, right: r.baseAddress! + frames.lowerBound, count: frames.count)
            }
        }
    }

    /// Nil when nothing was heard (under one window of audio).
    public func finish() -> InstrumentShares? {
        analyzer.completeAnalysis()
        return counter.lock.withLock {
            counter.windows == 0 ? nil
                : InstrumentShares(guitar: Float(counter.guitar) / Float(counter.windows), keys: Float(counter.keys) / Float(counter.windows))
        }
    }

    /// The shares for a whole part, or only for its active half-second frames (`active[i]` true).
    public static func shares(of a: StereoAudio, active: [Bool]? = nil) -> InstrumentShares? {
        guard let listener = try? InstrumentListener(sampleRate: a.sampleRate) else { return nil }
        let f = PartPresence.frame
        for (i, start) in stride(from: 0, to: a.frameCount, by: f).enumerated() where active.map({ i < $0.count && $0[i] }) ?? true {
            listener.feed(a, frames: start..<min(a.frameCount, start + f))
        }
        return listener.finish()
    }
}

/// The naming rules on top of the level gate (U06). Trial values from 7 songs; the shares are stored on the
/// record, so the rules can change without splitting again.
public enum NameCheck {
    /// Under this share of guitar windows in the whole song, a "guitar" part is suspect.
    public static let mixGuitar: Float = 0.3
    /// A lead guitar must sound like guitar in at least this share of its active windows.
    public static let leadGuitar: Float = 0.5

    public enum GuitarFate: Equatable, Sendable {
        /// Leave the guitar part as it is.
        case keep
        /// It is really keys (e.g. a keyboard riff the separator filed as guitar): join the Keys row.
        case joinKeys
        /// Probably not a guitar at all and unclear what it is: list it under "More parts".
        case moreParts
    }

    /// `mix`: the whole song; `guitarStem`: the guitar part's active frames. On a separated part the classifier
    /// confuses piano and guitar, so the part only decides guitar against keys once the mix says "no guitar".
    public static func guitarFate(mix: InstrumentShares?, guitarStem: InstrumentShares?) -> GuitarFate {
        guard let mix, mix.guitar < mixGuitar else { return .keep }
        guard let g = guitarStem else { return .moreParts }
        return g.keys > g.guitar ? .joinKeys : .moreParts
    }

    /// "Lead guitar" only when the lead's active windows are mostly guitar and more guitar than keys.
    public static func trustLead(_ lead: InstrumentShares?) -> Bool {
        guard let lead else { return true }
        return lead.guitar >= leadGuitar && lead.guitar > lead.keys
    }
}
