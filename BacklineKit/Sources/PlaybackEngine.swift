import AVFoundation
import BacklineEngine
import Foundation

/// Owns the C++ stem engine and the AVAudioEngine that pulls audio from it.
///
/// The render block is built in a `nonisolated static` function so it carries no actor isolation
/// check (which would trap on the audio thread under Swift 6 main-actor defaults).
public final class PlaybackEngine: @unchecked Sendable {
    public let sampleRate: Double
    let core: OpaquePointer
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    public private(set) var stemCount = 0
    public private(set) var length: Int64 = 0

    /// `drivesOutput: false` gives an engine that is only rendered manually (tests, export).
    private let drivesOutput: Bool

    private var configObserver: NSObjectProtocol?

    public init(sampleRate: Double = 44_100, drivesOutput: Bool = true) {
        self.sampleRate = sampleRate
        self.drivesOutput = drivesOutput
        self.core = bl_engine_create(sampleRate)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let node = Self.makeSourceNode(core: core, format: format)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        source = node
        if drivesOutput {
            // Output device changed (headphones, AirPods, USB interface, sample-rate change): AVAudioEngine
            // stops itself. Reconnect at the new hardware format and resume if we were playing; if that
            // fails, pause the transport so the UI doesn't sit on "playing" in silence.
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                let wasPlaying = bl_engine_status(self.core).playing
                self.engine.stop()
                if let node = self.source {
                    let fmt = AVAudioFormat(standardFormatWithSampleRate: self.sampleRate, channels: 2)!
                    self.engine.disconnectNodeOutput(node)
                    self.engine.connect(node, to: self.engine.mainMixerNode, format: fmt)
                }
                self.engine.prepare()
                if wasPlaying {
                    do { try self.engine.start() } catch { bl_engine_pause(self.core) }
                }
            }
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        engine.stop()
        bl_engine_destroy(core)
    }

    private var raw: OpaquePointer { core }

    nonisolated static func makeSourceNode(core: OpaquePointer, format: AVAudioFormat) -> AVAudioSourceNode {
        nonisolated(unsafe) let e = core
        return AVAudioSourceNode(format: format) { @Sendable _, _, frameCount, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            guard buffers.count >= 2,
                  let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            bl_engine_render(e, l, r, Int32(frameCount))
            return noErr
        }
    }

    /// Loads stems (planar stereo, all the same length). `pitchLocked` stems are never transposed.
    public func load(stems: [StereoAudio], pitchLocked: [Bool]) {
        let frames = stems.map(\.frameCount).max() ?? 0
        guard frames > 0, bl_engine_allocate(raw, Int32(stems.count), Int64(frames)) else { return }
        for (i, s) in stems.enumerated() {
            if let l = bl_engine_stem_channel(raw, Int32(i), 0) {
                s.left.withUnsafeBufferPointer { if let b = $0.baseAddress { l.update(from: b, count: s.frameCount) } }
            }
            if let r = bl_engine_stem_channel(raw, Int32(i), 1) {
                s.right.withUnsafeBufferPointer { if let b = $0.baseAddress { r.update(from: b, count: s.frameCount) } }
            }
            bl_engine_set_stem_pitch_locked(raw, Int32(i), i < pitchLocked.count ? pitchLocked[i] : false)
        }
        bl_engine_commit(raw)
        stemCount = stems.count
        length = Int64(frames)
    }

    /// Direct access for loading without an intermediate copy.
    public func allocate(stemCount n: Int, frames: Int) -> Bool {
        guard bl_engine_allocate(raw, Int32(n), Int64(frames)) else { return false }
        stemCount = n
        length = Int64(frames)
        return true
    }
    public func channelPointer(stem: Int, channel: Int) -> UnsafeMutablePointer<Float>? {
        bl_engine_stem_channel(raw, Int32(stem), Int32(channel))
    }
    public func setPitchLocked(stem: Int, _ locked: Bool) { bl_engine_set_stem_pitch_locked(raw, Int32(stem), locked) }
    public func commit() { bl_engine_commit(raw) }

    public func startOutput() throws {
        if drivesOutput && !engine.isRunning { try engine.start() }
    }
    public func stopOutput() { engine.pause() }

