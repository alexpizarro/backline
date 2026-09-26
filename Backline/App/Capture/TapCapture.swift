import CoreAudio
import Foundation
import Synchronization

nonisolated public enum CaptureTarget: Sendable {
    case app(AudioSource)          // tap only this app's audio processes
    case system                    // everything except Backline itself
}

nonisolated public enum CaptureError: LocalizedError, Sendable {
    case osStatus(String, OSStatus)
    case noOutputDevice
    case nothingToTap
    public var errorDescription: String? {
        switch self {
        case .osStatus(let what, let s): "Your Mac wouldn't let Backline listen (code \(s))."
        case .noOutputDevice: "Backline can't find your speakers or headphones."
        case .nothingToTap: "That app isn't making any sound."
        }
    }
}

nonisolated func fourCC(_ s: OSStatus) -> String {
    let u = UInt32(bitPattern: s)
    let b = [24, 16, 8, 0].map { UInt8((u >> UInt32($0)) & 0xFF) }
    return b.allSatisfy({ $0 >= 32 && $0 < 127 }) ? String(decoding: b, as: UTF8.self) : "\(s)"
}

/// Live numbers for the UI (level meter, elapsed, silence/permission heuristics). Written by the
/// drain queue, read by the UI at ~15 Hz. Never touched on the real-time IO thread.
nonisolated public struct CaptureStats: Sendable {
    public var sampleRate: Double = 0
    public var framesWritten: Int = 0
    public var peakDB: Float = -120          // last ~100 ms block
    public var rmsDB: Float = -120
    public var everNonZero = false           // false + source playing => TCC denied or DRM-muted
    public var firstSoundAt: Double?         // seconds; first block above soundThresholdDB
    public var lastSoundAt: Double?
    public var loudestPeakDB: Float = -120
    public var droppedFrames: Int = 0        // ring overflow (should stay 0)
    public var ioCycles: Int = 0             // 0 => IO not running yet (tapautostart waits for first audio)
    public var measuredRate: Double?         // frames/s over wall clock since first data (>= 2 s)
    public var headerRate: Double = 0        // rate written to the WAV header on close
    public var seconds: Double { sampleRate > 0 ? Double(framesWritten) / sampleRate : 0 }
    public static let soundThresholdDB: Float = -50
    public init() {}
}

/// Layout facts from a tap + aggregate device, gathered without starting IO (no TCC prompt).
nonisolated public struct TapProbe: Sendable, CustomStringConvertible {
    public let tapFormat: AudioStreamBasicDescription
    public let inputStreamUsage: [UInt32]
    public let aggregateInputBuffers: [UInt32]   // channels per input buffer, in IOProc order
    public let subDeviceInputBuffers: Int
    public let outputDeviceName: String
    public let outputDeviceRate: Double
    public let aggregateRate: Double
    public let aggregateInputFormats: [AudioStreamBasicDescription]
    public var description: String {
        let f = tapFormat
        let flags = f.mFormatFlags
        let float = flags & kAudioFormatFlagIsFloat != 0
        let nonInt = flags & kAudioFormatFlagIsNonInterleaved != 0
        return """
        tap format: \(f.mSampleRate) Hz, \(f.mChannelsPerFrame) ch, \(f.mBitsPerChannel)-bit \
        \(float ? "float" : "int"), \(nonInt ? "non-interleaved" : "interleaved"), \
        formatID '\(fourCC(OSStatus(bitPattern: f.mFormatID)))'
        clock/main sub-device: \(outputDeviceName) @ \(outputDeviceRate) Hz
        aggregate input buffers (channels each, IOProc order): \(aggregateInputBuffers)
        sub-device input buffers to skip: \(subDeviceInputBuffers)
        aggregate nominal rate: \(aggregateRate) Hz; input stream virtual formats: \
        \(aggregateInputFormats.map { "\($0.mSampleRate) Hz/\($0.mChannelsPerFrame)ch" })
        IOProc input stream usage after disabling sub-device inputs: \(inputStreamUsage)
        """
    }
}

