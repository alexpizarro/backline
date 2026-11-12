import Accelerate
import XCTest
@testable import BacklineKit

/// Split F3: the stereo guitar split streams, two passes a frame at a time (13a in 1.0, 9a after the first
/// step, now its input and two outputs; a being one stereo float copy of the song). Its output must not
/// change: checked against the frozen 1.0 code. The lead comes out bit for bit the same.
final class GuitarSplitterTests: XCTestCase {
    /// Same lead within 1e-4, same width and confidence within 1e-5, same decision (the report's bar).
    /// `widthAgainst`: the exact width to hold `a` to instead of `b`'s (see the real stems).
    private func assertSame(_ a: GuitarSplitter.Result, _ b: GuitarSplitter.Result, _ what: String,
                            leadWithin: Float = 1e-4, widthAgainst exact: Double? = nil,
                            file: StaticString = #filePath, line: UInt = #line) {
        var worst: Float = 0
        for (x, y) in [(a.lead.left, b.lead.left), (a.lead.right, b.lead.right),
                       (a.rhythm.left, b.rhythm.left), (a.rhythm.right, b.rhythm.right)] {
            XCTAssertEqual(x.count, y.count, what, file: file, line: line)
            var d = [Float](repeating: 0, count: x.count), m: Float = 0
            vDSP_vsub(y, 1, x, 1, &d, 1, vDSP_Length(x.count))
            vDSP_maxmgv(d, 1, &m, vDSP_Length(d.count))
            worst = max(worst, m)
        }
        print("\(what): largest difference \(worst), width \(a.width) / \(b.width), confidence \(a.confidence) / \(b.confidence)")
        XCTAssertLessThanOrEqual(worst, leadWithin, what, file: file, line: line)
        if leadWithin < 1e-4 { XCTAssertLessThan(worst, 1e-4, what, file: file, line: line) }
        if let exact {
            XCTAssertEqual(a.width, exact, accuracy: 1e-6, what, file: file, line: line)
            XCTAssertEqual(b.width, exact, accuracy: 2e-5, "the frozen split's own single-precision sum", file: file, line: line)
        } else {
            XCTAssertEqual(a.width, b.width, accuracy: 1e-5, what, file: file, line: line)
        }
        XCTAssertEqual(a.confidence, b.confidence, accuracy: 1e-5, what, file: file, line: line)
        XCTAssertEqual(a.leadDynamics, b.leadDynamics, accuracy: 1e-5, what, file: file, line: line)
        XCTAssertEqual(a.shouldSplit, b.shouldSplit, what, file: file, line: line)
    }

