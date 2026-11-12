import AppKit
import AVFoundation
import Observation

/// Records with a microphone or an audio interface for the "Microphone" choice of the Record sheet: a live
/// band, a speaker playing the song, a rehearsal. Audio goes straight to a 44.1 kHz stereo Float32 CAF in
/// `ImportStaging.recordingsDirectory`; afterwards the silence around the song is trimmed and the file is
/// handed to the app through `onFinished`.
///
/// Port of backline-ios `App/Recording/MicRecorder.swift`. What macOS changes: there is no audio session, so
/// the input is picked by its Core Audio device (`AudioInputs`) and set on the engine's input unit; the
/// permission is the microphone's (`AVCaptureDevice`); nothing interrupts a recording on a Mac, so a take
/// pauses only when its input goes away; and the Mac is kept awake instead of the screen.
@MainActor @Observable
final class MicRecorder {
    enum Permission: Equatable { case undetermined, granted, denied }

    enum Failure: Equatable {
        /// The take held no usable song (nothing loud enough, or shorter than a few seconds).
        case nothingHeard
        case noInput
        case engine(String)
    }

    enum Phase: Equatable {
        /// Nothing running (no permission yet, or before the first preview).
        case idle
        /// Engine running for the level meter, nothing is written.
        case monitoring
        case recording
        /// The input went away (unplugged) and could not be started again; the take keeps its place.
        case interrupted
        case finishing
        case finished
        case failed(Failure)
    }

    private(set) var permission: Permission = .undetermined
    private(set) var phase: Phase = .idle
    /// Loudest sample in the last interval, dBFS.
    private(set) var peakDB: Float = AudioLevel.floorDB
    private(set) var rmsDB: Float = AudioLevel.floorDB
    private(set) var elapsed: Double = 0
    private(set) var quality: RecordingQuality = .waitingForSound
    private(set) var inputName = "Microphone"
    private(set) var isStereo = false
    /// The 20-minute limit ended this take.
    private(set) var stoppedAtLimit = false
    /// The Mac's inputs, refreshed about once a second while nothing is being recorded.
    private(set) var inputs: [AudioInput] = []
    /// The input picked in the sheet; nil follows the Mac's own input (System Settings ▸ Sound).
    private(set) var selectedInputID: AudioObjectID?

    /// Called with the trimmed file and a title once a take is ready.
    @ObservationIgnored var onFinished: (URL, String) -> Void = { _, _ in }

    var isRecording: Bool { phase == .recording || phase == .interrupted }
    var isBusy: Bool { isRecording || phase == .finishing }

    @ObservationIgnored private let core = MicCaptureCore()
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var recordingURL: URL?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var engineObserver: NSObjectProtocol?
    @ObservationIgnored private var lastRestart = Date.distantPast
    @ObservationIgnored private var finishRequested = false
    @ObservationIgnored private var awake: NSObjectProtocol?
    @ObservationIgnored private var ticks = 0

    private struct NoInput: Error {}

    static let privacyURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

    // MARK: Permission