/// Core Audio process tap -> private aggregate device -> IOProc -> lock-free ring -> WAV on disk.
/// Thread model: `start` runs off the main actor (@concurrent); the IO block runs on `ioQueue`
/// (HAL real-time, dispatched synchronously); the drain timer runs on `drainQueue`.
nonisolated public final class TapCapture: Sendable {
    public let url: URL
    public let sampleRate: Double
    private let system = AudioHardwareSystem.shared
    private let tap: AudioHardwareTap
    private let aggregate: AudioHardwareAggregateDevice
    private let procID: AudioDeviceIOProcID
    private let ring: FloatRing
    private let drain: Drainer
    private let ioQueue = DispatchQueue(label: "backline.capture.io", qos: .userInteractive)
    private let stopped = Mutex(false)

    public var stats: CaptureStats { drain.stats }

    /// True when IO has stopped arriving for over a second (output device went away, e.g. a
    /// Bluetooth profile switch). The caller stops and keeps what was recorded.
    public var isStalled: Bool { drain.secondsSinceData > 1.5 }

    // MARK: Start / stop

    @concurrent
    public static func start(_ target: CaptureTarget, writingTo url: URL) async throws -> TapCapture {
        let (tap, agg, skip, _) = try makeTapAndAggregate(target)
        do {
            return try TapCapture(tap: tap, aggregate: agg, skipBuffers: skip, url: url)
        } catch {
            try? AudioHardwareSystem.shared.destroyAggregateDevice(agg)
            try? AudioHardwareSystem.shared.destroyProcessTap(tap)
            throw error
        }
    }

    private init(tap: AudioHardwareTap, aggregate: AudioHardwareAggregateDevice, skipBuffers: Int, url: URL) throws {
        self.tap = tap
        self.aggregate = aggregate
        self.url = url
        let fmt = try tap.format
        sampleRate = fmt.mSampleRate
        ring = FloatRing(capacity: 1 << 21)              // 2M floats = ~21 s stereo @ 48 kHz
        drain = try Drainer(ring: ring, url: url, sampleRate: fmt.mSampleRate)

        var id: AudioDeviceIOProcID?
        let block = TapCapture.makeIOBlock(ring: ring, skipBuffers: skipBuffers)
        let err = AudioDeviceCreateIOProcIDWithBlock(&id, aggregate.id, ioQueue, block)
        guard err == noErr, let id else { throw CaptureError.osStatus("AudioDeviceCreateIOProcIDWithBlock", err) }
        procID = id
        // Guitarists' default output is often a USB interface WITH inputs; those input streams sit in
        // front of the tap in the aggregate. Switch them off for our IOProc so we never pull mic/
        // instrument input (and never trip a Microphone prompt — unverified whether it would).
        // Only when there is something to switch off: setting usage on a tap-only input list blocked
        // inside coreaudiod (mach_msg, never returned) in testing — see report.
        if skipBuffers > 0 { _ = try? TapCapture.setInputStreamUsage(aggregate, procID: id, off: skipBuffers) }
        drain.resume()
        // First start of an aggregate that contains a tap is what triggers the TCC prompt
        // "“Backline” would like access to record your system audio." If denied, IO runs but
        // delivers zeros — there is no error code to detect.
        do { try aggregate.start(IOProcID: id) } catch {
            AudioDeviceDestroyIOProcID(aggregate.id, id)
            drain.finish()
            throw error
        }
    }

    /// Idempotent. Stops IO, flushes the ring, finalises the WAV header, tears down HAL objects.
    @discardableResult
    public func stop() -> CaptureStats {
        let already = stopped.withLock { s in defer { s = true }; return s }
        if !already {
            try? aggregate.stop(IOProcID: procID)
            AudioDeviceDestroyIOProcID(aggregate.id, procID)
            drain.finish()
            try? system.destroyAggregateDevice(aggregate)
            try? system.destroyProcessTap(tap)
        }
        return drain.stats
    }

    deinit { stop() }

    // MARK: HAL objects

    /// Creates the tap and a private aggregate device (default output as clock + the tap as sub-tap).
    /// Does NOT start IO, so it can be used to probe formats without a permission prompt.
    static func makeTapAndAggregate(_ target: CaptureTarget)
        throws -> (AudioHardwareTap, AudioHardwareAggregateDevice, Int, AudioHardwareDevice) {
        let system = AudioHardwareSystem.shared
        let desc: CATapDescription
        switch target {
        case .app(let src):
            guard !src.processObjectIDs.isEmpty else { throw CaptureError.nothingToTap }
            desc = CATapDescription(stereoMixdownOfProcesses: src.processObjectIDs)
            desc.name = "Backline – \(src.name)"
        case .system:
            // Exclude Backline's own output (its HAL process object exists once it has touched audio).
            let me = (try? system.process(for: getpid()))?.map { [$0.id] } ?? []
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: me)
            desc.name = "Backline – system audio"
        }
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted                 // user must hear the song while recording

        guard let tap = try system.makeProcessTap(description: desc) else {
            throw CaptureError.osStatus("AudioHardwareCreateProcessTap", -1)
        }
        do {
            guard let out = try system.defaultOutputDevice else { throw CaptureError.noOutputDevice }
            let outUID = try out.uid
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Backline Capture",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString,
                                                   kAudioSubTapDriftCompensationKey: true]],
            ]
            guard let agg = try system.makeAggregateDevice(description: composition) else {
                throw CaptureError.osStatus("AudioHardwareCreateAggregateDevice", -1)
            }
            // If the output device also has inputs (USB interfaces!), its input buffers come first
            // in the IOProc's input list; skip them (verified with `probe <app> --clock <uid-of-device-with-inputs>`: buffers [1, 2]).
            let skip = (try? out.inputStreamConfiguration.count) ?? 0
            return (tap, agg, skip, out)
        } catch {
            try? system.destroyProcessTap(tap)
            throw error
        }
    }

    /// kAudioDevicePropertyIOProcStreamUsage: first `off` input streams disabled (NULL mData in the IOProc).
    /// Returns the usage flags read back after setting.
    @discardableResult
    static func setInputStreamUsage(_ dev: AudioHardwareDevice, procID: AudioDeviceIOProcID, off: Int) throws -> [UInt32] {
        let n = try dev.inputStreamConfiguration.count
        guard n > 0 else { return [] }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIOProcStreamUsage,
                                              mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
        var size = UInt32(max(MemoryLayout<AudioHardwareIOProcStreamUsage>.size, flagsOffset + 4 * n))
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        let usage = raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        usage.pointee.mIOProc = unsafeBitCast(procID, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(n)
        var err = AudioObjectGetPropertyData(dev.id, &addr, 0, nil, &size, raw)
        guard err == noErr else { throw CaptureError.osStatus("get IOProcStreamUsage", err) }
        let flags = (raw + flagsOffset).assumingMemoryBound(to: UInt32.self)
        for i in 0..<n { flags[i] = i < off ? 0 : 1 }
        err = AudioObjectSetPropertyData(dev.id, &addr, 0, nil, size, raw)
        guard err == noErr else { throw CaptureError.osStatus("set IOProcStreamUsage", err) }
        err = AudioObjectGetPropertyData(dev.id, &addr, 0, nil, &size, raw)
        guard err == noErr else { throw CaptureError.osStatus("re-get IOProcStreamUsage", err) }
        return (0..<n).map { flags[$0] }
    }

    public static func probe(_ target: CaptureTarget, clockDeviceUID: String? = nil) throws -> TapProbe {
        let system = AudioHardwareSystem.shared
        var (tap, agg, skip, out) = try makeTapAndAggregate(target)
        defer { try? system.destroyAggregateDevice(agg); try? system.destroyProcessTap(tap) }
        if let clockDeviceUID, let dev = try system.device(forUID: clockDeviceUID) {
            // Re-create with a different clock/main sub-device to observe buffer ordering.
            try? system.destroyAggregateDevice(agg)
            var comp = try agg.composition
            comp[kAudioAggregateDeviceUIDKey] = UUID().uuidString
            comp[kAudioAggregateDeviceMainSubDeviceKey] = clockDeviceUID
            comp[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: clockDeviceUID]]
            comp[kAudioAggregateDeviceTapListKey] = [[kAudioSubTapUIDKey: try tap.uid,
                                                      kAudioSubTapDriftCompensationKey: true]]
            guard let a2 = try system.makeAggregateDevice(description: comp) else {
                throw CaptureError.osStatus("AudioHardwareCreateAggregateDevice", -1)
            }
            agg = a2; out = dev
            skip = (try? dev.inputStreamConfiguration.count) ?? 0
        }
        // Register (but never start) an IOProc to exercise the stream-usage switch without IO/TCC.
        var usage: [UInt32] = []
        var pid: AudioDeviceIOProcID?
        let q = DispatchQueue(label: "probe")
        if AudioDeviceCreateIOProcIDWithBlock(&pid, agg.id, q, makeIOBlock(ring: FloatRing(capacity: 1024), skipBuffers: skip)) == noErr,
           let pid {
            if skip > 0 { usage = (try? setInputStreamUsage(agg, procID: pid, off: skip)) ?? [] }
            AudioDeviceDestroyIOProcID(agg.id, pid)
        }
        return TapProbe(tapFormat: try tap.format,
                        inputStreamUsage: usage,
                        aggregateInputBuffers: try agg.inputStreamConfiguration.map(\.mNumberChannels),
                        subDeviceInputBuffers: skip,
                        outputDeviceName: (try? out.name) ?? "?",
                        outputDeviceRate: (try? out.nominalSampleRate) ?? 0,
                        aggregateRate: (try? agg.nominalSampleRate) ?? 0,
                        aggregateInputFormats: ((try? agg.streams) ?? [])
                            .filter { ((try? $0.direction) ?? .output) == .input }
                            .compactMap { try? $0.virtualFormat })
    }

    // MARK: Real-time IO block

    /// Built in a nonisolated context on purpose: with default MainActor isolation, a closure
    /// literal formed inside a @MainActor method would inherit MainActor and Swift 6's dynamic
    /// isolation check would trap when the HAL calls it on `ioQueue`.
    /// RT rules: no allocation, no locks, no Swift runtime calls that may allocate.
    static func makeIOBlock(ring: FloatRing, skipBuffers: Int) -> AudioDeviceIOBlock {
        { _, input, _, _, _ in
            ring.cycles.wrappingAdd(1, ordering: .relaxed)
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let n = abl.count
            guard n > skipBuffers else { return }
            let first = abl[skipBuffers]
            guard let p0 = first.mData?.assumingMemoryBound(to: Float.self) else { return }
            let ch0 = Int(max(first.mNumberChannels, 1))
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * ch0)
            if ch0 >= 2 {
                ring.writeInterleaved(p0, frames: frames, stride: ch0)          // interleaved stereo
            } else if n > skipBuffers + 1, let p1 = abl[skipBuffers + 1].mData?.assumingMemoryBound(to: Float.self) {
                ring.writePlanar(p0, p1, frames: frames)                        // non-interleaved L/R
            } else {
                ring.writePlanar(p0, p0, frames: frames)                        // mono -> dual mono
            }
        }
    }
}

