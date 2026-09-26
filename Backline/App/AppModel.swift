import AppKit
import BacklineKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Thread-safe cancellation flag read by the import pipeline.
nonisolated final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

enum Screen: Equatable {
    case empty
    case analyzing
    case mixer
    case failed(String)
}

/// The single source of truth for the window. Drives the C++ engine; the UI reads from here.
@MainActor @Observable
final class AppModel {
    // Library
    var library: [SongRecord] = []
    var showSidebar = true

    // Navigation
    var screen: Screen = .empty
    var dropRejected = false

    // Import
    var importTitle = ""
    var importProgress = ImportProgress(phase: 0, fraction: 0, secondsRemaining: nil)
    private var importTask: Task<Void, Never>?
    private(set) var lastImportURL: URL?
    @ObservationIgnored private let cancelBox = CancelBox()

    // Current song
    var song: SongRecord?
    var artwork: NSImage?
    var settings = SongSettings() { didSet { settingsChanged(from: oldValue) } }

    // Transport (published at display rate by the ticker)
    var position: Double = 0
    var isPlaying = false
    var countInBeat = 0
    var loopPasses: UInt32 = 0
    /// Speed actually playing (differs from settings.speed while the speed trainer runs).
    var liveSpeed = 100

    // Record from an app
    var recordSheet = false
    /// Title to use for the next import (recordings have no metadata).
    @ObservationIgnored var importTitleOverride: String?
    @ObservationIgnored var importArtistOverride: String?
    @ObservationIgnored var importSourceOverride: String?
    /// True while a YouTube link's audio is downloading (before separation starts).
    var downloadingFromYouTube = false

    // Export
    var exportSheet = false
    var exportFormat: ExportFormat = .wav
    var exportFileName = ""
    /// Export only the loop (for drilling one section away from the Mac).
    var exportLoopOnly = false
    var isExporting = false
    var exportProgress = 0.0
    var toast: Toast?

    struct Toast: Equatable, Identifiable {
        let id = UUID()
        var text: String
        var url: URL?
        var isError = false
    }

    /// Global "I'm playing" choice remembered across songs (nil = full mix).
    @ObservationIgnored @AppStorage("playingInstrument") private var playingInstrumentRaw: String = StemKind.leadGuitar.rawValue

    let engine = PlaybackEngine()
    let store = SongStore.shared
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var ticker: Timer?
    /// Serialises everything that reallocates engine memory (song loads, exports).
    @ObservationIgnored private let engineGate = EngineGate()
    @ObservationIgnored private var loadGeneration = 0
    /// Set while the user drags the playhead so the ticker doesn't fight the drag.
    @ObservationIgnored var isScrubbing = false

    init() {
        library = store.loadAll()
        SeparationService.shared.warmUp()
        startTicker()
    }

    /// Detected tempo scaled by the user's half-time / double-time choice.
    var bpm: Double { (song?.analysis.bpm ?? 0) * settings.tempoScale }
    var detectedBPM: Double { song?.analysis.bpm ?? 0 }

    /// Beat grid at the chosen tempo: half-time keeps every other beat (aligned to bar starts),
    /// double-time inserts midpoints.
    var effectiveBeats: [Double] {
        guard let beats = song?.analysis.beats, beats.count > 1 else { return song?.analysis.beats ?? [] }
        switch settings.tempoScale {
        case 0.5:
            let first = song?.analysis.downbeats.first ?? beats[0]
            let offset = beats.firstIndex { abs($0 - first) < 0.02 } ?? 0
            return beats.enumerated().filter { ($0.offset - offset) % 2 == 0 }.map(\.element)
        case 2:
            var out: [Double] = []
            for (a, b) in zip(beats, beats.dropFirst()) { out.append(a); out.append((a + b) / 2) }
            out.append(beats.last!)
            return out
        default:
            return beats
        }
    }

    func setTempoScale(_ s: Double) { settings.tempoScale = s }
    var duration: Double { song?.duration ?? 0 }
    var sections: [SongAnalysis.Section] {
        guard let song else { return [] }
        return song.analysis.sections.map { s in
            var s = s
            if let custom = settings.sectionNames[Self.sectionKey(s.start)] { s.label = custom }
            return s
        }
    }
    static func sectionKey(_ t: Double) -> String { String(Int((t * 1000).rounded())) }

