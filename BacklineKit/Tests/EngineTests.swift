import XCTest
@testable import BacklineKit

final class EngineTests: XCTestCase {
    let sr = 44_100.0

    /// Stem i is a sine at a distinct frequency so we can check what's audible. On 16-bit steps, as a part read
    /// from disk is (the engine holds 16 bits, D3), so the exact-mix checks compare like with like.
    func makeStems(seconds: Double = 6) -> [StereoAudio] {
        let n = Int(seconds * sr)
        return (0..<3).map { i in
            let f = 220.0 * Double(i + 1)
            let x = Self.on16Bits((0..<n).map { Float(0.2 * sin(2 * .pi * f * Double($0) / sr)) })
            return StereoAudio(left: x, right: x, sampleRate: sr)
        }
    }

    /// Rounds to the nearest 1/32768, what a 16-bit part file holds.
    static func on16Bits(_ x: [Float]) -> [Float] {
        x.map { Float(max(-32768, min(32767, ($0 * 32768).rounded()))) / 32768 }
    }

    func rms(_ x: ArraySlice<Float>) -> Float {
        sqrt(x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count)))
    }

    func testIdentityPlaybackIsSampleExactMix() {
        let e = PlaybackEngine(drivesOutput: false)
        let stems = makeStems()
        e.load(stems: stems, pitchLocked: [false, false, false])
        e.play()
        _ = e.renderForTesting(frames: 256)            // fade-in block
        let out = e.renderForTesting(frames: 4096)
        // Expected: plain sum from frame 256.
        var maxErr: Float = 0
        for i in 0..<4096 {
            let exp = stems[0].left[256 + i] + stems[1].left[256 + i] + stems[2].left[256 + i]
            maxErr = max(maxErr, abs(out.left[i] - exp))
        }
        XCTAssertLessThan(maxErr, 1e-5)
        XCTAssertEqual(e.status.position, 256 + 4096)
    }

    /// T39 (AD-11): each part's level is what it adds to the mix; a part at gain 0 reports 0, a full-scale sine
    /// at gain 1 about 0.707, and everything reads 0 once paused.
    func testLevelsFollowEachPartAndTheMaster() {
        let e = PlaybackEngine(drivesOutput: false)
        let n = Int(4 * sr)
        let sine = (0..<n).map { Float(sin(2 * .pi * 440 * Double($0) / sr)) }
        let silent = [Float](repeating: 0, count: n)
        e.load(stems: [StereoAudio(left: sine, right: sine, sampleRate: sr), StereoAudio(left: sine, right: sine, sampleRate: sr),
                       StereoAudio(left: silent, right: silent, sampleRate: sr)], pitchLocked: [false, false, false])
        e.setGain(stem: 1, 0)
        e.play()
        _ = e.renderForTesting(frames: 4096)          // past the fade-in and the gain ramp
        _ = e.renderForTesting(frames: 4096)
        var parts = [Float](repeating: -1, count: 4)
        let master = e.levels(into: &parts)
        XCTAssertEqual(parts[0], 0.707, accuracy: 0.01, "a full-scale sine at gain 1")
        XCTAssertEqual(parts[1], 0, accuracy: 1e-4, "gain 0 reports 0")
        XCTAssertEqual(parts[2], 0, accuracy: 1e-4, "a silent part")
        XCTAssertEqual(parts[3], 0, "past the last part")
        XCTAssertGreaterThan(master, 0.5, "the master carries the sine (softly clipped)")
        e.pause()
        _ = e.renderForTesting(frames: 4096)
        _ = e.renderForTesting(frames: 512)
        XCTAssertEqual(e.levels(into: &parts), 0, "paused: silent")
        XCTAssertEqual(parts[0], 0)
    }

    /// Before the first Play nothing renders, so a seek must still show at once (it used to snap back to 0).
    func testSeekBeforeFirstRenderReportsNewPosition() {
        let e = PlaybackEngine(drivesOutput: false)
        e.load(stems: makeStems(), pitchLocked: [false, false, false])
        e.seek(frame: Int64(3 * sr))
        XCTAssertEqual(e.status.position, Int64(3 * sr))
        e.seek(frame: Int64(4 * sr))
        XCTAssertEqual(e.status.position, Int64(4 * sr))
        e.play()
        _ = e.renderForTesting(frames: 512)
        XCTAssertEqual(e.status.position, Int64(4 * sr) + 512)
    }

    func testMuteRampsWithoutClick() {
        let e = PlaybackEngine(drivesOutput: false)
        e.load(stems: makeStems(), pitchLocked: [false, false, false])
        e.play()
        _ = e.renderForTesting(frames: 4096)
        e.setGain(stem: 0, 0)
        e.setGain(stem: 1, 0)
        e.setGain(stem: 2, 0)
        let out = e.renderForTesting(frames: 4096)
        // Max sample-to-sample jump stays small (no step discontinuity).
        var maxJump: Float = 0
        for i in 1..<4096 { maxJump = max(maxJump, abs(out.left[i] - out.left[i - 1])) }
        XCTAssertLessThan(maxJump, 0.1)
        XCTAssertLessThan(rms(out.left[1000..<4096]), 1e-6)
    }

    func testLoopWrapsSampleAccurately() {
        let e = PlaybackEngine(drivesOutput: false)
        e.load(stems: makeStems(), pitchLocked: [false, false, false])
        e.setLoop(enabled: true, start: 10_000, end: 20_000)
        e.seek(frame: 10_000)
        e.play()
        _ = e.renderForTesting(frames: 25_000)
        let st = e.status
        // 25_000 frames from 10_000 in a 10_000-frame loop → position 15_000, 2 wraps.
        XCTAssertEqual(st.position, 15_000)
        XCTAssertEqual(st.loopPasses, 2)
    }

    func testCountInPrecedesAudio() {
        let e = PlaybackEngine(drivesOutput: false)
        e.load(stems: makeStems(), pitchLocked: [false, false, false])
        e.setCountIn(enabled: true, bpm: 120, beats: 4)    // 4 × 0.5 s = 88_200 frames
        e.play()
        _ = e.renderForTesting(frames: 44_100)
        XCTAssertEqual(e.status.countInBeat, 2)   // frames 22050..<44100 are beat 2
        XCTAssertEqual(e.status.position, 0)
        _ = e.renderForTesting(frames: 44_100 + 1000)
        XCTAssertEqual(e.status.countInBeat, 0)
        XCTAssertEqual(e.status.position, 1000)
    }

    func testStretchKeepsDurationAndPosition() {
        let e = PlaybackEngine(drivesOutput: false)
        e.load(stems: makeStems(seconds: 10), pitchLocked: [false, false, false])
        e.setRate(0.5)
        e.play()
        let out = e.renderForTesting(frames: 88_200)       // 2 s of output = 1 s of source
        let pos = e.status.position
        XCTAssertEqual(Double(pos), 44_100, accuracy: 2_000)
        XCTAssertGreaterThan(rms(out.left[20_000..<88_200]), 0.1)
    }

    func testStretchPitchShiftMovesFrequency() {
        let e = PlaybackEngine(drivesOutput: false)
        // Single 440 Hz stem.
        let n = Int(4 * sr)
        let x = (0..<n).map { Float(0.3 * sin(2 * .pi * 440 * Double($0) / sr)) }
        e.load(stems: [StereoAudio(left: x, right: x, sampleRate: sr)], pitchLocked: [false])
        e.setSemitones(12)
        e.play()
        let out = e.renderForTesting(frames: 44_100)
        // Zero-crossing rate over the steady part ≈ 2 × 880.
        let seg = out.left[20_000..<44_100]
        var zc = 0
        var prev = seg.first!
        for v in seg.dropFirst() { if (prev < 0) != (v < 0) { zc += 1 }; prev = v }
        let freq = Double(zc) / 2 / (Double(seg.count) / sr)
        XCTAssertEqual(freq, 880, accuracy: 25)
    }

    func testExportLengthsAndIdentity() {
        let e = PlaybackEngine(drivesOutput: false)
        let stems = makeStems(seconds: 3)
        e.load(stems: stems, pitchLocked: [false, false, false])
        let s = PlaybackEngine.ExportSettings(gains: [1, 0, 1], rate: 1, semitones: 0)
        XCTAssertEqual(e.exportLength(s), Int64(stems[0].frameCount))
        var got = [Float]()
        e.export(s) { l, _, n in got.append(contentsOf: UnsafeBufferPointer(start: l, count: n)); return true }
        XCTAssertEqual(got.count, stems[0].frameCount)
        var maxErr: Float = 0
        for i in 0..<got.count { maxErr = max(maxErr, abs(got[i] - (stems[0].left[i] + stems[2].left[i]))) }
        XCTAssertLessThan(maxErr, 1e-5)

        let slow = PlaybackEngine.ExportSettings(gains: [1, 1, 1], rate: 0.75, semitones: -2)
        var count = 0
        e.export(slow) { _, _, n in count += n; return true }
        XCTAssertEqual(count, Int((Double(stems[0].frameCount) / 0.75).rounded()))
    }
}