// MARK: - SPSC lock-free ring of interleaved stereo Float32

nonisolated final class FloatRing: @unchecked Sendable {
    // @unchecked: `buf` is only written by the single producer (IO block) in the region
    // [write, read+capacity) and only read by the single consumer (drain queue) in [read, write);
    // the atomics publish those regions with acquire/release ordering.
    let capacity: Int
    private let mask: Int
    private let buf: UnsafeMutablePointer<Float>
    private let writePos = Atomic<Int>(0)
    private let readPos = Atomic<Int>(0)
    let dropped = Atomic<Int>(0)
    let cycles = Atomic<Int>(0)

    init(capacity: Int) {                            // power of two, in floats
        precondition(capacity & (capacity - 1) == 0)
        self.capacity = capacity; mask = capacity - 1
        buf = .allocate(capacity: capacity); buf.initialize(repeating: 0, count: capacity)
    }
    deinit { buf.deallocate() }

    @inline(__always) private func reserve(_ floats: Int) -> Int? {
        let w = writePos.load(ordering: .relaxed), r = readPos.load(ordering: .acquiring)
        if capacity - (w - r) < floats { dropped.wrappingAdd(floats / 2, ordering: .relaxed); return nil }
        return w
    }
    func writeInterleaved(_ src: UnsafePointer<Float>, frames: Int, stride: Int) {
        guard let w = reserve(frames * 2) else { return }
        for f in 0..<frames {
            buf[(w + 2 * f) & mask] = src[f * stride]
            buf[(w + 2 * f + 1) & mask] = src[f * stride + 1]
        }
        writePos.store(w + frames * 2, ordering: .releasing)
    }
    func writePlanar(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, frames: Int) {
        guard let w = reserve(frames * 2) else { return }
        for f in 0..<frames {
            buf[(w + 2 * f) & mask] = l[f]
            buf[(w + 2 * f + 1) & mask] = r[f]
        }
        writePos.store(w + frames * 2, ordering: .releasing)
    }
    /// Consumer: copies everything available into `out` (reusing its storage).
    func read(into out: inout [Float]) {
        let r = readPos.load(ordering: .relaxed), w = writePos.load(ordering: .acquiring)
        let n = w - r
        out.removeAll(keepingCapacity: true)
        guard n > 0 else { return }
        out.reserveCapacity(n)
        for i in 0..<n { out.append(buf[(r + i) & mask]) }
        readPos.store(w, ordering: .releasing)
    }
}

