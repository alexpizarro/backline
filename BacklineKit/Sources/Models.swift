import Foundation

// Persisted song model. Every type decodes tolerantly (missing keys → defaults, unknown enum
// values → skipped) so that neither upgrading nor rolling back to an older build ever makes
// songs disappear from the library.

/// Instruments as the app presents them. Data-driven: a song only has the stems the engine produced.
public enum StemKind: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case vocals, leadGuitar, rhythmGuitar, guitar, bass, drums, keys, other

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .vocals: "Vocals"
        case .leadGuitar: "Lead guitar"
        case .rhythmGuitar: "Rhythm guitar"
        case .guitar: "Guitar"
        case .bass: "Bass"
        case .drums: "Drums"
        case .keys: "Keys"
        case .other: "Other"
        }
    }

    /// Short pill label for the "I'm playing" row.
    public var shortName: String {
        switch self {
        case .leadGuitar: "Lead"
        case .rhythmGuitar: "Rhythm"
        default: name
        }
    }

    /// oklch hue of the stem colour (lightness 0.72, chroma 0.15), per the design handoff.
    public var hue: Double {
        switch self {
        case .vocals: 20
        case .leadGuitar: 330
        case .rhythmGuitar: 295
        case .guitar: 330
        case .bass: 260
        case .drums: 200
        case .keys: 150
        case .other: 90
        }
    }

    public var symbol: String {
        switch self {
        case .vocals: "music.mic"
        case .leadGuitar: "guitars.fill"
        case .rhythmGuitar: "guitars"
        case .guitar: "guitars.fill"
        case .bass: "waveform.path"
        case .drums: "light.cylindrical.ceiling.fill"
        case .keys: "pianokeys"
        case .other: "sparkles"
        }
    }

    /// Demucs source name → kind.
    public init?(demucsSource: String) {
        switch demucsSource {
        case "vocals": self = .vocals
        case "guitar": self = .guitar
        case "bass": self = .bass
        case "drums": self = .drums
        case "piano": self = .keys
        case "other": self = .other
        default: return nil
        }
    }

    /// Display order in the mixer.
    public static let displayOrder: [StemKind] = [.vocals, .leadGuitar, .rhythmGuitar, .guitar, .bass, .drums, .keys, .other]

    /// Drums are time-stretched but never transposed (keeps kick/snare natural).
    public var isPitchLocked: Bool { self == .drums }

    public var isGuitar: Bool { self == .guitar || self == .leadGuitar || self == .rhythmGuitar }
}

public enum ExportFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case wav = "WAV", mp3 = "MP3", aiff = "AIFF"
    public var id: String { rawValue }
    public var fileExtension: String {
        switch self {
        case .wav: "wav"
        case .mp3: "mp3"
        case .aiff: "aif"
        }
    }
}

/// Gradually raises the speed each time the loop comes round (ported from go-play-in-the-band, MIT).
public struct SpeedTrainer: Codable, Hashable, Sendable {
    public var enabled = false
    public var from = 70
    public var step = 5
    public var every = 2
    public var to = 100

    public init() {}

    public func speed(afterPasses passes: Int) -> Int {
        let steps = max(0, passes) / max(1, every)
        return min(to, from + steps * step)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        from = try c.decodeIfPresent(Int.self, forKey: .from) ?? 70
        step = try c.decodeIfPresent(Int.self, forKey: .step) ?? 5
        every = try c.decodeIfPresent(Int.self, forKey: .every) ?? 2
        to = try c.decodeIfPresent(Int.self, forKey: .to) ?? 100
    }
}

/// Everything the user can change about a song. Persisted per song.
public struct SongSettings: Codable, Hashable, Sendable {
    public var removed: Set<StemKind> = []
    public var volumes: [String: Double] = [:]          // StemKind.rawValue → 0…100
    public var solo: StemKind?
    public var loopEnabled = false
    public var loopStart: Double?
    public var loopEnd: Double?
    public var speed = 100                                // percent
    public var pitch = 0                                  // semitones
    public var countIn = true
    public var trainer = SpeedTrainer()
    public var sectionNames: [String: String] = [:]       // section start (ms) → custom label
    public var lastPosition: Double = 0
    // v0.12
    public var tempoScale: Double = 1                     // 0.5 half-time · 1 · 2 double-time
    public var guide = false                              // removed parts play quietly instead of silent
    public var click = false                              // metronome on the beat grid during playback
    public var showGuitarSplit = true                     // lead/rhythm rows vs a single guitar row