    // MARK: - Stem state

    /// Tracks shown in the mixer and loaded in the engine (lead/rhythm replace guitar when split).
    var stems: [StemKind] { song?.mixStems ?? [] }

    func isOn(_ k: StemKind) -> Bool { !settings.removed.contains(k) }
    func isAudible(_ k: StemKind) -> Bool {
        if let solo = settings.solo { return solo == k }
        return isOn(k)
    }

    func toggle(_ k: StemKind) {
        if settings.removed.contains(k) { settings.removed.remove(k) } else { settings.removed.insert(k) }
        rememberPlayingChoice()
    }

    func toggleSolo(_ k: StemKind) { settings.solo = settings.solo == k ? nil : k }

    func setVolume(_ k: StemKind, _ v: Double) { settings.volumes[k.rawValue] = v.rounded() }

    /// "I'm playing" pill: removes exactly that stem; clicking the active one restores the full mix.
    func choosePlaying(_ k: StemKind) {
        if playingStem == k {
            settings.removed = []
        } else {
            settings.removed = [k]
        }
        settings.solo = nil
        rememberPlayingChoice()
    }

    /// The single removed stem, if exactly one is removed.
    var playingStem: StemKind? { settings.removed.count == 1 ? settings.removed.first : nil }

    /// Remembers the instrument the user plays for new songs. Only a single-instrument choice is kept;
    /// full mix or multi-stem experiments don't overwrite it (the default stays Lead guitar).
    private func rememberPlayingChoice() {
        guard let k = playingStem else { return }
        // Lead and plain Guitar are the same choice for songs with/without a split.
        playingInstrumentRaw = (k == .guitar ? StemKind.leadGuitar : k).rawValue
    }

    // MARK: - Transport

    @ObservationIgnored private var lastTransportCommand = Date.distantPast

    func togglePlay() {
        guard song != nil else { return }
        lastTransportCommand = Date()
        if isPlaying { engine.pause() } else {
            engine.play()
        }
        isPlaying.toggle()
    }

    @ObservationIgnored private var lastSeek = Date.distantPast

    func seek(to t: Double) {
        lastSeek = Date()
        let clamped = max(0, min(duration, t))
        engine.seek(frame: Int64(clamped * engine.sampleRate))
        position = clamped
    }

    func nudge(bars: Int) {
        let barLen = bpm > 0 ? 240 / bpm : 2
        seek(to: position + Double(bars) * barLen)
    }

    /// One-button loop capture while listening: first press sets A, second sets B (and loops),
    /// third clears. Points snap to the nearest bar line within a beat, else to the nearest beat.
    var loopCaptureA: Double?

    enum ABState { case setA, setB, clear }
    var abState: ABState {
        if loopCaptureA != nil { return .setB }
        return settings.loopEnabled && loopRange != nil ? .clear : .setA
    }

    func abPress() {
        switch abState {
        case .setA:
            loopCaptureA = snapToBar(position)
        case .setB:
            guard let a = loopCaptureA else { return }
            let beat = bpm > 0 ? 60 / bpm : 0.5
            var b = snapToBar(position)
            // Only stretch to a minimum length when the two marks are closer than a beat;
            // marking B before A (after seeking back) makes the loop B–A.
            if abs(b - a) < beat { b = min(duration, a + max(beat, snapToBar(position + beat) - a)) }
            loopCaptureA = nil
            setLoop(start: min(a, b), end: max(a, b))
            seek(to: min(a, b))
        case .clear:
            settings.loopEnabled = false
            loopCaptureA = nil
        }
    }

    /// Nearest bar line if within one beat, otherwise nearest beat.
    func snapToBar(_ t: Double) -> Double {
        let beat = bpm > 0 ? 60 / bpm : 0.5
        if let bars = song?.analysis.downbeats, !bars.isEmpty {
            let nearest = bars.min { abs($0 - t) < abs($1 - t) }!
            if abs(nearest - t) <= beat { return nearest }
        }
        let beats = effectiveBeats
        guard !beats.isEmpty else { return t }
        return beats.min { abs($0 - t) < abs($1 - t) }!
    }