    func refreshPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: permission = .granted
        case .denied, .restricted: permission = .denied
        default: permission = .undetermined
        }
    }

    /// Shows the system's microphone prompt (the first time only).
    func requestPermission() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        permission = granted ? .granted : .denied
        if granted { startMonitoring() }
    }

    static func openSettings() {
        NSWorkspace.shared.open(privacyURL)
    }

    // MARK: Lifecycle

    /// Called when the Microphone choice appears: lists the inputs, checks permission and, if granted, starts
    /// the level preview. Never asks for permission by itself.
    func begin() {
        refreshPermission()
        refreshInputs()
        // A recording an unfinished import keeps to try again stays (D20 d).
        let kept = Set(WorkJournal.shared.unfinished.filter { $0.entry.staged.hasPrefix("Recordings/") }
            .map { ($0.entry.staged as NSString).lastPathComponent })
        // A journal that couldn't be read at launch named no file: none is deleted this run (ios-storage#4).
        if !WorkJournal.shared.unreadable { RecordingTrimmer.purgeStale(in: ImportStaging.recordingsDirectory, keeping: kept) }
        if permission == .granted { startMonitoring() }
        startPolling()
    }

    /// Starts the engine without writing, so the meter works before the person presses Record.
    func startMonitoring() {
        guard permission == .granted, !isBusy, engine == nil else { return }
        do {
            try startEngine()
            phase = .monitoring
            startPolling()
        } catch {
            fail(error)
        }
    }

    /// Records from `id` (nil: the Mac's own input). Only between takes.
    func selectInput(_ id: AudioObjectID?) {
        guard !isBusy, id != selectedInputID else { return }
        selectedInputID = id
        guard engine != nil else { updateInputName(); return }
        stopEngine()
        phase = .idle
        startMonitoring()
    }

    func startRecording() {
        if permission != .granted {
            Task {
                if permission == .undetermined { await requestPermission() }
                if permission == .granted { startRecording() }
            }
            return
        }
        guard !isBusy else { return }
        do {
            if engine == nil { try startEngine() }
            try RecordingTrimmer.prepareRecordingsDirectory()
            let url = RecordingTrimmer.newRecordingURL()
            try core.beginWriting(to: url, soundThresholdDB: RecordingHeuristics.micSoundThresholdDB)
            recordingURL = url
            elapsed = 0
            quality = .waitingForSound
            stoppedAtLimit = false
            finishRequested = false
            phase = .recording
            startPolling()
            stayAwake(true)
        } catch {
            fail(error)
        }
    }

    /// Stops, trims the silence around the song and hands the file to `onFinished`.
    func stopAndFinish() async {
        guard isRecording else { return }
        phase = .finishing
        stayAwake(false)
        stopEngine()
        poller?.cancel()
        poller = nil
        let stats = core.endWriting()
        let url = recordingURL
        recordingURL = nil
        guard let url, let stats, let range = RecordingHeuristics.trimRange(stats) else {
            if let url { try? FileManager.default.removeItem(at: url) }
            phase = .failed(.nothingHeard)
            return
        }
        do {
            let trimmed = try await RecordingTrimmer.trim(url, to: range)
            phase = .finished
            onFinished(trimmed, Self.title())
        } catch {
            try? FileManager.default.removeItem(at: url)
            fail(error)
        }
    }

    /// Throws the take away and stops everything (Cancel, another choice, or the sheet going away).
    func cancel() {
        stayAwake(false)
        poller?.cancel()
        poller = nil
        stopEngine()
        _ = core.endWriting()
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        recordingURL = nil
        if phase != .finished { phase = .idle }
        peakDB = AudioLevel.floorDB
        rmsDB = AudioLevel.floorDB
    }

    /// After "nothing heard" or an error: back to the preview.
    func reset() {
        if case .failed = phase { phase = .idle }
        elapsed = 0
        quality = .waitingForSound
        refreshInputs()
        startMonitoring()
        startPolling()
    }

    static func title(_ date: Date = .now) -> String {
        "Recording – " + date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: Engine

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let id = selectedInputID {
            // Before the format is read: the input unit then reports the chosen device's channels and rate.
            try input.auAudioUnit.setDeviceID(id)
        }
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw NoInput() }
        // No format given: the tap gets the node's own output format, whatever the device is (a mismatch
        // would raise an Objective-C exception). The writer converts any PCM to 44.1 kHz stereo.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil, block: MicCaptureCore.tapBlock(core))
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        isStereo = format.channelCount >= 2
        updateInputName()
        engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartEngine() }
        }
    }

    private func stopEngine() {
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    /// The device or its format changed (an interface was plugged in or out, its rate was changed): rebuild
    /// the engine and keep writing to the same file.
    private func restartEngine() {
        guard phase == .monitoring || phase == .recording || phase == .interrupted else { return }
        lastRestart = Date()
        stopEngine()
        refreshInputs()
        do {
            try startEngine()
            if phase == .interrupted { phase = .recording }
        } catch {
            // The input is gone: keep the take paused instead of losing it.
            if phase == .recording || phase == .interrupted { phase = .interrupted } else { fail(error) }
        }
    }

    /// Picks the recording up again after its input came back (the file keeps its place).
    func resume() {
        guard phase == .interrupted else { return }
        stopEngine()
        refreshInputs()
        do {
            try startEngine()
            phase = .recording
        } catch {
            // Still not there: stay paused so the person can plug it in, pick another input or keep the take.
        }
    }

    // MARK: Inputs

    private func refreshInputs() {
        let list = AudioInputs.list()
        if list != inputs { inputs = list }
        // A chosen input that was unplugged between takes: follow the Mac's own input again.
        if let id = selectedInputID, !list.contains(where: { $0.id == id }), !isBusy {
            selectedInputID = nil
            if engine != nil { stopEngine(); phase = .idle; startMonitoring() }
        }
        updateInputName()
    }

    private func updateInputName() {
        let id = selectedInputID ?? AudioInputs.systemDefaultID
        inputName = inputs.first { $0.id == id }?.name ?? "Microphone"
    }

    // MARK: Keeping the Mac awake

    /// A long take must not be cut by the Mac going to sleep; the display may still turn off.
    private func stayAwake(_ on: Bool) {
        if on, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                          reason: "Recording a song")
        } else if !on, let token = awake {
            ProcessInfo.processInfo.endActivity(token)
            awake = nil
        }
    }

    // MARK: Polling (about 15 Hz)

    private func startPolling() {
        guard poller == nil || poller?.isCancelled == true else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(66))
                self?.tick()
            }
        }
    }

    private func tick() {
        ticks += 1
        if ticks % 15 == 0, !isBusy { refreshInputs() }
        let meter = core.readMeter()
        peakDB = meter.peakDB
        rmsDB = meter.rmsDB
        switch phase {
        case .recording:
            if let stats = core.stats() {
                elapsed = stats.seconds
                quality = RecordingHeuristics.quality(stats)
                if stats.seconds >= RecordingHeuristics.maxSeconds {
                    stoppedAtLimit = true
                    requestFinish()
                }
            }
            if core.takeWriteError() != nil {
                // Disk full or similar: keep what we have rather than lose the whole take.
                requestFinish()
            } else if core.secondsSinceLastBuffer > 2.5, Date().timeIntervalSince(lastRestart) > 3 {
                // The engine went quiet without telling us: kick it.
                restartEngine()
            }
        default: break
        }
    }

    private func requestFinish() {
        guard !finishRequested else { return }
        finishRequested = true
        Task { await stopAndFinish() }
    }

    private func fail(_ error: Error) {
        stayAwake(false)
        stopEngine()
        if error is NoInput { phase = .failed(.noInput) }
        else { phase = .failed(.engine(error.localizedDescription)) }
    }
}