extension EngineTests {
    /// Switching from identity to stretched playback mid-song (inside a loop) keeps time moving.
    func testRateChangeWhilePlayingInLoop() {
        let e = PlaybackEngine(drivesOutput: false)
        e.load(stems: makeStems(seconds: 20), pitchLocked: [false, false, false])
        let sr = 44_100
        e.setLoop(enabled: true, start: Int64(5 * sr), end: Int64(15 * sr))
        e.seek(frame: Int64(5 * sr))
        e.play()
        for _ in 0..<(sr / 512) { _ = e.renderForTesting(frames: 512) }       // 1 s
        let p1 = e.status.position
        XCTAssertEqual(Double(p1), Double(6 * sr), accuracy: 600)
        e.pause(); e.play()                                                     // collapses to "keep playing"
        e.setRate(0.7)
        e.setSemitones(-2)
        for _ in 0..<(2 * sr / 512) { _ = e.renderForTesting(frames: 512) }   // 2 s
        let p2 = e.status.position
        print("rate switch: \(p1) -> \(p2) (expected ≈ \(Double(p1) + 1.4 * Double(sr)))")
        XCTAssertEqual(Double(p2 - p1), 1.4 * Double(sr), accuracy: 4_000)
    }
}

extension EngineTests {
    /// Pause (processed), change rate/pitch while paused, then play: time must advance at the new rate.
    func testChangeRateWhilePausedThenPlay() {
        let e = PlaybackEngine(drivesOutput: false)
        e.load(stems: makeStems(seconds: 20), pitchLocked: [false, true, false])
        let sr = 44_100
        e.setLoop(enabled: true, start: Int64(5 * sr), end: Int64(15 * sr))
        e.seek(frame: Int64(6 * sr))
        e.play()
        for _ in 0..<(sr / 512) { _ = e.renderForTesting(frames: 512) }
        e.pause()
        _ = e.renderForTesting(frames: 512)
        let p1 = e.status.position
        e.setRate(0.7)
        e.setSemitones(-2)
        _ = e.renderForTesting(frames: 512)
        e.play()
        for _ in 0..<(2 * sr / 512) { _ = e.renderForTesting(frames: 512) }
        let p2 = e.status.position
        print("paused-change: \(p1) -> \(p2) (expected +\(1.4 * Double(sr)))")
        XCTAssertEqual(Double(p2 - p1), 1.4 * Double(sr), accuracy: 4_000)
    }
}