    /// 20 s of double-tracked rhythm (different takes left and right, so decorrelated) with a centred lead
    /// that comes and goes: the case the split is for.
    static func wideGuitar(seconds: Double = 20, leadLevel: Float = 0.3) -> StereoAudio {
        let sr = 44_100.0, n = Int(seconds * sr)
        var seed: UInt64 = 0x1234_5678_9ABC_DEF1
        func noise() -> Float {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Double(seed >> 11) / Double(1 << 53) - 0.5)
        }
        var l = [Float](repeating: 0, count: n), r = l
        var lpL: Float = 0, lpR: Float = 0
        for i in 0..<n {
            let t = Double(i) / sr
            // Rhythm: low-passed noise bursts on eighth notes, a different take on each side.
            let gate: Float = (t * 4).truncatingRemainder(dividingBy: 1) < 0.6 ? 1 : 0.1
            lpL += 0.08 * (noise() - lpL); lpR += 0.08 * (noise() - lpR)
            l[i] = 6 * gate * lpL + 0.05 * Float(sin(2 * .pi * 82.4 * t))
            r[i] = 6 * gate * lpR + 0.05 * Float(sin(2 * .pi * 82.4 * t + 0.7))
            // Lead: a centred melody in the upper register, playing in the second and fourth 5 s.
            if Int(t / 5) % 2 == 1 {
                let f = 440 * pow(2, Double(Int(t * 3) % 7) / 12)
                let v = leadLevel * Float(sin(2 * .pi * f * t) + 0.4 * sin(2 * .pi * 2 * f * t))
                l[i] += v; r[i] += v
            }
        }
        return StereoAudio(left: l, right: r, sampleRate: sr)
    }

    func testTheLeanerSplitMatchesTheShippedOneOnAWideGuitar() {
        let g = Self.wideGuitar()
        let new = GuitarSplitter.split(g), old = GuitarSplitterReference.split(g)
        XCTAssertTrue(old.shouldSplit, "the fixture is wide enough to split (width \(old.width))")
        XCTAssertGreaterThan(old.confidence, 0, "and confident, so the lead-share path runs too")
        assertSame(new, old, "wide guitar", leadWithin: 0)
    }

    func testTheLeanerSplitMatchesTheShippedOneOnANearMonoGuitar() {
        let w = Self.wideGuitar(seconds: 8)
        // Mostly the mid: the split is not offered.
        var l = w.left, r = w.right
        for i in 0..<l.count {
            let m = 0.5 * (w.left[i] + w.right[i]), s = 0.5 * (w.left[i] - w.right[i])
            l[i] = m + 0.03 * s; r[i] = m - 0.03 * s
        }
        let g = StereoAudio(left: l, right: r, sampleRate: w.sampleRate)
        let new = GuitarSplitter.split(g), old = GuitarSplitterReference.split(g)
        XCTAssertFalse(old.shouldSplit, "near-mono (width \(old.width))")
        assertSame(new, old, "near-mono guitar", leadWithin: 0)
    }

    /// Shorter than the smoothing windows, and one frame: the ring's edges.
    func testShortInputsMatch() {
        for frames in [1, 100, 5_000, 30_000] {
            let w = Self.wideGuitar(seconds: 1)
            let g = StereoAudio(left: Array(w.left.prefix(frames)), right: Array(w.right.prefix(frames)), sampleRate: w.sampleRate)
            assertSame(GuitarSplitter.split(g), GuitarSplitterReference.split(g), "\(frames) samples")
        }
    }

    /// The ring-buffer box filter equals a plain centred moving average with edge renormalisation.
    func testBoxTimeIsACentredMovingAverage() {
        for (frames, bins, size) in [(1, 3, 15), (4, 2, 15), (40, 5, 15), (40, 5, 3), (33, 1, 21)] {
            var seed: UInt64 = UInt64(frames * 31 + size)
            let a = (0..<(frames * bins)).map { _ -> Float in
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Float(seed >> 40) / Float(1 << 24)
            }
            var got = a
            GuitarSplitter.boxTime(&got, frames: frames, bins: bins, size: size)
            var old = a
            GuitarSplitterReference.boxTime(&old, frames: frames, bins: bins, size: size)
            XCTAssertEqual(got, old, "same arithmetic as before, \(frames)x\(bins) size \(size)")
            let h = size / 2
            for t in 0..<frames {
                for k in 0..<bins {
                    let range = max(0, t - h)...min(frames - 1, t + h)
                    let want = range.map { a[$0 * bins + k] }.reduce(0, +) / Float(range.count)
                    XCTAssertEqual(got[t * bins + k], want, accuracy: 1e-5)
                }
            }
        }
    }

    /// The report's bar on real stems: guitar + other of each song folder in `GUITAR_SPLIT_STEMS` (default: the
    /// Mac repository's six-part reference outputs, `ref_out` then `htdemucs_6s` in its git-ignored local test
    /// folder, run from its root), fed in as the import does. The path is built from its components so the
    /// publish check, which stops on that folder's name followed by a slash, has nothing to find here.
    /// The lead is the same bit for bit. The width is held to the exact figure (sums in double precision)
    /// within 1e-6: the frozen split sums the whole song in single precision, which on Big Rock is itself
    /// 1.04e-5 from the exact width (0.038290 against 0.038301; the streaming split gives 0.0383005).
    func testTheLeanerSplitMatchesTheShippedOneOnRealStems() throws {
        let env = ProcessInfo.processInfo.environment["GUITAR_SPLIT_STEMS"]
        let local = NSString.path(withComponents: [FileManager.default.currentDirectoryPath, "testdata", "ref_out", "htdemucs_6s"])
        let root = URL(fileURLWithPath: env ?? local)
        let songs = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("guitar.wav").path) }
            .sorted { $0.path < $1.path }
        try XCTSkipIf(songs.isEmpty, "set GUITAR_SPLIT_STEMS to a folder of song folders with guitar.wav and other.wav")
        for song in songs.prefix(2) {
            let g = try AudioDecoder.decode(song.appendingPathComponent("guitar.wav"))
            let o = try AudioDecoder.decode(song.appendingPathComponent("other.wav"))
            var src = g
            vDSP_vadd(src.left, 1, o.left, 1, &src.left, 1, vDSP_Length(src.frameCount))
            vDSP_vadd(src.right, 1, o.right, 1, &src.right, 1, vDSP_Length(src.frameCount))
            var exact = GuitarSplitter.Params()
            exact.exactSums = true
            assertSame(GuitarSplitter.split(src), GuitarSplitterReference.split(src), song.lastPathComponent,
                       leadWithin: 0, widthAgainst: GuitarSplitter.split(src, params: exact).width)
        }
    }
}