    public init() {}

    public func volume(_ k: StemKind) -> Double { volumes[k.rawValue] ?? 80 }

    enum CodingKeys: String, CodingKey {
        case removed, volumes, solo, loopEnabled, loopStart, loopEnd, speed, pitch, countIn, trainer
        case sectionNames, lastPosition, tempoScale, guide, click, showGuitarSplit
        case removedExact, soloExact
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `removedExact` / `soloExact` carry lead/rhythm choices; `removed` / `solo` are the
        // v0.11-compatible projections (lead/rhythm → guitar).
        let removedRaw = try c.decodeIfPresent([String].self, forKey: .removedExact)
            ?? c.decodeIfPresent([String].self, forKey: .removed) ?? []
        removed = Set(removedRaw.compactMap(StemKind.init(rawValue:)))
        volumes = try c.decodeIfPresent([String: Double].self, forKey: .volumes) ?? [:]
        let soloExact = (try? c.decodeIfPresent(String.self, forKey: .soloExact)) ?? nil
        let soloLegacy = (try? c.decodeIfPresent(String.self, forKey: .solo)) ?? nil
        solo = (soloExact ?? soloLegacy).flatMap { StemKind(rawValue: $0) }
        loopEnabled = try c.decodeIfPresent(Bool.self, forKey: .loopEnabled) ?? false
        loopStart = try c.decodeIfPresent(Double.self, forKey: .loopStart)
        loopEnd = try c.decodeIfPresent(Double.self, forKey: .loopEnd)
        speed = try c.decodeIfPresent(Int.self, forKey: .speed) ?? 100
        pitch = try c.decodeIfPresent(Int.self, forKey: .pitch) ?? 0
        countIn = try c.decodeIfPresent(Bool.self, forKey: .countIn) ?? true
        trainer = (try? c.decodeIfPresent(SpeedTrainer.self, forKey: .trainer)) ?? SpeedTrainer()
        sectionNames = try c.decodeIfPresent([String: String].self, forKey: .sectionNames) ?? [:]
        lastPosition = try c.decodeIfPresent(Double.self, forKey: .lastPosition) ?? 0
        tempoScale = try c.decodeIfPresent(Double.self, forKey: .tempoScale) ?? 1
        guide = try c.decodeIfPresent(Bool.self, forKey: .guide) ?? false
        click = try c.decodeIfPresent(Bool.self, forKey: .click) ?? false
        showGuitarSplit = try c.decodeIfPresent(Bool.self, forKey: .showGuitarSplit) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Only kinds an older build understands go in `removed` / `solo`; split kinds are mapped back
        // to `guitar` so a rolled-back v0.11 still loads the song and removes the guitar.
        func legacy(_ k: StemKind) -> StemKind { k == .leadGuitar || k == .rhythmGuitar ? .guitar : k }
        try c.encode(Set(removed.map(legacy)).map(\.rawValue).sorted(), forKey: .removed)
        try c.encode(removed.map(\.rawValue).sorted(), forKey: .removedExact)
        try c.encode(volumes, forKey: .volumes)
        try c.encodeIfPresent(solo.map(legacy)?.rawValue, forKey: .solo)
        try c.encodeIfPresent(solo?.rawValue, forKey: .soloExact)
        try c.encode(loopEnabled, forKey: .loopEnabled)
        try c.encodeIfPresent(loopStart, forKey: .loopStart)
        try c.encodeIfPresent(loopEnd, forKey: .loopEnd)
        try c.encode(speed, forKey: .speed)
        try c.encode(pitch, forKey: .pitch)
        try c.encode(countIn, forKey: .countIn)
        try c.encode(trainer, forKey: .trainer)
        try c.encode(sectionNames, forKey: .sectionNames)
        try c.encode(lastPosition, forKey: .lastPosition)
        try c.encode(tempoScale, forKey: .tempoScale)
        try c.encode(guide, forKey: .guide)
        try c.encode(click, forKey: .click)
        try c.encode(showGuitarSplit, forKey: .showGuitarSplit)
    }
}