extension EngineTests {
    /// Trainer: 70 % → +10 % every pass → capped at 90 %, switching exactly at each wrap.
    func testSpeedTrainerRampsAtLoopWraps() {
        let e = PlaybackEngine(drivesOutput: false)
        e.load(stems: makeStems(seconds: 12), pitchLocked: [false, false, false])
        let sr = 44_100
        e.setLoop(enabled: true, start: Int64(2 * sr), end: Int64(4 * sr))   // 2 s loop
        e.setTrainer(enabled: true, from: 0.7, step: 0.1, every: 1, to: 0.9)
        e.seek(frame: Int64(2 * sr))
        e.play()
        var rates: [Double] = []
        var lastPasses: UInt32 = 0
        for _ in 0..<(12 * sr / 512) {
            _ = e.renderForTesting(frames: 512)
            let st = e.status
            if st.loopPasses != lastPasses || rates.isEmpty { rates.append(st.rate); lastPasses = st.loopPasses }
        }
        print("trainer rates per pass:", rates.map { String(format: "%.2f", $0) })
        XCTAssertEqual(rates.first ?? 0, 0.7, accuracy: 0.001)
        XCTAssertEqual(rates.dropFirst().first ?? 0, 0.8, accuracy: 0.001)
        XCTAssertEqual(rates.last ?? 0, 0.9, accuracy: 0.001)
    }
}

