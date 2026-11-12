import Accelerate
import BacklineKit
import XCTest
@testable import Backline

/// D2 (`split.md` F1, F2, F7): the import makes the stereo lead/rhythm split only; `LeadRefineJob` adds the lead
/// guitar model afterwards from the stored files.
final class LeadRefineTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let names: [StemKind: String] = [.vocals: "vocals", .drums: "drums", .bass: "bass", .guitar: "guitar",
                                            .keys: "piano", .other: "other"]

    private func tempStore() throws -> SongStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LeadRefineTests-\(UUID().uuidString)")
        let store = SongStore(root: dir)
        try FileManager.default.createDirectory(at: store.folder("t"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return store
    }

    private func record(_ p: ImportPipeline.Processed, duration: Double) throws -> SongRecord {
        let json: [String: Any] = ["bpm": 120.0, "beats": [0.0, 0.5], "downbeats": [0.0], "key": "E minor", "tuningCents": 0.0,
                                   "sections": [] as [Any]]
        let analysis = try JSONDecoder().decode(SongAnalysis.self, from: JSONSerialization.data(withJSONObject: json))
        var r = SongRecord(id: "t", title: "Test", artist: nil, duration: duration, sourceName: "t.mp3", addedAt: Date(),
                           lastOpened: Date(), stems: p.order, analysis: analysis, peaks: p.peaks, storageScale: p.scales,
                           hasArtwork: false, settings: SongSettings(), guitarSplit: p.guitarSplit)
        r.levels = p.levels
        r.instruments = p.instruments
        return r
    }

    /// F2: a guitar that is there but near mono stays one part, and the lead model is never even loaded for it.
    func testTheLeadModelIsNeverLoadedForANearMonoGuitar() async throws {
        typealias T = ImportPipelineTests
        let mono = T.plus(T.noise(0.2, seed: 11), T.tone(330, 0.2))        // same on both sides: width 0
        let parts: [StemKind: StereoAudio] = [.vocals: T.tone(300, 0.3), .guitar: mono, .bass: T.tone(110, 0.25),
                                              .drums: T.noise(0.15, seed: 12), .keys: T.noise(0.001, seed: 13),
                                              .other: T.noise(0.05, seed: 14)]
        var byName: [String: StereoAudio] = [:]
        for (k, a) in parts { byName[Self.names[k]!] = a }
        let before = ImportPipeline.leadModelLoads.value
        let withModel = try await ImportPipeline.process(byName, id: "t", store: try tempStore(), useLeadModel: true,
                                                         isCancelled: { false })
        XCTAssertEqual(ImportPipeline.leadModelLoads.value, before, "the lead model is not loaded for a guitar that stays one part")
        XCTAssertTrue(withModel.order.contains(.guitar), "the guitar is there and tried")
        XCTAssertNil(withModel.guitarSplit)
        let without = try await ImportPipeline.process(byName, id: "t", store: try tempStore(), useLeadModel: false,
                                                       isCancelled: { false })
        XCTAssertEqual(withModel.order, without.order)
        // The same numbers up to the order the parts are summed in (a dictionary's order).
        XCTAssertEqual(Set(withModel.levels.keys), Set(without.levels.keys))
        for (k, l) in withModel.levels {
            let m = try XCTUnwrap(without.levels[k])
            XCTAssertEqual(l.share, m.share, accuracy: 1e-4, k)
            XCTAssertEqual(l.active, m.active, accuracy: 1e-6, k)
            XCTAssertEqual(l.peak, m.peak, accuracy: 1e-4, k)
        }
        XCTAssertEqual(withModel.scales, without.scales)
        XCTAssertEqual(withModel.peaks, without.peaks)
        XCTAssertEqual(withModel.instruments, without.instruments)
    }

    /// F7: the storage gain applied while writing gives exactly the file a scaled copy gave.
    func testWritingWithAGainMatchesScalingACopyFirst() throws {
        let store = try tempStore()
        let n = 300_000                                       // more than one 256 K-frame chunk
        let a = StereoAudio(left: (0..<n).map { Float(1.3 * sin(Double($0) * 0.013)) },
                            right: (0..<n).map { Float(0.9 * sin(Double($0) * 0.021)) }, sampleRate: 44_100)
        let gain: Float = 0.988 / 1.3
        var scaled = a
        var g = gain
        vDSP_vsmul(a.left, 1, &g, &scaled.left, 1, vDSP_Length(n))
        vDSP_vsmul(a.right, 1, &g, &scaled.right, 1, vDSP_Length(n))
        let copyURL = store.folder("t").appendingPathComponent("copy.caf")
        let gainURL = store.folder("t").appendingPathComponent("gain.caf")
        try store.writeStem(scaled, to: copyURL)
        try store.writeStem(a, to: gainURL, gain: gain)
        let x = try store.readAudio(copyURL), y = try store.readAudio(gainURL)
        XCTAssertEqual(x.frameCount, n)
        XCTAssertEqual(x.left, y.left)
        XCTAssertEqual(x.right, y.right)
    }

    /// F1: refining the stored stereo split gives what the single-pass import with the model gave (1.0's way),
    /// within −80 dB, and the record says so.
    func testRefiningFromTheStoredFilesMatchesTheSinglePass() async throws {
        // 20 s of "Summon the Rawk" by Kevin MacLeod (incompetech.com, CC BY), from 1:10: a lead and a rhythm guitar that split.
        let song = try AudioDecoder.decode(Self.fixtures.appendingPathComponent("SummonTheRawk-20s.mp3"))
        let sep = try await SeparationService.shared.separator()
        let raw = try sep.separate(song)
        SeparationService.shared.release()
        var byName: [String: StereoAudio] = [:]
        for (name, s) in zip(DemucsSeparator.sources, raw) { byName[name] = s }
        let modelURL = try XCTUnwrap(LeadSeparator.bundledModel(), "the lead model ships in the app")

        let singleStore = try tempStore()
        let single = try await ImportPipeline.process(byName, id: "t", store: singleStore, original: song,
                                                      useLeadModel: true, isCancelled: { false })
        XCTAssertEqual(single.guitarSplit?.method, LeadRefineJob.refinedMethod)

        let store = try tempStore()
        let stereo = try await ImportPipeline.process(byName, id: "t", store: store, original: song,
                                                      useLeadModel: false, isCancelled: { false })
        let rec = try record(stereo, duration: song.duration)
        XCTAssertEqual(rec.guitarSplit?.method, LeadRefineJob.stereoMethod)
        XCTAssertTrue(LeadRefineJob.isPending(rec), "a stereo split with the model in the app is pending")

        let refined = try XCTUnwrap(try LeadRefineJob.run(rec: rec, store: store, modelURL: modelURL, isCancelled: { false }),
                                    "the refined split is kept")
        try LeadRefineJob.install(refined.files)
        let new = LeadRefineJob.applied(refined, to: rec)
        XCTAssertEqual(new.guitarSplit?.method, LeadRefineJob.refinedMethod)
        XCTAssertFalse(LeadRefineJob.isPending(new))
        XCTAssertEqual(new.guitarSplit?.otherAdjusted, single.guitarSplit?.otherAdjusted)
        for f in refined.files { XCTAssertFalse(FileManager.default.fileExists(atPath: f.temp.path), "renamed into place") }

        // The parts on disk, storage gains undone, against the single pass's.
        func part(_ s: SongStore, _ url: URL, _ gain: Float) throws -> StereoAudio { try LeadRefineJob.read(url, gain: gain, store: s) }
        let a = try XCTUnwrap(single.guitarSplit), b = try XCTUnwrap(new.guitarSplit)
        var pairs: [(String, StereoAudio, StereoAudio)] = [
            ("lead", try part(singleStore, singleStore.stemURL("t", .leadGuitar), a.leadScale),
             try part(store, store.stemURL("t", .leadGuitar), b.leadScale)),
            ("rhythm", try part(singleStore, singleStore.stemURL("t", .rhythmGuitar), a.rhythmScale),
             try part(store, store.stemURL("t", .rhythmGuitar), b.rhythmScale)),
        ]
        if a.otherAdjusted {
            pairs.append(("other-split", try part(singleStore, singleStore.otherSplitURL("t"), a.otherScale),
                          try part(store, store.otherSplitURL("t"), b.otherScale)))
        }
        // The refinement starts from 16-bit files where the single pass had the float parts, so the two differ
        // by what 16-bit storage changes (about −98 dB below full scale per sample): the difference is measured
        // against full scale, and against the part itself (printed; the storage floor is printed beside it).
        func rms(_ x: StereoAudio, _ y: StereoAudio?) -> Double {
            var e: Double = 0
            for i in 0..<x.frameCount {
                let dl = Double(x.left[i] - (y?.left[i] ?? 0)), dr = Double(x.right[i] - (y?.right[i] ?? 0))
                e += dl * dl + dr * dr
            }
            return e / Double(2 * max(x.frameCount, 1))
        }
        let guitar = try XCTUnwrap(byName["guitar"])
        let stored = try part(store, store.stemURL("t", .guitar), stereo.scales["guitar"] ?? 1)
        print("[refine] 16-bit storage floor: guitar.caf against the float guitar \(String(format: "%.1f", 10 * log10(rms(guitar, stored) / rms(guitar, nil)))) dB")
        for (name, x, y) in pairs {
            XCTAssertEqual(x.frameCount, y.frameCount)
            let full = 10 * log10(max(rms(x, y), 1e-30))
            let relative = 10 * log10(max(rms(x, y), 1e-30) / max(rms(x, nil), 1e-30))
            print("[refine] \(name): difference \(String(format: "%.1f", full)) dBFS, \(String(format: "%.1f", relative)) dB against the part")
            XCTAssertLessThan(full, -80, "\(name) within −80 dB (full scale) of the single pass")
        }
        // The decisions the rows are made from are the same.
        for k in [StemKind.leadGuitar.rawValue, StemKind.rhythmGuitar.rawValue] {
            let x = try XCTUnwrap(single.levels[k]), y = try XCTUnwrap(new.levels?[k])
            XCTAssertEqual(x.active, y.active, accuracy: 0.02, k)
        }
        XCTAssertEqual(NameCheck.trustLead(single.instruments["lead"]), NameCheck.trustLead(new.instruments?["lead"]))
    }

    /// The landing rule: the refined split only goes in when no mode's rows change.
    @MainActor
    func testRowsCompareAcrossEveryMode() throws {
        let json: [String: Any] = ["bpm": 120.0, "beats": [0.0], "downbeats": [0.0], "key": "E minor", "tuningCents": 0.0,
                                   "sections": [] as [Any]]
        let analysis = try JSONDecoder().decode(SongAnalysis.self, from: JSONSerialization.data(withJSONObject: json))
        let gs = GuitarSplit(method: LeadRefineJob.stereoMethod, confidence: 0.5, leadPeaks: [], rhythmPeaks: [],
                             leadScale: 1, rhythmScale: 1)
        var a = SongRecord(id: "t", title: "T", artist: nil, duration: 10, sourceName: "t", addedAt: Date(), lastOpened: Date(),
                           stems: [.vocals, .guitar, .bass, .drums, .other], analysis: analysis, peaks: [:], storageScale: [:],
                           hasArtwork: false, settings: SongSettings(), guitarSplit: gs)
        let present = PartLevel(share: -10, active: 0.8, peak: -5)
        a.levels = Dictionary(uniqueKeysWithValues: ["vocals", "guitar", "bass", "drums", "other", "leadGuitar", "rhythmGuitar"].map { ($0, present) })
        var same = a
        same.guitarSplit?.method = LeadRefineJob.refinedMethod
        same.levels?["leadGuitar"] = PartLevel(share: -12, active: 0.7, peak: -6)
        XCTAssertTrue(AppModel.sameRows(a, same, placement: [:]))
        var quieter = same
        quieter.levels?["leadGuitar"] = PartLevel(share: -40, active: 0.01, peak: -30)   // would go under More parts
        XCTAssertFalse(AppModel.sameRows(a, quieter, placement: [:]))
        XCTAssertTrue(AppModel.sameRows(a, quieter, placement: ["leadGuitar": true]), "a part placed by hand stays put")
        var notGuitar = same
        notGuitar.instruments = ["lead": InstrumentShares(guitar: 0, keys: 0.9)]          // lead no longer trusted
        XCTAssertFalse(AppModel.sameRows(a, notGuitar, placement: [:]))
    }
}