    public func play() { try? startOutput(); bl_engine_play(raw) }
    public func pause() { bl_engine_pause(raw) }
    public func seek(frame: Int64) { bl_engine_seek(raw, frame) }
    public func setGain(stem: Int, _ gain: Float) { bl_engine_set_stem_gain(raw, Int32(stem), gain) }
    public func setRate(_ rate: Double) { bl_engine_set_rate(raw, rate) }
    public func setSemitones(_ s: Double) { bl_engine_set_semitones(raw, s) }
    public func setLoop(enabled: Bool, start: Int64, end: Int64) { bl_engine_set_loop(raw, enabled, start, end) }
    public func setCountIn(enabled: Bool, bpm: Double, beats: Int = 4) { bl_engine_set_count_in(raw, enabled, bpm, Int32(beats)) }
    public func setClickGain(_ g: Float) { bl_engine_set_click_gain(raw, g) }
    /// Beat grid for the playback metronome (seconds; `accents` marks bar starts).
    public func setBeatGrid(_ beats: [Double], accents: [Bool]) {
        let frames = beats.map { Int64(($0 * sampleRate).rounded()) }
        let acc = accents.map { UInt8($0 ? 1 : 0) }
        frames.withUnsafeBufferPointer { f in
            acc.withUnsafeBufferPointer { a in
                bl_engine_set_beat_grid(raw, f.baseAddress, a.baseAddress, Int32(frames.count))
            }
        }
    }
    public func setClick(_ on: Bool) { bl_engine_set_click(raw, on) }

    public func setTrainer(enabled: Bool, from: Double, step: Double, every: Int, to: Double) {
        bl_engine_set_trainer(raw, enabled, from, step, Int32(every), to)
    }

    public struct Status: Sendable {
        public var position: Int64
        public var playing: Bool
        public var countInBeat: Int
        public var loopPasses: UInt32
        public var reachedEnd: Bool
        public var rate: Double
    }

    /// Output-latency compensated status. Safe to poll at display rate.
    public var status: Status {
        let s = bl_engine_status(raw)
        let hw = engine.isRunning ? Int64(engine.outputNode.presentationLatency * sampleRate) : 0
        return Status(position: max(0, s.position - (s.playing ? hw : 0)), playing: s.playing,
                      countInBeat: Int(s.countInBeat), loopPasses: s.loopPasses, reachedEnd: s.reachedEnd, rate: s.rate)
    }

    /// Renders `frames` frames directly (tests / offline use). Not for use while output is running.
    public func renderForTesting(frames: Int) -> (left: [Float], right: [Float]) {
        var l = [Float](repeating: 0, count: frames), r = [Float](repeating: 0, count: frames)
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            bl_engine_render(raw, lp.baseAddress!, rp.baseAddress!, Int32(frames))
        } }
        return (l, r)
    }

    // MARK: Export

    public struct ExportSettings: Sendable {
        public var gains: [Float]
        public var rate: Double
        public var semitones: Double
        /// Source frame range; `end == 0` means the whole song.
        public var start: Int64 = 0
        public var end: Int64 = 0
        public init(gains: [Float], rate: Double, semitones: Double, start: Int64 = 0, end: Int64 = 0) {
            self.gains = gains; self.rate = rate; self.semitones = semitones
            self.start = start; self.end = end
        }
    }

    public func exportLength(_ s: ExportSettings) -> Int64 {
        s.gains.withUnsafeBufferPointer { g in
            var p = BLExportParams(gains: g.baseAddress!, gainCount: Int32(g.count), rate: s.rate, semitones: s.semitones, start: s.start, end: s.end)
            return bl_engine_export_length(raw, &p)
        }
    }

    /// Offline render of the whole song. `sink` receives consecutive planar blocks; return false to cancel.
    /// Runs on the caller's thread; playback must not be reloaded concurrently.
    @discardableResult
    public func export(_ s: ExportSettings, sink: (UnsafePointer<Float>, UnsafePointer<Float>, Int) -> Bool) -> Int64 {
        typealias Sink = (UnsafePointer<Float>, UnsafePointer<Float>, Int) -> Bool
        return withoutActuallyEscaping(sink) { esc in
            var box = esc
            return withUnsafeMutablePointer(to: &box) { ctx in
                s.gains.withUnsafeBufferPointer { g in
                    var p = BLExportParams(gains: g.baseAddress!, gainCount: Int32(g.count), rate: s.rate, semitones: s.semitones, start: s.start, end: s.end)
                    return bl_engine_export(raw, &p, { ctx, l, r, n in
                        let f = ctx!.assumingMemoryBound(to: Sink.self).pointee
                        return f(l, r, Int(n))
                    }, ctx)
                }
            }
        }
    }
}