extension EngineTests {
    /// Synthetic metal-style guitar: two decorrelated chug parts hard L/R + a centred sustained lead in the
    /// middle third. The split must put most of the lead in `lead`, keep rhythm mostly in `rhythm`,
    /// and reconstruct the stem exactly.
    func testGuitarSplitterSeparatesCentredLead() {
        let sr = 44_100.0, n = Int(12 * sr)
        var seed: UInt32 = 7
        func rnd() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 8) / Float(1 << 24) - 0.5 }
        // Double-tracked takes: different timing, tone and noise per side (as real doubles are).
        func chug(_ phase: Double, detune: Double) -> [Float] {
            (0..<n).map { i in
                let t = Double(i) / sr
                let beat = (t * 4 + phase).truncatingRemainder(dividingBy: 1)
                let env = Float(exp(-beat * 9))
                return env * (0.4 * Float(sin(2 * .pi * 82.4 * detune * t)) + 0.3 * Float(sin(2 * .pi * 123.5 * detune * t))
                              + 0.2 * Float(sin(2 * .pi * 329.6 * detune * t + 1.3)) + 0.35 * rnd())
            }
        }
        let rl = chug(0, detune: 1), rr = chug(0.06, detune: 1.004)
        let lead: [Float] = (0..<n).map { i in
            let t = Double(i) / sr
            guard t > 4 && t < 8 else { return 0 }
            let f = 660 * (1 + 0.01 * sin(2 * .pi * 5.5 * t))
            return 0.35 * Float(sin(2 * .pi * f * t) + 0.4 * sin(4 * .pi * f * t))
        }
        let L = zip(rl, lead).map(+), R = zip(rr, lead).map(+)
        let r = GuitarSplitter.split(StereoAudio(left: L, right: R, sampleRate: sr))
        func e(_ x: [Float], _ a: Int, _ b: Int) -> Float { x[a..<b].reduce(0) { $0 + $1 * $1 } }
        // Reconstruction
        var maxErr: Float = 0
        for i in 0..<n { maxErr = max(maxErr, abs(r.lead.left[i] + r.rhythm.left[i] - L[i])) }
        XCTAssertLessThan(maxErr, 1e-5)
        // During the lead: lead output energy vs true lead; rhythm output should not carry it.
        let a = Int(4.5 * sr), b = Int(7.5 * sr)
        var leadErr: Float = 0, leadTrue: Float = 0
        for i in a..<b { let d = r.lead.left[i] - lead[i]; leadErr += d * d; leadTrue += lead[i] * lead[i] }
        let sdrLead = 10 * log10(leadTrue / leadErr)
        print("synthetic lead SDR during solo:", sdrLead, "dB, width", r.width, "split", r.shouldSplit)
        XCTAssertGreaterThan(sdrLead, 3)
        // Rhythm-only section: very little goes to lead.
        let q = Int(1 * sr), w = Int(3.5 * sr)
        XCTAssertLessThan(e(r.lead.left, q, w) / e(L, q, w), 0.1)
        XCTAssertTrue(r.shouldSplit)
    }

    /// A mono guitar stem must not be split.
    func testGuitarSplitterLeavesMonoAlone() {
        let sr = 44_100.0, n = Int(6 * sr)
        let x = (0..<n).map { Float(0.3 * sin(2 * .pi * 110 * Double($0) / sr)) }
        XCTAssertFalse(GuitarSplitter.split(StereoAudio(left: x, right: x, sampleRate: sr)).shouldSplit)
    }
}

