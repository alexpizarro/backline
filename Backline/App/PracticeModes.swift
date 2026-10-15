import BacklineKit
import Foundation

/// Practice modes (Play · Dance · Beats): one switch re-dresses the same screen. Play is the original
/// guitar-practice app; Dance adds counts and "Listen for"; Beats adds bar loops. Nothing here reloads
/// the engine: modes only change labels, defaults, gains and which controls are shown.
extension AppModel {
    /// The mode the open song shows (the app's last-used mode when no song is open).
    var mode: PracticeMode { song == nil ? appMode : (settings.mode ?? appMode) }

    var danceStyle: DanceStyle { settings.danceStyle ?? .other }

    func label(_ k: StemKind) -> String {
        if mode == .beats, k == .other, musicIsOpen { return StemKind.other.name }
        return k.label(in: mode, style: settings.danceStyle)
    }
    func shortLabel(_ k: StemKind) -> String {
        if mode == .beats, k == .other, musicIsOpen { return StemKind.other.shortName }
        return k.shortLabel(in: mode, style: settings.danceStyle)
    }

    // MARK: Beats: the Music row opens into its parts

    var musicLeaves: [StemKind] { song.map(Self.musicLeaves) ?? [] }
    /// True when Beats shows Music as separate parts.
    var musicIsOpen: Bool { settings.musicOpen && musicLeaves.count > 1 }
    var musicCanOpen: Bool { musicLeaves.count > 1 }

    /// Opens or closes Music. A Music row that was off turns every part off, and back.
    func toggleMusicOpen() {
        let leaves = Set(musicLeaves)
        guard leaves.count > 1 else { return }
        var st = settings
        if st.musicOpen {
            let allOff = leaves.allSatisfy { st.removed.contains($0) }
            st.removed.subtract(leaves)
            if allOff { st.removed.insert(.other) }
            if let s = st.solo, leaves.contains(s) { st.solo = nil }
        } else {
            if st.removed.contains(.other) { st.removed.formUnion(leaves) }
            if st.solo == .other { st.solo = nil }
        }
        st.musicOpen.toggle()
        settings = st
    }

    // MARK: Switching

    func setMode(_ m: PracticeMode) {
        appMode = m
        guard song != nil, m != mode else { return }
        var st = settings
        st.removedByMode[mode.rawValue] = st.removed.map(\.rawValue).sorted()
        if let saved = st.removedByMode[m.rawValue] {
            st.removed = Set(saved.compactMap(StemKind.init(rawValue:))).intersection(stems)
        } else {
            st.removed = defaultRemoved(for: m, tracks: stems)
        }
        st.solo = nil
        st.spotlight = nil
        if m == .dance { st.guide = false }
        st.mode = m
        if m == .dance, st.danceStyle == nil, let song { applyDanceGuess(&st, song: song) }
        loopCaptureA = nil
        settings = st
        ensureDrumSplit()
    }

    /// What a mode turns off on a song you haven't changed yet.
    func defaultRemoved(for m: PracticeMode, tracks: [StemKind]) -> Set<StemKind> {
        switch m {
        case .play:
            // The remembered "I'm playing" choice; Lead falls back to the single guitar part and back.
            guard let k = StemKind(rawValue: playingInstrumentRaw.isEmpty ? StemKind.leadGuitar.rawValue : playingInstrumentRaw)
            else { return [] }
            if tracks.contains(k) { return [k] }
            if k.isGuitar, let g = tracks.first(where: { $0 == .leadGuitar }) ?? tracks.first(where: { $0 == .guitar }) { return [g] }
            return []
        case .dance:
            return []
        case .beats:
            return tracks.contains(.vocals) ? [.vocals] : []
        }
    }

    /// The mode a new song opens in: a dance named in the title wins, otherwise the app's mode.
    func suggestedMode(for rec: SongRecord) -> PracticeMode {
        switch DanceGuess.style(fromTitle: rec.title + " " + (rec.artist ?? "")) {
        case .bachata?, .salsa?: .dance
        default: appMode
        }
    }