// MARK: - Audio-thread side

/// Everything the engine's tap callback touches, kept out of the main actor: a meter and the optional writer,
/// all behind one lock. The tap runs on an audio-engine queue, never on the main thread.
nonisolated final class MicCaptureCore: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: PCMStreamWriter?
    private var meterPeak: Float = 0
    private var meterRMS: Float = 0
    private var writeError: Error?
    private var lastBufferAt = DispatchTime.now().uptimeNanoseconds

    /// Built here, in a nonisolated context, so the closure is not MainActor-isolated: a MainActor closure
    /// called from the audio queue would trap under Swift 6's dynamic isolation checks.
    static func tapBlock(_ core: MicCaptureCore) -> AVAudioNodeTapBlock {
        { buffer, _ in core.process(buffer) }
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        var peak: Float = 0
        var rms: Float = 0
        if let data = buffer.floatChannelData {
            let channels = min(Int(buffer.format.channelCount), 2)
            if buffer.format.isInterleaved {
                (peak, rms) = AudioLevel.peakAndRMS(UnsafePointer(data[0]), count: frames * Int(buffer.format.channelCount))
            } else {
                (peak, rms) = AudioLevel.peakAndRMS(channels: (0..<channels).map { UnsafePointer(data[$0]) }, frames: frames)
            }
        }
        lock.lock()
        meterPeak = max(meterPeak, peak)
        meterRMS = rms
        lastBufferAt = DispatchTime.now().uptimeNanoseconds
        let writer = self.writer
        lock.unlock()
        if let writer {
            do { try writer.append(buffer) } catch {
                lock.lock(); writeError = error; lock.unlock()
            }
        }
    }

    func beginWriting(to url: URL, soundThresholdDB: Float) throws {
        let w = try PCMStreamWriter(url: url, soundThresholdDB: soundThresholdDB)
        lock.lock(); writer = w; writeError = nil; lock.unlock()
    }

    /// Closes the file and returns its final numbers (nil if nothing was being written).
    func endWriting() -> RecordingStats? {
        lock.lock()
        let w = writer
        writer = nil
        lock.unlock()
        return w?.finish()
    }

    func stats() -> RecordingStats? {
        lock.lock(); let w = writer; lock.unlock()
        return w?.snapshot(resetPeak: false)
    }

    /// The loudest sample since the previous call.
    func readMeter() -> (peakDB: Float, rmsDB: Float) {
        lock.lock(); defer { lock.unlock() }
        let result = (AudioLevel.db(fromLinear: meterPeak), AudioLevel.db(fromLinear: meterRMS))
        meterPeak = 0
        return result
    }

    func takeWriteError() -> Error? {
        lock.lock(); defer { lock.unlock() }
        defer { writeError = nil }
        return writeError
    }

    var secondsSinceLastBuffer: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(DispatchTime.now().uptimeNanoseconds - lastBufferAt) / 1e9
    }
}
