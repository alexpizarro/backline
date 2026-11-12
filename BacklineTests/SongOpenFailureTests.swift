import BacklineKit
import XCTest
@testable import Backline

/// D7 / storage F7: a song whose part can't be read is never deleted by the app. It says so and offers Try again
/// and Delete song; a kit or guitar split that can't be read falls back to the part it came from.
@MainActor
final class SongOpenFailureTests: XCTestCase {
    /// The app model lives for the whole process (see AppLogicTests).
    private static var keepAlive: [AppModel] = []
    private let store = SongStore.shared

    /// Waits for the launch read of the Library (UIP-05, off the main thread) so it can't replace the
    /// `library` a test sets next.
    private func makeModel() async -> AppModel {
        let m = AppModel()
        Self.keepAlive.append(m)
        await m.libraryReady()
        return m
    }

    /// A 4-second song on disk with the six parts (and the kit parts when `kit`).
    private func song(_ id: String, kit: Bool = false) throws -> SongRecord {
        try FileManager.default.createDirectory(at: store.folder(id), withIntermediateDirectories: true)
        let n = 4 * 44_100
        let tone = StereoAudio(left: (0..<n).map { Float(0.3 * sin(Double($0) * 0.05)) },
                               right: (0..<n).map { Float(0.3 * sin(Double($0) * 0.03)) }, sampleRate: 44_100)
        let kinds: [StemKind] = [.vocals, .guitar, .bass, .drums, .keys, .other]
        for k in kinds + (kit ? StemKind.drumParts : []) { try store.writeStem(tone, to: store.stemURL(id, k)) }
        let json: [String: Any] = ["bpm": 120.0, "beats": [0.0, 0.5], "downbeats": [0.0], "key": "E minor", "tuningCents": 0.0,
                                   "sections": [] as [Any]]
        let analysis = try JSONDecoder().decode(SongAnalysis.self, from: JSONSerialization.data(withJSONObject: json))
        var r = SongRecord(id: id, title: "Open failure", artist: nil, duration: 4, sourceName: "t.mp3", addedAt: Date(),
                           lastOpened: Date(), stems: kinds, analysis: analysis, peaks: [:], storageScale: [:],
                           hasArtwork: false, settings: SongSettings())
        if kit {
            r.drumSplit = DrumSplit(method: "t", peaks: Dictionary(uniqueKeysWithValues: StemKind.drumParts.map { ($0.rawValue, [Float](repeating: 0.5, count: 8)) }),
                                    scales: [:], energy: ["kick": 0.3, "snare": 0.3, "hats": 0.3, "toms": 0.1])
        }
        try store.save(r)
        addTeardownBlock { [store] in store.delete(id) }
        return r
    }

