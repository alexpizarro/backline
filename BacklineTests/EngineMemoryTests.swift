import BacklineKit
import XCTest
@testable import Backline

/// D3 / storage F2: what an open song costs in memory. The engine holds every part for the whole song; at
/// 16 bits that is 10.58 MB per part per minute (it was 21.17 as Float32).
final class EngineMemoryTests: XCTestCase {
    func testAnOpenSongHoldsSixteenBitsPerSample() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("EngineMemoryTests-\(UUID().uuidString)")
        let store = SongStore(root: dir)
        try FileManager.default.createDirectory(at: store.folder("t"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A 4-minute song with the six parts; one part written, the others are copies of its file.
        let minutes = 4.0
        let n = Int(minutes * 60 * 44_100)
        var left = [Float](repeating: 0, count: n), right = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let x = Double(i)
            left[i] = Float(0.4 * sin(x * 0.0311))
            right[i] = Float(0.3 * sin(x * 0.0173))
        }
        let kinds: [StemKind] = [.vocals, .drums, .bass, .guitar, .keys, .other]
        try store.writeStem(StereoAudio(left: left, right: right, sampleRate: 44_100), to: store.stemURL("t", kinds[0]))
        left = []; right = []
        for k in kinds.dropFirst() { try FileManager.default.copyItem(at: store.stemURL("t", kinds[0]), to: store.stemURL("t", k)) }
        let json: [String: Any] = ["bpm": 120.0, "beats": [0.0], "downbeats": [0.0], "key": "E minor", "tuningCents": 0.0,
                                   "sections": [] as [Any]]
        let analysis = try JSONDecoder().decode(SongAnalysis.self, from: JSONSerialization.data(withJSONObject: json))
        let rec = SongRecord(id: "t", title: "T", artist: nil, duration: minutes * 60, sourceName: "t.mp3", addedAt: Date(),
                             lastOpened: Date(), stems: kinds, analysis: analysis, peaks: [:], storageScale: [:],
                             hasArtwork: false, settings: SongSettings())
        XCTAssertEqual(rec.engineTracks.count, kinds.count)

        let engine = PlaybackEngine(drivesOutput: false)
        let before = MemoryFootprint.bytes
        XCTAssertTrue(AppModel.loadEngine(rec, store: store, engine: engine))
        let after = MemoryFootprint.bytes
        let held = Double(after) - Double(before)
        let float32 = Double(kinds.count) * Double(n) * 8
        let mb = held / 1_048_576
        print("[engine-memory] \(kinds.count) parts × \(Int(minutes)) min: footprint +\(Int(mb)) MB (Float32 would be \(Int(float32 / 1_048_576)) MB)")
        // 16 bits per sample is half of Float32; a little room for the decoder's buffers.
        XCTAssertLessThan(held, float32 * 0.6, "the engine holds 16-bit samples: about half of Float32")
        withExtendedLifetime(engine) {}
    }
}