extension EngineTests {
    /// Loop-only export: length = (end − start) / rate, within one frame.
    func testExportRangeLength() {
        let e = PlaybackEngine(drivesOutput: false)
        let stems = makeStems(seconds: 6)
        e.load(stems: stems, pitchLocked: [false, false, false])
        let s = PlaybackEngine.ExportSettings(gains: [1, 1, 1], rate: 0.8, semitones: 0, start: 44_100, end: 3 * 44_100)
        var count = 0
        e.export(s) { _, _, n in count += n; return true }
        XCTAssertEqual(Double(count), Double(2 * 44_100) / 0.8, accuracy: 1)
        let id = PlaybackEngine.ExportSettings(gains: [1, 0, 1], rate: 1, semitones: 0, start: 44_100, end: 2 * 44_100)
        var first = [Float]()
        e.export(id) { l, _, n in first.append(contentsOf: UnsafeBufferPointer(start: l, count: n)); return true }
        XCTAssertEqual(first.count, 44_100)
        XCTAssertEqual(first[0], stems[0].left[44_100] + stems[2].left[44_100], accuracy: 1e-6)
    }
}

extension EngineTests {
    /// Clicks land on the beat grid (±1 ms) at 70 % speed, and never appear in exports.
    func testClickTrackFollowsGridAndRate() {
        let sr = 44_100.0
        let n = Int(8 * sr)
        let silent = StereoAudio(left: [Float](repeating: 0, count: n), right: [Float](repeating: 0, count: n), sampleRate: sr)
        let e = PlaybackEngine(drivesOutput: false)
        e.load(stems: [silent], pitchLocked: [false])
        let beats = stride(from: 0.5, to: 7.5, by: 0.5).map { $0 }
        e.setBeatGrid(beats, accents: beats.indices.map { $0 % 4 == 0 })
        e.setClick(true)
        e.setRate(0.7)
        e.play()
        var out = [Float]()
        for _ in 0..<(Int(6 * sr) / 512) { out += e.renderForTesting(frames: 512).left }
        // Find click onsets (first sample above threshold after silence).
        var onsets: [Int] = []
        var quiet = 2000
        for (i, v) in out.enumerated() {
            if abs(v) > 0.02 && quiet >= 2000 { onsets.append(i) }
            quiet = abs(v) > 0.02 ? 0 : quiet + 1
        }
        XCTAssertGreaterThanOrEqual(onsets.count, 6)
        // Consecutive clicks are 0.5 s of source apart → 0.5 / 0.7 s of output.
        let expected = 0.5 / 0.7 * sr
        for (a, b) in zip(onsets, onsets.dropFirst()).prefix(5) {
            XCTAssertEqual(Double(b - a), expected, accuracy: 0.002 * sr)   // stretcher latency jitter bound
        }
        var exported: Float = 0
        e.export(.init(gains: [1], rate: 0.7, semitones: 0)) { l, _, k in
            for i in 0..<k { exported = max(exported, abs(l[i])) }; return true
        }
        XCTAssertLessThan(exported, 1e-4)
    }
}

// MARK: - Release-review regressions

extension EngineTests {
    /// Onset of each click (first sample over a threshold after ≥ 2000 quiet samples).
    func clickOnsets(_ x: [Float], threshold: Float = 0.02) -> [Int] {
        var onsets: [Int] = [], quiet = 2000
        for (i, v) in x.enumerated() {
            if abs(v) > threshold && quiet >= 2000 { onsets.append(i) }
            quiet = abs(v) > threshold ? 0 : quiet + 1
        }
        return onsets
    }

    /// Clicks land on the beat (±1 ms) at 1× with 512-frame buffers, including a beat exactly at the play position.
    func testClicksLandOnBeatsAtUnityRate() {
        let sr = 44_100.0, n = Int(6 * sr)
        let silent = StereoAudio(left: [Float](repeating: 0, count: n), right: [Float](repeating: 0, count: n), sampleRate: sr)
        let e = PlaybackEngine(drivesOutput: false)
        e.load(stems: [silent], pitchLocked: [false])
        e.setBeatGrid([0, 0.5, 1.0, 1.5, 2.0], accents: [true, false, false, false, true])
        e.setClick(true)
        e.play()
        var out = [Float]()
        for _ in 0..<(Int(2.5 * sr) / 512) { out += e.renderForTesting(frames: 512).left }
        let onsets = clickOnsets(out)
        XCTAssertEqual(onsets.count, 5, "beat at the play-start position must click")
        for (i, o) in onsets.enumerated() {
            XCTAssertEqual(Double(o), Double(i) * 0.5 * sr, accuracy: 0.001 * sr, "click \(i) off the beat")
        }
    }