    /// Waits until the open has settled: the song is open, or the failure screen is up.
    private func settle(_ m: AppModel, _ id: String) async {
        for _ in 0..<200 {
            // `select` marks the row as loading at once and clears it when the parts are read or failed.
            if m.loadingSongID == nil {
                if m.song?.id == id { return }
                if case .failed = m.screen { return }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("the song neither opened nor failed")
    }

    private func damage(_ url: URL, truncate: Bool) throws {
        if truncate {
            let data = try Data(contentsOf: url)
            try data.prefix(data.count / 3).write(to: url)
        } else {
            try Data("not audio at all".utf8).write(to: url)
        }
    }

    func testAPartThatCantBeReadKeepsTheSong() async throws {
        for truncate in [false, true] {
            let id = "f7-unreadable-\(truncate ? "truncated" : "garbage")-\(UUID().uuidString.prefix(6))"
            let rec = try song(id)
            try damage(store.stemURL(id, .vocals), truncate: truncate)
            let m = await makeModel()
            m.library = [rec]
            m.select(rec)
            await settle(m, id)
            // Whatever the reader made of the damage, the song is still there with its record.
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.recordURL(id).path), "\(id): the record stays")
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.folder(id).path), "\(id): the folder stays")
            XCTAssertEqual(m.library.map(\.id), [id], "\(id): the song stays in the Library")
            if !truncate {
                XCTAssertEqual(m.screen, .failed(AppModel.openFailureMessage), "a part that can't be read says so")
                XCTAssertEqual(m.openFailure?.id, id)
                XCTAssertNil(m.song, "nothing half-loaded is left open")
            }
            if case .failed(let message) = m.screen {
                let c = FailureView.content(message: message, fromLink: false, canSignIn: false)
                XCTAssertEqual([c.primary, c.secondary], [.openAgain, .deleteSong], "\(id): Try again and Delete song")
                XCTAssertEqual(c.title, "Couldn't open it")
            }
        }
    }

    func testTryAgainOpensTheSongOnceItCanBeRead() async throws {
        let id = "f7-retry-\(UUID().uuidString.prefix(6))"
        let rec = try song(id)
        let vocals = store.stemURL(id, .vocals)
        let good = try Data(contentsOf: vocals)
        try damage(vocals, truncate: false)
        let m = await makeModel()
        m.library = [rec]
        m.select(rec)
        await settle(m, id)
        XCTAssertEqual(m.openFailure?.id, id)
        try good.write(to: vocals)
        m.retryOpen()
        await settle(m, id)
        XCTAssertEqual(m.song?.id, id, "Try again opens it")
        XCTAssertEqual(m.screen, .mixer)
        XCTAssertNil(m.openFailure)
    }

    func testDeleteSongIsThePersonsChoice() async throws {
        let id = "f7-delete-\(UUID().uuidString.prefix(6))"
        let rec = try song(id)
        try damage(store.stemURL(id, .bass), truncate: false)
        let m = await makeModel()
        m.library = [rec]
        m.select(rec)
        await settle(m, id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.recordURL(id).path))
        m.deleteFailedSong()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(id).path), "deleted when the person asks")
        XCTAssertTrue(m.library.isEmpty)
        XCTAssertEqual(m.screen, .empty)
    }

    func testAKitPartThatCantBeReadFallsBackToTheDrums() async throws {
        let id = "f7-kit-\(UUID().uuidString.prefix(6))"
        let rec = try song(id, kit: true)
        XCTAssertTrue(rec.engineTracks.contains(.kick))
        try damage(store.stemURL(id, .kick), truncate: false)
        let m = await makeModel()
        m.library = [rec]
        m.select(rec)
        await settle(m, id)
        XCTAssertEqual(m.song?.id, id, "the song opens")
        XCTAssertEqual(m.screen, .mixer)
        XCTAssertNil(m.song?.drumSplit, "without the kit")
        XCTAssertTrue(m.loadedTracks.contains(.drums))
        XCTAssertFalse(m.loadedTracks.contains(.kick))
    }

    func testOpenVariantsDropTheKitThenTheGuitarSplit() {
        let r = SongRecord(id: "v", title: "V", artist: nil, duration: 1, sourceName: "t", addedAt: Date(), lastOpened: Date(),
                           stems: [.vocals, .guitar, .drums], analysis: try! JSONDecoder().decode(SongAnalysis.self, from: Data(
                               #"{"bpm":120,"beats":[],"downbeats":[],"key":"E minor","tuningCents":0,"sections":[]}"#.utf8)),
                           peaks: [:], storageScale: [:], hasArtwork: false, settings: SongSettings())
        XCTAssertEqual(AppModel.openVariants(r).count, 1, "nothing to fall back to")
        var both = r
        both.drumSplit = DrumSplit(method: "t", peaks: [:], scales: [:], energy: [:])
        both.guitarSplit = GuitarSplit(method: "t", confidence: 0.8, leadPeaks: [0.5], rhythmPeaks: [0.5], leadScale: 1, rhythmScale: 1)
        let v = AppModel.openVariants(both)
        XCTAssertEqual(v.count, 3)
        XCTAssertNotNil(v[1].guitarSplit); XCTAssertNil(v[1].drumSplit)
        XCTAssertNil(v[2].guitarSplit); XCTAssertNil(v[2].drumSplit)
    }
}
