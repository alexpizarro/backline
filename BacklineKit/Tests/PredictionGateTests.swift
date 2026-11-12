import Foundation
import XCTest
@testable import BacklineKit

/// ios-split-safety (1): one six-part prediction at a time in the process, whichever instance makes it, and no
/// other Core ML prediction beside it.
final class PredictionGateTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let package = root.appendingPathComponent("Backline/Resources/HTDemucs6s.mlpackage")

    /// Who is inside the gate, checked on every entry.
    final class Inside: @unchecked Sendable {
        private let lock = NSLock()
        private var exclusive = 0
        private var shared = 0
        private(set) var overlaps = 0
        private(set) var order: [String] = []
        func enter(exclusive e: Bool, _ name: String) {
            lock.withLock {
                if e { if exclusive > 0 || shared > 0 { overlaps += 1 }; exclusive += 1 } else { if exclusive > 0 { overlaps += 1 }; shared += 1 }
                order.append(name)
            }
        }
        func leave(exclusive e: Bool) { lock.withLock { if e { exclusive -= 1 } else { shared -= 1 } } }
        var maxShared = 0
        func noteShared() { lock.withLock { maxShared = max(maxShared, shared) } }
    }

    func testExclusiveHoldersNeverOverlapAnythingAndSharedOnesMayOverlapEachOther() {
        let gate = PredictionGate()
        let inside = Inside()
        DispatchQueue.concurrentPerform(iterations: 24) { i in
            let exclusive = i % 4 == 0
            let body = {
                inside.enter(exclusive: exclusive, "\(i)")
                if !exclusive { inside.noteShared() }
                Thread.sleep(forTimeInterval: 0.01)
                inside.leave(exclusive: exclusive)
            }
            if exclusive { try? gate.exclusively(body) } else { try? gate.shared(body) }
        }
        XCTAssertEqual(inside.overlaps, 0, "a six-part pass ran beside another prediction")
        XCTAssertEqual(inside.order.count, 24)
    }

    func testAWaitingSixPartPassGoesBeforeNewPredictions() {
        let gate = PredictionGate()
        let inside = Inside()
        let firstIn = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            try? gate.shared { inside.enter(exclusive: false, "first"); firstIn.signal(); Thread.sleep(forTimeInterval: 0.3); inside.leave(exclusive: false) }
        }
        firstIn.wait()
        DispatchQueue.global().async(group: group) {
            try? gate.exclusively { inside.enter(exclusive: true, "six-part"); Thread.sleep(forTimeInterval: 0.1); inside.leave(exclusive: true) }
        }
        Thread.sleep(forTimeInterval: 0.1)       // the six-part pass is waiting now
        DispatchQueue.global().async(group: group) {
            try? gate.shared { inside.enter(exclusive: false, "late"); inside.leave(exclusive: false) }
        }
        group.wait()
        XCTAssertEqual(inside.order, ["first", "six-part", "late"])
        XCTAssertEqual(inside.overlaps, 0)
    }

    func testWaitingStopsWhenCancelled() {
        let gate = PredictionGate()
        let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { try? gate.exclusively { held.signal(); release.wait() } }
        held.wait()
        let t = Date()
        XCTAssertThrowsError(try gate.shared(isCancelled: { Date().timeIntervalSince(t) > 0.3 }) { XCTFail("ran beside the six-part pass") }) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertThrowsError(try gate.exclusively(isCancelled: { Date().timeIntervalSince(t) > 0.6 }) { XCTFail("ran beside the six-part pass") })
        release.signal()
        // Free again: neither cancelled waiter left anything behind.
        XCTAssertNoThrow(try gate.exclusively { })
        XCTAssertNoThrow(try gate.shared { })
    }

    /// Two separators (two instances, as a warm-up beside an import was) asked to split at once: the passes run
    /// one after the other, and each gives exactly what it gives alone.
    func testTwoSeparatorsPredictingAtOnceAreSerialised() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.package.path), "model not present")
        let url = try await DemucsSeparator.locateModel(in: Bundle(for: Self.self), packageFallback: Self.package)
        let song = Self.music(seconds: 12)
        let a = try DemucsSeparator(modelURL: url), b = try DemucsSeparator(modelURL: url)
        let alone = try a.separate(song)

        final class Spans: @unchecked Sendable {
            let lock = NSLock()
            var spans: [Int: (Date, Date)] = [:]
            func note(_ i: Int) { lock.withLock { let now = Date(); spans[i] = (spans[i]?.0 ?? now, now) } }
        }
        let spans = Spans()
        let results = try await withThrowingTaskGroup(of: (Int, [StereoAudio]).self) { group in
            for (i, s) in [a, b].enumerated() {
                group.addTask { (i, try s.separate(song, progress: { _ in spans.note(i) })) }
            }
            var out: [Int: [StereoAudio]] = [:]
            for try await (i, r) in group { out[i] = r }
            return out
        }
        let s0 = try XCTUnwrap(spans.spans[0]), s1 = try XCTUnwrap(spans.spans[1])
        XCTAssertTrue(s0.1 <= s1.0 || s1.1 <= s0.0, "the two passes' chunks interleaved: \(s0) \(s1)")
        for i in 0..<2 {
            let r = try XCTUnwrap(results[i])
            for (x, y) in zip(r, alone) {
                XCTAssertEqual(x.left, y.left, "pass \(i) differs from the same split alone")
                XCTAssertEqual(x.right, y.right)
            }
            XCTAssertTrue(DemucsSeparator.reconstructs(r, song: song))
        }
    }

    /// Music-like stereo: a bass line, a chord and a noisy hi-hat, panned apart.
    static func music(seconds: Int) -> StereoAudio {
        let sr = 44_100.0, n = seconds * 44_100
        var l = [Float](repeating: 0, count: n), r = l
        var seed: UInt64 = 0x1234_5678_9ABC_DEF1
        for i in 0..<n {
            let t = Double(i) / sr
            let beat = t.truncatingRemainder(dividingBy: 0.5)
            let bass = Float(0.3 * sin(2 * .pi * (beat < 0.25 ? 55 : 82.4) * t) * exp(-beat * 4))
            let chord = Float(0.1 * (sin(2 * .pi * 261.6 * t) + sin(2 * .pi * 329.6 * t) + sin(2 * .pi * 392 * t)))
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Float(Double(seed >> 11) / Double(1 << 53) - 0.5) * Float(0.2 * exp(-t.truncatingRemainder(dividingBy: 0.25) * 30))
            l[i] = bass + chord * 0.8 + noise * 0.3
            r[i] = bass + chord * 0.3 + noise * 0.9
        }
        return StereoAudio(left: l, right: r, sampleRate: sr)
    }
}