    func toggleLoop() {
        if settings.loopStart == nil { defaultLoopFromPosition() }
        settings.loopEnabled.toggle()
    }

    func loopSection(_ s: SongAnalysis.Section) {
        settings.loopStart = s.start
        settings.loopEnd = s.end
        settings.loopEnabled = true
        seek(to: s.start)
    }

    func setLoop(start: Double, end: Double) {
        settings.loopStart = max(0, min(start, end - 0.25))
        settings.loopEnd = min(duration, max(end, start + 0.25))
        settings.loopEnabled = true
    }

    /// Snaps a time to the nearest beat (within 120 ms) for loop edges.
    func snapToBeat(_ t: Double) -> Double {
        let beats = effectiveBeats
        guard !beats.isEmpty else { return t }
        var lo = 0, hi = beats.count - 1
        while lo < hi { let m = (lo + hi) / 2; if beats[m] < t { lo = m + 1 } else { hi = m } }
        let cands = [beats[max(0, lo - 1)], beats[lo]]
        let best = cands.min { abs($0 - t) < abs($1 - t) }!
        return abs(best - t) < 0.12 ? best : t
    }

    private func defaultLoopFromPosition() {
        if let s = sections.first(where: { $0.start <= position && position < $0.end }) {
            settings.loopStart = s.start
            settings.loopEnd = s.end
        } else {
            let bar = bpm > 0 ? 240 / bpm : 4
            settings.loopStart = position
            settings.loopEnd = min(duration, position + 4 * bar)
        }
    }

    var loopRange: ClosedRange<Double>? {
        guard let a = settings.loopStart, let b = settings.loopEnd, b > a else { return nil }
        return a...b
    }

    var currentLoopSection: SongAnalysis.Section? {
        guard settings.loopEnabled, let r = loopRange else { return nil }
        return sections.first { abs($0.start - r.lowerBound) < 0.01 && abs($0.end - r.upperBound) < 0.01 }
    }

    func stepSpeed(_ d: Int) {
        settings.trainer.enabled = false
        settings.speed = max(50, min(150, settings.speed + d * 5))
    }
    func stepPitch(_ d: Int) { settings.pitch = max(-12, min(12, settings.pitch + d)) }


    // MARK: - Mix waveform

    /// Each bar = sqrt(Σ audible (peak × gain)²) / sqrt(Σ all peak²) × overall envelope.
    @ObservationIgnored private var mixBarsCache: (key: Int, bars: [Float])?

    func mixBars(count: Int) -> [Float] {
        guard let song else { return [] }
        // Depends only on the song, the bar count and the mix settings — not the playhead — so it is
        // cached and the 30 Hz position updates don't re-sample every stem.
        var h = Hasher()
        h.combine(song.id); h.combine(count); h.combine(settings.removed); h.combine(settings.solo)
        h.combine(settings.volumes); h.combine(settings.showGuitarSplit)
        let key = h.finalize()
        if let c = mixBarsCache, c.key == key { return c.bars }
        let bars = computeMixBars(song: song, count: count)
        mixBarsCache = (key, bars)
        return bars
    }

    private func computeMixBars(song: SongRecord, count: Int) -> [Float] {
        var sum = [Float](repeating: 0, count: count)
        var tot = [Float](repeating: 0, count: count)
        for k in song.mixStems {
            let p = song.peaks(for: k)
            guard !p.isEmpty else { continue }
            let r = Peaks.resample(p, to: count)
            let g = isAudible(k) ? Float(settings.volume(k) / 80) : 0
            for i in 0..<count {
                tot[i] += r[i] * r[i]
                sum[i] += (r[i] * g) * (r[i] * g)
            }
        }
        let env = tot.map { sqrt($0) }
        let envMax = max(env.max() ?? 1, 1e-6)
        return (0..<count).map { i in
            let frac = tot[i] > 0 ? min(1.2, sqrt(sum[i] / tot[i])) : 0
            return min(1, frac * (0.25 + 0.75 * env[i] / envMax))
        }
    }

    // MARK: - Mini player

