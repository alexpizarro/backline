import AVFoundation
import XCTest
@testable import BacklineKit

/// The audio track of a video container (a saved reel, a QuickTime .mov) decodes through AVAssetReader.
final class VideoAudioTests: XCTestCase {
    func testDecodesTheSoundOfAMovie() throws {
        let url = URL(fileURLWithPath: "/tmp/clips/vid.mov")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "needs /tmp/clips/vid.mov (20 s of video with sound)")
        let t0 = Date()
        let audio = try AudioDecoder.decodeAssetAudio(url, sampleRate: 44_100, progress: nil)
        XCTAssertEqual(audio.duration, 20, accuracy: 0.2)
        XCTAssertGreaterThan(audio.left.map(abs).max() ?? 0, 0.05, "has sound")
        print("decoded in", Date().timeIntervalSince(t0))
    }
}