    /// Fills in a song's practice-mode settings the first time it is shown in 0.17.
    func prepareMode(_ st: inout SongSettings, song rec: SongRecord, fresh: Bool) {
        guard st.mode == nil else { return }
        let m = fresh ? suggestedMode(for: rec) : appMode
        st.mode = m
        if m != .play {
            st.removedByMode[PracticeMode.play.rawValue] = st.removed.map(\.rawValue).sorted()
            st.removed = defaultRemoved(for: m, tracks: Self.rows(for: m, style: st.danceStyle, song: rec, musicOpen: st.musicOpen).map(\.kind))
            st.loopEnabled = false
        }
        if m == .dance { applyDanceGuess(&st, song: rec) }
    }

    func applyDanceGuess(_ st: inout SongSettings, song rec: SongRecord) {
        let g = DanceGuess.guess(title: rec.title, artist: rec.artist, bpm: rec.analysis.bpm)
        st.danceStyle = g.style
        // Only when the tempo hasn't been picked by hand.
        if st.tempoScale == 1 { st.tempoScale = g.tempoScale }
    }

    func setDanceStyle(_ s: DanceStyle) {
        settings.danceStyle = s
        if s != .other { settings.tempoScale = DanceGuess.guess(title: s.rawValue, bpm: detectedBPM).tempoScale }
        if let k = settings.spotlight, !danceListenParts.contains(k) { settings.spotlight = nil }
        ensureDrumSplit()
    }

    // MARK: Dance: Listen for

    /// Parts in the "Listen for" row, in the order dancers listen for them.
    var danceListenParts: [StemKind] {
        var order: [StemKind] = [.drums, .snare, .hats, .kick, .bass, .leadGuitar, .rhythmGuitar, .guitar, .keys]
        if danceStyle == .salsa { order.append(.other) }
        order.append(.vocals)
        return order.filter(stems.contains)
    }

    /// One tap: that part loud, the rest quiet. Tap it again for the whole band.
    func toggleSpotlight(_ k: StemKind) {
        if settings.spotlight == k {
            settings.spotlight = nil
        } else {
            settings.removed.remove(k)
            settings.solo = nil
            settings.spotlight = k
        }
    }

    /// Gain factor for the "Listen for" spotlight: the rest of the band plays at −12 dB.
    func spotlightFactor(_ k: StemKind) -> Float {
        guard mode == .dance, let s = settings.spotlight, s != k else { return 1 }
        return 0.25
    }

    // MARK: Dance: counts

    /// Beat index of a count 1 (the stored "1", or the first bar line).
    var oneBeatIndex: Int? {
        let beats = effectiveBeats
        guard !beats.isEmpty else { return nil }
        if let t = settings.countOne { return BeatGrid.nearest(to: t, in: beats) }
        if let d = song?.analysis.downbeats.first { return BeatGrid.nearest(to: d, in: beats) }
        return 0
    }

    /// Dancers count to 8; a bar of music counts to 4.
    var countsPerCycle: Int { mode == .beats ? 4 : 8 }

    /// The count at the playhead. Nothing until someone has set the 1: a guessed 1 that's wrong is worse
    /// than no count at all.
    var currentCount: Int? {
        guard countsConfirmed, let one = oneBeatIndex, let i = BeatGrid.index(at: position, in: effectiveBeats) else { return nil }
        return DanceCounts.count(beat: i, one: one, cycle: countsPerCycle)
    }

    /// Bar number at the playhead (1-based), counted from the bar lines.
    var currentBar: Int? { BeatGrid.index(at: position, in: barLines).map { $0 + 1 } }

    /// True once someone has set the 1 by hand (machine counts are shown dashed until then).
    var countsConfirmed: Bool { settings.countOne != nil }

    /// "Tap on the 1": the beat nearest the playhead becomes count 1. While the song plays, people tap a
    /// little after they hear the beat, so the tap is moved back by a typical reaction time first.
    func setOneHere() {
        let beats = effectiveBeats
        let t = isPlaying ? position - 0.12 : position
        guard let i = BeatGrid.nearest(to: t, in: beats) else { return }
        settings.countOne = beats[i]
    }