    /// True while the compact floating player is the active window.
    var isMiniPlayer = false
    func enterMiniPlayer() { isMiniPlayer = true }
    func exitMiniPlayer() { isMiniPlayer = false }
    @ObservationIgnored lazy var miniPlayer = MiniPlayerController(model: self)
    @ObservationIgnored weak var mainWindow: NSWindow?
    func toggleMiniPlayer() { miniPlayer.toggle(from: mainWindow ?? NSApp.windows.first { $0.identifier?.rawValue == "main" }) }

    // MARK: - Engine sync

    private func settingsChanged(from old: SongSettings) {
        guard song != nil else { return }
        pushMix()
        if old.speed != settings.speed { engine.setRate(Double(settings.speed) / 100) }
        if old.pitch != settings.pitch { engine.setSemitones(Double(settings.pitch)) }
        if old.loopEnabled != settings.loopEnabled || old.loopStart != settings.loopStart || old.loopEnd != settings.loopEnd {
            pushLoop()
        }
        if old.countIn != settings.countIn || old.tempoScale != settings.tempoScale { pushCountIn() }
        if old.tempoScale != settings.tempoScale { pushBeatGrid() }
        if old.click != settings.click { engine.setClick(settings.click) }
        if old.trainer != settings.trainer || old.loopEnabled != settings.loopEnabled { pushTrainer() }
        scheduleSave()
    }

    private func pushAll() {
        pushMix()
        engine.setRate(Double(settings.speed) / 100)
        engine.setSemitones(Double(settings.pitch))
        pushLoop()
        pushCountIn()
        pushTrainer()
        pushBeatGrid()
        engine.setClick(settings.click)
    }

    /// Metronome grid at the chosen tempo, accented on bar starts.
    private func pushBeatGrid() {
        let beats = effectiveBeats
        let bars = song?.analysis.downbeats ?? []
        let accents = beats.map { b in bars.contains { abs($0 - b) < 0.03 } }
        engine.setBeatGrid(beats, accents: accents)
    }

    private func pushTrainer() {
        let t = settings.trainer
        engine.setTrainer(enabled: t.enabled && settings.loopEnabled, from: Double(t.from) / 100,
                          step: Double(t.step) / 100, every: t.every, to: Double(t.to) / 100)
    }

    /// Linear gain for a track: its fader when audible; −15 dB of its fader when removed in guide mode.
    func trackGain(_ k: StemKind) -> Float {
        let fader = Self.gain(forVolume: settings.volume(k))
        if isAudible(k) { return fader }
        if settings.guide && settings.solo == nil && !isOn(k) { return fader * 0.178 }   // −15 dB
        return 0
    }

    /// Perceptual fader: 80 = unity (0 dB), 100 = +6 dB, 40 ≈ −12 dB, 0 = silent.
    static func gain(forVolume v: Double) -> Float {
        guard v > 0 else { return 0 }
        let db = v >= 80 ? (v - 80) * 0.3 : -60 * pow(1 - v / 80, 1.6) * (v < 2 ? 2 : 1)
        return Float(pow(10, db / 20))
    }

    private func pushMix() {
        for (i, k) in stems.enumerated() {
            let scale = song?.storageGain(k) ?? 1
            let g = trackGain(k) / max(scale, 1e-6)
            engine.setGain(stem: i, g)
        }
    }

    private func pushLoop() {
        let sr = engine.sampleRate
        if let r = loopRange {
            engine.setLoop(enabled: settings.loopEnabled, start: Int64(r.lowerBound * sr), end: Int64(r.upperBound * sr))
        } else {
            engine.setLoop(enabled: false, start: 0, end: 0)
        }
    }

    private func pushCountIn() {
        engine.setCountIn(enabled: settings.countIn, bpm: bpm > 0 ? bpm : 120, beats: 4)
    }

    private func startTicker() {
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        guard song != nil else { return }
        let st = engine.status
        let p = Double(st.position) / engine.sampleRate
        if !isScrubbing && Date().timeIntervalSince(lastSeek) > 0.12 && abs(p - position) > 0.0005 { position = p }
        // Only trust "stopped" once the engine has had time to act on our last play command
        // (commands are applied at the next render quantum).
        if isPlaying && !st.playing && Date().timeIntervalSince(lastTransportCommand) > 0.25 {
            isPlaying = false
        }
        if st.countInBeat != countInBeat { countInBeat = st.countInBeat }
        if st.loopPasses != loopPasses { loopPasses = st.loopPasses }
        let live = settings.trainer.enabled && settings.loopEnabled
            ? (st.playing ? Int((st.rate * 100).rounded()) : settings.trainer.from)
            : settings.speed
        if live != liveSpeed { liveSpeed = live }
    }