// MARK: - Drain: ring -> WAV + stats (runs on its own serial queue, never on the IO thread)

nonisolated final class Drainer: Sendable {
    private let ring: FloatRing
    private let queue = DispatchQueue(label: "backline.capture.drain", qos: .utility)
    private let timer: any DispatchSourceTimer
    private let state: Mutex<State>
    private struct State {
        let wav: WavWriter; var scratch: [Float] = []; var stats = CaptureStats(); var done = false
        var t0: UInt64?; var frames0 = 0
        var lastDataAt: UInt64?
    }

    var stats: CaptureStats { state.withLock { $0.stats } }

    init(ring: FloatRing, url: URL, sampleRate: Double) throws {
        self.ring = ring
        var s = CaptureStats(); s.sampleRate = sampleRate
        state = Mutex(State(wav: try WavWriter(url: url, sampleRate: sampleRate), stats: s))
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.tick() }
    }
    func resume() { timer.resume() }

    var secondsSinceData: Double {
        state.withLock { s in
            guard let last = s.lastDataAt else { return 0 }
            return Double(DispatchTime.now().uptimeNanoseconds - last) / 1e9
        }
    }

    func finish() {
        timer.cancel()
        queue.sync {
            tick()
            state.withLock { s in
                guard !s.done else { return }
                s.done = true
                // Trust the declared tap rate unless the measured rate clearly says otherwise
                // (e.g. aggregate clocked at 44.1 kHz while the tap reports 48 kHz — unverified which wins).
                var rate = s.stats.sampleRate
                if let m = s.stats.measuredRate, abs(m - rate) / rate > 0.03,
                   let snap = [44_100.0, 48_000, 88_200, 96_000].min(by: { abs($0 - m) < abs($1 - m) }),
                   abs(snap - m) / snap < 0.02 { rate = snap }
                s.stats.headerRate = rate
                s.wav.close(sampleRate: rate)
            }
        }
    }

    private func tick() {
        state.withLock { s in
            guard !s.done else { return }
            ring.read(into: &s.scratch)
            s.stats.droppedFrames = ring.dropped.load(ordering: .relaxed)
            s.stats.ioCycles = ring.cycles.load(ordering: .relaxed)
            guard !s.scratch.isEmpty else { return }
            s.lastDataAt = DispatchTime.now().uptimeNanoseconds
            s.wav.append(s.scratch)
            var peak: Float = 0, sum: Float = 0, nonZero = false
            for x in s.scratch { let a = abs(x); peak = max(peak, a); sum += x * x; if x != 0 { nonZero = true } }
            let frames = s.scratch.count / 2
            let now = DispatchTime.now().uptimeNanoseconds
            if s.t0 == nil { s.t0 = now; s.frames0 = s.stats.framesWritten + frames }
            s.stats.framesWritten += frames
            if let t0 = s.t0, now - t0 > 2_000_000_000 {
                s.stats.measuredRate = Double(s.stats.framesWritten - s.frames0) / (Double(now - t0) / 1e9)
            }
            s.stats.peakDB = 20 * log10(max(peak, 1e-6))
            s.stats.rmsDB = 10 * log10(max(sum / Float(s.scratch.count), 1e-12))
            s.stats.loudestPeakDB = max(s.stats.loudestPeakDB, s.stats.peakDB)
            s.stats.everNonZero = s.stats.everNonZero || nonZero
            if s.stats.peakDB > CaptureStats.soundThresholdDB {
                let t = s.stats.seconds
                if s.stats.firstSoundAt == nil { s.stats.firstSoundAt = t - Double(frames) / s.stats.sampleRate }
                s.stats.lastSoundAt = t
            }
        }
    }
}

// MARK: - Streaming 32-bit float stereo WAV (WAVE_FORMAT_IEEE_FLOAT), header patched on close

nonisolated final class WavWriter {
    private let fh: FileHandle
    private var dataBytes: UInt32 = 0
    private var sampleRate: UInt32

    init(url: URL, sampleRate: Double) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fh = try FileHandle(forWritingTo: url)
        self.sampleRate = UInt32(sampleRate.rounded())
        try fh.write(contentsOf: header(dataBytes: 0))
    }
    func append(_ interleaved: [Float]) {
        interleaved.withUnsafeBytes { try? fh.write(contentsOf: Data($0)) }
        dataBytes &+= UInt32(interleaved.count * 4)
    }
    func close(sampleRate: Double? = nil) {
        if let sampleRate { self.sampleRate = UInt32(sampleRate.rounded()) }
        try? fh.seek(toOffset: 0)
        try? fh.write(contentsOf: header(dataBytes: dataBytes))
        try? fh.close()
    }
    private func header(dataBytes: UInt32) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(3); u16(2)       // IEEE float, 2 ch
        u32(sampleRate); u32(sampleRate * 8); u16(8); u16(32)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return d
    }
}
