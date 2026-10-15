import Testing
@testable import BacklineKit

struct PracticeTests {
    let beats = (0..<64).map { Double($0) * 0.5 }      // 120 bpm, beat every 0.5 s

    @Test func beatIndexAndNearest() {
        #expect(BeatGrid.index(at: -1, in: beats) == nil)
        #expect(BeatGrid.index(at: 0, in: beats) == 0)
        #expect(BeatGrid.index(at: 1.24, in: beats) == 2)
        #expect(BeatGrid.nearest(to: 1.3, in: beats) == 3)
        #expect(BeatGrid.time(of: 70, in: beats) == 35)
        #expect(BeatGrid.time(of: -2, in: beats) == -1)
    }

    @Test func countsWrapInEights() {
        #expect(DanceCounts.count(beat: 4, one: 4) == 1)
        #expect(DanceCounts.count(beat: 11, one: 4) == 8)
        #expect(DanceCounts.count(beat: 12, one: 4) == 1)
        #expect(DanceCounts.count(beat: 1, one: 4) == 6)       // before the 1 still counts
        #expect(DanceCounts.eightStart(beat: 10, one: 4) == 4)
        #expect(DanceCounts.eightStart(beat: 3, one: 4) == -4)
    }

    @Test func danceGuessFixesHalfTimeSalsa() {
        #expect(DanceGuess.guess(title: "Some song", bpm: 93).style == .salsa)
        #expect(DanceGuess.guess(title: "Some song", bpm: 93).tempoScale == 2)
        #expect(DanceGuess.guess(title: "Some song", bpm: 130).style == .bachata)
        #expect(DanceGuess.guess(title: "Some song", bpm: 130).tempoScale == 1)
        #expect(DanceGuess.guess(title: "Some song", bpm: 65).tempoScale == 2)
        #expect(DanceGuess.guess(title: "Some song", bpm: 90).style == .salsa)   // 180: a guess, menu can fix
        #expect(DanceGuess.guess(title: "Eres Mía (Bachata Version)", bpm: 64).style == .bachata)
        #expect(DanceGuess.guess(title: "Eres Mía (Bachata Version)", bpm: 64).tempoScale == 2)
        #expect(DanceGuess.guess(title: "Kizomba mix", bpm: 90).style == .other)
        #expect(DanceGuess.guess(title: "Kizomba mix", bpm: 90).tempoScale == 1)
        #expect(DanceGuess.guess(title: "Salsa clásica", bpm: 186).tempoScale == 1)
    }

    @Test func barLoopsSnapToBarLines() {
        let bars = stride(from: 1.0, to: 60, by: 2).map { $0 }   // bar lines every 2 s from 1 s
        #expect(BarLoop.range(bars: 2, at: 6.2, downbeats: bars, fallbackBar: 2) == 5...9)
        #expect(BarLoop.range(bars: 1, at: 0.4, downbeats: bars, fallbackBar: 2) == 0...2)   // before the first bar line
        #expect(BarLoop.barCount(of: 5...9, downbeats: bars) == 2)
        #expect(BarLoop.barCount(of: 5.4...9, downbeats: bars) == nil)
    }

    @Test func dancersSeeDanceNames() {
        #expect(StemKind.leadGuitar.label(in: .dance, style: .bachata) == "Requinto")
        #expect(StemKind.rhythmGuitar.label(in: .dance, style: .bachata) == "Segunda")
        #expect(StemKind.other.label(in: .dance, style: .salsa) == "Horns")
        #expect(StemKind.drums.label(in: .dance) == "Percussion")
        #expect(StemKind.leadGuitar.label(in: .play) == "Lead guitar")
    }
}
