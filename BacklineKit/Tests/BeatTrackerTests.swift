import CoreML
import XCTest
@testable import BacklineKit

/// Swift Beat This! port vs the Python reference fixtures in ml/fixtures_beat.
final class BeatTrackerTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let fixtures = root.appendingPathComponent("ml/fixtures_beat")
    static let package = root.appendingPathComponent("Backline/Resources/BeatThisSmall.mlpackage")

    func load(_ name: String) throws -> [Float] {
        let d = try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
        return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    func testFilterbankMatchesTorchaudio() throws {
        let ref = try load("mel_fbank_513x128.f32")
        let fb = BeatTracker.slaneyMelFilterbank()
        var maxErr: Float = 0
        for i in 0..<ref.count { maxErr = max(maxErr, abs(ref[i] - fb[i])) }
        XCTAssertLessThan(maxErr, 5e-5)   // float32 vs float64 reference
    }

    func testMelAndBeatsMatchReference() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.package.path), "model not present")
        let url = try await BeatTracker.locateModel(in: Bundle(for: Self.self), packageFallback: Self.package)
        let tracker = try BeatTracker(modelURL: url)
        let audio = try load("audio_22050.f32")
        let mel = tracker.melSpectrogram(audio)
        let ref = try load("mel.f32")
        XCTAssertEqual(mel.count, ref.count)
        var maxErr: Float = 0
        for i in 0..<min(mel.count, ref.count) { maxErr = max(maxErr, abs(mel[i] - ref[i])) }
        print("mel max abs err", maxErr)
        XCTAssertLessThan(maxErr, 1e-3)

        // The fixture logits are a single direct pass over these 1500 frames.
        let input = try MLMultiArray(shape: [1, 1500, 128], dataType: .float32)
        let (b, d) = try ref.withUnsafeBufferPointer { try tracker.predictChunk($0.baseAddress!, into: input) }
        let refB = try load("beat_logits_small.f32"), refD = try load("downbeat_logits_small.f32")
        var eb: Float = 0, ed: Float = 0
        for i in 0..<refB.count { eb = max(eb, abs(b[i] - refB[i])); ed = max(ed, abs(d[i] - refD[i])) }
        print("logit max abs err beat", eb, "downbeat", ed)
        XCTAssertLessThan(eb, 2e-3)
        XCTAssertLessThan(ed, 2e-3)

        let (beats, downbeats) = BeatTracker.postprocess(beat: b, downbeat: d)
        XCTAssertEqual(beats.count, 82)
        XCTAssertEqual(downbeats.count, 27)
        XCTAssertEqual(beats.first ?? -1, 0.04, accuracy: 1e-6)

        // Full chunked pipeline on the same audio: interior beats must agree with the direct pass.
        let full = try XCTUnwrap(tracker.track(mono22k: audio))
        let interior = beats.filter { $0 > 1 && $0 < 28 }
        let matched = interior.filter { t in full.beats.contains { abs($0 - t) < 0.021 } }
        XCTAssertGreaterThanOrEqual(Double(matched.count) / Double(interior.count), 0.97)
        print("chunked bpm", full.bpm, "beats", full.beats.count)
    }
}
