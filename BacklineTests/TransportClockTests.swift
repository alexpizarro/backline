import BacklineKit
import XCTest
@testable import Backline

/// The drawn playhead must follow a finger at once and never wait for the audio thread to apply a seek.
final class TransportClockTests: XCTestCase {
    private final class FakeEngine: EngineStatusSource, @unchecked Sendable {
        var seconds = 0.0
        var playing = false
        var rate = 1.0
        let sampleRate = 44_100.0
        var status: PlaybackEngine.Status {
            PlaybackEngine.Status(position: Int64(seconds * sampleRate), playing: playing, rate: rate)
        }
    }

    func testAScrubShowsTheFingerWhateverTheEngineSays() {
        let engine = FakeEngine()
        engine.seconds = 2
        let clock = TransportClock(engine: engine)
        clock.beginScrub(5)
        XCTAssertEqual(clock.sample(hostTime: 1).time, 5, accuracy: 1e-9)
        clock.updateScrub(7)
        XCTAssertEqual(clock.sample(hostTime: 1.016).time, 7, accuracy: 1e-9)
        XCTAssertTrue(clock.isOverriding)
    }

    func testASettleHoldsTheTargetUntilTheEngineCatchesUp() {
        let engine = FakeEngine()
        let clock = TransportClock(engine: engine)
        clock.endScrub(7, now: 10)
        XCTAssertEqual(clock.sample(hostTime: 10.10).time, 7, accuracy: 1e-9, "the engine is still at 0")
        XCTAssertEqual(clock.sample(hostTime: 10.20).time, 7, accuracy: 1e-9)
        engine.seconds = 7.02
        XCTAssertEqual(clock.sample(hostTime: 10.25).time, 7.02, accuracy: 1e-9, "the engine has arrived: it leads again")
        XCTAssertFalse(clock.isOverriding)
    }

    func testASettleGivesUpAfter350ms() {
        let engine = FakeEngine()
        let clock = TransportClock(engine: engine)
        clock.jump(to: 7, now: 10)
        XCTAssertEqual(clock.sample(hostTime: 10.30).time, 7, accuracy: 1e-9)
        XCTAssertEqual(clock.sample(hostTime: 10.40).time, 0, accuracy: 1e-9, "the engine never got there: trust it")
        XCTAssertFalse(clock.isOverriding)
    }

    func testWhilePlayingTheTargetMovesOnAndInterpolationResumes() {
        let engine = FakeEngine()
        engine.playing = true
        let clock = TransportClock(engine: engine)
        clock.jump(to: 7, now: 10)
        XCTAssertEqual(clock.sample(hostTime: 10.10).time, 7.10, accuracy: 1e-9, "the target plays on")

        engine.seconds = 7.15
        let caught = clock.sample(hostTime: 10.15).time
        XCTAssertEqual(caught, 7.15, accuracy: 0.01)
        XCTAssertFalse(clock.isOverriding)

        // Back to normal: the estimate advances with the display clock between engine updates.
        let next = clock.sample(hostTime: 10.15 + 1.0 / 120).time
        XCTAssertGreaterThan(next, caught)
        XCTAssertEqual(next, caught + 1.0 / 120, accuracy: 0.002)
    }
}
