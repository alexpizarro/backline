import Foundation
import Testing
@testable import BacklineKit

/// U05: how much of a part is really in the song (`docs/release/part-detection.md`, Step 1 tests).
struct PartPresenceTests {
    static let sr = 44_100
    /// A steady tone of `seconds`, at `gain`, switched on only where `on` says (per half-second frame).
    static func tone(_ seconds: Int, gain: Float, hz: Float = 220, on: (Int) -> Bool = { _ in true }) -> StereoAudio {
        let n = seconds * sr
        var l = [Float](repeating: 0, count: n)
        for i in 0..<n where on(i / PartPresence.frame) { l[i] = gain * sin(2 * .pi * hz * Float(i) / Float(sr)) }
        return StereoAudio(left: l, right: l, sampleRate: Double(sr))
    }
    static func sum(_ a: StereoAudio, _ b: StereoAudio) -> StereoAudio {
        StereoAudio(left: zip(a.left, b.left).map(+), right: zip(a.right, b.right).map(+), sampleRate: a.sampleRate)
    }
    static let db: (Float) -> Float = { pow(10, $0 / 20) }

    @Test func aPartSixtyDecibelsUnderTheMixIsNotActive() {
        let band = Self.tone(20, gain: 0.5)
        let ghost = Self.tone(20, gain: 0.5 * Self.db(-60), hz: 330)
        let l = PartPresence.measure(part: ghost, mix: Self.sum(band, ghost))
        #expect(l.active == 0)
        #expect(l.share < -55)
        #expect(!PartPresence.isPresent(l))
    }

    @Test func aPartInThirtyPercentOfTheFramesIsAboutThirtyPercentActive() {
        let band = Self.tone(20, gain: 0.5)
        let part = Self.tone(20, gain: 0.5 * Self.db(-6), hz: 330, on: { $0 % 10 < 3 })
        let l = PartPresence.measure(part: part, mix: Self.sum(band, part))
        #expect(abs(l.active - 0.30) < 0.03, "active \(l.active)")
        #expect(PartPresence.isPresent(l))
    }

    @Test func aShortLoudBurstPassesOnItsPeak() {
        // −3 dB against the band for 8 % of the song: rarely active, but loud when it plays.
        let band = Self.tone(25, gain: 0.5)
        let burst = Self.tone(25, gain: 0.5 * Self.db(-3), hz: 330, on: { $0 < 4 })
        let l = PartPresence.measure(part: burst, mix: Self.sum(band, burst))
        #expect(l.active < PartPresence.presentActive)
        #expect(l.peak >= PartPresence.presentPeak, "peak \(l.peak)")
        #expect(PartPresence.isPresent(l))
    }

    @Test func aSilentIntroInTheMixIsIgnored() {
        // The first half of the song is silence; the part plays at −6 dB through the second half only.
        let band = Self.tone(20, gain: 0.5, on: { $0 >= 20 })
        let part = Self.tone(20, gain: 0.5 * Self.db(-6), hz: 330, on: { $0 >= 20 })
        let l = PartPresence.measure(part: part, mix: Self.sum(band, part))
        #expect(l.active > 0.95, "silent frames don't count against the part: \(l.active)")
    }

    @Test func thresholdsAreInclusive() {
        #expect(PartPresence.isPresent(PartLevel(share: -30, active: PartPresence.presentActive, peak: -40)))
        #expect(!PartPresence.isPresent(PartLevel(share: -30, active: PartPresence.presentActive - 0.001, peak: -40)))
        #expect(PartPresence.isPresent(PartLevel(share: -30, active: 0, peak: PartPresence.presentPeak)))
        #expect(!PartPresence.isPresent(PartLevel(share: -30, active: 0, peak: PartPresence.presentPeak - 0.1)))
    }

    @Test func streamedFramesGiveTheSameLevelAsWholeAudio() {
        let band = Self.tone(10, gain: 0.4)
        let part = Self.tone(10, gain: 0.2, hz: 330, on: { $0 % 3 == 0 })
        let mix = Self.sum(band, part)
        let a = PartPresence.measure(part: part, mix: mix)
        let b = PartPresence.level(part: PartPresence.frames(part), mix: PartPresence.frames(mix))
        #expect(a == b)
    }
}
