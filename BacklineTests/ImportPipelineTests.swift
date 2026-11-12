import BacklineKit
import XCTest
@testable import Backline

/// U05: what the pipeline makes of songs without a guitar (`docs/release/part-detection.md`, Step 1).
/// Synthetic parts, 12 s, without the lead model (it would only blend into a split the stereo analysis allows).
final class ImportPipelineTests: XCTestCase {
    static let sr = 44_100, seconds = 12
    static func db(_ x: Float) -> Float { pow(10, x / 20) }

    static func tone(_ hz: Float, _ gain: Float, rightHz: Float? = nil) -> StereoAudio {
        let n = sr * seconds
        let l = (0..<n).map { gain * sin(2 * .pi * hz * Float($0) / Float(sr)) }
        let r = rightHz.map { rh in (0..<n).map { gain * sin(2 * .pi * rh * Float($0) / Float(sr)) } } ?? l
        return StereoAudio(left: l, right: r, sampleRate: Double(sr))
    }
    /// Deterministic noise; different seeds for the two sides make it wide.
    static func noise(_ gain: Float, seed: UInt64, wide: Bool = false) -> StereoAudio {
        func run(_ s: UInt64) -> [Float] {
            var x = s
            return (0..<(sr * seconds)).map { _ in
                x = x &* 6364136223846793005 &+ 1442695040888963407
                return gain * (Float(x >> 40) / Float(1 << 24) * 2 - 1)
            }
        }
        let l = run(seed)
        return StereoAudio(left: l, right: wide ? run(seed &+ 99) : l, sampleRate: Double(sr))
    }
    static func plus(_ a: StereoAudio, _ b: StereoAudio) -> StereoAudio {
        StereoAudio(left: zip(a.left, b.left).map(+), right: zip(a.right, b.right).map(+), sampleRate: a.sampleRate)
    }

    private func process(_ parts: [StemKind: StereoAudio]) async throws -> ImportPipeline.Processed {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ImportPipelineTests-\(UUID().uuidString)")
        let store = SongStore(root: dir)
        try FileManager.default.createDirectory(at: store.folder("t"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let names: [StemKind: String] = [.vocals: "vocals", .drums: "drums", .bass: "bass", .guitar: "guitar", .keys: "piano", .other: "other"]
        var byName: [String: StereoAudio] = [:]
        for (k, a) in parts { byName[names[k]!] = a }
        return try await ImportPipeline.process(byName, id: "t", store: store, useLeadModel: false, isCancelled: { false })
    }

    func testPianoAndVoiceGetsNoGuitarRows() async throws {
        let ghost = Self.db(-65) * 0.3
        let p = try await process([.vocals: Self.tone(300, 0.3), .keys: Self.tone(440, 0.3),
                                   .guitar: Self.noise(ghost, seed: 1), .drums: Self.noise(ghost, seed: 2),
                                   .bass: Self.noise(ghost, seed: 3), .other: Self.noise(ghost, seed: 4)])
        XCTAssertNil(p.guitarSplit, "no Lead / Rhythm guitar")
        XCTAssertFalse(p.order.contains(.guitar), "a silent guitar is folded into Other")
        XCTAssertFalse(PartPresence.isPresent(try XCTUnwrap(p.levels[StemKind.other.rawValue])), "Other is quiet")
        XCTAssertTrue(PartPresence.isPresent(try XCTUnwrap(p.levels[StemKind.keys.rawValue])))
    }

    func testARiffInOtherIsNotCalledLeadGuitar() async throws {
        let p = try await process([.vocals: Self.tone(300, 0.3), .guitar: Self.noise(Self.db(-80) * 0.3, seed: 5),
                                   .other: Self.plus(Self.tone(523, 0.25), Self.tone(1046, 0.08)),
                                   .bass: Self.tone(110, 0.25), .drums: Self.noise(0.15, seed: 6), .keys: Self.noise(0.001, seed: 7)])
        XCTAssertNil(p.guitarSplit, "the centred riff in Other doesn't become a lead guitar")
    }

    /// Whether a split survives, with the levels measured on real songs (`part-detection.md`, HTDemucs pass,
    /// lead from the app's stereo + ML blend). Synthetic tones don't exercise the stereo splitter's lead gate,
    /// so the real numbers are used here; `backline-cli presence` checks whole songs.
    func testRealGuitarsKeepTheirSplitAndFakeOnesDont() {
        func l(_ share: Float, _ active: Float, _ peak: Float) -> PartLevel { PartLevel(share: share, active: active, peak: peak) }
        // La Isla Bonita and Los Infieles: real lead and rhythm guitars.
        XCTAssertTrue(ImportPipeline.mayTrySplit(guitar: l(-11, 0.45, -7)))
        XCTAssertTrue(ImportPipeline.keepSplit(lead: l(-13, 0.45, -9), rhythm: l(-16, 0.36, -14)))
        XCTAssertTrue(ImportPipeline.keepSplit(lead: l(-9, 0.64, -8), rhythm: l(-9, 0.88, -9)))
        // Someone Like You: the guitar stem is near-silent, so it isn't even tried.
        XCTAssertFalse(ImportPipeline.mayTrySplit(guitar: l(-66, 0, -64)))
        // HUMBLE.: bleed guitar; split halves barely there.
        XCTAssertFalse(ImportPipeline.mayTrySplit(guitar: l(-21, 0.14, -16)))
        XCTAssertFalse(ImportPipeline.keepSplit(lead: l(-27, 0.03, -22), rhythm: l(-24, 0.06, -19)))
    }

    /// The split's six parts add back up to the song (22 Oct 2026: the iOS Simulator's Core ML GPU path did not,
    /// 13 % of the power; every device re-splits on the CPU if the check fails). It reads 20 s of the test
    /// fixture, or of the song BACKLINE_TEST_SONG names.
    func testTheSplitAddsBackUpToTheSong() async throws {
        let song = try Self.testSong(seconds: 20)
        let sep = try await SeparationService.shared.separator()
        let parts = try sep.separate(song)
        let r = DemucsSeparator.reconstruction(of: parts, song: song)
        XCTAssertEqual(r.power, 1, accuracy: 0.1, "power of the parts over the song")
        XCTAssertGreaterThan(r.correlation, 0.95)
        XCTAssertTrue(DemucsSeparator.passes(r), "the tightened add-up check passes a clean split")
    }

    /// The first `seconds` of the song BACKLINE_TEST_SONG names, or of the test fixture (20 s of "Summon the
    /// Rawk" by Kevin MacLeod, CC BY, in BacklineTests/Fixtures).
    static func testSong(seconds: Int) throws -> StereoAudio {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SummonTheRawk-20s.mp3")
        let url = ProcessInfo.processInfo.environment["BACKLINE_TEST_SONG"].map { URL(fileURLWithPath: $0) } ?? fixture
        let full = try AudioDecoder.decode(url)
        let n = min(full.frameCount, seconds * Int(full.sampleRate))
        return StereoAudio(left: Array(full.left[0..<n]), right: Array(full.right[0..<n]), sampleRate: full.sampleRate)
    }
}
