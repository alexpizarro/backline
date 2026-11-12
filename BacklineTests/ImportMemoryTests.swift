import BacklineKit
import Darwin
import XCTest
@testable import Backline

/// The highest footprint seen by a sampling thread.
final class FootprintBox: @unchecked Sendable {
    let lock = NSLock()
    var highest: UInt64 = 0
    var running = true
}

/// D20 (a): what `ImportPipeline.process` holds beside the parts and the original it is given, measured as the
/// app's footprint while it runs (sampled every millisecond on a thread of its own).
final class ImportMemoryTests: XCTestCase {
    /// The highest footprint while `body` runs, and the footprint before it.
    static func measure<T>(_ body: () async throws -> T) async rethrows -> (before: UInt64, peak: UInt64, value: T) {
        let box = FootprintBox()
        let before = MemoryFootprint.bytes
        box.highest = before
        Thread.detachNewThread {
            while box.lock.withLock({ box.running }) {
                let f = MemoryFootprint.bytes
                box.lock.withLock { box.highest = max(box.highest, f) }
                usleep(1000)
            }
        }
        defer { box.lock.withLock { box.running = false } }
        let value = try await body()
        let end = MemoryFootprint.bytes
        return (before, box.lock.withLock { max(box.highest, end) }, value)
    }

    /// Six parts of `seconds`, made by repeating 10 s: a wide guitar with a centred lead in it, the rest plain.
    static func parts(seconds: Double) -> (byName: [String: StereoAudio], original: StereoAudio) {
        let sr = 44_100.0, unit = Int(10 * sr), n = Int(seconds * sr)
        var seed: UInt64 = 0x5EED
        func noise() -> Float {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Double(seed >> 11) / Double(1 << 53) - 0.5)
        }
        func looped(_ make: (Int) -> (Float, Float)) -> StereoAudio {
            var l = [Float](repeating: 0, count: n), r = l
            for i in 0..<min(unit, n) { (l[i], r[i]) = make(i) }
            var at = unit
            while at < n {
                let m = min(unit, n - at)
                l.withUnsafeMutableBufferPointer { ($0.baseAddress! + at).update(from: $0.baseAddress!, count: m) }
                r.withUnsafeMutableBufferPointer { ($0.baseAddress! + at).update(from: $0.baseAddress!, count: m) }
                at += m
            }
            return StereoAudio(left: l, right: r, sampleRate: sr)
        }
        func sine(_ hz: Double, _ i: Int) -> Float { Float(sin(2 * .pi * hz * Double(i) / sr)) }
        var lpL: Float = 0, lpR: Float = 0
        let guitar = looped { i in
            lpL += 0.08 * (noise() - lpL); lpR += 0.08 * (noise() - lpR)
            let lead: Float = (i / Int(sr * 2.5)) % 2 == 1 ? 0.3 * sine(440 * pow(2, Double(i / 7_000 % 7) / 12), i) : 0
            return (3 * lpL + lead, 3 * lpR + lead)
        }
        let parts: [String: StereoAudio] = [
            "vocals": looped { i in let v = 0.25 * sine(300, i); return (v, v) },
            "drums": looped { _ in let v = (noise() > 0.45 ? 0.6 : 0.02) * noise(); return (v, v) },
            "bass": looped { i in let v = 0.3 * sine(55, i); return (v, v) },
            "guitar": guitar,
            "piano": looped { i in let v = 0.2 * sine(523, i); return (v, v * 0.9) },
            "other": looped { _ in (0.05 * noise(), 0.05 * noise()) },
        ]
        var original = parts["vocals"]!
        for (k, p) in parts where k != "vocals" { ImportPipeline.add(p, into: &original) }
        return (parts, original)
    }

    private func run(seconds: Double) async throws -> (added: Double, a: Double, processed: ImportPipeline.Processed) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ImportMemoryTests-\(UUID().uuidString)")
        let store = SongStore(root: dir)
        try FileManager.default.createDirectory(at: store.folder("m"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // The parts are handed over as `run` hands them (no other reference left), the original kept beside.
        final class Hold: @unchecked Sendable {
            var parts: [String: StereoAudio]?
            init(_ p: [String: StereoAudio]) { parts = p }
            func take() -> [String: StereoAudio] { defer { parts = nil }; return parts! }
        }
        let hold: Hold, original: StereoAudio
        do {
            let made = Self.parts(seconds: seconds)
            hold = Hold(made.byName)
            original = made.original
        }
        let a = Double(original.frameCount * 8)
        let m = try await Self.measure {
            try await ImportPipeline.process(hold.take(), id: "m", store: store, original: original, writeOriginal: true,
                                             useLeadModel: false, isCancelled: { false })
        }
        let added = (Double(m.peak) - Double(m.before)) / a
        print(String(format: "[import-memory] process %.0f s: before %.0f MB, peak %.0f MB, added %.2f a (a = %.0f MB), split %@",
                     seconds, Double(m.before) / 1e6, Double(m.peak) / 1e6, added, a / 1e6,
                     m.value.guitarSplit == nil ? "no" : "yes"))
        return (added, a, m.value)
    }

    /// Beside the six parts and the original it is given, `process` holds at most the guitar + Other sum, the
    /// lead, the rhythm and Other with the lead taken out (1.0: the whole mix, folded copies, the guitar sum and
    /// nine or more copies inside the stereo split, 12 or more in all).
    func testProcessHoldsAtMostFourSongCopiesMore() async throws {
        // On the Mac the first `process` in a run also loads what stays loaded (the sound classifier and its
        // working memory: about 115 MB whatever the length), and the footprint carries 40 to 70 MB of noise from
        // run to run; on a 90 s song (a = 32 MB) those read as 3.5 and 2 copies more (measured 5.7, 6.5, 4.96,
        // 3.74). A 10 s run first takes the first out, and a 4-minute song (a = 85 MB) keeps the second small:
        // the figure is then the song copies (2.6 to 2.8 measured at 3, 6 and 9 minutes).
        _ = try await run(seconds: 10)
        let r = try await run(seconds: 240)
        XCTAssertNotNil(r.processed.guitarSplit, "the fixture's guitar is split, so the split's memory is counted")
        XCTAssertLessThan(r.added, 4.5)
    }

    /// The gate's numbers for long songs: `TEST_RUNNER_BL_IMPORT_MEMORY=540,1200` (seconds) prints each.
    func testLongSongFootprint() async throws {
        guard let list = ProcessInfo.processInfo.environment["BL_IMPORT_MEMORY"] else {
            throw XCTSkip("set TEST_RUNNER_BL_IMPORT_MEMORY to a list of seconds")
        }
        for seconds in list.split(separator: ",").compactMap({ Double($0) }) { _ = try await run(seconds: seconds) }
    }
}