    /// Loop wrap inside a block: clicks at the loop start keep coming every pass.
    func testClicksContinueAcrossLoopWrap() {
        let sr = 44_100.0, n = Int(6 * sr)
        let silent = StereoAudio(left: [Float](repeating: 0, count: n), right: [Float](repeating: 0, count: n), sampleRate: sr)
        let e = PlaybackEngine(drivesOutput: false)
        e.load(stems: [silent], pitchLocked: [false])
        e.setBeatGrid([1.0, 1.5], accents: [true, false])
        e.setClick(true)
        e.setLoop(enabled: true, start: Int64(1.0 * sr), end: Int64(2.0 * sr))
        e.seek(frame: Int64(1.0 * sr))
        e.play()
        var out = [Float]()
        for _ in 0..<(Int(4 * sr) / 500) { out += e.renderForTesting(frames: 500).left }   // odd block size
        let onsets = clickOnsets(out)
        XCTAssertEqual(onsets.count, 8, "2 clicks per 1 s pass × 4 passes")
        for (a, b) in zip(onsets, onsets.dropFirst()) { XCTAssertEqual(Double(b - a), 0.5 * sr, accuracy: 0.001 * sr) }
    }

    /// Re-publishing grids while paused (1× → 2× → ½×) must not leave a stale cursor.
    func testGridRepublishWhilePausedUsesNewGrid() {
        let sr = 44_100.0, n = Int(8 * sr)
        let silent = StereoAudio(left: [Float](repeating: 0, count: n), right: [Float](repeating: 0, count: n), sampleRate: sr)
        let e = PlaybackEngine(drivesOutput: false)
        e.load(stems: [silent], pitchLocked: [false])
        let beats = stride(from: 0.0, to: 8, by: 0.5).map { $0 }
        e.setBeatGrid(beats, accents: beats.map { _ in false })
        e.setClick(true)
        e.play()
        for _ in 0..<(Int(1.2 * sr) / 512) { _ = e.renderForTesting(frames: 512) }
        e.pause()
        _ = e.renderForTesting(frames: 512)
        e.setBeatGrid(stride(from: 0.0, to: 8, by: 0.25).map { $0 }, accents: Array(repeating: false, count: 32))
        e.setBeatGrid(stride(from: 0.0, to: 8, by: 1.0).map { $0 }, accents: Array(repeating: false, count: 8))
        e.play()
        var out = [Float]()
        for _ in 0..<(Int(3 * sr) / 512) { out += e.renderForTesting(frames: 512).left }
        let onsets = clickOnsets(out)
        XCTAssertGreaterThanOrEqual(onsets.count, 2)
        for (a, b) in zip(onsets, onsets.dropFirst()) { XCTAssertEqual(Double(b - a), 1.0 * sr, accuracy: 0.002 * sr) }
    }

    /// After a count-in, audio fades in (no step on the downbeat).
    func testNoPopAfterCountIn() {
        let sr = 44_100.0, n = Int(6 * sr)
        let dc = [Float](repeating: 0.5, count: n)
        let e = PlaybackEngine(drivesOutput: false)
        e.load(stems: [StereoAudio(left: dc, right: dc, sampleRate: sr)], pitchLocked: [false])
        e.setCountIn(enabled: true, bpm: 240, beats: 4)             // 4 × 0.25 s
        e.setClickGain(0)
        e.play()
        var out = [Float]()
        for _ in 0..<(Int(1.2 * sr) / 512) { out += e.renderForTesting(frames: 512).left }
        var maxJump: Float = 0
        for i in 1..<out.count { maxJump = max(maxJump, abs(out[i] - out[i - 1])) }
        XCTAssertLessThan(maxJump, 0.01)
    }

