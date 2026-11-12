import XCTest
@testable import BacklineKit

/// The check that a split's parts add back up to the song (a GPU path that got the model wrong did not).
final class SeparationCheckTests: XCTestCase {
    private func tone(_ f: Double, _ amp: Float, n: Int = 44_100, phase: Double = 0) -> StereoAudio {
        let x = (0..<n).map { amp * Float(sin(2 * .pi * f * Double($0) / 44_100 + phase)) }
        return StereoAudio(left: x, right: x, sampleRate: 44_100)
    }

    func testPartsThatAddUpPass() {
        let a = tone(220, 0.3), b = tone(330, 0.2)
        let song = StereoAudio(left: zip(a.left, b.left).map(+), right: zip(a.right, b.right).map(+), sampleRate: 44_100)
        let r = DemucsSeparator.reconstruction(of: [a, b], song: song)
        XCTAssertEqual(r.power, 1, accuracy: 1e-3)
        XCTAssertEqual(r.correlation, 1, accuracy: 1e-3)
        XCTAssertTrue(DemucsSeparator.reconstructs([a, b], song: song))
    }

    func testPartsThatDoNotAddUpFail() {
        let song = tone(220, 0.5)
        XCTAssertFalse(DemucsSeparator.reconstructs([tone(220, 0.15)], song: song), "a tenth of the power")
        XCTAssertFalse(DemucsSeparator.reconstructs([tone(523, 0.5)], song: song), "the wrong sound")
        XCTAssertFalse(DemucsSeparator.reconstructs([], song: song), "nothing at all")
    }

    /// ios-split-safety (2): the figures measured on ten real songs (CPU and GPU gave the same), every clean one
    /// passes the tightened check.
    static let measured: [(song: String, power: Float, correlation: Float)] = [
        ("Big Rock", 0.98575, 0.98864), ("Summon the Rawk", 0.97762, 0.99715), ("Breakdown", 0.99244, 0.99975),
        ("Neolith", 0.96039, 0.99616), ("Pump", 0.95158, 0.99030), ("Volatile Reaction", 0.95959, 0.99844),
        ("Feral Angel Waltz", 0.94732, 0.99607), ("Gearhead", 0.98922, 0.99524), ("Iron Bacon", 0.95043, 0.99662),
    ]

    func testEveryCleanRealSplitPasses() {
        for m in Self.measured {
            XCTAssertTrue(DemucsSeparator.passes((m.power, m.correlation)), m.song)
        }
    }

    /// What the Mac saw when a six-part prediction ran beside a split: 0.68 to 16 times the power. 1.0's bounds
    /// (0.5 to 2, correlation 0.8) let the mild end through.
    func testTheMacsSpoiledSplitsFail() {
        XCTAssertFalse(DemucsSeparator.passes((0.68, 0.9)))
        XCTAssertFalse(DemucsSeparator.passes((16, 0.3)))
        XCTAssertFalse(DemucsSeparator.passes((1.4, 0.97)))
    }

    /// A split mixed up on purpose: one part a sixth of a cycle out of place. The power still adds up (1.0), the
    /// correlation is 0.85: 1.0's check passed it, the tightened one doesn't.
    func testAMildlyMixedUpSplitFails() {
        let a = tone(220, 0.3), b = tone(330, 0.2)
        let song = StereoAudio(left: zip(a.left, b.left).map(+), right: zip(a.right, b.right).map(+), sampleRate: 44_100)
        let shifted = tone(330, 0.2, phase: .pi / 3)
        let r = DemucsSeparator.reconstruction(of: [a, shifted], song: song)
        XCTAssertEqual(r.power, 1, accuracy: 0.02)
        XCTAssertEqual(r.correlation, 0.85, accuracy: 0.02)
        XCTAssertTrue((0.5...2).contains(r.power) && r.correlation > 0.8, "1.0's check passed it")
        XCTAssertFalse(DemucsSeparator.reconstructs([a, shifted], song: song))
    }

    /// Take the Lead adds up at 3.55 and 0.714 on the CPU and the GPU alike: two splits that agree put the
    /// failure on the song, so the device keeps its GPU. A GPU that spoiled the split disagrees with the CPU.
    func testSplitsThatAgreeBlameTheSong() {
        XCTAssertTrue(DemucsSeparator.agree((3.54943, 0.71393), (3.54927, 0.71391)))
        XCTAssertFalse(DemucsSeparator.agree((0.68, 0.9), (0.98, 0.99)))
        XCTAssertFalse(DemucsSeparator.agree((.infinity, 0), (.infinity, 0)))
    }
}
