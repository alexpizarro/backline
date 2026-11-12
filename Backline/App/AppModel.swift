import AppKit
import BacklineKit
import ImageIO
import Observation
import SwiftUI
import Synchronization
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
    var screen: Screen = .empty {
        // Back on the open song after an import was cancelled or failed: whatever it was waiting for (the lead
        // refinement, the kit split, the cleaner pass) carries on, as iOS does when the app comes back.
        didSet {
            if screen == .mixer, oldValue != .mixer { resumeBackgroundWork() }
            if oldValue == .analyzing, screen != .analyzing { importMayHaveEnded() }
        }
    }
    var dropRejected = false

    // Import
    var importTitle = ""
    var importArtist = ""
    /// The song's picture while a link is being fetched (a video's thumbnail, a music service's cover).
    var importArtwork: NSImage?
    var importProgress = ImportProgress(phase: 0, fraction: 0, secondsRemaining: nil)
    @ObservationIgnored var importTask: Task<Void, Never>?
    /// The file of the last import from a file (nil for a link): the failure screen and Try again read it,
    /// and every link path clears it.
    var lastImportURL: URL?
    /// The running import's own cancel flag (a new import gets a new one, so it never revives an old import).
    @ObservationIgnored var cancelBox = CancelBox()

    // Current song
    var song: SongRecord? {
        didSet {
            refreshPlayheadSection()
            refreshPlayheadReadouts()
            if song?.id != oldValue?.id || mapWindow.duration != max(duration, 0.001) { mapWindow = .whole(duration) }
            if (song == nil) != (oldValue == nil) || song?.duration != oldValue?.duration {
                retuneTicker()
                updateTimeText()
            }
            if song?.id != oldValue?.id { NowPlaying.shared.refresh() }
        }
    }
    /// What the Map and its tapes show (U07): the whole song, or a pinch-zoomed part of it.
    var mapWindow = MapWindow.whole(1)
    /// A pinch or two-finger pan on the Map is in progress: the view doesn't turn pages under the fingers.
    @ObservationIgnored var mapGestureActive = false
    var artwork: NSImage? { didSet { if artwork !== oldValue { NowPlaying.shared.refresh() } } }
    var settings = SongSettings() { didSet { settingsChanged(from: oldValue) } }
    #if DEBUG
    /// How many times `settings` was written (tests check one write per user action).
    @ObservationIgnored var settingsChangeCount = 0
    #endif

    /// One settings write per user action: every change lands in a single assignment, so the engine pushes,
    /// the save timer and every view that reads `settings` run once instead of once per field.
    func updateSettings(_ change: (inout SongSettings) -> Void) {
        var s = settings
        change(&s)
        if s != settings { settings = s }
    }

    // Transport (published at display rate by the ticker)
    var position: Double = 0 {
        didSet {
            // Zoomed in: when the playhead leaves the view, turn the page (U07).
            if mapWindow.isZoomed, !isScrubbing, !mapGestureActive, let next = mapWindow.following(position) { mapWindow = next }
            updateTimeText()
            refreshPlayheadSection()
            refreshPlayheadReadouts()
        }
    }
    /// The section under the playhead (nil before the first). Set only when it changes, so a view that reads it
    /// doesn't redraw with every tick of `position` (UIP-11).
    private(set) var playheadSection: Int?

    private func refreshPlayheadSection() {
        // The starts are enough: renamed labels don't move a section, so the list isn't rebuilt per tick (UIP-11).
        let i = song?.analysis.sections.lastIndex { $0.start <= position }
        if i != playheadSection { playheadSection = i }
    }

    /// What the count strip draws: the count and the bar at the playhead, set only when one changes (UIP-11).
    struct PlayheadBeat: Equatable { var count: Int?; var bar: Int? }
    private(set) var playheadBeat = PlayheadBeat()

    /// Updates the count strip's values from the playhead, writing only a change.
    func refreshPlayheadReadouts() {
        let beat = song == nil ? PlayheadBeat() : PlayheadBeat(count: currentCount, bar: mode == .beats ? currentBar : nil)
        if beat != playheadBeat { playheadBeat = beat }
    }
    /// What the time labels show. It changes once a second, so they redraw once a second instead of with
    /// every tick of `position` (UIP-11).
    private(set) var timeText = TimeText()
    struct TimeText: Equatable {
        var elapsed = formatTime(0)
        var remaining = formatTime(0)
    }
    private func updateTimeText() {
        let next = TimeText(elapsed: formatTime(position), remaining: formatTime(max(0, duration - position)))
        if next != timeText { timeText = next }
    }
    var isPlaying = false {
        didSet {
            guard isPlaying != oldValue else { return }
            retuneTicker()
            WaveformScheduler.shared.isPlaying = isPlaying
            NowPlaying.shared.refresh()
            // Nothing plays: a Library song's lead refinement may go now (D19).
            if !isPlaying { ensureLibraryLeadRefine() }
        }
    }
    var countInBeat = 0
    var loopPasses: UInt32 = 0
    /// Speed actually playing (differs from settings.speed while the speed trainer runs).
    var liveSpeed = 100

    // Record from an app
    var recordSheet = false
    /// True while the Record window is taking a recording (the microphone, or another app's sound): Quit asks first.
    @ObservationIgnored var recordingUnderWay = false
    /// Title to use for the next import (recordings have no metadata).
    @ObservationIgnored var importTitleOverride: String?
    @ObservationIgnored var importArtistOverride: String?
    @ObservationIgnored var importSourceOverride: String?
    @ObservationIgnored var importArtworkOverride: Data?
    /// True while a link's audio is downloading (before separation starts): "Getting the song".
    var downloadingFromYouTube = false {
        didSet {
            if downloadingFromYouTube, !oldValue { linkWait.begin() }
            if !downloadingFromYouTube, oldValue { linkWait.end(); importMayHaveEnded() }
        }
    }
    /// The wait before a link's audio arrives: its stage, "Still trying" after 15 s, the song service's minutes (L2).
    let linkWait = LinkWait()
    /// True while the song service is getting a song this Mac couldn't: "Trying another way…".
    var tryingAnotherWay = false
    /// The file or Vimeo link being downloaded or last tried, for Try again.
    @ObservationIgnored var lastLink: WebLink?
    /// A link to a song on a music service: the lookup, the match and its sheets (S04, `AppModel+Spotify`).
    let spotify = SpotifyFlow()

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
    @ObservationIgnored @AppStorage("playingInstrument") var playingInstrumentRaw: String = StemKind.leadGuitar.rawValue

    /// The practice mode last used (Play · Dance · Beats). Songs remember their own; this is the default.
    var appMode: PracticeMode = PracticeMode(rawValue: UserDefaults.standard.string(forKey: "practiceMode") ?? "") ?? .play {
        didSet {
            UserDefaults.standard.set(appMode.rawValue, forKey: "practiceMode")
            refreshPlayheadReadouts()
        }
    }

    let engine = PlaybackEngine()
    /// The playhead the views draw: eases between the engine's positions and is optimistic under a finger.
    let clock: TransportClock
    let store = SongStore.shared
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var ticker: Timer?
    /// Serialises everything that reallocates engine memory (song loads, exports).
    @ObservationIgnored let engineGate = EngineGate()
    @ObservationIgnored var loadGeneration = 0
    /// Tracks currently in engine memory (the song's engine tracks as of its last load).
    @ObservationIgnored var loadedTracks: [StemKind] = []
    /// Each loaded track's `SongStore.formatGain` as of its last load (2 for an AAC part, D19); a track not
    /// listed is 1. Read under the engine gate, as the parts were, so it is the level of what the engine holds.
    @ObservationIgnored var loadedFormatGains: [StemKind: Float] = [:]
    /// The background read of the open song's parts (U01); the next song cancels it.
    @ObservationIgnored var engineFill: EngineFill?
    /// The library row whose parts are being read from disk.
    var loadingSongID: String?
    /// Background drum split of the open song (0…1 while running).
    var drumSplitProgress: Double?
    @ObservationIgnored var drumJob: Task<Void, Never>?
    @ObservationIgnored var drumCancel: CancelBox?
    /// The song whose kit split failed this session, so the cleaner pass stops waiting for it.
    @ObservationIgnored var drumSplitFailedFor: String?
    @ObservationIgnored var pendingTrackReload = false
    /// Cleaner background pass (0…1 while running).
    var hqProgress: Double?
    @ObservationIgnored var hqJob: Task<Void, Never>?
    @ObservationIgnored var hqCancel: CancelBox?
    /// The lead guitar refinement (D2, `LeadRefineJob`), and the song whose refinement failed this session.
    @ObservationIgnored var leadJob: Task<Void, Never>?
    @ObservationIgnored var leadCancel: CancelBox?
    @ObservationIgnored var leadRefineFailedFor: String?
    /// Set when the refinement was stopped so the kit split could go first (Beats, Dance for bachata).
    @ObservationIgnored var leadStoppedForKit = false
    /// The song the running lead refinement works on: the open one, or a Library song's while nothing plays.
    @ObservationIgnored var leadJobSong: String?
    /// Library songs whose lead refinement failed this session (not started again by itself).
    @ObservationIgnored var libraryLeadFailed: Set<String> = []
    /// The AAC conversion of finished parts (D19, `PartsCompactJob`), and each song's parts as last looked at.
    @ObservationIgnored var compactJob: Task<Void, Never>?
    @ObservationIgnored var compactCancel: CancelBox?
    @ObservationIgnored var compactVisited: [String: [String]] = [:]
    /// Songs whose pass was refused at its start for want of memory, this session (ios-import#4): not started
    /// again by itself until the song is next opened or the app next comes to the front.
    @ObservationIgnored var roomRefused: [String: Set<MemoryBudget.Pass>] = [:]
    /// Each running pass and the length of the song it works on, for a memory warning's question (K1): do the
    /// running passes still have room for what they make between chunks?
    @ObservationIgnored var runningPassSeconds: [MemoryBudget.Pass: Double] = [:]
    /// The running import's split (`startImport`'s task) until it ends, by its token: part of `importUnderWay`.
    @ObservationIgnored var splitRunning: Int?
    @ObservationIgnored private var splitToken = 0
    /// A look at whether the import has ended is queued for the next turn of the main actor.
    @ObservationIgnored private var importEndCheckQueued = false
    /// The open song's record with new parts on disk, applied when the engine reloads at the next pause.
    @ObservationIgnored var pendingRecord: SongRecord?
    /// Levels measured for a song split before part levels existed (U05), applied at the next pause.
    @ObservationIgnored var pendingLevels: (levels: [String: PartLevel], instruments: [String: InstrumentShares])?
    @ObservationIgnored var forceTrackReload = false
    /// Big models fetched once in the background (see ModelDownloads).
    var downloadingModel: String?
    var modelDownloadProgress: Double?
    @ObservationIgnored var modelDownloadTask: Task<Void, Never>?
    /// Models the manifest withdrew (R01d): not offered for download. Read from the last good copy at launch.
    var withdrawnModels: Set<String> = Set(ModelDownloads.assets.filter { ModelManifest.isWithdrawn($0, in: ModelManifest.lastGood()) }.map(\.name))
    /// Set while the user drags the playhead so the ticker doesn't fight the drag.
    @ObservationIgnored var isScrubbing = false {
        didSet { if isScrubbing != oldValue { retuneTicker(); WaveformScheduler.shared.kick() } }
    }
    /// True from Reset Backline's confirmation until Welcome: every way in stays shut meanwhile.
    var resetting = false

    /// Not "empty" until the songs on disk have been read (UIP-05): the sidebar doesn't say there are no songs
    /// for a moment at launch.
    var libraryIsEmpty: Bool { libraryLoaded && library.isEmpty && unfinishedImports.isEmpty }
    /// The songs on disk are in `library`. Launch reads them off the main thread, so the first frame doesn't
    /// wait for every `song.json` (UIP-05).
    private(set) var libraryLoaded = false
    @ObservationIgnored private var libraryLoad: Task<Void, Never>?

    /// Returns once the songs on disk are in `library`. Anything that asks "is this song already here?"
    /// waits for it, so a file or link that launched the app never imports a song twice.
    func libraryReady() async { await libraryLoad?.value }

    /// The song that couldn't be opened (D7, storage F7). The failure screen offers Try again and Delete song
    /// for it; nothing is deleted unless the person asks.
    var openFailure: SongRecord?
    /// Imports the last run ended during (D20 d, `WorkJournal`): the Library shows each as not finished, with
    /// Try again (from the kept file, without getting the song again) and Remove.
    var unfinishedImports: [WorkJournal.Unfinished] = WorkJournal.shared.unfinished
    /// The open song's passes that failed twice (a crash during one counts): they wait for Try again.
    var heldBackPasses: [WorkJournal.Pass] = []
    /// True while a file someone added is still being fingerprinted, once that has taken more than a moment
    /// (UIP-08): the splitting screen shows "Getting the song" until the split starts.
    var preparingFile = false

    init() {
        clock = TransportClock(engine: engine)
        loadLibrary()
        // No model warm-up at launch (F5, UIP-04): an import loads the separator when it starts.
        // The Metal views read the playhead from the clock at the display's rate; the ticker only publishes
        // what SwiftUI shows, and runs only while a song is open (UIP-11).
        WaveformScheduler.shared.clock = clock
        WaveformScheduler.shared.engine = engine
        NowPlaying.shared.attach(self)
        #if DEBUG
        let harness = Snapshotter.outputDir != nil && !CommandLine.arguments.contains("--models-base")
        #else
        let harness = false
        #endif
        if !harness {
            // Nothing is fetched before the user has said yes (R01b). The offer is the extra parts row in the
            // player, so nobody is asked about models before they have any music.
            if ModelDownloads.consent == .yes { startModelDownloads() }
        }
        // What the extra parts row offers is read off the main thread now and when the app comes back to the
        // front (free space may have changed meanwhile); the row never looks at the disk itself (UIP-02).
        ExtraParts.shared.refreshSoon()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                ExtraParts.shared.refreshSoon()
                self?.retryRoomRefused()
            }
        }
        // A memory-pressure warning stops the background passes and frees their models (D20 c, AppModel+Memory).
        watchMemory()
    }

    /// Reads every song's record off the main thread, several at once, and puts the list in place in one
    /// assignment (UIP-05). A reset that came meanwhile wins: its empty Library stays.
    private func loadLibrary() {
        let store = self.store
        let epoch = ResetBackline.epoch
        libraryLoad = Task { [weak self] in
            let songs = await Task.detached(priority: .userInitiated) { store.loadAll() }.value
            guard let self else { return }
            if ResetBackline.isCurrent(epoch) {
                // Nothing adds a song before this (every import waits for it), but keep any that did.
                let ids = Set(songs.map(\.id))
                self.library = self.library.filter { !ids.contains($0.id) } + songs
            }
            self.libraryLoaded = true
            self.ensurePartsCompact()
            self.ensureLibraryLeadRefine()
        }
    }

    /// Detected tempo scaled by the user's half-time / double-time choice.
    var bpm: Double { (song?.analysis.bpm ?? 0) * settings.tempoScale }
    var detectedBPM: Double { song?.analysis.bpm ?? 0 }

    /// Beat grid at the chosen tempo: half-time keeps every other beat (aligned to bar starts),
    /// double-time inserts midpoints.
    /// Cached on the song and the tempo choice (UIP-11): the count strip asks for it on every transport tick.
    var effectiveBeats: [Double] {
        var h = Hasher()
        h.combine(song?.id); h.combine(settings.tempoScale)
        h.combine(song?.analysis.beats.count); h.combine(song?.analysis.downbeats.first)
        let key = h.finalize()
        if let c = beatsCache, c.key == key { return c.beats }
        let beats = computeEffectiveBeats()
        beatsCache = (key, beats)
        return beats
    }
    @ObservationIgnored private var beatsCache: (key: Int, beats: [Double])?

    private func computeEffectiveBeats() -> [Double] {
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

    /// Rows shown in the mixer for the current mode (each controls one or more engine tracks).
    var stems: [StemKind] { rows.map(\.kind) }

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

    /// Every part back in the mix (the "Hear all" button, the role chip's menu, the R key).
    func hearAll() { updateSettings { $0.removed = []; $0.solo = nil; $0.spotlight = nil } }

    func setVolume(_ k: StemKind, _ v: Double) {
        let v = v.rounded()
        // An unchanged value writes nothing (a fader click that doesn't move it, the release of a drag that
        // came back to where it started).
        guard settings.volume(k) != v else { pushMix(); return }
        settings.volumes[k.rawValue] = v
    }

    /// A fader being dragged (UIP-03): the row's tracks take the new gain now, so you hear it, and the settings
    /// wait for the release (`setVolume`, once per gesture).
    func previewVolume(_ k: StemKind, _ v: Double) {
        for (i, leaf) in loadedTracks.enumerated() where rowKind(forTrack: leaf) == k {
            let scale = song?.storageGain(leaf) ?? 1
            let gain = trackGain(k, volume: v.rounded())
            engine.setGain(stem: i, gain * formatGain(leaf) / max(scale, 1e-6))
            #if DEBUG
            pushedGains[leaf] = gain
            #endif
        }
    }

    /// "I'm playing" pill: removes exactly that stem; clicking the active one restores the full mix.
    func choosePlaying(_ k: StemKind) {
        let wasPlaying = playingStem == k
        updateSettings { s in
            s.removed = wasPlaying ? [] : [k]
            s.solo = nil
        }
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

    /// Now Playing, the media keys and AirPods (WP6).
    func play() { if !isPlaying { togglePlay() } }
    func pause() { if isPlaying { togglePlay() } }

    @ObservationIgnored private var lastSeek = Date.distantPast

    func seek(to t: Double) {
        lastSeek = Date()
        let clamped = max(0, min(duration, t))
        engine.seek(frame: Int64(clamped * engine.sampleRate))
        position = clamped
        // Show the new place now, without waiting for the audio thread to apply the seek, and wake the display
        // link (asleep while paused) so the Metal playhead moves at once.
        clock.jump(to: clamped)
        WaveformScheduler.shared.kick()
        if !isScrubbing { refreshNowPlayingAfterSeek() }
    }

    @ObservationIgnored private var lastNowPlayingRefresh: CFTimeInterval = 0
    @ObservationIgnored private var nowPlayingRefreshPending = false
    #if DEBUG
    /// Now Playing refreshes after seeks, and the position each one showed (tests).
    @ObservationIgnored var nowPlayingSeekRefreshes: [Double] = []
    #endif

    /// Now Playing shows the new time after a seek: at most 4 times a second, and the last one always lands.
    /// It runs on the next turn of the main loop, so the seek itself returns at once and the frame draws first.
    private func refreshNowPlayingAfterSeek() {
        let wait = max(0, 0.25 - (CACurrentMediaTime() - lastNowPlayingRefresh))
        guard !nowPlayingRefreshPending else { return }
        nowPlayingRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.nowPlayingRefreshPending = false
                self.lastNowPlayingRefresh = CACurrentMediaTime()
                #if DEBUG
                self.nowPlayingSeekRefreshes.append(self.position)
                #endif
                NowPlaying.shared.refresh()
            }
        }
    }

    // MARK: Safe seeking: one seek per gesture
    /// Rollback switch for the engine scrub hold (on unless the `scrubHold` default says otherwise).
    static var scrubHoldEnabled: Bool { UserDefaults.standard.object(forKey: "scrubHold") as? Bool ?? true }

    @ObservationIgnored private var scrubTarget = 0.0
    @ObservationIgnored private var lastScrubSeek: CFTimeInterval = 0
    @ObservationIgnored private var scrubDuration = 0.0
    @ObservationIgnored private var scrubHoldOn = true
    /// True while a finger drags the playhead: the time row shows the big numeral for it.
    private(set) var showsScrubTime = false

    /// A finger landed on the Map and moved sideways: the playhead follows it. While playing, the engine goes
    /// quiet and waits (one seek on release instead of one per touch event).
    func beginScrub(_ t: Double) {
        guard let song else { return }
        scrubDuration = song.duration
        scrubHoldOn = Self.scrubHoldEnabled
        let t = max(0, min(scrubDuration, t))
        isScrubbing = true
        showsScrubTime = true
        clock.beginScrub(t)
        if isPlaying && scrubHoldOn { engine.setHold(true) }
        WaveformScheduler.shared.kick()
        // The ticker must not fight the drag, and must not read the hold as a natural stop.
        lastTransportCommand = Date()
        position = t
        scrubTarget = t
    }

    /// Each touch event: only the drawn playhead moves.
    // Written out without generic min/max, which stay unspecialised in Debug builds.
    func updateScrub(_ time: Double) {
        guard isScrubbing else { return }
        var t = time
        if t < 0 { t = 0 } else if t > scrubDuration { t = scrubDuration }
        clock.updateScrub(t)
        scrubTarget = t
        if !scrubHoldOn {
            let now = CACurrentMediaTime()
            if now - lastScrubSeek >= 1.0 / 30 {
                engine.seek(frame: Int64(t * engine.sampleRate))
                lastScrubSeek = now
            }
        }
    }

    /// The finger lifted: one seek, and audio carries on from there if it was playing.
    func endScrub(_ t: Double) {
        guard isScrubbing else { return }
        let t = max(0, min(duration, t))
        isScrubbing = false
        showsScrubTime = false
        seek(to: t)
        engine.setHold(false)
        clock.endScrub(t)
    }

    /// A click on the Map: jump there, onto the beat if one is within 120 ms.
    func tapMap(_ t: Double) {
        guard song != nil else { return }
        seek(to: snapToBeat(t))
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
            updateSettings { $0.loopEnabled = false }
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
        var seekTo: Double?
        updateSettings { s in
            if s.loopStart == nil { seekTo = fillDefaultLoop(&s) }
            s.loopEnabled.toggle()
        }
        if let seekTo { seek(to: seekTo) }
    }

    /// The speed trainer needs a loop: turning it on starts one if none is running.
    func setTrainer(_ on: Bool) {
        var seekTo: Double?
        updateSettings { s in
            s.trainer.enabled = on
            if on && !s.loopEnabled {
                if s.loopStart == nil { seekTo = fillDefaultLoop(&s) }
                s.loopEnabled = true
            }
        }
        if let seekTo { seek(to: seekTo) }
    }

    func loopSection(_ s: SongAnalysis.Section) {
        updateSettings { st in
            st.loopStart = s.start
            st.loopEnd = s.end
            st.loopEnabled = true
        }
        seek(to: s.start)
    }

    /// The Loop button (3.4): turns the loop off, or on at this mode's default: the section under the
    /// playhead (Play), the eight (Dance), four bars from this bar (Beats). Playing carries on where it is.
    func toggleDefaultLoop() {
        if settings.loopEnabled {
            updateSettings { $0.loopEnabled = false }
            loopCaptureA = nil
            return
        }
        switch mode {
        case .play:
            if let i = playheadSection, i < sections.count {
                let s = sections[i]
                setLoop(start: s.start, end: s.end)
                if !isPlaying { seek(to: s.start) }
                return
            }
        case .dance:
            if countsRange(8) != nil { loopCounts(8); return }
        case .beats:
            if BarLoop.range(bars: 4, at: position, downbeats: barLines, fallbackBar: barLength) != nil { loopBars(4); return }
        }
        toggleLoop()
    }

    /// The Loop menu's "This section": loops the section under the playhead.
    func toggleSectionLoop() {
        guard let i = playheadSection, i < sections.count else { return }
        let s = sections[i]
        setLoop(start: s.start, end: s.end)
        if !isPlaying { seek(to: s.start) }
    }

    /// The Loop menu's "Set A": marks the start of a new A–B loop, even while another loop plays.
    func markLoopA() { loopCaptureA = snapToBar(position) }

    /// A loop being drawn or resized on the Map: the engine loops it now; settings wait for the release.
    func previewLoop(_ r: ClosedRange<Double>) {
        let sr = engine.sampleRate
        engine.setLoop(enabled: true, start: Int64(r.lowerBound * sr), end: Int64(r.upperBound * sr))
    }

    /// The pointer lifted: one settings write for the whole gesture; a new loop starts from its beginning.
    func commitLoop(_ r: ClosedRange<Double>, seekToStart: Bool) {
        #if DEBUG
        let before = settingsChangeCount
        #endif
        setLoop(start: r.lowerBound, end: r.upperBound)
        pushLoop()
        if seekToStart, let start = loopRange?.lowerBound { seek(to: start) }
        #if DEBUG
        print("[loop] gesture wrote the settings \(settingsChangeCount - before) time(s)")
        #endif
    }

    /// A loop gesture was cancelled: the engine goes back to the settings' loop.
    func cancelLoopPreview() { pushLoop() }

    func setLoop(start: Double, end: Double) {
        let a = max(0, min(start, end - 0.25)), b = min(duration, max(end, start + 0.25))
        updateSettings { s in
            s.loopStart = a
            s.loopEnd = b
            s.loopEnabled = true
        }
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

    /// Puts the default loop for the current mode into `s` (enabling is the caller's choice). Returns where to
    /// seek, if anywhere: dancers loop an eight and start it from its 1 when paused.
    private func fillDefaultLoop(_ s: inout SongSettings) -> Double? {
        // Dancers loop an eight; Beats loops 4 bars from the bar line. Play loops the section.
        if mode == .dance, oneBeatIndex != nil {
            guard let r = countsRange(8) else { return nil }
            s.loopStart = max(0, min(r.lowerBound, r.upperBound - 0.25))
            s.loopEnd = min(duration, max(r.upperBound, r.lowerBound + 0.25))
            return isPlaying ? nil : r.lowerBound
        }
        if mode == .beats, let r = BarLoop.range(bars: 4, at: position, downbeats: barLines, fallbackBar: barLength) {
            s.loopStart = r.lowerBound
            s.loopEnd = min(duration, r.upperBound)
            return nil
        }
        if let sec = sections.first(where: { $0.start <= position && position < $0.end }) {
            s.loopStart = sec.start
            s.loopEnd = sec.end
        } else {
            let bar = bpm > 0 ? 240 / bpm : 4
            s.loopStart = position
            s.loopEnd = min(duration, position + 4 * bar)
        }
        return nil
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
        updateSettings { s in
            s.trainer.enabled = false
            s.speed = max(50, min(150, s.speed + d * 5))
        }
    }

    func resetSpeed() { updateSettings { $0.trainer.enabled = false; $0.speed = 100 } }
    func resetSpeedAndPitch() { updateSettings { $0.trainer.enabled = false; $0.speed = 100; $0.pitch = 0 } }
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
        h.combine(settings.spotlight); h.combine(mode); h.combine(song.drumSplit != nil)
        let key = h.finalize()
        if let c = mixBarsCache, c.key == key { return c.bars }
        let bars = computeMixBars(song: song, count: count)
        mixBarsCache = (key, bars)
        return bars
    }

    private func computeMixBars(song: SongRecord, count: Int) -> [Float] {
        var sum = [Float](repeating: 0, count: count)
        var tot = [Float](repeating: 0, count: count)
        for k in stems {
            let p = rowPeaks(k)
            guard !p.isEmpty else { continue }
            let r = Peaks.resample(p, to: count)
            let g = isAudible(k) ? Float(settings.volume(k) / 80) * spotlightFactor(k) : 0
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
        #if DEBUG
        settingsChangeCount += 1
        #endif
        refreshPlayheadReadouts()              // the 1, the tempo or the mode may move the count (UIP-11)
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
        if old.speed != settings.speed { NowPlaying.shared.refresh() }
        scheduleSave()
    }

    func pushAll() {
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
    func trackGain(_ k: StemKind, volume: Double? = nil) -> Float {
        let fader = Self.gain(forVolume: volume ?? settings.volume(k))
        if isAudible(k) { return fader * spotlightFactor(k) }
        if settings.guide && settings.solo == nil && !isOn(k) { return fader * 0.178 }   // −15 dB
        return 0
    }

    /// Perceptual fader: 80 = unity (0 dB), 100 = +6 dB, 40 ≈ −12 dB, 0 = silent.
    static func gain(forVolume v: Double) -> Float {
        guard v > 0 else { return 0 }
        let db = v >= 80 ? (v - 80) * 0.3 : -60 * pow(1 - v / 80, 1.6) * (v < 2 ? 2 : 1)
        return Float(pow(10, db / 20))
    }

    /// Every loaded track's gain from the settings. The storage gain is undone here, in the mixer gain: the
    /// engine holds the stored 16-bit samples as they are (D3).
    private func pushMix() {
        for (i, leaf) in loadedTracks.enumerated() {
            let gain = trackGain(rowKind(forTrack: leaf))
            let scale = song?.storageGain(leaf) ?? 1
            engine.setGain(stem: i, gain * formatGain(leaf) / max(scale, 1e-6))
            #if DEBUG
            pushedGains[leaf] = gain
            #endif
        }
    }

    /// The gain the engine's samples of `leaf` need on top of the fader and the storage gain: 2 for an AAC part.
    func formatGain(_ leaf: StemKind) -> Float { loadedFormatGains[leaf] ?? 1 }

    /// Each engine track's `formatGain` from its file. Called under the engine gate, right after the load.
    nonisolated static func formatGains(_ rec: SongRecord, store: SongStore) -> [StemKind: Float] {
        var out: [StemKind: Float] = [:]
        for k in rec.engineTracks { out[k] = SongStore.formatGain(of: store.mixURL(rec, k)) }
        return out
    }

    #if DEBUG
    /// The last gain sent to each loaded track before its storage scale (tests check a fader preview reaches the engine).
    @ObservationIgnored var pushedGains: [StemKind: Float] = [:]
    #endif

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

    /// The state SwiftUI shows (time labels, count-in, play state) is published at 30 Hz while playing, 15 Hz
    /// under a scrubbing pointer and 4 Hz otherwise; with no song open the ticker stops (UIP-11). The Metal views
    /// never wait for it: they read `clock` at the display's rate.
    private var desiredTickInterval: Double? {
        guard song != nil else { return nil }
        return isScrubbing ? 1.0 / 15 : isPlaying ? 1.0 / 30 : 0.25
    }
    @ObservationIgnored private var tickerInterval: Double?

    #if DEBUG
    /// The ticker's period, nil when it is stopped (tests).
    var tickerIntervalForTesting: Double? { ticker == nil ? nil : tickerInterval }
    #endif

    private func retuneTicker() {
        let want = desiredTickInterval
        guard want != tickerInterval || (ticker == nil) != (want == nil) else { return }
        ticker?.invalidate()
        ticker = nil
        tickerInterval = want
        guard let want else { return }
        let t = Timer(timeInterval: want, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = want * 0.1
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        guard song != nil else { retuneTicker(); return }
        // Under the pointer the playhead, the time and the part rows follow the drag (UIP-01): the engine is
        // held and only gets one seek on release, so its position would stay at the press point.
        if isScrubbing, abs(scrubTarget - position) > 0.0005 { position = scrubTarget }
        let st = engine.status
        let p = Double(st.position) / engine.sampleRate
        if !isScrubbing && Date().timeIntervalSince(lastSeek) > 0.12 && abs(p - position) > 0.0005 { position = p }
        // Only trust "stopped" once the engine has had time to act on our last play command
        // (commands are applied at the next render quantum).
        if isPlaying && !st.playing && Date().timeIntervalSince(lastTransportCommand) > 0.25 {
            isPlaying = false
        }
        // A measured song's levels reach the rows at a pause, never while it plays (U05).
        if !isPlaying && pendingLevels != nil { applyPendingLevels() }
        if st.countInBeat != countInBeat { countInBeat = st.countInBeat }
        if pendingTrackReload && !isPlaying { performTrackReload() }
        if st.loopPasses != loopPasses { loopPasses = st.loopPasses }
        let live = settings.trainer.enabled && settings.loopEnabled
            ? (st.playing ? Int((st.rate * 100).rounded()) : settings.trainer.from)
            : settings.speed
        if live != liveSpeed { liveSpeed = live }
    }

    #if DEBUG
    /// One ticker pass, for tests.
    func tickForTesting() { tick() }
    #endif

    // MARK: - Library / import

    func openPanel() {
        let panel = NSOpenPanel()
        // Videos too: the sound is taken from them (the kit decodes mov, m4v, mp4 and 3gp).
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff, .mpeg4Audio, UTType("org.xiph.flac"),
                                     .movie, .mpeg4Movie, .quickTimeMovie].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.message = "Choose a song to split into parts"
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        guard !resetting else { return }
        // One import at a time (ios-import#3).
        guard !refuseAnotherImport(url) else { return }
        accept(url)
    }

    /// The import under way hands on its own file: a link's download, or the song service's. Never refused, as it
    /// is not another song.
    func continueImport(_ url: URL) {
        guard !resetting else { return }
        accept(url)
    }

    /// The Record window's take. The window refuses to open while an import is under way, and nothing else starts
    /// one while it is open (`refuseAnotherImport`), so a take is never thrown away for this.
    func openTake(_ url: URL) {
        guard !resetting else { return }
        accept(url)
    }

    /// Every way a person or another app starts a song asks this first (ios-import#3): while an import is under
    /// way, or the Record window is open, it says so and starts nothing; a file the app staged for it goes (a
    /// recording never does, and a person's own file is never touched). True when refused.
    func refuseAnotherImport(_ url: URL? = nil) -> Bool {
        let words: String
        if importUnderWay {
            words = "Still splitting another song."
        } else if recordSheet {
            words = "Finish recording first."
        } else {
            return false
        }
        AppLog.note("import: another song refused (\(importUnderWay ? "an import is under way" : "recording"))")
        if let url { Self.discardRefused(url) }
        showToast(Toast(text: words))
        return true
    }

    /// A refused file the app staged (a link's download) goes; a recording stays where it is, and a person's own
    /// file is never deleted (`ImportStaging.discard` only touches Backline's own folders).
    nonisolated static func discardRefused(_ url: URL) {
        let recordings = ImportStaging.recordingsDirectory.standardizedFileURL.path + "/"
        guard !url.standardizedFileURL.path.hasPrefix(recordings) else { return }
        ImportStaging.discard(url)
    }

    /// True from the moment a file or link is accepted until its import ends (ios-import#1, ios-storage#5): a
    /// link's download (and a music-service link's lookup), a file being fingerprinted, and the split itself. No
    /// pass of any song starts meanwhile; the hand-overs between them happen in one turn of the main actor, so
    /// there is no gap.
    var importUnderWay: Bool { openPending != nil || splitRunning != nil || downloadingFromYouTube }

    /// The import under way was cancelled and is unwinding ("Record instead" cancels the link it replaces).
    /// (A file being fingerprinted and a music-service lookup have no box of their own: the last one may be stale.)
    var importCancelled: Bool { cancelBox.value && openPending == nil && !spotify.owning }

    /// Something that kept `importUnderWay` true has ended. Looked at on the next turn, so a hand-over in this one
    /// (a link's file to the split, a fingerprint to `startImport`) is not taken for an end. When the import has
    /// ended (a song opened, a failure, a cancel), the passes it paused start again.
    func importMayHaveEnded() {
        guard !importEndCheckQueued else { return }
        importEndCheckQueued = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.importEndCheckQueued = false
            guard !self.importUnderWay, !self.resetting else { return }
            self.resumeAfterImport()
        }
    }

    /// The passes an import paused, for the open song and the Library (each asks for room and checks its own turn).
    func resumeAfterImport() {
        ensureLeadRefine()
        ensureCleanerParts()
        ensureDrumSplit()
        ensurePartsCompact()
        ensureLibraryLeadRefine()
        if let rec = song, rec.levels == nil || rec.instruments == nil, pendingLevels == nil { measurePartLevels(rec) }
    }

    /// The app came back to the front: a pass refused for room is tried again (ios-import#4).
    func retryRoomRefused() {
        guard !roomRefused.isEmpty else { return }
        roomRefused = [:]
        guard !resetting, !importUnderWay else { return }
        resumeAfterImport()
    }

    /// The passes still running after `pauseBackgroundWork` (they stop at their next check).
    var passesRunning: Bool { leadJob != nil || hqJob != nil || drumJob != nil || compactJob != nil }

    /// ios-import#5: waits until the passes told to stop have stopped, so the import's split doesn't wait on a
    /// pass's chunk. Ends early on `stop`, or after `limit`.
    func waitForPassesToStop(upTo limit: Duration = .seconds(120), stop: () -> Bool) async {
        let end = ContinuousClock.now + limit
        while passesRunning, !stop(), ContinuousClock.now < end {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func accept(_ url: URL) {
        guard AudioDecoder.isSupported(url) else {
            dropRejected = true
            if song == nil { screen = .empty }
            return
        }
        dropRejected = false
        // Most likely a new song: load the separator while the file is hashed.
        SeparationService.shared.prepare()
        let accessing = url.startAccessingSecurityScopedResource()
        // The file is hashed off the main thread (UIP-08: a whole read and SHA-256, a second for a long video),
        // then the Library is waited for, then the song opens if it is already there or is split.
        openToken += 1
        let token = openToken
        openPending = token
        showGettingTheSongIfSlow(url, token: token)
        let epoch = ResetBackline.epoch
        Task { [weak self] in
            let id = await Task.detached(priority: .userInitiated) { () -> String? in
                #if DEBUG
                if let s = Self.slowFingerprint { usleep(useconds_t(s * 1_000_000)) }
                #endif
                return try? SongStore.contentID(of: url)
            }.value
            await self?.libraryReady()
            guard let self, token == self.openToken, ResetBackline.isCurrent(epoch), !self.resetting else {
                // A newer file, Cancel, or a reset took over: this one is let go.
                if accessing { url.stopAccessingSecurityScopedResource() }
                return
            }
            let shown = self.preparingFile
            self.endPreparing(token)
            guard let id else {
                if accessing { url.stopAccessingSecurityScopedResource() }
                SeparationService.shared.release()
                self.screen = .failed("Can't read this file.")
                return
            }
            if let existing = self.library.first(where: { $0.id == id }) {
                if accessing { url.stopAccessingSecurityScopedResource() }
                SeparationService.shared.release()     // already split: nothing to load it for
                ImportStaging.discard(url)              // a recording or download of it isn't needed (never a picked file)
                if shown { withAnimation(.smooth) { self.screen = self.song == nil ? .empty : .mixer } }
                self.select(existing)
                return
            }
            self.startImport(url: url, id: id, accessing: accessing)
        }
    }

    /// The newest file being opened; an older one still hashing gives way to it, and so does Cancel.
    @ObservationIgnored private var openToken = 0
    /// The open that is still fingerprinting, if any.
    @ObservationIgnored private var openPending: Int? {
        didSet { if openPending == nil, oldValue != nil { importMayHaveEnded() } }
    }
    /// How long fingerprinting a file may take before the splitting screen comes up to say so.
    nonisolated static let preparingGrace: Duration = .milliseconds(300)

    #if DEBUG
    /// `--slow-fingerprint S`: fingerprinting an added file takes S seconds longer, as a long video's would.
    nonisolated static var slowFingerprint: Double? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--slow-fingerprint"), i + 1 < a.count else { return nil }
        return Double(a[i + 1])
    }
    #endif

    /// A large file can take a second or more to fingerprint (a long video): past `preparingGrace` the splitting
    /// screen comes up with "Getting the song", so the click is answered (UIP-08).
    private func showGettingTheSongIfSlow(_ url: URL, token: Int) {
        Task { [weak self] in
            try? await Task.sleep(for: Self.preparingGrace)
            // A link's own screen is already up while its file is fingerprinted: nothing to add.
            guard let self, self.openPending == token, token == self.openToken, self.screen != .analyzing,
                  !self.resetting else { return }
            self.importTitle = self.importTitleOverride ?? ImportStaging.displayName(for: url)
            self.importArtist = self.importArtistOverride ?? ""
            if self.importArtworkOverride == nil { self.importArtwork = nil }
            self.importProgress = ImportProgress(phase: 0, fraction: 0, secondsRemaining: nil)
            self.preparingFile = true
            withAnimation(.smooth(duration: 0.35)) { self.screen = .analyzing }
        }
    }

    /// The open `token` is past fingerprinting.
    private func endPreparing(_ token: Int) {
        guard openPending == token else { return }
        openPending = nil
        preparingFile = false
    }

    /// Reset: no open is pending.
    func forgetPreparing() { preparingFile = false; openPending = nil }

    private func startImport(url: URL, id: String, accessing: Bool) {
        // The backstop (ios-import#3): never a second split beside a running one.
        guard splitRunning == nil else {
            AppLog.note("import \(id): refused, another split is running")
            if accessing { url.stopAccessingSecurityScopedResource() }
            Self.discardRefused(url)
            showToast(Toast(text: "Still splitting another song."))
            return
        }
        if !url.path.contains("/Backline/Downloads/") { lastYouTube = nil; lastLink = nil }
        pauseBackgroundWork()
        persistCurrent()
        stopPlayback()
        lastImportURL = url
        importTitle = importTitleOverride ?? ImportStaging.displayName(for: url)
        importArtist = importArtistOverride ?? ""
        if importArtworkOverride == nil { importArtwork = nil }
        importProgress = ImportProgress(phase: 0, fraction: 0, secondsRemaining: nil)
        let cancel = CancelBox()
        cancelBox = cancel
        // Reset Backline bumps the epoch: this import then stops and its completion changes nothing.
        let epoch = ResetBackline.epoch
        withAnimation(.smooth(duration: 0.35)) { screen = .analyzing }
        let store = self.store
        // Written before the work (D20 d): if this run ends before the import does, the next launch keeps the
        // file and offers the song again.
        let journal = WorkJournal.shared
        noteImportStarted(url: url, id: id)
        // Only this import and the unfinished ones can carry on from a split's checkpoint (R3).
        PassCheckpoints.dropOthers(.importSplit, keeping: Set(unfinishedImports.map(\.id) + [id]))
        ImportKeepAwake.begin()
        splitToken += 1
        let split = splitToken
        splitRunning = split
        importTask = Task { [weak self] in
            defer {
                // Let go when this import ends, unless a newer import has taken over meanwhile (it lets go itself).
                if self == nil || self?.cancelBox === cancel { ImportKeepAwake.end() }
                // The passes it paused start again (and the new song's, which waited for this).
                if self?.splitRunning == split { self?.splitRunning = nil; self?.importMayHaveEnded() }
            }
            // The file's own title and artist, while the split runs (a link's come from the download).
            Task {
                let meta = await TrackMetadata.load(from: url)
                await MainActor.run {
                    guard let self, self.lastImportURL == url else { return }
                    if self.importTitleOverride == nil, let t = meta.title {
                        self.importTitle = t
                        WorkJournal.shared.noteImport(id, title: t)
                    }
                    if self.importArtistOverride == nil, let a = meta.artist { self.importArtist = a }
                }
            }
            // ios-import#5: the passes paused above stop at their next check. Until they have, the split would wait
            // on their chunk, and what they hold isn't free yet: "Getting the song".
            if let self, self.passesRunning {
                let waited = ContinuousClock.now
                self.preparingFile = true
                await self.waitForPassesToStop(stop: { cancel.value || !ResetBackline.isCurrent(epoch) })
                if ResetBackline.isCurrent(epoch) { self.preparingFile = false }
                AppLog.note("import \(id): waited \(Int((ContinuousClock.now - waited).components.seconds)) s for the background passes to stop")
            }
            do {
                let (imported, _) = try await Task.detached(priority: .userInitiated) { [weak self] in
                    try await ImportPipeline.run(url: url, id: id, store: store, progress: { p in
                        journal.noteImport(id, stage: p.phase)
                        #if DEBUG
                        if p.phase >= 1 { DebugExit.at("import-split") }
                        // Half way through the six-part split: its checkpoint holds finished chunks (R3).
                        if (3...4).contains(p.phase) { DebugExit.at("import-split-half") }
                        #endif
                        Task { @MainActor in self?.importProgress = p }
                    }, isCancelled: { cancel.value || !ResetBackline.isCurrent(epoch) })
                }.value
                if accessing { url.stopAccessingSecurityScopedResource() }
                guard let self, ResetBackline.isCurrent(epoch) else { Self.dropAfterReset(id: id, url: url); return }
                var rec = imported
                if self.importTitleOverride != nil || self.importArtistOverride != nil || self.importSourceOverride != nil {
                    if let t = self.importTitleOverride { rec.title = t }
                    if let a = self.importArtistOverride { rec.artist = a }
                    if let src = self.importSourceOverride { rec.sourceName = src }
                    if let art = self.importArtworkOverride, (try? art.write(to: self.store.artworkURL(id))) != nil { rec.hasArtwork = true }
                    self.importArtworkOverride = nil
                    self.importTitleOverride = nil
                    self.importArtistOverride = nil
                    self.importSourceOverride = nil
                    try? self.store.save(rec)
                }
                self.library.insert(rec, at: 0)
                journal.endImport(id)
                // Finished: nothing to carry on from.
                PassCheckpoints.discard(.importSplit, id)
                // Our own recordings and downloads are temporary once split (the stems live in the library);
                // a file the person picked is never deleted, wherever it is.
                ImportStaging.discard(url)
                await self.openImported(rec)
            } catch is CancellationError {
                if accessing { url.stopAccessingSecurityScopedResource() }
                ImportStaging.discard(url)
                guard let self, ResetBackline.isCurrent(epoch) else { Self.dropAfterReset(id: id, url: url); return }
                journal.endImport(id)
                self.store.delete(id)
                withAnimation(.smooth) { self.screen = self.song == nil ? .empty : .mixer }
            } catch {
                if accessing { url.stopAccessingSecurityScopedResource() }
                guard let self, ResetBackline.isCurrent(epoch) else { Self.dropAfterReset(id: id, url: url); return }
                // Ended with a message on screen and Try again there: not an unfinished import for the next launch.
                // The split's checkpoint stays for that Try again (the file does too); the launch sweep removes it
                // if nothing names it by then.
                journal.endImport(id)
                self.store.delete(id, keepingImport: true)
                withAnimation(.smooth) { self.screen = .failed(error.localizedDescription) }
            }
        }
    }

    /// The end of an import (storage F8): the pipeline kept no parts in memory, so the new song opens from the
    /// files just written the way `select` opens a song: the stretch around where it starts is read at once,
    /// off the main thread, then the rest in the background while the engine gate is held.
    private func openImported(_ rec: SongRecord) async {
        loadGeneration += 1
        let generation = loadGeneration
        let store = self.store, engine = self.engine, gate = engineGate
        // Where `activate` will start a new song: its solo, if the analysis found one.
        let start = rec.analysis.sections.first(where: { $0.label.hasPrefix("Solo") })?.start ?? 0
        engineFill?.cancel()
        let fill = EngineFill()
        engineFill = fill
        await gate.acquire()
        guard generation == loadGeneration else { await gate.release(); return }
        let (opened, gains) = await Task.detached(priority: .userInitiated) {
            (Self.loadEngineWindow(rec, store: store, engine: engine, around: start), Self.formatGains(rec, store: store))
        }.value
        guard generation == loadGeneration else { await gate.release(); return }
        guard case .success(let first) = opened else {
            // D7: the song stays in the library; nothing is deleted.
            await gate.release()
            if case .failure(let why) = opened { showOpenFailure(rec, why) }
            return
        }
        activate(rec, fresh: true, formatGains: gains)
        Task {
            let done = await Task.detached(priority: .utility) {
                Self.fillEngine(rec, store: store, engine: engine, except: first.window, frames: first.frames, fill: fill)
            }.value
            await gate.release()
            if !done, !fill.isCancelled, generation == self.loadGeneration { self.showOpenFailure(rec, .unreadable) }
        }
    }

    func cancelImport() {
        // Still fingerprinting a file: that open is dropped, and the screen goes back.
        if let pending = openPending {
            openToken += 1
            endPreparing(pending)
            if screen == .analyzing { withAnimation(.smooth) { screen = song == nil ? .empty : .mixer } }
        }
        cancelBox.value = true
        importTask?.cancel()
        cancelSpotifyIfRunning()
    }

    @ObservationIgnored var lastYouTube: YouTubeImport.Video?
    /// The "Add a song" sheet (file / YouTube link / record), from every "+" and ⌘O.
    var addSongSheet = false

    /// One entry point for adding music, everywhere ("+ Add song", "Add a song…", ⌘O): the Add Song
    /// sheet with the same three choices — a file, a YouTube link, or record from an app.
    func addSong() {
        // One import at a time (ios-import#3): the sheet's ways in would all be refused.
        guard !refuseAnotherImport() else { return }
        addSongSheet = true
    }

    /// Shows the "Sign in to YouTube" window (from the error screen, Settings or Help).
    var youTubeSignInSheet = false
    /// Page the Help window shows (set by the "?" buttons before opening it).
    var helpTopic: HelpTopic? = .start
    /// First launch: a three-card welcome, shown once.
    var showWelcome = !UserDefaults.standard.bool(forKey: "welcomeSeen")

    func select(_ rec: SongRecord) {
        guard !resetting else { return }
        guard rec.id != song?.id else { if screen != .mixer { screen = .mixer }; return }
        guard !isExporting else {
            showToast(Toast(text: "Still saving your track. One moment…"))
            return
        }
        persistCurrent()
        stopPlayback()
        pendingRecord = nil
        pendingLevels = nil
        forceTrackReload = false
        loadGeneration += 1
        let generation = loadGeneration
        loadingSongID = rec.id
        // Load stems off the main thread straight into engine memory (one load at a time).
        let store = self.store
        let engine = self.engine
        let gate = engineGate
        // Opening (U01): every part's stretch around the place you left off is read at once, the player
        // shows and can play, then the rest is read in the background while the gate is still held (so an
        // export or a parts swap waits for it, and the next song cancels it).
        let resume = rec.settings.lastPosition < rec.duration - 1 ? rec.settings.lastPosition : 0
        engineFill?.cancel()
        let fill = EngineFill()
        engineFill = fill
        let openStart = CACurrentMediaTime()
        Task {
            await gate.acquire()
            guard generation == self.loadGeneration else { await gate.release(); return }
            // A kit or a guitar split that can't be read falls back to the part it came from (storage F7).
            let (opened, loaded, gains) = await Task.detached(priority: .userInitiated) { () -> (OpenResult, SongRecord, [StemKind: Float]) in
                var result: OpenResult = .failure(.unreadable)
                for variant in Self.openVariants(rec) {
                    result = Self.loadEngineWindow(variant, store: store, engine: engine, around: resume)
                    if case .success = result { return (result, variant, Self.formatGains(variant, store: store)) }
                    if case .failure(.memory) = result { break }
                }
                return (result, rec, [:])
            }.value
            guard generation == self.loadGeneration else { await gate.release(); return }
            #if DEBUG
            print("[harness] parts ready in \(Int((CACurrentMediaTime() - openStart) * 1000)) ms (\(loaded.engineTracks.count) tracks, \(Int(rec.duration)) s, footprint \(MemoryFootprint.megabytes) MB)")
            #endif
            self.loadingSongID = nil
            guard case .success(let first) = opened else {
                await gate.release()
                if case .failure(let why) = opened { self.showOpenFailure(rec, why) }
                return
            }
            if loaded.engineTracks != rec.engineTracks {
                AppLog.note("open \(rec.id): a split part can't be read; playing the part it came from")
            }
            self.activate(loaded, fresh: false, formatGains: gains)
            let done = await Task.detached(priority: .utility) {
                Self.fillEngine(loaded, store: store, engine: engine, except: first.window, frames: first.frames, fill: fill)
            }.value
            #if DEBUG
            print("[harness] whole song read in \(Int((CACurrentMediaTime() - openStart) * 1000)) ms\(done ? "" : " (stopped for the next song)"), footprint \(MemoryFootprint.megabytes) MB")
            #else
            _ = openStart
            #endif
            await gate.release()
            if !done, !fill.isCancelled, generation == self.loadGeneration { self.showOpenFailure(rec, .unreadable) }
        }
    }

    /// Why a song didn't open.
    nonisolated enum OpenFailure: Error, Equatable {
        /// The engine couldn't get the memory for the whole song.
        case memory
        /// A part's file is missing or can't be decoded.
        case unreadable
    }
    typealias OpenResult = Result<(window: Range<Int>, frames: Int), OpenFailure>

    /// The failure screen's line for a song that didn't open, and the message that tells `FailureView` it is one.
    static let openFailureMessage = "A part of this song can't be read."
    static let openMemoryMessage = "Not enough free memory to open it. Close other apps and try again."

    /// The record to try, then the same song without its kit split, then also without its guitar split: the
    /// parts those came from are still on disk (D9).
    nonisolated static func openVariants(_ rec: SongRecord) -> [SongRecord] {
        var out = [rec]
        var r = rec
        if r.drumSplitActive { r.drumSplit = nil; out.append(r) }
        if r.guitarSplit != nil { r.guitarSplit = nil; out.append(r) }
        return out
    }

    /// D7: a song that didn't open stays in the Library with its loops and mixes. The engine no longer holds the
    /// song that was open, so that is closed (its settings were saved before the load), and the failure screen
    /// offers Try again and Delete song.
    func showOpenFailure(_ rec: SongRecord, _ why: OpenFailure) {
        AppLog.note("open \(rec.id): failed (\(why)); the song is kept")
        if let open = song {
            // A song that opened and then failed to read on keeps its place; one that was open before `select`
            // was saved there already, and the engine's position is no longer its own.
            if open.id == rec.id { persistCurrent() }
            stopPlayback()
            song = nil
            loadedTracks = []
            NowPlaying.shared.refresh()
        }
        openFailure = rec
        withAnimation(.smooth) { screen = .failed(why == .memory ? Self.openMemoryMessage : Self.openFailureMessage) }
    }

    /// Try again on a song that didn't open.
    func retryOpen() {
        guard let rec = openFailure else { return }
        openFailure = nil
        select(library.first { $0.id == rec.id } ?? rec)
    }

    /// Delete song on a song that didn't open, after the person confirmed it.
    func deleteFailedSong() {
        guard let rec = openFailure else { return }
        openFailure = nil
        remove(library.first { $0.id == rec.id } ?? rec)
        withAnimation(.smooth) { screen = song == nil ? .empty : .mixer }
    }

    /// Opening a song: allocates the engine and reads 2 s before to 30 s after `start` of every part at
    /// once. Returns the frames read and the song's length, or why it failed. Off the main thread.
    nonisolated static func loadEngineWindow(_ rec: SongRecord, store: SongStore, engine: PlaybackEngine,
                                             around start: Double) -> OpenResult {
        let tracks = rec.engineTracks
        let urls = tracks.map { store.mixURL(rec, $0) }
        let lengths = urls.map { SongStore.frameCount(of: $0) }
        let frames = lengths.max() ?? 0
        if let i = lengths.firstIndex(of: 0) {
            AppLog.note("open \(rec.id): \(urls[i].lastPathComponent) can't be read")
            return .failure(.unreadable)
        }
        guard frames > 0 else { return .failure(.unreadable) }
        guard engine.allocate(stemCount: tracks.count, frames: frames) else {
            AppLog.note("open \(rec.id): no memory for \(tracks.count) parts of \(frames) frames")
            return .failure(.memory)
        }
        let sr = 44_100.0
        let s = Int(max(0, start - 2) * sr)
        let window = min(s, frames)..<min(frames, Int((start + 30) * sr))
        for (i, k) in tracks.enumerated() { engine.setPitchLocked(stem: i, k.isPitchLocked) }
        let ok = readParts(urls, store: store, engine: engine, ranges: { _ in [window] }, fill: nil)
        return ok ? .success((window, frames)) : .failure(.unreadable)
    }

    /// Reads everything outside `except` for every part, in parallel; stops early if `fill` is cancelled.
    nonisolated static func fillEngine(_ rec: SongRecord, store: SongStore, engine: PlaybackEngine,
                                       except: Range<Int>, frames: Int, fill: EngineFill) -> Bool {
        let urls = rec.engineTracks.map { store.mixURL(rec, $0) }
        return readParts(urls, store: store, engine: engine, ranges: { _ in [0..<except.lowerBound, except.upperBound..<frames] }, fill: fill)
    }

    /// One part per core: ALAC decoding is the cost of opening a song.
    nonisolated private static func readParts(_ urls: [URL], store: SongStore, engine: PlaybackEngine,
                                              ranges: (Int) -> [Range<Int>], fill: EngineFill?) -> Bool {
        let failed = Atomic<Bool>(false)
        DispatchQueue.concurrentPerform(iterations: urls.count) { i in
            guard let l = engine.channelPointer(stem: i, channel: 0), let r = engine.channelPointer(stem: i, channel: 1) else {
                failed.store(true, ordering: .relaxed); return
            }
            for range in ranges(i) where !range.isEmpty {
                do {
                    let finished = try store.readStem(urls[i], left: l, right: r, frames: range,
                                                      stop: { fill?.isCancelled ?? false || failed.load(ordering: .relaxed) })
                    if !finished { return }
                } catch {
                    AppLog.note("read \(urls[i].lastPathComponent): \(error.localizedDescription)")
                    failed.store(true, ordering: .relaxed); return
                }
            }
        }
        return !failed.load(ordering: .relaxed) && !(fill?.isCancelled ?? false)
    }

    /// Reads the song's mix tracks from disk straight into engine memory, all parts at once. Off the main
    /// thread (the parts swap after the drum kit or the cleaner pass).
    nonisolated static func loadEngine(_ rec: SongRecord, store: SongStore, engine: PlaybackEngine) -> Bool {
        let tracks = rec.engineTracks
        let urls = tracks.map { store.mixURL(rec, $0) }
        let frames = urls.map { SongStore.frameCount(of: $0) }.max() ?? 0
        guard frames > 0, engine.allocate(stemCount: tracks.count, frames: frames) else { return false }
        for (i, k) in tracks.enumerated() { engine.setPitchLocked(stem: i, k.isPitchLocked) }
        return readParts(urls, store: store, engine: engine, ranges: { _ in [0..<frames] }, fill: nil)
    }

    /// Makes `rec` current. Its parts are already in the engine, read from the files (a fresh import too, so it
    /// plays what reopening plays: storage F8); the storage gain is undone in the mixer gain (`pushMix`).
    private func activate(_ rec: SongRecord, fresh: Bool, formatGains: [StemKind: Float]) {
        let previousSong = song?.id
        var rec = rec
        openFailure = nil
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
            prepareMode(&st, song: rec, fresh: true)
            rec.settings = st
        } else if rec.settings.mode == nil {
            var st = rec.settings
            prepareMode(&st, song: rec, fresh: false)
            rec.settings = st
        }
        if let m = rec.settings.mode, m != appMode { appMode = m }
        loadedTracks = rec.engineTracks
        loadedFormatGains = formatGains
        rec.lastOpened = Date()
        engine.commit()
        song = rec
        loadArtwork(rec, sameSong: previousSong == rec.id)
        settings = rec.settings
        exportFileName = ""
        pushAll()
        // A song split before part levels existed is measured once, in the background (U05).
        if rec.levels == nil || rec.instruments == nil { measurePartLevels(rec) }
        let start = rec.settings.lastPosition < rec.duration - 1 ? rec.settings.lastPosition : 0
        seek(to: start)
        loopPasses = 0
        loopCaptureA = nil
        withAnimation(Motion.animation(.smooth(duration: 0.4))) { screen = .mixer }
        if let i = library.firstIndex(where: { $0.id == rec.id }) { library[i] = rec }
        scheduleSave()
        refreshHeldBack()
        // Opened again: a pass refused for room is tried again (ios-import#4).
        roomRefused[rec.id] = nil
        // The lead refinement first (D2), or the kit split when the screen shows kit parts; the cleaner pass
        // waits for both.
        ensureLeadRefine()
        ensureCleanerParts()
        ensureDrumSplit()
        // Then the parts that no pass will read again become AAC (D19), this song first.
        ensurePartsCompact()
    }
    func stopPlayback() {
        if isPlaying { engine.pause(); isPlaying = false }
    }

    /// The song's picture, decoded off the main thread at 600 px (UIP-10): enough for the header tile and Now
    /// Playing, where a 3000 px cover used to be decoded in full while the player opened. The same song keeps
    /// its picture while the new one is read; another song shows no picture meanwhile.
    private func loadArtwork(_ rec: SongRecord, sameSong: Bool) {
        if !sameSong { artwork = nil }
        guard rec.hasArtwork else { artwork = nil; return }
        let store = self.store, id = rec.id
        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                store.artwork(id).flatMap { Self.artworkThumbnail($0, maxPixels: Self.artworkPixels) }
            }.value
            guard let self, self.song?.id == id else { return }
            self.artwork = image
        }
    }

    /// A picture for the Getting-the-song screen, decoded off the main thread at the same size (UIP-10).
    nonisolated static func artworkImage(_ data: Data) async -> NSImage? {
        await Task.detached(priority: .userInitiated) { artworkThumbnail(data, maxPixels: artworkPixels) }.value
    }

    /// The longest side the open song's picture is decoded to.
    nonisolated static let artworkPixels = 600

    /// Decodes a picture straight to a small size (never the full image in memory).
    nonisolated static func artworkThumbnail(_ data: Data, maxPixels: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
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
        WorkJournal.shared.forgetSong(rec.id)
        // The folder leaves the Library at once by a rename, so the same song can be added again straight
        // away; its 100 MB or so are deleted off the main thread (UIP-08). What's left (a staging copy, a
        // checkpoint) is small and goes now.
        let fm = FileManager.default
        let aside = fm.temporaryDirectory.appendingPathComponent(ImportStaging.deletingPrefix + UUID().uuidString, isDirectory: true)
        let moved = (try? fm.moveItem(at: store.folder(rec.id), to: aside)) != nil
        store.delete(rec.id)
        if moved {
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: aside) }
        }
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
        guard !resetting else { return }
        guard var rec = song else { return }
        rec.settings = settings
        rec.settings.lastPosition = position
        song = rec
        // New parts waiting for the engine: what's on disk is the new record, with today's settings.
        var disk = rec
        if let p = pendingRecord, p.id == rec.id {
            disk = p
            disk.settings = rec.settings
            disk.lastOpened = rec.lastOpened
        }
        if let i = library.firstIndex(where: { $0.id == rec.id }) { library[i] = disk }
        let store = self.store
        if synchronously { try? store.save(disk) }
        else { Task.detached(priority: .utility) { try? store.save(disk) } }
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
        // The backing track never contains a removed part, not via Guide and not via Solo.
        let gains = exportGains()
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

/// A background read of a song's parts that the next song can stop (U01).
nonisolated final class EngineFill: Sendable {
    private let cancelled = Atomic<Bool>(false)
    func cancel() { cancelled.store(true, ordering: .relaxed) }
    var isCancelled: Bool { cancelled.load(ordering: .relaxed) }
}

extension AppModel {
    /// After a reset, work that ended late removes what it wrote under its own song id: the staging copy, the
    /// checkpoint, the staged file, and the song itself unless it was saved after the reset (re-imported).
    nonisolated static func dropAfterReset(id: String, url: URL?) {
        let fm = FileManager.default
        let store = SongStore.shared
        try? fm.removeItem(at: store.staging.folder(id))
        try? fm.removeItem(at: store.staging.root.appendingPathComponent(id + "-old", isDirectory: true))
        PassCheckpoints.discardAll(id)
        if let url { ImportStaging.discard(url) }
        let json = store.folder(id).appendingPathComponent("song.json")
        let saved = (try? fm.attributesOfItem(atPath: json.path)[.modificationDate]) as? Date
        if saved.map({ $0 < ResetBackline.lastReset }) ?? true { try? fm.removeItem(at: store.folder(id)) }
    }
}
