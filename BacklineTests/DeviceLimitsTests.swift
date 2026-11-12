import XCTest
@testable import Backline

/// Songs longer than this Mac can split are refused, in plain words (iOS R04, Mac tiers from paritymac WP1).
final class DeviceLimitsTests: XCTestCase {
    func testTheLimitFollowsTheMacsMemory() {
        XCTAssertEqual(DeviceLimits.maxSongSeconds(memory: 8 << 30), 1200, "8 GB: 20 minutes, as links")
        XCTAssertEqual(DeviceLimits.maxSongSeconds(memory: 16 << 30), 1800, "16 GB: 30 minutes")
        XCTAssertEqual(DeviceLimits.maxSongSeconds(memory: 128 << 30), 1800, "more memory doesn't go past 30 minutes")
        XCTAssertEqual(DeviceLimits.maxSongSeconds(memory: 4 << 30), 720)
        XCTAssertGreaterThanOrEqual(DeviceLimits.maxSongSeconds, 1200, "every Apple silicon Mac takes 20 minutes")
    }

    func testTheMessageIsPlain() {
        XCTAssertEqual(DeviceLimits.tooLongMessage(seconds: 1200), "Longer than 20 minutes.")
        XCTAssertEqual(DeviceLimits.tooLongMessage(seconds: 1800), "Longer than 30 minutes.")
        XCTAssertEqual(DeviceLimits.TooLong().errorDescription, DeviceLimits.tooLongMessage())
    }
}
