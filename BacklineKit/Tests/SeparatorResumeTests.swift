import Accelerate
import CoreML
import XCTest
@testable import BacklineKit

/// A pass stopped part-way (the app closed, a memory stop, an import) carries on from its checkpoint, and what it
/// gives is the same, sample for sample, as a pass that was never stopped. One test per separator: the kit split
/// (`DrumSeparator`), the lead refinement (`LeadSeparator`) and the import's six-part split (`DemucsSeparator`).
/// The kit model is never in the repository, so its test uses the stand-in model the drum tests already use; the
/// lead and six-part tests run the real models from `Backline/Resources` on the CPU, and the lead test also runs
/// a stand-in so it says something where the package is missing.
final class SeparatorResumeTests: XCTestCase {
    static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Backline/Resources")

    private func tempCheckpoint(_ key: String) -> SeparationCheckpoint {
        SeparationCheckpoint(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("resume-\(UUID().uuidString)", isDirectory: true), key: key)
    }

    /// Stops a run once `after` chunks have been reported, as the app's own checks do (`isCancelled` says yes).
    final class StopAfter: @unchecked Sendable {
        private let lock = NSLock()
        private var reported = 0
        let after: Int
        init(_ after: Int) { self.after = after }
        func report() { lock.withLock { reported += 1 } }
        var stop: Bool { lock.withLock { reported >= after } }
        var count: Int { lock.withLock { reported } }
    }

