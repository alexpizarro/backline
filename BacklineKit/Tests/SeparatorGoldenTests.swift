import CoreML
import CryptoKit
import Foundation
import XCTest
@testable import BacklineKit

/// ios-polish: the six-part split's own arithmetic around the model (the song's normalisation, the chunks fed
/// to the model, the overlap-add and the finishing of each part) is changed to hold less memory. Its output must
/// stay bit for bit what it was: the digests recorded on the code before that change (`41dff0d`) still matched
/// after it (`3611a76`). They were recorded again once, on purpose, when the song's offset from zero came to be
/// shared out among the parts instead of added to each. On the CPU, where Core ML gives the same numbers every run.
final class SeparatorGoldenTests: XCTestCase {
    /// SHA-256 of the six parts' samples (left then right, in `sources` order) for `song(frames:)`.
    static let golden: [Int: String] = [
        // Three chunks, the last one padded with silence on both sides.
        12 * 44_100 + 12_345: "813dc063baf3bf16b82e41813cd556c8840ae7643ea820f8d1ab1bcc2a504bc7",
        // Shorter than one chunk: the only chunk is padded.
        200_001: "83a6f467be0c1a39e6d24b13cfa7fc35999a5de2301f81368660962c29d99e59",
    ]

    func testTheSixPartSplitIsBitForBitWhatItWas() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: PredictionGateTests.package.path), "model not present")
        let url = try await DemucsSeparator.locateModel(in: Bundle(for: Self.self), packageFallback: PredictionGateTests.package)
        let sep = try DemucsSeparator(modelURL: url, computeUnits: .cpuOnly)
        for (frames, expected) in Self.golden.sorted(by: { $0.key < $1.key }) {
            let parts = try sep.separate(Self.song(frames: frames))
            XCTAssertEqual(parts.count, 6)
            XCTAssertTrue(parts.allSatisfy { $0.frameCount == frames })
            let digest = Self.digest(parts)
            print("[golden] \(frames) frames: \(digest)")
            XCTAssertEqual(digest, expected, "the split of \(frames) frames changed")
        }
    }

    /// A song mastered off centre (a steady offset from zero, as "Take the Lead" has) adds back up to itself: its
    /// offset is shared out among the parts, not added to each of them six times over.
    func testASongOffCentreStillAddsUp() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: PredictionGateTests.package.path), "model not present")
        let url = try await DemucsSeparator.locateModel(in: Bundle(for: Self.self), packageFallback: PredictionGateTests.package)
        let base = PredictionGateTests.music(seconds: 12)
        let song = StereoAudio(left: base.left.map { $0 + 0.06 }, right: base.right.map { $0 + 0.06 }, sampleRate: 44_100)
        let parts = try DemucsSeparator(modelURL: url, computeUnits: .cpuOnly).separate(song)
        let r = DemucsSeparator.reconstruction(of: parts, song: song)
        XCTAssertTrue(DemucsSeparator.passes(r), "power \(r.power), correlation \(r.correlation)")
        // The parts' offsets add up to the song's, not to six times it.
        let offsets = parts.map { $0.left.reduce(0, +) / Float($0.frameCount) }.reduce(0, +)
        let songOffset = song.left.reduce(0, +) / Float(song.frameCount)
        XCTAssertEqual(offsets, songOffset, accuracy: 0.02)
    }

    static func digest(_ parts: [StereoAudio]) -> String {
        var h = SHA256()
        for p in parts {
            for ch in [p.left, p.right] { ch.withUnsafeBytes { h.update(bufferPointer: $0) } }
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Music-like stereo with a DC offset, so the song's mean and spread both matter to the normalisation.
    static func song(frames: Int) -> StereoAudio {
        let base = PredictionGateTests.music(seconds: (frames + 44_099) / 44_100)
        let l = base.left.prefix(frames).map { $0 + 0.05 }, r = base.right.prefix(frames).map { $0 - 0.02 }
        return StereoAudio(left: Array(l), right: Array(r), sampleRate: 44_100)
    }
}
