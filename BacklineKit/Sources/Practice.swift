import Foundation

/// Beat-grid maths shared by the practice modes. Plain functions on sorted beat times so they are
/// cheap (binary search) and unit-testable.
public enum BeatGrid {
    /// Index of the last beat at or before `t`, or nil before the first beat.
    public static func index(at t: Double, in beats: [Double]) -> Int? {
        guard let first = beats.first, t >= first - 0.03 else { return nil }
        var lo = 0, hi = beats.count - 1
        while lo < hi {
            let m = (lo + hi + 1) / 2
            if beats[m] <= t + 0.03 { lo = m } else { hi = m - 1 }
        }
        return lo
    }

    /// Index of the beat nearest to `t`.
    public static func nearest(to t: Double, in beats: [Double]) -> Int? {
        guard !beats.isEmpty else { return nil }
        guard let i = index(at: t, in: beats) else { return 0 }
        if i + 1 < beats.count, abs(beats[i + 1] - t) < abs(beats[i] - t) { return i + 1 }
        return i
    }

    /// Time of beat `i`, extrapolated with the local beat length past either end of the grid.
    public static func time(of i: Int, in beats: [Double]) -> Double {
        guard !beats.isEmpty else { return 0 }
        if i >= 0 && i < beats.count { return beats[i] }
        guard beats.count > 1 else { return beats[0] }
        if i < 0 { return beats[0] + Double(i) * (beats[1] - beats[0]) }
        let n = beats.count
        return beats[n - 1] + Double(i - n + 1) * (beats[n - 1] - beats[n - 2])
    }
}

/// Dancers count in eights. Count = (beat − the "1") mod 8 + 1.
public enum DanceCounts {
    /// 1…cycle for beat `i` when beat `one` is a count 1 (8 for dancers, 4 for a bar of music).
    public static func count(beat i: Int, one: Int, cycle: Int = 8) -> Int { ((i - one) % cycle + cycle) % cycle + 1 }

    /// Index of the count-1 beat that starts the eight holding beat `i`.
    public static func eightStart(beat i: Int, one: Int) -> Int { i - (count(beat: i, one: one) - 1) }
}

/// Guesses the dance style and the tempo dancers count, from the title and the detected tempo.
/// Tempo bands dancers use: bachata 106–145, salsa 150–210. Salsa is often detected at
/// half tempo (about 93 for a song danced at 186), so the double is tried before giving up.
/// It is a soft guess: the style and tempo menus can always change it.
public enum DanceGuess {
    public static let bachata: ClosedRange<Double> = 106...145
    public static let salsa: ClosedRange<Double> = 150...210

    public static func style(fromTitle text: String) -> DanceStyle? {
        let t = text.lowercased()
        if t.contains("bachata") { return .bachata }
        for k in ["salsa", "son montuno", "timba", "mambo"] where t.contains(k) { return .salsa }
        for k in ["kizomba", "zouk", "urban kiz", "tarraxinha", "merengue", "cha cha", "cumbia"] where t.contains(k) {
            return .other
        }
        return nil
    }

    /// Returns the style and the tempo scale (0.5, 1 or 2) to apply to the detected tempo.
    public static func guess(title: String, artist: String? = nil, bpm: Double) -> (style: DanceStyle, tempoScale: Double) {
        let named = style(fromTitle: title + " " + (artist ?? ""))
        guard bpm > 0 else { return (named ?? .other, 1) }
        let scales: [Double] = [1, 2, 0.5]
        func band(_ s: DanceStyle) -> ClosedRange<Double>? {
            switch s {
            case .bachata: bachata
            case .salsa: salsa
            case .other: nil
            }
        }
        if let named {
            guard let b = band(named) else { return (named, 1) }
            return (named, scales.first { b.contains(bpm * $0) } ?? 1)
        }
        for s in scales {
            if bachata.contains(bpm * s) { return (.bachata, s) }
            if salsa.contains(bpm * s) { return (.salsa, s) }
        }
        return (.other, 1)
    }
}

/// Bar-aligned loops for Beats mode.
public enum BarLoop {
    /// A loop of `bars` whole bars starting at the bar that holds `t`. `downbeats` are bar starts.
    public static func range(bars: Int, at t: Double, downbeats: [Double], fallbackBar: Double) -> ClosedRange<Double>? {
        guard bars > 0 else { return nil }
        if let i = BeatGrid.index(at: t, in: downbeats) {
            let a = BeatGrid.time(of: i, in: downbeats)
            let b = BeatGrid.time(of: i + bars, in: downbeats)
            return b > a ? a...b : nil
        }
        // Before the first bar line (or no grid): bars of the detected length from the first bar line.
        let a = downbeats.first.map { $0 - fallbackBar * ((($0 - t) / fallbackBar).rounded(.up)) } ?? t
        return max(0, a)...(max(0, a) + fallbackBar * Double(bars))
    }

    /// How many whole bars `r` spans if it starts and ends on bar lines (within 30 ms), else nil.
    public static func barCount(of r: ClosedRange<Double>, downbeats: [Double]) -> Int? {
        guard let i = BeatGrid.nearest(to: r.lowerBound, in: downbeats),
              abs(downbeats[i] - r.lowerBound) < 0.03 else { return nil }
        for n in 1...64 where abs(BeatGrid.time(of: i + n, in: downbeats) - r.upperBound) < 0.03 { return n }
        return nil
    }
}