    // MARK: - Library / import

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff, .mpeg4Audio, UTType("org.xiph.flac")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.message = "Choose a song to split into parts"
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        guard AudioDecoder.isSupported(url) else {
            dropRejected = true
            if song == nil { screen = .empty }
            return
        }
        dropRejected = false
        let accessing = url.startAccessingSecurityScopedResource()
        guard let id = try? SongStore.contentID(of: url) else {
            if accessing { url.stopAccessingSecurityScopedResource() }
            screen = .failed("Backline couldn't read this file.")
            return
        }
        if let existing = library.first(where: { $0.id == id }) {
            if accessing { url.stopAccessingSecurityScopedResource() }
            select(existing)
            return
        }
        startImport(url: url, id: id, accessing: accessing)
    }

    private func startImport(url: URL, id: String, accessing: Bool) {
        if !url.path.contains("/Backline/Downloads/") { lastYouTube = nil }
        persistCurrent()
        stopPlayback()
        lastImportURL = url
        importTitle = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
        importProgress = ImportProgress(phase: 0, fraction: 0, secondsRemaining: nil)
        cancelBox.value = false
        withAnimation(.smooth(duration: 0.35)) { screen = .analyzing }
        let store = self.store
        importTask = Task { [weak self] in
            Task { if let t = await TrackMetadata.load(from: url).title { await MainActor.run { self?.importTitle = t } } }
            do {
                let (imported, stems) = try await Task.detached(priority: .userInitiated) { [weak self] in
                    try await ImportPipeline.run(url: url, id: id, store: store, progress: { p in
                        Task { @MainActor in self?.importProgress = p }
                    }, isCancelled: { [cancelBox = self?.cancelBox] in cancelBox?.value ?? true })
                }.value
                if accessing { url.stopAccessingSecurityScopedResource() }
                guard let self else { return }
                var rec = imported
                if self.importTitleOverride != nil || self.importArtistOverride != nil || self.importSourceOverride != nil {
                    if let t = self.importTitleOverride { rec.title = t }
                    if let a = self.importArtistOverride { rec.artist = a }
                    if let src = self.importSourceOverride { rec.sourceName = src }
                    self.importTitleOverride = nil
                    self.importArtistOverride = nil
                    self.importSourceOverride = nil
                    try? self.store.save(rec)
                }
                self.library.insert(rec, at: 0)
                // Our own recordings/downloads are temporary once split (the stems live in the library).
                if url.path.contains("/Backline/Recordings/") || url.path.contains("/Backline/Downloads/") {
                    try? FileManager.default.removeItem(at: url)
                }
                self.loadGeneration += 1
                await self.engineGate.acquire()
                self.activate(rec, stems: stems, fresh: true)
                await self.engineGate.release()
            } catch is CancellationError {
                if accessing { url.stopAccessingSecurityScopedResource() }
                self?.store.delete(id)
                guard let self else { return }
                withAnimation(.smooth) { self.screen = self.song == nil ? .empty : .mixer }
            } catch {
                if accessing { url.stopAccessingSecurityScopedResource() }
                self?.store.delete(id)
                withAnimation(.smooth) { self?.screen = .failed(error.localizedDescription) }
            }
        }
    }

    /// Pasted / dropped YouTube link → download the audio (yt-dlp) → normal import.
    func openYouTube(_ video: YouTubeImport.Video) {
        guard YouTubeImport.isEnabled else { return }
        lastYouTube = video
        lastImportURL = nil
        // Already in the library? Reopen instantly.
        if let existing = library.first(where: { $0.sourceName == "youtube:\(video.id)" }) {
            select(existing)
            return
        }
        persistCurrent()
        stopPlayback()
        importTitle = "YouTube link"
        importProgress = ImportProgress(phase: 0, fraction: 0, secondsRemaining: nil)
        downloadingFromYouTube = true
        cancelBox.value = false
        withAnimation(.smooth(duration: 0.35)) { screen = .analyzing }
        let cancel = cancelBox
        importTask = Task { [weak self] in
            do {
                let progress: @Sendable (Double) -> Void = { p in
                    Task { @MainActor in self?.importProgress = ImportProgress(phase: 0, fraction: p, secondsRemaining: nil) }
                }
                // Signed-in session (if the user signed in) → temporary cookies.txt, deleted right after.
                let cookieFile = YouTubeSignIn.isEnabled && YouTubeSignIn.isSignedIn ? await YouTubeSignIn.writeCookieFile() : nil
                let result: YouTubeImport.Result
                do {
                    result = try await YouTubeImport.download(video, cookieFile: cookieFile, progress: progress,
                                                              isCancelled: { cancel.value })
                    if let cookieFile { await YouTubeSignIn.finish(cookieFile: cookieFile) }
                } catch {
                    if let cookieFile { await YouTubeSignIn.finish(cookieFile: cookieFile) }
                    // Sent cookies but YouTube still wants a sign-in → the session expired.
                    if cookieFile != nil, case YouTubeImport.Failure.needsSignIn = error { await YouTubeSignIn.sessionExpired() }
                    throw error
                }
                guard let self else { return }
                self.downloadingFromYouTube = false
                if let t = result.title { self.importTitle = t }
                self.importTitleOverride = result.title
                self.importArtistOverride = result.uploader
                self.importSourceOverride = "youtube:\(video.id)"
                self.open(result.file)
            } catch is CancellationError {
                guard let self else { return }
                self.downloadingFromYouTube = false
                withAnimation(.smooth) { self.screen = self.song == nil ? .empty : .mixer }
            } catch {
                guard let self else { return }
                self.downloadingFromYouTube = false
                withAnimation(.smooth) { self.screen = .failed(error.localizedDescription) }
            }
        }
    }

    /// Opens whatever was pasted or dropped: a YouTube link or a file URL.
    func openText(_ text: String) -> Bool {
        if let v = YouTubeImport.find(in: text), YouTubeImport.isEnabled { openYouTube(v); return true }
        return false
    }

    func cancelImport() {
        cancelBox.value = true
        importTask?.cancel()
    }

    @ObservationIgnored var lastYouTube: YouTubeImport.Video?
    /// The "Add a song" sheet (file / YouTube link / record), from every "+" and ⌘O.
    var addSongSheet = false

    /// One entry point for adding music, everywhere ("+ Add song", "Add a song…", ⌘O): the Add Song
    /// sheet with the same three choices — a file, a YouTube link, or record from an app.
    func addSong() {
        addSongSheet = true
    }

    /// Shows the "Sign in to YouTube" window (from the error screen, Settings or Help).
    var youTubeSignInSheet = false
    /// Page the Help window shows (set by the "?" buttons before opening it).
    var helpTopic: HelpTopic? = .start
    /// First launch: a three-card welcome, shown once.
    var showWelcome = !UserDefaults.standard.bool(forKey: "welcomeSeen")

    func retryImport() {
        if let v = lastYouTube, lastImportURL == nil { openYouTube(v); return }
        if let url = lastImportURL { open(url) } else { screen = .empty }
    }

    func select(_ rec: SongRecord) {
        guard rec.id != song?.id else { if screen != .mixer { screen = .mixer }; return }
        guard !isExporting else {
            showToast(Toast(text: "Still saving your track. One moment…"))
            return
        }
        persistCurrent()
        stopPlayback()
        loadGeneration += 1
        let generation = loadGeneration
        // Load stems off the main thread straight into engine memory (one load at a time).
        let store = self.store
        let engine = self.engine
        let gate = engineGate
        Task {
            await gate.acquire()
            defer { Task { await gate.release() } }
            guard generation == self.loadGeneration else { return }
            let ok = await Task.detached(priority: .userInitiated) { () -> Bool in
                Self.loadEngine(rec, store: store, engine: engine)
            }.value
            guard generation == self.loadGeneration else { return }
            guard ok else {
                self.library.removeAll { $0.id == rec.id }
                self.store.delete(rec.id)
                self.screen = .failed("This song's parts are missing. Add the song again.")
                return
            }
            self.activate(rec, stems: nil, fresh: false)
        }
    }

    /// Reads the song's mix tracks from disk straight into engine memory. Off the main thread.
    nonisolated static func loadEngine(_ rec: SongRecord, store: SongStore, engine: PlaybackEngine) -> Bool {
                let tracks = rec.mixStems
                let frames = tracks.map { SongStore.frameCount(of: store.mixURL(rec, $0)) }.max() ?? 0
                guard frames > 0, engine.allocate(stemCount: tracks.count, frames: frames) else { return false }
                for (i, k) in tracks.enumerated() {
                    guard let l = engine.channelPointer(stem: i, channel: 0),
                          let r = engine.channelPointer(stem: i, channel: 1) else { return false }
                    do { try store.readStem(store.mixURL(rec, k), left: l, right: r, capacity: frames) } catch { return false }
                    engine.setPitchLocked(stem: i, k.isPitchLocked)
                }
                return true
    }

    /// Makes `rec` current. When `stems` is given (fresh import) they are loaded into the engine here.
    private func activate(_ rec: SongRecord, stems: [StemKind: StereoAudio]?, fresh: Bool) {
        var rec = rec
        if let stems {
            let tracks = rec.mixStems
            _ = engine.allocate(stemCount: tracks.count, frames: stems.values.map(\.frameCount).max() ?? 0)
            for (i, k) in tracks.enumerated() {
                guard let s = stems[k] else { continue }
                let scale = rec.storageGain(k)
                if let l = engine.channelPointer(stem: i, channel: 0), let r = engine.channelPointer(stem: i, channel: 1) {
                    // Match what reopening from disk will give (stored scaled), so gains are consistent.
                    for j in 0..<s.frameCount { l[j] = s.left[j] * scale; r[j] = s.right[j] * scale }
                }
                engine.setPitchLocked(stem: i, k.isPitchLocked)
            }
        }
        if fresh {
            var st = SongSettings()
            // Apply the remembered "I'm playing" choice. Lead guitar is the default goal; a song
            // without a lead/rhythm split falls back to its single guitar stem (and vice versa).
            let tracks = rec.mixStems
            if let k = StemKind(rawValue: playingInstrumentRaw.isEmpty ? StemKind.leadGuitar.rawValue : playingInstrumentRaw) {
                if tracks.contains(k) { st.removed = [k] }
                else if k.isGuitar, let g = tracks.first(where: { $0 == .leadGuitar }) ?? tracks.first(where: { $0 == .guitar }) {
                    st.removed = [g]
                }
            }
            if let solo = rec.analysis.sections.first(where: { $0.label.hasPrefix("Solo") }) {
                st.loopStart = solo.start
                st.loopEnd = solo.end
                st.loopEnabled = true
                st.lastPosition = solo.start
            }
            rec.settings = st
        }
        rec.lastOpened = Date()
        engine.commit()
        song = rec
        artwork = rec.hasArtwork ? store.artwork(rec.id).flatMap(NSImage.init(data:)) : nil
        settings = rec.settings
        exportFileName = ""
        pushAll()
        let start = rec.settings.lastPosition < rec.duration - 1 ? rec.settings.lastPosition : 0
        seek(to: start)
        loopPasses = 0
        loopCaptureA = nil
        withAnimation(.smooth(duration: 0.4)) { screen = .mixer }
        if let i = library.firstIndex(where: { $0.id == rec.id }) { library[i] = rec }
        scheduleSave()
    }

    private func stopPlayback() {
        if isPlaying { engine.pause(); isPlaying = false }
    }

    func showEmpty() {
        persistCurrent()
        stopPlayback()
        dropRejected = false
        withAnimation(.smooth(duration: 0.3)) { screen = .empty }
    }

    func remove(_ rec: SongRecord) {
        if rec.id == song?.id {
            stopPlayback()
            song = nil
            screen = .empty
        }
        library.removeAll { $0.id == rec.id }
        store.delete(rec.id)
    }

    func renameSection(_ s: SongAnalysis.Section, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.sectionKey(s.start)
        if trimmed.isEmpty { settings.sectionNames[key] = nil } else { settings.sectionNames[key] = trimmed }
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.persistCurrent() } }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
    }

    /// Saves the current song's settings. `synchronously` for quit/close, where a background write
    /// would be lost when the process exits.
    func persistCurrent(synchronously: Bool = false) {
        saveWork?.cancel(); saveWork = nil
        guard var rec = song else { return }
        rec.settings = settings
        rec.settings.lastPosition = position
        song = rec
        if let i = library.firstIndex(where: { $0.id == rec.id }) { library[i] = rec }
        let store = self.store
        if synchronously { try? store.save(rec) }
        else { Task.detached(priority: .utility) { try? store.save(rec) } }
    }

    // MARK: - Export

    var audibleStems: [StemKind] { stems.filter(isAudible) }

    var defaultExportName: String {
        guard let song else { return "" }
        let removed = stems.filter { !isAudible($0) }
        let tag = removed.isEmpty ? "" : " – no " + removed.map { $0.name.lowercased() }.joined(separator: ", ")
        return song.title + tag
    }

    func openExport() {
        guard song != nil else { return }
        if isPlaying { togglePlay() }
        exportLoopOnly = false
        exportFileName = defaultExportName
        exportSheet = true
    }

    func performExport() {
        guard let song else { return }
        // Snapshot the mix before the modal save panel: nothing the user types there (or any key that
        // reaches the app) can change what gets exported.
        let removed = settings.removed
        let gains: [Float] = stems.map { k in
            // The backing track never contains a removed part — not via Guide, not via Solo.
            (isAudible(k) && !removed.contains(k)) ? Self.gain(forVolume: settings.volume(k)) / max(song.storageGain(k), 1e-6) : 0
        }
        let rate = Double(settings.speed) / 100
        let semitones = Double(settings.pitch)
        let loopOnly = exportLoopOnly
        let loop = loopRange
        let base = exportFileName.trimmingCharacters(in: .whitespaces).isEmpty ? defaultExportName : exportFileName
        let name = (base as NSString).deletingPathExtension == base ? base : (base as NSString).deletingPathExtension
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name + "." + exportFormat.fileExtension
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent("Backline")
        try? FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        panel.directoryURL = music
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: exportFormat.fileExtension) ?? .audio]
        exportSheet = false
        guard panel.runModal() == .OK, let url = panel.url, self.song?.id == song.id else { return }

        let sr = engine.sampleRate
        var range: (Int64, Int64) = (0, 0)
        if loopOnly, let r = loop { range = (Int64(r.lowerBound * sr), Int64(r.upperBound * sr)) }
        let job = ExportJob(settings: .init(gains: gains, rate: rate, semitones: semitones,
                                            start: range.0, end: range.1),
                            format: exportFormat, url: url, title: song.title, artist: song.artist)
        isExporting = true
        exportProgress = 0
        let engine = self.engine
        let gate = engineGate
        let songID = song.id
        Task {
            await gate.acquire()
            // A song switch queued ahead of us may have reloaded the engine: never export the wrong audio.
            guard self.song?.id == songID, engine.stemCount == job.settings.gains.count else {
                await gate.release()
                self.isExporting = false
                self.showToast(Toast(text: "Didn't save, because the song changed.", isError: true))
                return
            }
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Exporter.run(job, engine: engine) { p in Task { @MainActor in self.exportProgress = p } } }
            }.value
            await gate.release()
            self.isExporting = false
            switch result {
            case .success:
                let folder = url.deletingLastPathComponent()
                let where_ = folder.standardizedFileURL == music.standardizedFileURL ? "Music › Backline" : folder.lastPathComponent
                self.showToast(Toast(text: "Saved to \(where_)", url: url))
            case .failure(let e):
                self.showToast(Toast(text: "Couldn't save. \(e.localizedDescription)", isError: true))
            }
        }
    }

    func showToast(_ t: Toast) {
        withAnimation(.spring(duration: 0.35)) { toast = t }
        let id = t.id
        DispatchQueue.main.asyncAfter(deadline: .now() + (t.url != nil ? 4 : 2.6)) { [weak self] in
            MainActor.assumeIsolated {
                if self?.toast?.id == id { withAnimation(.easeOut(duration: 0.25)) { self?.toast = nil } }
            }
        }
    }
}