    /// Something like music, the same every run: two tones, noise, and a quiet stretch in the middle.
    private func song(seconds: Double, quietSpan: Range<Double>? = nil) -> StereoAudio {
        let sr = 44_100.0, n = Int(seconds * sr)
        var seed: UInt64 = 0x5EED_0000_1234_ABCD
        func noise() -> Float {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Double(seed >> 11) / Double(1 << 53) - 0.5)
        }
        var l = [Float](repeating: 0, count: n), r = l
        for i in 0..<n {
            let t = Double(i) / sr
            if let q = quietSpan, q.contains(t) { l[i] = 1e-5 * noise(); r[i] = 1e-5 * noise(); continue }
            let k = i % Int(sr / 4), env = Float(exp(-Double(k) / sr * 30))
            l[i] = Float(0.3 * sin(t * 2 * .pi * 110)) + 0.4 * env * noise()
            r[i] = Float(0.3 * sin(t * 2 * .pi * 165)) + 0.4 * env * noise()
        }
        return StereoAudio(left: l, right: r, sampleRate: sr)
    }

    private func assertSame(_ a: [StereoAudio], _ b: [StereoAudio], _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, what, file: file, line: line)
        var differing = 0, worst: Float = 0
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x.frameCount, y.frameCount, what, file: file, line: line)
            for (p, q) in zip(x.left + x.right, y.left + y.right) where p != q {
                differing += 1
                worst = max(worst, abs(p - q))
            }
        }
        XCTAssertEqual(differing, 0, "\(what): \(differing) samples differ (worst \(worst))", file: file, line: line)
    }

    // MARK: The kit split

    /// The drum tests' stand-in: each part is a fixed share of the input spectrum. Counts its calls.
    private func standInKit(_ calls: Counter) throws -> (MLMultiArray, () -> Bool) throws -> MLMultiArray {
        let weights: [Float] = [0.30, 0.20, 0.10, 0.15, 0.05]
        let F = DrumSeparator.dimF, T = DrumSeparator.frames, plane = F * T
        let out = try MLMultiArray(shape: [1, 5, 4, NSNumber(value: F), NSNumber(value: T)], dataType: .float32)
        return { spec, _ in
            calls.add()
            let src = spec.dataPointer.assumingMemoryBound(to: Float.self)
            let dst = out.dataPointer.assumingMemoryBound(to: Float.self)
            for p in 0..<5 {
                var w = weights[p]
                vDSP_vsmul(src, 1, &w, dst + p * 4 * plane, 1, vDSP_Length(4 * plane))
            }
            return out
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    private func kitParts(_ r: [String: StereoAudio]) -> [StereoAudio] {
        (DrumSeparator.parts + [DrumSeparator.restKey]).compactMap { r[$0] }
    }

    func testAResumedKitSplitMatchesAnUninterruptedOne() throws {
        // A drumless stretch in the middle: the chunks the kit split skips must resume the same way too.
        let drums = song(seconds: 50, quietSpan: 20..<32)
        for overlap in [2, 4] {
            let all = Counter()
            let reference = try DrumSeparator(overlap: overlap, predict: standInKit(all)).separate(drums)

            let cp = tempCheckpoint("kit")
            defer { cp.discard() }
            let firstCalls = Counter()
            let stop = StopAfter(6)
            XCTAssertThrowsError(try DrumSeparator(overlap: overlap, predict: standInKit(firstCalls))
                .separate(drums, checkpoint: cp, progress: { _ in stop.report() }, isCancelled: { stop.stop })) {
                XCTAssertTrue($0 is CancellationError)
            }
            let resumedCalls = Counter()
            var reports: [Double] = []
            let resumed = try DrumSeparator(overlap: overlap, predict: standInKit(resumedCalls))
                .separate(drums, checkpoint: cp, progress: { reports.append($0) })
            assertSame(kitParts(reference), kitParts(resumed), "kit split, overlap \(overlap)")
            XCTAssertLessThan(resumedCalls.value, all.value, "the resumed run doesn't start from the beginning")
            XCTAssertLessThan(firstCalls.value + resumedCalls.value, 2 * all.value)
            XCTAssertGreaterThan(reports.first ?? 0, 0.1, "overlap \(overlap): it starts past the kept chunks")

            // And a third run over a finished checkpoint does no model work at all, and still gives the same.
            let none = Counter()
            let again = try DrumSeparator(overlap: overlap, predict: standInKit(none)).separate(drums, checkpoint: cp)
            XCTAssertEqual(none.value, 0, "everything was kept")
            assertSame(kitParts(reference), kitParts(again), "kit split from a whole checkpoint, overlap \(overlap)")
        }
    }

    /// A checkpoint made for other drums (another key) is not used: the run starts from zero.
    func testAKitCheckpointUnderAnotherKeyIsNotUsed() throws {
        let drums = song(seconds: 30)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let stop = StopAfter(2)
        XCTAssertThrowsError(try DrumSeparator(overlap: 2, predict: standInKit(Counter()))
            .separate(drums, checkpoint: SeparationCheckpoint(directory: dir, key: "old drums"),
                      progress: { _ in stop.report() }, isCancelled: { stop.stop }))
        let all = Counter(), other = Counter()
        let reference = try DrumSeparator(overlap: 2, predict: standInKit(all)).separate(drums)
        let fresh = try DrumSeparator(overlap: 2, predict: standInKit(other))
            .separate(drums, checkpoint: SeparationCheckpoint(directory: dir, key: "new drums"))
        XCTAssertEqual(other.value, all.value, "every chunk computed again")
        assertSame(kitParts(reference), kitParts(fresh), "kit split under a new key")
    }

    // MARK: The lead refinement

    /// A stand-in for the lead model: the lead's spectrum is a share of the input's, its time branch a share of the
    /// input. Counts its calls.
    private func standInLead(_ calls: Counter) throws -> (MLMultiArray, MLMultiArray) throws -> (freq: MLMultiArray, time: MLMultiArray) {
        let stft = DemucsSTFT()
        let L = LeadSeparator.segment, F = stft.bins, T = stft.frames(for: L)
        let freq = try MLMultiArray(shape: [1, 2, 4, NSNumber(value: F), NSNumber(value: T)], dataType: .float32)
        let time = try MLMultiArray(shape: [1, 2, 2, NSNumber(value: L)], dataType: .float32)
        return { mix, spec in
            calls.add()
            var a: Float = 0.3, b: Float = 0.1
            vDSP_vsmul(spec.dataPointer.assumingMemoryBound(to: Float.self), 1, &a,
                       freq.dataPointer.assumingMemoryBound(to: Float.self), 1, vDSP_Length(4 * F * T))
            vDSP_vsmul(mix.dataPointer.assumingMemoryBound(to: Float.self), 1, &b,
                       time.dataPointer.assumingMemoryBound(to: Float.self), 1, vDSP_Length(2 * L))
            return (freq, time)
        }
    }

    func testAResumedLeadRefinementMatchesAnUninterruptedOne() throws {
        let guitar = song(seconds: 31)
        let sep = LeadSeparator()
        let all = Counter()
        let reference = try sep.lead(of: guitar, checkpoint: nil, progress: { _ in }, isCancelled: { false },
                                     predict: standInLead(all))
        let cp = tempCheckpoint("lead")
        defer { cp.discard() }
        let stop = StopAfter(5)
        XCTAssertThrowsError(try sep.lead(of: guitar, checkpoint: cp, progress: { _ in stop.report() },
                                          isCancelled: { stop.stop }, predict: standInLead(Counter()))) {
            XCTAssertTrue($0 is CancellationError)
        }
        let resumedCalls = Counter()
        let resumed = try sep.lead(of: guitar, checkpoint: cp, progress: { _ in }, isCancelled: { false },
                                   predict: standInLead(resumedCalls))
        assertSame([reference], [resumed], "lead refinement (stand-in)")
        XCTAssertEqual(resumedCalls.value, all.value - 4, "five segments ran; the last reaches past what was kept and is redone")
    }

    func testAResumedLeadRefinementWithTheRealModelMatchesAnUninterruptedOne() async throws {
        let pkg = Self.resources.appendingPathComponent("LeadRhythmHTDemucs.mlpackage")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: pkg.path), "no lead model package")
        let compiled = try await MLModel.compileModel(at: pkg)
        defer { try? FileManager.default.removeItem(at: compiled) }
        let sep = try LeadSeparator(modelURL: compiled, computeUnits: .cpuOnly)
        let guitar = song(seconds: 16)
        let reference = try sep.lead(of: guitar)
        let cp = tempCheckpoint("lead-real")
        defer { cp.discard() }
        let stop = StopAfter(3)
        XCTAssertThrowsError(try sep.lead(of: guitar, checkpoint: cp, progress: { _ in stop.report() }, isCancelled: { stop.stop }))
        let resumed = try sep.lead(of: guitar, checkpoint: cp)
        assertSame([reference], [resumed], "lead refinement (real model)")
    }

    // MARK: The import's six-part split

    func testAResumedSixPartSplitMatchesAnUninterruptedOne() async throws {
        let pkg = Self.resources.appendingPathComponent("HTDemucs6s.mlpackage")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: pkg.path), "no six-part model package")
        let url = try await DemucsSeparator.locateModel(in: Bundle(for: Self.self), packageFallback: pkg)
        let sep = try DemucsSeparator(modelURL: url, computeUnits: .cpuOnly)
        let audio = song(seconds: 27)

        let reference = try sep.separate(audio)
        let cp = tempCheckpoint("six")
        defer { cp.discard() }
        let stop = StopAfter(2)
        XCTAssertThrowsError(try sep.separate(audio, checkpoint: cp, progress: { _ in stop.report() },
                                              isCancelled: { stop.stop })) {
            XCTAssertTrue($0 is CancellationError)
        }
        final class Chunks: @unchecked Sendable { let lock = NSLock(); var seen: [Int] = [] }
        let chunks = Chunks()
        let resumed = try sep.separate(audio, checkpoint: cp, progress: { p in chunks.lock.withLock { chunks.seen.append(p.chunk) } })
        XCTAssertGreaterThanOrEqual(stop.count, 2)
        XCTAssertEqual(chunks.lock.withLock { chunks.seen.first }, stop.count,
                       "the resumed run starts with the chunk at the edge of what was kept")
        assertSame(reference, resumed, "six-part split")
    }

    // MARK: The checks before a checkpoint is trusted

    /// A channel file longer than the pass makes isn't this pass's: the checkpoint starts again from zero.
    func testAFileLongerThanThePassMakesStartsOver() throws {
        let cp = tempCheckpoint("song")
        defer { cp.discard() }
        let acc = [[Float]](repeating: [Float](repeating: 1, count: 1000), count: 2)
        let weight = [Float](repeating: 1, count: 1000)
        do {
            let w = try CheckpointWriter(cp, total: 1000, step: 100, channels: 2)
            try w.append(upTo: 300, accumulated: acc, weight: weight)
        }
        let ch0 = cp.directory.appendingPathComponent("ch0.f32")
        let h = try FileHandle(forUpdating: ch0)
        try h.seekToEnd()
        try h.write(contentsOf: Data(count: 4 * 1000))
        try h.close()
        XCTAssertEqual(try CheckpointWriter(cp, total: 1000, step: 100, channels: 2).resumeFrom, 0)
    }

    /// Another length (or step, or channel count) under the same key starts over.
    func testAnotherLengthUnderTheSameKeyStartsOver() throws {
        let cp = tempCheckpoint("song")
        defer { cp.discard() }
        do {
            let w = try CheckpointWriter(cp, total: 1000, step: 100, channels: 2)
            try w.append(upTo: 300, accumulated: [[Float]](repeating: [Float](repeating: 1, count: 1000), count: 2),
                         weight: [Float](repeating: 1, count: 1000))
        }
        XCTAssertEqual(try CheckpointWriter(cp, total: 1001, step: 100, channels: 2).resumeFrom, 0)
    }

    func testTheFirstChunkToRedoIsTheFirstThatReachesPastTheKeptPrefix() {
        let offsets = Array(stride(from: 0, to: 1000, by: 100))
        // Chunks four steps long (overlap 4): the chunk at 0 ends at 400.
        XCTAssertEqual(CheckpointWriter.firstChunk(offsets, resumeFrom: 0) { _ in 400 }, 0)
        XCTAssertEqual(CheckpointWriter.firstChunk(offsets, resumeFrom: 500) { _ in 400 }, 2, "300 + 400 reaches past 500")
        XCTAssertEqual(CheckpointWriter.firstChunk(offsets, resumeFrom: 1000) { min(400, 1000 - $0) }, offsets.count)
    }
}