/// Lead/rhythm split of the guitar stem, stored beside the plain guitar stem so older builds keep working.
public struct GuitarSplit: Codable, Hashable, Sendable {
    public var method: String            // e.g. "stereo-v1"
    public var confidence: Double        // 0…1
    public var leadPeaks: [Float]
    public var rhythmPeaks: [Float]
    public var leadScale: Float          // 16-bit storage gain of lead.caf (undone on load)
    public var rhythmScale: Float
    /// When the lead was also taken out of "other", the adjusted Other lives in other-split.caf
    /// (other.caf stays original so the unsplit view and older builds are unchanged).
    public var otherAdjusted: Bool = false
    public var otherPeaks: [Float] = []
    public var otherScale: Float = 1

    public init(method: String, confidence: Double, leadPeaks: [Float], rhythmPeaks: [Float], leadScale: Float, rhythmScale: Float,
                otherAdjusted: Bool = false, otherPeaks: [Float] = [], otherScale: Float = 1) {
        self.method = method; self.confidence = confidence
        self.leadPeaks = leadPeaks; self.rhythmPeaks = rhythmPeaks
        self.leadScale = leadScale; self.rhythmScale = rhythmScale
        self.otherAdjusted = otherAdjusted; self.otherPeaks = otherPeaks; self.otherScale = otherScale
    }

    enum CodingKeys: String, CodingKey {
        case method, confidence, leadPeaks, rhythmPeaks, leadScale, rhythmScale, otherAdjusted, otherPeaks, otherScale
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? "stereo-v1"
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        leadPeaks = try c.decodeIfPresent([Float].self, forKey: .leadPeaks) ?? []
        rhythmPeaks = try c.decodeIfPresent([Float].self, forKey: .rhythmPeaks) ?? []
        leadScale = try c.decodeIfPresent(Float.self, forKey: .leadScale) ?? 1
        rhythmScale = try c.decodeIfPresent(Float.self, forKey: .rhythmScale) ?? 1
        otherAdjusted = try c.decodeIfPresent(Bool.self, forKey: .otherAdjusted) ?? false
        otherPeaks = try c.decodeIfPresent([Float].self, forKey: .otherPeaks) ?? []
        otherScale = try c.decodeIfPresent(Float.self, forKey: .otherScale) ?? 1
    }
}