    /// Speed trainer: pausing after it ramped and pressing play starts again from the first speed.
    func testTrainerRestartsFromFirstSpeedOnPlay() {
        let e = PlaybackEngine(drivesOutput: false)
        e.load(stems: makeStems(seconds: 12), pitchLocked: [false, false, false])
        let sr = 44_100
        e.setLoop(enabled: true, start: Int64(2 * sr), end: Int64(3 * sr))
        e.setTrainer(enabled: true, from: 0.7, step: 0.1, every: 1, to: 1.0)
        e.seek(frame: Int64(2 * sr))
        e.play()
        for _ in 0..<(6 * sr / 512) { _ = e.renderForTesting(frames: 512) }
        XCTAssertGreaterThan(e.status.rate, 0.85)
        e.pause(); _ = e.renderForTesting(frames: 512)
        e.play(); _ = e.renderForTesting(frames: 512)
        XCTAssertEqual(e.status.rate, 0.7, accuracy: 0.001)
    }

    /// Export gains shorter than the stem count (song changed under an export) must not over-read.
    func testExportWithShortGainsArrayIsSafe() {
        let e = PlaybackEngine(drivesOutput: false)
        let stems = makeStems(seconds: 2)
        e.load(stems: stems, pitchLocked: [false, false, false])
        var got = [Float]()
        e.export(.init(gains: [1], rate: 1, semitones: 0)) { l, _, n in got.append(contentsOf: UnsafeBufferPointer(start: l, count: n)); return true }
        XCTAssertEqual(got.count, stems[0].frameCount)
        XCTAssertEqual(got[1000], stems[0].left[1000], accuracy: 1e-6)   // only stem 0 audible
    }
}

/// T08: while a finger scrubs, the engine holds: silent after one fade-out, and seeks only move the position
/// (re-priming every stretcher per drag event used to overrun the audio thread at speeds other than 100 %).
extension EngineTests {
    private func renderBlocks(_ e: PlaybackEngine, _ count: Int) -> [Float] {
        var out: [Float] = []
        for _ in 0..<count { out += e.renderForTesting(frames: 1024).left }
        return out
    }

    /// One 440 Hz stem whose level steps up every second (0.04 x (second + 1)), so a level says where we are.
    private func staircase(seconds: Int = 10) -> StereoAudio {
        let n = seconds * Int(sr)
        let x = (0..<n).map { i -> Float in
            let step = Float(i / Int(sr) + 1) * 0.04
            return step * Float(sin(2 * .pi * 440 * Double(i) / sr))
        }
        let q = Self.on16Bits(x)
        return StereoAudio(left: q, right: q, sampleRate: sr)
    }

    func testAScrubHoldIsSilentAfterOneFadeOut() {
        let e = PlaybackEngine(drivesOutput: false)
        e.load(stems: makeStems(seconds: 10), pitchLocked: [false, false, false])
        e.play()
        _ = renderBlocks(e, 8)
        e.setHold(true)
        let held = renderBlocks(e, 4)
        XCTAssertGreaterThan(held[0..<256].map(abs).max() ?? 0, 0, "the fade-out tail")
        XCTAssertEqual(held[256...].map(abs).max() ?? 1, 0, "silent for the rest of the hold")
    }

    func testReleasingAHoldPlaysOnFromTheLastSeek() {
        for rate in [1.0, 0.8] {
            let e = PlaybackEngine(drivesOutput: false)
            let stem = staircase()
            e.load(stems: [stem], pitchLocked: [false])
            e.setRate(rate)
            e.seek(frame: Int64(1 * sr))
            e.play()
            _ = renderBlocks(e, 43)
            e.setHold(true)
            _ = renderBlocks(e, 1)

            var last = 0
            for i in 0..<10 {
                last = Int((1.25 + Double(i) / 3) * sr)        // ends at 4.25 s, inside the 0.20 step
                e.seek(frame: Int64(last))
                _ = renderBlocks(e, 1)
                XCTAssertEqual(e.status.position, Int64(last), "rate \(rate): the position during a hold is the last seek")
            }

            e.setHold(false)
            var block: [Float] = []
            for _ in 0..<4 {
                block = renderBlocks(e, 1)
                if (block.map(abs).max() ?? 0) > 0 { break }
            }
            XCTAssertGreaterThan(block.map(abs).max() ?? 0, 0, "rate \(rate): sound comes back on release")
            if rate == 1 {
                var worst: Float = 0
                for i in 256..<1024 { worst = max(worst, abs(block[i] - stem.left[last + i])) }
                XCTAssertLessThan(worst, 1e-5, "at 100 % the output is the source from the last seek, sample for sample")
            } else {
                let level = rms(block[256..<1024])
                XCTAssertEqual(level, 0.20 / sqrt(2), accuracy: 0.012, "rate \(rate): the level of the 4-5 s step")
            }
            let expected = Double(last) + 1024 * rate
            XCTAssertEqual(Double(e.status.position), expected, accuracy: 2048, "rate \(rate): playing on from the last seek")
        }
    }
}

