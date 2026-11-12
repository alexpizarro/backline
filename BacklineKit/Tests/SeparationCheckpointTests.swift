import CoreML
import XCTest
@testable import BacklineKit

/// The cleaner pass takes minutes on a phone and used to start again from zero after any interruption.
final class SeparationCheckpointTests: XCTestCase {
    private func tempCheckpoint(_ key: String) -> SeparationCheckpoint {
        SeparationCheckpoint(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("checkpoint-\(UUID().uuidString)", isDirectory: true), key: key)
    }

    func testAFinalPrefixSurvivesAndAnotherKeyStartsOver() throws {
        let cp = tempCheckpoint("song-a")
        defer { cp.discard() }
        let total = 1000, step = 100
        var acc = [[Float]](repeating: (0..<total).map { Float($0) }, count: 2)
        let weight = [Float](repeating: 2, count: total)

        do {
            let w = try CheckpointWriter(cp, total: total, step: step, channels: 2)
            XCTAssertEqual(w.resumeFrom, 0)
            try w.append(upTo: 300, accumulated: acc, weight: weight)
        }
        let again = try CheckpointWriter(cp, total: total, step: step, channels: 2)
        XCTAssertEqual(again.resumeFrom, 300)
        acc = [[Float]](repeating: [Float](repeating: -1, count: total), count: 2)
        try again.loadPrefix(into: &acc)
        XCTAssertEqual(acc[1][299], 149.5, "final values are accumulated / weight")
        XCTAssertEqual(acc[1][300], -1, "nothing past the prefix is touched")

        let other = try CheckpointWriter(SeparationCheckpoint(directory: cp.directory, key: "song-b"), total: total, step: step, channels: 2)
        XCTAssertEqual(other.resumeFrom, 0, "a different input or model starts over")
    }

    /// A run killed between two channel writes leaves uneven files: only what every channel has, cut back to a
    /// chunk boundary, is trusted.
    func testUnevenFilesAreCutBackToAChunkBoundary() throws {
        let cp = tempCheckpoint("song-a")
        defer { cp.discard() }
        let acc = [[Float]](repeating: [Float](repeating: 1, count: 1000), count: 2)
        let weight = [Float](repeating: 1, count: 1000)
        do {
            let w = try CheckpointWriter(cp, total: 1000, step: 100, channels: 2)
            try w.append(upTo: 400, accumulated: acc, weight: weight)
        }
        let ch1 = cp.directory.appendingPathComponent("ch1.f32")
        let h = try FileHandle(forUpdating: ch1)
        try h.truncate(atOffset: UInt64(250 * MemoryLayout<Float>.size))
        try h.close()
        XCTAssertEqual(try CheckpointWriter(cp, total: 1000, step: 100, channels: 2).resumeFrom, 200)
    }

    /// The real thing: a run stopped after two chunks and resumed gives the same stems as one that never
    /// stopped. Needs the BS-RoFormer package (not in this repository), so it skips without it.
    func testAResumedRoformerPassMatchesAnUninterruptedOne() async throws {
        let env = ProcessInfo.processInfo.environment["ROFORMER_PACKAGE"]
        let pkg = URL(fileURLWithPath: env ?? FileManager.default.currentDirectoryPath + "/ml/BSRoformerSW_fp16.mlpackage")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: pkg.path), "set ROFORMER_PACKAGE to a BSRoformerSW .mlpackage")
        let modelURL = try await RoformerSeparator.locateModel(in: Bundle(for: Self.self), packageFallback: pkg)
        let sep = try RoformerSeparator(modelURL: modelURL, computeUnits: .cpuOnly)

        // 20 s of noise shaped like music is enough: the point is that the arithmetic lines up exactly.
        let n = 882_000
        var rng = SystemRandomNumberGenerator()
        let l = (0..<n).map { i in Float(0.3 * sin(Double(i) * 0.031)) + Float.random(in: -0.05...0.05, using: &rng) }
        let r = (0..<n).map { i in Float(0.3 * sin(Double(i) * 0.017)) + Float.random(in: -0.05...0.05, using: &rng) }
        let audio = StereoAudio(left: l, right: r, sampleRate: 44_100)

        let reference = try sep.separate(audio)

        let cp = tempCheckpoint("noise")
        defer { cp.discard() }
        final class Count: @unchecked Sendable { var chunks: [Int] = []; let lock = NSLock() }
        let first = Count()
        XCTAssertThrowsError(try sep.separate(audio, checkpoint: cp, progress: { p in
            first.lock.lock(); first.chunks.append(p.chunk); first.lock.unlock()
        }, isCancelled: { first.lock.lock(); defer { first.lock.unlock() }; return first.chunks.count >= 2 })) {
            XCTAssertTrue($0 is CancellationError)
        }

        let second = Count()
        let resumed = try sep.separate(audio, checkpoint: cp, progress: { p in
            second.lock.lock(); second.chunks.append(p.chunk); second.lock.unlock()
        })
        XCTAssertEqual(second.chunks.first, 2, "the resumed run redoes only the chunk at the edge of what was kept")

        var worst: Float = 0
        for (a, b) in zip(reference, resumed) {
            for (x, y) in zip(a.left + a.right, b.left + b.right) { worst = max(worst, abs(x - y)) }
        }
        XCTAssertLessThan(worst, 1e-6, "a resumed pass must sound exactly like an uninterrupted one")
    }
}
