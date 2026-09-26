import XCTest
@testable import BacklineKit

/// Real-time headroom: render 20 s of 6 stems with time-stretch + pitch-shift active.
final class EngineBenchTests: XCTestCase {
    func testStretchedRenderIsFarFasterThanRealtime() {
        let sr = 44_100.0
        let n = Int(30 * sr)
        var seed: UInt32 = 1
        func noise() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 8) / Float(1 << 24) - 0.5 }
        let stems = (0..<6).map { _ -> StereoAudio in
            let x = (0..<n).map { _ in noise() * 0.1 }
            return StereoAudio(left: x, right: x, sampleRate: sr)
        }
        let e = PlaybackEngine(drivesOutput: false)
        e.load(stems: stems, pitchLocked: [true, false, false, false, false, false])
        e.setRate(0.7)
        e.setSemitones(-2)
        e.play()
        let block = 512
        let blocks = Int(20 * sr) / block
        let t0 = Date()
        for _ in 0..<blocks { _ = e.renderForTesting(frames: block) }
        let dt = Date().timeIntervalSince(t0)
        let rt = 20 / dt
        print(String(format: "6 stems stretched: %.1fx realtime (%.2f%% of one core)", rt, 100 / rt))
        XCTAssertGreaterThan(rt, 8)
    }
}