/// T08 review (GPT-6 via codex): transitions the first tests missed.
extension EngineTests {
    /// A hold and a seek in the same audio block: the fade-out is of the old audio, the seek is cheap, and the
    /// release plays from exactly the seek target.
    func testAHoldAndASeekInTheSameBlock() {
        let e = PlaybackEngine(drivesOutput: false)
        let stem = staircase()
        e.load(stems: [stem], pitchLocked: [false])
        e.seek(frame: Int64(2 * sr))
        e.play()
        _ = renderBlocks(e, 10)                                   // around 2.2 s: the 0.12 step
        let target = Int(4.25 * sr)                               // the 0.20 step
        e.setHold(true)
        e.seek(frame: Int64(target))
        let first = renderBlocks(e, 1)
        XCTAssertLessThanOrEqual(first[0..<256].map(abs).max() ?? 1, 0.121, "the fade-out is of the old audio")
        XCTAssertEqual(first[256...].map(abs).max() ?? 1, 0)
        XCTAssertEqual(e.status.position, Int64(target))
        e.setHold(false)
        let back = renderBlocks(e, 1)
        var worst: Float = 0
        for i in 256..<1024 { worst = max(worst, abs(back[i] - stem.left[target + i])) }
        XCTAssertLessThan(worst, 1e-5, "it plays on from exactly the seek target")
    }

    func testPlayWithAFingerAlreadyDownStaysSilent() {
        let e = PlaybackEngine(drivesOutput: false)
        e.load(stems: makeStems(seconds: 6), pitchLocked: [false, false, false])
        e.setHold(true)
        e.play()
        XCTAssertEqual(renderBlocks(e, 3).map(abs).max() ?? 1, 0)
    }

    func testTheEndOfACountInDuringAHoldLeaksNoAudio() {
        let e = PlaybackEngine(drivesOutput: false)
        e.load(stems: makeStems(seconds: 6), pitchLocked: [false, false, false])
        e.setCountIn(enabled: true, bpm: 120, beats: 4)            // 2 s of clicks
        e.setHold(true)
        e.play()
        let out = renderBlocks(e, 108)                              // 2.5 s
        XCTAssertGreaterThan(out[0..<88_200].map(abs).max() ?? 0, 0, "the count-in still clicks")
        XCTAssertEqual(out[88_200...].map(abs).max() ?? 1, 0, "and no song audio slips out when it ends")
    }

    func testLoadingASongEndsAHold() {
        let e = PlaybackEngine(drivesOutput: false)
        e.load(stems: makeStems(seconds: 6), pitchLocked: [false, false, false])
        e.play()
        _ = renderBlocks(e, 4)
        e.setHold(true)
        _ = renderBlocks(e, 2)
        e.setHold(false)
        e.load(stems: makeStems(seconds: 6), pitchLocked: [false, false, false])
        e.play()
        XCTAssertGreaterThan(renderBlocks(e, 3).map(abs).max() ?? 0, 0.1)
    }
}

extension EngineTests {
    /// The fade-out at the start of a hold reads ahead; a loop wrap inside it is not a pass the player heard
    /// (it would advance the counter and the speed trainer early).
    func testAHoldAtTheLoopEndCountsNoPass() {
        let e = PlaybackEngine(drivesOutput: false)
        e.load(stems: makeStems(seconds: 8), pitchLocked: [false, false, false])
        let a = Int64(2 * sr), b = Int64(4 * sr)
        e.setLoop(enabled: true, start: a, end: b)
        e.seek(frame: b - 1100)
        e.play()
        _ = renderBlocks(e, 1)                                    // 76 frames before the loop end
        XCTAssertEqual(e.status.loopPasses, 0)
        e.setHold(true)
        _ = renderBlocks(e, 2)
        XCTAssertEqual(e.status.loopPasses, 0, "the fade-out crossed the loop end, but nobody heard a pass")
    }
}