    /// Forget the 1 (the counts stop until it's set again).
    func clearOne() { settings.countOne = nil }

    /// Bachata's 1 is often a bar away from where a machine puts it: move it by 4 counts.
    func moveOne(by n: Int) {
        let beats = effectiveBeats
        guard let one = oneBeatIndex, beats.count >= 8 else { return }
        var k = one + n
        while k >= beats.count { k -= 8 }
        while k < 0 { k += 8 }
        settings.countOne = beats[min(max(0, k), beats.count - 1)]
    }

    /// Loops `counts` counts (8, 16, 32) from the start of the eight at the playhead.
    func loopCounts(_ counts: Int) {
        let beats = effectiveBeats
        guard let one = oneBeatIndex, !beats.isEmpty else { return }
        let i = BeatGrid.index(at: position, in: beats) ?? one
        let s = DanceCounts.eightStart(beat: i, one: one)
        let a = max(0, BeatGrid.time(of: s, in: beats)), b = BeatGrid.time(of: s + counts, in: beats)
        guard b > a else { return }
        setLoop(start: a, end: b)
        if !isPlaying { seek(to: a) }
    }

    /// Length in counts of the current loop when it runs beat to beat (for "8 counts" labels).
    var loopCountLength: Int? {
        guard let r = loopRange else { return nil }
        let beats = effectiveBeats
        guard let ia = BeatGrid.nearest(to: r.lowerBound, in: beats), abs(beats[ia] - r.lowerBound) < 0.03,
              let ib = BeatGrid.nearest(to: r.upperBound, in: beats),
              abs(BeatGrid.time(of: ib, in: beats) - r.upperBound) < 0.03 || ib == beats.count - 1 else { return nil }
        let n = ib - ia
        return n > 0 ? n : nil
    }

    /// The count shown on the count-in overlay: dancers hear 5, 6, 7, 8 before the 1.
    var countInLabel: Int { mode == .dance && countInBeat > 0 ? countInBeat + 4 : countInBeat }

    // MARK: Beats: bar loops

    /// Bar starts: every 4th beat from the 1 once it's set, otherwise the detected bar lines.
    var barLines: [Double] {
        if countsConfirmed, let one = oneBeatIndex {
            let beats = effectiveBeats
            return Array(stride(from: one % 4, to: beats.count, by: 4).map { beats[$0] })
        }
        return song?.analysis.downbeats ?? []
    }
    var barLength: Double { detectedBPM > 0 ? 240 / detectedBPM : 2 }

    /// One tap loops `bars` whole bars from the bar at the playhead; tapping the same length again stops it.
    func loopBars(_ bars: Int) {
        guard let r = BarLoop.range(bars: bars, at: position, downbeats: barLines, fallbackBar: barLength) else { return }
        // Tapping the loop that's already playing stops it; any other tap makes the new loop.
        if settings.loopEnabled, let cur = loopRange, loopBarCount == bars,
           cur.contains(position) || abs(cur.lowerBound - r.lowerBound) < 0.03 {
            settings.loopEnabled = false
            return
        }
        setLoop(start: r.lowerBound, end: min(duration, r.upperBound))
        if !isPlaying { seek(to: r.lowerBound) }
    }

    var loopBarCount: Int? {
        guard settings.loopEnabled, let r = loopRange else { return nil }
        return BarLoop.barCount(of: r, downbeats: barLines)
    }

    /// Nearest bar line (no distance limit), for dragging loops in Beats.
    func snapToBarLine(_ t: Double) -> Double {
        guard let i = BeatGrid.nearest(to: t, in: barLines) else { return snapToBeat(t) }
        return barLines[i]
    }

    /// Lines drawn on the waveform: every eight in Dance, every bar in Beats.
    var gridLines: [Double] {
        switch mode {
        case .play: return []
        case .beats: return barLines
        case .dance:
            let beats = effectiveBeats
            guard countsConfirmed, let one = oneBeatIndex else { return [] }
            var out: [Double] = []
            var k = one % 8
            while k < beats.count { out.append(beats[k]); k += 8 }
            return out
        }
    }
}
