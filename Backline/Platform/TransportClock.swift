import BacklineKit
import Foundation
import QuartzCore

/// What the clock reads from the engine (a protocol so tests can drive it with a fake).
nonisolated protocol EngineStatusSource: AnyObject, Sendable {
    var status: PlaybackEngine.Status { get }
    var sampleRate: Double { get }
}

extension PlaybackEngine: EngineStatusSource {}

/// The playhead for the Metal views. The engine publishes its position once per render block (every
/// 10–25 ms); at 120 Hz that would step. This keeps a local estimate that advances with the display
/// clock at the playback rate and eases toward the engine's value, snapping on a seek or a loop wrap.
///
/// It is also optimistic: under a finger the playhead is wherever the finger is, and after a seek it shows
/// the target straight away and holds it until the engine catches up (or 350 ms pass), so the screen never
/// waits for the audio thread.
nonisolated final class TransportClock: @unchecked Sendable {
    private let engine: EngineStatusSource
    private var estimate = 0.0
    private var lastHostTime = 0.0
    private var foreground = true
    private let lock = NSLock()

    private enum Override { case none, scrub(Double), settle(target: Double, since: CFTimeInterval) }
    private var override = Override.none
    /// The engine is close enough to a settle target to take over again.
    static let settleTolerance = 0.06
    /// A settle target is shown for at most this long, even if the engine never gets there.
    static let settleTimeout = 0.35

    init(engine: EngineStatusSource) { self.engine = engine }

    func setForeground(_ value: Bool) { lock.withLock { foreground = value } }

    /// A finger is on the timeline: the playhead is at `t` until the finger lifts.
    // Called for every touch event: written out without generic helpers, which stay unspecialised in Debug.
    func beginScrub(_ t: Double) { lock.lock(); override = .scrub(t); lock.unlock() }
    func updateScrub(_ t: Double) { lock.lock(); override = .scrub(t); lock.unlock() }
    /// The finger lifted at `t` (or a seek went there): show it until the engine agrees.
    func endScrub(_ t: Double, now: CFTimeInterval = CACurrentMediaTime()) {
        lock.withLock { override = .settle(target: t, since: now) }
    }
    func jump(to t: Double, now: CFTimeInterval = CACurrentMediaTime()) { endScrub(t, now: now) }

    var isOverriding: Bool {
        lock.withLock { if case .none = override { return false } else { return true } }
    }

    struct Sample: Sendable {
        var time: Double
        var playing: Bool
    }

    /// Call once per display frame.
    func sample(hostTime: CFTimeInterval = CACurrentMediaTime()) -> Sample {
        lock.lock(); defer { lock.unlock() }
        let st = engine.status
        let enginePos = Double(st.position) / engine.sampleRate
        let dt = max(0, min(0.1, hostTime - lastHostTime))
        lastHostTime = hostTime
        switch override {
        case .scrub(let t):
            estimate = t
            return Sample(time: t, playing: st.playing)
        case .settle(let target, let since):
            // While playing, the target moves on at the playback rate.
            let expected = target + (st.playing ? max(0, hostTime - since) * st.rate : 0)
            if abs(enginePos - expected) < Self.settleTolerance || hostTime - since > Self.settleTimeout {
                override = .none
            } else {
                estimate = expected
                return Sample(time: expected, playing: st.playing)
            }
        case .none:
            break
        }
        guard st.playing, st.countInBeat == 0 else {
            estimate = enginePos
            return Sample(time: estimate, playing: st.playing)
        }
        estimate += dt * st.rate
        let error = enginePos - estimate
        if abs(error) > 0.08 { estimate = enginePos } else { estimate += error * 0.12 }
        return Sample(time: estimate, playing: true)
    }
}
