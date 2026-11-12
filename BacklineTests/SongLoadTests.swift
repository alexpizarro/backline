import BacklineKit
import XCTest
@testable import Backline

/// U01: opening a song reads every part's stretch around the resume point first and the rest later.
/// Reading a part in pieces must give exactly what one full read gives.
final class SongLoadTests: XCTestCase {
    func testReadingInPiecesMatchesAFullRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SongLoadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SongStore(root: dir)
        let n = 44_100 * 6
        let left = (0..<n).map { Float(sin(Double($0) * 0.013)) * 0.5 }
        let right = (0..<n).map { Float(cos(Double($0) * 0.007)) * 0.4 }
        let url = dir.appendingPathComponent("part.caf")
        try store.writeStem(StereoAudio(left: left, right: right, sampleRate: 44_100), to: url)

        var fullL = [Float](repeating: 0, count: n), fullR = [Float](repeating: 0, count: n)
        try fullL.withUnsafeMutableBufferPointer { l in
            try fullR.withUnsafeMutableBufferPointer { r in try store.readStem(url, left: l.baseAddress!, right: r.baseAddress!, capacity: n) }
        }
        var pieceL = [Float](repeating: 0, count: n), pieceR = [Float](repeating: 0, count: n)
        let window = 100_000..<180_000
        try pieceL.withUnsafeMutableBufferPointer { l in
            try pieceR.withUnsafeMutableBufferPointer { r in
                for range in [window, 0..<window.lowerBound, window.upperBound..<n] {
                    XCTAssertTrue(try store.readStem(url, left: l.baseAddress!, right: r.baseAddress!, frames: range))
                }
            }
        }
        XCTAssertEqual(pieceL, fullL, "left channel read in pieces")
        XCTAssertEqual(pieceR, fullR, "right channel read in pieces")
    }

    func testAStoppedReadStopsAtOnce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SongLoadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SongStore(root: dir)
        let n = 44_100 * 2
        let url = dir.appendingPathComponent("part.caf")
        try store.writeStem(StereoAudio(left: [Float](repeating: 0.25, count: n), right: [Float](repeating: 0.25, count: n), sampleRate: 44_100), to: url)
        var l = [Float](repeating: 0, count: n), r = [Float](repeating: 0, count: n)
        let fill = EngineFill()
        fill.cancel()
        let finished = try l.withUnsafeMutableBufferPointer { lp in
            try r.withUnsafeMutableBufferPointer { rp in
                try store.readStem(url, left: lp.baseAddress!, right: rp.baseAddress!, frames: 0..<n, stop: { fill.isCancelled })
            }
        }
        XCTAssertFalse(finished)
        XCTAssertEqual(l.max(), 0, "nothing was written after the stop")
    }
}
