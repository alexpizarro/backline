import Darwin
import Foundation
import XCTest
@testable import BacklineKit

/// The task's physical footprint (what iOS counts against an app), sampled on a thread of its own every
/// millisecond while `body` runs, so a short-lived peak inside one call is caught.
final class FootprintSampler: @unchecked Sendable {
    static var now: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    private let lock = NSLock()
    private var highest: UInt64 = 0
    private var running = true

    /// Footprint before `body` and the highest it reached while `body` ran, in bytes.
    static func measure<T>(_ body: () -> T) -> (before: UInt64, peak: UInt64, value: T) {
        let s = FootprintSampler()
        let before = now
        s.highest = before
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            while s.lock.withLock({ s.running }) {
                let f = now
                s.lock.withLock { s.highest = max(s.highest, f) }
                usleep(1000)
            }
            done.signal()
        }
        let value = body()
        let end = now
        s.lock.withLock { s.running = false; s.highest = max(s.highest, end) }
        done.wait()
        return (before, s.lock.withLock { s.highest }, value)
    }
}

/// Split F3 in full: the stereo guitar split streams, so beside its input and its outputs it holds only a few
/// frames of spectra (the report's bar: under 4 song copies in all, input included).
final class GuitarSplitterMemoryTests: XCTestCase {
    /// A wide guitar of `seconds`, built by repeating the 20 s fixture (cheap to make for long songs).
    static func looped(seconds: Double) -> StereoAudio {
        let unit = GuitarSplitterTests.wideGuitar(seconds: 20)
        let n = Int(seconds * unit.sampleRate)
        var l = [Float](repeating: 0, count: n), r = l
        var at = 0
        while at < n {
            let m = min(unit.frameCount, n - at)
            l.withUnsafeMutableBufferPointer { ($0.baseAddress! + at).update(from: unit.left, count: m) }
            r.withUnsafeMutableBufferPointer { ($0.baseAddress! + at).update(from: unit.right, count: m) }
            at += m
        }
        return StereoAudio(left: l, right: r, sampleRate: unit.sampleRate)
    }

    /// One stereo float copy of `audio`, in bytes ("a" in the split report).
    static func copyBytes(_ audio: StereoAudio) -> Double { Double(audio.frameCount * 2 * MemoryLayout<Float>.size) }

    func testTheSplitHoldsUnderFourSongCopies() {
        // Long enough that a few frames of spectra and the FFT buffers are small beside one copy.
        let g = Self.looped(seconds: 120)
        let a = Self.copyBytes(g)
        let m = FootprintSampler.measure { GuitarSplitter.split(g) }
        // The input is already held; what the split adds is its two outputs plus working memory.
        let added = Double(m.peak) - Double(m.before)
        print(String(format: "split of 120 s: footprint %.0f MB before, peak %.0f MB, %.2f song copies added (a = %.0f MB)",
                     Double(m.before) / 1e6, Double(m.peak) / 1e6, added / a, a / 1e6))
        XCTAssertTrue(m.value.shouldSplit)
        XCTAssertLessThan(added / a + 1, 4, "input, lead, rhythm and a few frames: under 4a")
    }

    /// Without the rhythm: the same lead and figures, no rhythm, and one song copy less at the peak.
    func testWithoutTheRhythmTheLeadIsTheSame() {
        let g = Self.looped(seconds: 60)
        let a = Self.copyBytes(g)
        let both = GuitarSplitter.split(g)
        let m = FootprintSampler.measure { GuitarSplitter.split(g, withRhythm: false) }
        let leadOnly = m.value
        XCTAssertEqual(leadOnly.lead.left, both.lead.left)
        XCTAssertEqual(leadOnly.lead.right, both.lead.right)
        XCTAssertEqual(leadOnly.rhythm.frameCount, 0)
        XCTAssertEqual(leadOnly.width, both.width)
        XCTAssertEqual(leadOnly.confidence, both.confidence)
        XCTAssertEqual(leadOnly.shouldSplit, both.shouldSplit)
        // Lead + rhythm is the guitar, sample for sample (rhythm = guitar − lead).
        for i in stride(from: 0, to: g.frameCount, by: 997) {
            XCTAssertEqual(both.lead.left[i] + both.rhythm.left[i], g.left[i], accuracy: 1e-6)
        }
        let added = (Double(m.peak) - Double(m.before)) / a
        XCTAssertLessThan(added, 1.5, "the lead and a few frames (\(added) a)")
    }

    /// The gate's numbers for long songs (run on its own: `BL_SPLIT_MEMORY=540,1200 swift test --filter …`).
    /// Prints, for each length, the footprint the split adds, in MB and in song copies, for the shipped split
    /// (`GuitarSplitter`) and for 1.0's (`GuitarSplitterReference`, with `BL_SPLIT_REFERENCE=1`).
    func testLongSongFootprint() throws {
        let env = ProcessInfo.processInfo.environment
        guard let list = env["BL_SPLIT_MEMORY"] else { throw XCTSkip("set BL_SPLIT_MEMORY to a list of seconds") }
        let reference = env["BL_SPLIT_REFERENCE"] != nil
        for seconds in list.split(separator: ",").compactMap({ Double($0) }) {
            let g = Self.looped(seconds: seconds)
            let a = Self.copyBytes(g)
            let t0 = Date()
            let m = FootprintSampler.measure { reference ? GuitarSplitterReference.split(g) : GuitarSplitter.split(g) }
            let added = Double(m.peak) - Double(m.before)
            print(String(format: "[split-memory] %@ %.0f s: %.1f s, before %.0f MB, peak %.0f MB, added %.0f MB = %.2f a (a = %.0f MB), shouldSplit %@",
                         reference ? "1.0" : "streaming", seconds, Date().timeIntervalSince(t0), Double(m.before) / 1e6,
                         Double(m.peak) / 1e6, added / 1e6, added / a, a / 1e6, m.value.shouldSplit ? "yes" : "no"))
        }
    }
}