/// A separated song in the library.
public struct SongRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String                                 // content hash
    public var title: String
    public var artist: String?
    public var duration: Double
    public var sourceName: String
    public var addedAt: Date
    public var lastOpened: Date
    /// Stems on disk, one `<kind>.caf` each. Always base kinds (`.guitar`, never lead/rhythm).
    public var stems: [StemKind]
    public var analysis: SongAnalysis
    public var peaks: [String: [Float]]                   // StemKind.rawValue → max-abs per bucket
    public var storageScale: [String: Float]              // gain applied before 16-bit storage (undone on load)
    public var hasArtwork: Bool
    public var settings: SongSettings
    // v0.12
    public var guitarSplit: GuitarSplit?                  // present when lead.caf / rhythm.caf exist
    public var bpmOverride: Double?                       // user-corrected tempo, if any

    public init(id: String, title: String, artist: String?, duration: Double, sourceName: String,
                addedAt: Date, lastOpened: Date, stems: [StemKind], analysis: SongAnalysis,
                peaks: [String: [Float]], storageScale: [String: Float], hasArtwork: Bool,
                settings: SongSettings, guitarSplit: GuitarSplit? = nil) {
        self.id = id; self.title = title; self.artist = artist; self.duration = duration
        self.sourceName = sourceName; self.addedAt = addedAt; self.lastOpened = lastOpened
        self.stems = stems; self.analysis = analysis; self.peaks = peaks; self.storageScale = storageScale
        self.hasArtwork = hasArtwork; self.settings = settings; self.guitarSplit = guitarSplit
    }

    public var durationString: String { formatTime(duration) }

    /// Tracks the mixer and engine use: the stored stems, with `.guitar` replaced by lead + rhythm
    /// when a split exists and is switched on.
    public var mixStems: [StemKind] {
        guard splitActive else { return stems }
        return stems.flatMap { $0 == .guitar ? [StemKind.leadGuitar, .rhythmGuitar] : [$0] }
    }

    /// File name stem for a stored stem (`lead` / `rhythm` for the split parts).
    public static func fileStem(_ k: StemKind) -> String {
        switch k {
        case .leadGuitar: "lead"
        case .rhythmGuitar: "rhythm"
        default: k.rawValue
        }
    }

    /// True when the mixer is showing the lead/rhythm split.
    public var splitActive: Bool { guitarSplit != nil && settings.showGuitarSplit && stems.contains(.guitar) }

    /// File name stem for a mix track in the current view (the adjusted Other while split).
    public func mixFileStem(_ k: StemKind) -> String {
        if k == .other, splitActive, guitarSplit?.otherAdjusted == true { return "other-split" }
        return Self.fileStem(k)
    }

    /// 16-bit storage gain of a mix track (undone on load).
    public func storageGain(_ k: StemKind) -> Float {
        switch k {
        case .leadGuitar: guitarSplit?.leadScale ?? 1
        case .rhythmGuitar: guitarSplit?.rhythmScale ?? 1
        case .other where splitActive && guitarSplit?.otherAdjusted == true: guitarSplit?.otherScale ?? 1
        default: storageScale[k.rawValue] ?? 1
        }
    }

    public func peaks(for k: StemKind) -> [Float] {
        switch k {
        case .leadGuitar: guitarSplit?.leadPeaks ?? []
        case .rhythmGuitar: guitarSplit?.rhythmPeaks ?? []
        case .other where splitActive && guitarSplit?.otherAdjusted == true: guitarSplit?.otherPeaks ?? []
        default: peaks[k.rawValue] ?? []
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, title, artist, duration, sourceName, addedAt, lastOpened, stems, analysis, peaks
        case storageScale, hasArtwork, settings, guitarSplit, bpmOverride
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        duration = try c.decode(Double.self, forKey: .duration)
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date(timeIntervalSinceReferenceDate: 0)
        lastOpened = try c.decodeIfPresent(Date.self, forKey: .lastOpened) ?? addedAt
        let stemRaw = try c.decode([String].self, forKey: .stems)
        stems = stemRaw.compactMap(StemKind.init(rawValue:))
        analysis = try c.decode(SongAnalysis.self, forKey: .analysis)
        peaks = try c.decodeIfPresent([String: [Float]].self, forKey: .peaks) ?? [:]
        storageScale = try c.decodeIfPresent([String: Float].self, forKey: .storageScale) ?? [:]
        hasArtwork = try c.decodeIfPresent(Bool.self, forKey: .hasArtwork) ?? false
        settings = (try? c.decodeIfPresent(SongSettings.self, forKey: .settings)) ?? SongSettings()
        guitarSplit = try? c.decodeIfPresent(GuitarSplit.self, forKey: .guitarSplit)
        bpmOverride = try c.decodeIfPresent(Double.self, forKey: .bpmOverride)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(artist, forKey: .artist)
        try c.encode(duration, forKey: .duration)
        try c.encode(sourceName, forKey: .sourceName)
        try c.encode(addedAt, forKey: .addedAt)
        try c.encode(lastOpened, forKey: .lastOpened)
        try c.encode(stems.map(\.rawValue), forKey: .stems)
        try c.encode(analysis, forKey: .analysis)
        try c.encode(peaks, forKey: .peaks)
        try c.encode(storageScale, forKey: .storageScale)
        try c.encode(hasArtwork, forKey: .hasArtwork)
        try c.encode(settings, forKey: .settings)
        try c.encodeIfPresent(guitarSplit, forKey: .guitarSplit)
        try c.encodeIfPresent(bpmOverride, forKey: .bpmOverride)
    }
}

public func formatTime(_ t: Double) -> String {
    let s = max(0, Int(t.rounded(.down)))
    return "\(s / 60):" + String(format: "%02d", s % 60)
}

/// Pitch in frets (one fret = one semitone): guitar students count frets, not semitones.
public func formatPitch(_ st: Int, compact: Bool = false) -> String {
    let unit = compact ? "" : (abs(st) == 1 ? " fret" : " frets")
    return st == 0 ? "0\(unit)" : (st > 0 ? "+\(st)\(unit)" : "−\(abs(st))\(unit)")
}
