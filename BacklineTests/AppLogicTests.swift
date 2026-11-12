import BacklineKit
import XCTest
@testable import Backline

/// The mode, presence and naming logic behind the rows the screen shows (U05, U06, U07).
/// Ported from backline-ios BacklineTests/AppLogicTests.swift; cases the Mac cannot run yet stay on iOS.
@MainActor
final class AppLogicTests: XCTestCase {
    /// The app model lives for the whole process on iOS to dodge a Swift runtime bug in isolated deinit;
    /// keeping the same shape here means a ported case behaves the same on both sides.
    private static var keepAlive: [AppModel] = []
    private func makeModel() -> AppModel {
        let m = AppModel()
        // The remembered mode lives in the test host's defaults: every case starts in Play.
        m.appMode = .play
        Self.keepAlive.append(m)
        return m
    }

    private func record(stems: [StemKind] = [.vocals, .guitar, .bass, .drums, .keys, .other],
                        drumSplit: Bool = false, guitarSplit: Bool = false) -> SongRecord {
        let beats = (0..<64).map { Double($0) * 0.5 }, bars = (0..<16).map { Double($0) * 2 }
        let json: [String: Any] = ["bpm": 120.0, "beats": beats, "downbeats": bars, "key": "E minor", "tuningCents": 0.0,
                                   "sections": [["id": UUID().uuidString, "label": "Verse", "start": 0.0, "end": 16.0],
                                                ["id": UUID().uuidString, "label": "Solo", "start": 16.0, "end": 24.0]]]
        let analysis = try! JSONDecoder().decode(SongAnalysis.self, from: JSONSerialization.data(withJSONObject: json))
        var r = SongRecord(id: "t", title: "Test", artist: nil, duration: 32, sourceName: "t.mp3", addedAt: Date(), lastOpened: Date(),
                           stems: stems, analysis: analysis, peaks: [:], storageScale: [:], hasArtwork: false, settings: SongSettings())
        if drumSplit {
            r.drumSplit = DrumSplit(method: "t", peaks: Dictionary(uniqueKeysWithValues: StemKind.drumParts.map { ($0.rawValue, [Float](repeating: 0.5, count: 8)) }),
                                    scales: [:], energy: ["kick": 0.3, "snare": 0.3, "hats": 0.3, "toms": 0.1])
        }
        if guitarSplit {
            r.guitarSplit = GuitarSplit(method: "t", confidence: 0.8, leadPeaks: [0.5], rhythmPeaks: [0.5], leadScale: 1, rhythmScale: 1)
        }
        return r
    }

    // MARK: Parts that are really there (U05)

    private func levels(present: [StemKind], quiet: [StemKind]) -> [String: PartLevel] {
        var l: [String: PartLevel] = [:]
        for k in present { l[k.rawValue] = PartLevel(share: -6, active: 0.8, peak: -3) }
        for k in quiet { l[k.rawValue] = PartLevel(share: -60, active: 0, peak: -55) }
        return l
    }

    func testAQuietGuitarSitsInMorePartsAndKeepsItsTrack() {
        var r = record()
        r.levels = levels(present: [.vocals, .bass, .drums, .keys], quiet: [.guitar, .other])
        let rows = AppModel.rows(for: .play, style: nil, song: r)
        XCTAssertEqual(rows.filter { !$0.quiet }.map(\.kind), [.vocals, .bass, .drums, .keys])
        XCTAssertEqual(rows.filter(\.quiet).map(\.kind), [.guitar, .other], "quiet parts go last, under More parts")
        XCTAssertEqual(rows.first { $0.kind == .guitar }?.leaves, [.guitar], "its switch and fader still control its own track")
    }

    func testMovingAPartBackBeatsTheLevels() {
        var r = record()
        r.levels = levels(present: [.vocals, .bass, .drums, .keys, .other], quiet: [.guitar])
        let rows = AppModel.rows(for: .play, style: nil, song: r, placement: ["guitar": true, "keys": false])
        XCTAssertFalse(rows.first { $0.kind == .guitar }!.quiet)
        XCTAssertTrue(rows.first { $0.kind == .keys }!.quiet)
    }

    func testASongWithoutLevelsKeepsTodaysRows() {
        let r = record(drumSplit: true)
        for m in PracticeMode.allCases {
            let rows = AppModel.rows(for: m, style: .bachata, song: r)
            XCTAssertEqual(rows, AppModel.baseRows(for: m, style: .bachata, song: r, musicOpen: false), "\(m)")
            XCTAssertFalse(rows.contains(where: \.quiet))
        }
    }

    // MARK: More parts and placing by hand (U05)

    func testMainStemsAreTheRowsThatAreReallyThere() {
        var r = record()
        r.levels = levels(present: [.vocals, .bass, .drums, .keys], quiet: [.guitar, .other])
        let m = makeModel()
        let saved = m.song
        m.song = r
        defer { m.song = saved }
        XCTAssertEqual(m.mainStems, [.vocals, .bass, .drums, .keys], "the Listen for row and the role chip use these")
    }

    func testPlacingAPartByHandIsRemembered() {
        var r = record()
        r.levels = levels(present: [.vocals, .bass, .drums, .keys], quiet: [.guitar, .other])
        let m = makeModel()
        let savedSong = m.song, savedSettings = m.settings
        m.song = r
        defer { m.song = savedSong; m.settings = savedSettings }
        m.placePart(.guitar, main: true)
        XCTAssertEqual(m.settings.partPlacement["guitar"], true)
        XCTAssertFalse(m.rows.first { $0.kind == .guitar }!.quiet, "moved back it leaves More parts")
        m.placePart(.keys, main: false)
        XCTAssertTrue(m.rows.first { $0.kind == .keys }!.quiet, "put under More parts it stays controllable there")
        XCTAssertTrue(m.rows.first { $0.kind == .keys }!.leaves.contains(.keys), "and keeps its own track")
    }

    func testPlayOpensAGuitarFreeSongWithNothingRemoved() {
        let m = makeModel()
        // The remembered choice is app-wide (other tests change it): start from the default, Lead guitar.
        let saved = m.playingInstrumentRaw
        m.playingInstrumentRaw = StemKind.leadGuitar.rawValue
        defer { m.playingInstrumentRaw = saved }
        var r = record()
        r.levels = levels(present: [.vocals, .bass, .drums, .keys], quiet: [.guitar, .other])
        let main = AppModel.rows(for: .play, style: nil, song: r).filter { !$0.quiet }.map(\.kind)
        XCTAssertEqual(m.defaultRemoved(for: .play, tracks: main), [], "no silent guitar is removed: the chip says Nobody")
    }

    // MARK: Naming check (U06)

    private func shares(_ g: Float, _ k: Float) -> InstrumentShares { InstrumentShares(guitar: g, keys: k) }

    func testALeadThatIsntGuitarPlaysWithTheRhythmAsOneGuitarRow() {
        var r = record(guitarSplit: true)
        r.instruments = ["mix": shares(0.6, 0.3), "lead": shares(0.26, 0.74)]
        let rows = AppModel.rows(for: .play, style: nil, song: r)
        XCTAssertFalse(rows.contains { $0.kind == .leadGuitar || $0.kind == .rhythmGuitar })
        XCTAssertEqual(rows.first { $0.kind == .guitar }?.leaves, [.leadGuitar, .rhythmGuitar], "one switch for both tracks")
    }

    func testAGuitarThatSoundsLikeKeysJoinsTheKeysRow() {
        var r = record()
        r.instruments = ["mix": shares(0.01, 0.75), "guitar": shares(0.31, 0.75)]
        let rows = AppModel.rows(for: .play, style: nil, song: r)
        XCTAssertFalse(rows.contains { $0.kind == .guitar })
        XCTAssertEqual(rows.first { $0.kind == .keys }?.leaves, [.keys, .guitar])
        // No keys part of its own (folded): the guitar track becomes the Keys row.
        var folded = record(stems: [.vocals, .guitar, .bass, .drums, .other])
        folded.instruments = r.instruments
        XCTAssertEqual(AppModel.rows(for: .play, style: nil, song: folded).first { $0.kind == .keys }?.leaves, [.guitar])
    }

    func testAnUnclearGuitarInASongWithoutGuitarGoesUnderMoreParts() {
        var r = record()
        r.instruments = ["mix": shares(0.01, 0.6), "guitar": shares(1.0, 0.2)]
        let rows = AppModel.rows(for: .play, style: nil, song: r)
        XCTAssertTrue(rows.first { $0.kind == .guitar }!.quiet)
        XCTAssertFalse(AppModel.rows(for: .play, style: nil, song: r, placement: ["guitar": true]).first { $0.kind == .guitar }!.quiet,
                       "moving it back still wins")
    }

    func testASongWithGuitarKeepsItsRows() {
        var r = record(guitarSplit: true)
        r.instruments = ["mix": shares(0.68, 0.28), "guitar": shares(0.99, 0.1), "lead": shares(0.81, 0.2)]
        XCTAssertEqual(AppModel.rows(for: .play, style: nil, song: r), AppModel.baseRows(for: .play, style: nil, song: r, musicOpen: false))
    }

    // MARK: Rows per mode

    func testPlayShowsEveryPartAndDrumsAsOneRow() {
        let r = record(drumSplit: true)
        let rows = AppModel.rows(for: .play, style: nil, song: r)
        XCTAssertEqual(rows.map(\.kind), [.vocals, .guitar, .bass, .drums, .keys, .other])
        XCTAssertEqual(rows.first { $0.kind == .drums }?.leaves, StemKind.drumParts)
    }

    func testBeatsShowsKitAndFoldsMusic() {
        let r = record(drumSplit: true)
        let rows = AppModel.rows(for: .beats, style: nil, song: r)
        XCTAssertEqual(rows.map(\.kind), [.vocals, .kick, .snare, .hats, .toms, .bass, .other])
        XCTAssertEqual(rows.last?.leaves, [.guitar, .keys, .other])
        let open = AppModel.rows(for: .beats, style: nil, song: r, musicOpen: true)
        XCTAssertTrue(open.map(\.kind).contains(.guitar))
    }

    func testBachataNamesTheKitAfterTheInstruments() {
        let r = record(drumSplit: true)
        let rows = AppModel.rows(for: .dance, style: .bachata, song: r)
        XCTAssertEqual(rows.map(\.kind).filter { [.snare, .hats, .kick].contains($0) }, [.snare, .hats, .kick])
        XCTAssertEqual(StemKind.snare.label(in: .dance, style: .bachata), "Bongó")
    }

    func testSilentKitPartsHandTheirTracksToAnotherRow() {
        var r = record(drumSplit: true)
        r.drumSplit?.energy = ["kick": 0.5, "snare": 0.5, "hats": 0.0001, "toms": 0.0001]
        let rows = AppModel.rows(for: .beats, style: nil, song: r)
        let leaves = rows.flatMap(\.leaves)
        for k in StemKind.drumParts { XCTAssertTrue(leaves.contains(k), "\(k) lost its fader") }
    }

    // MARK: Safe seeking (T09)

    /// Under a finger only the drawn playhead moves; the engine gets one seek, on release.
    func testAScrubMovesOnlyThePlayheadUntilRelease() {
        let m = makeModel()
        var r = record()
        r.id = "t09-scrub"
        m.song = r
        defer { m.song = nil; SongStore.shared.delete(r.id) }
        let sr = m.engine.sampleRate
        let silence = [Float](repeating: 0, count: Int(10 * sr))
        m.engine.load(stems: [StereoAudio(left: silence, right: silence, sampleRate: sr)], pitchLocked: [false])
        m.beginScrub(2)
        m.updateScrub(5)
        m.updateScrub(7)
        XCTAssertTrue(m.isScrubbing)
        XCTAssertEqual(m.clock.sample().time, 7, accuracy: 1e-9, "the drawn playhead is at the finger")
        XCTAssertEqual(m.engine.status.position, 0, "the engine has not been asked to seek yet")
        m.endScrub(8)
        XCTAssertFalse(m.isScrubbing)
        XCTAssertEqual(m.position, 8, accuracy: 1e-9)
        XCTAssertEqual(m.engine.status.position, Int64(8 * sr), "one seek, to where the finger let go")
    }

    // MARK: Scrubbing on the Mac (UIP-01)

    /// The Mac draws the playhead, the time and the part rows from `position`: during a drag the ticker must
    /// move it to the pointer, or everything stays at the press point until release.
    func testTheTickerFollowsAScrub() {
        let m = makeModel()
        var r = record()
        r.id = "uip01-scrub"
        m.song = r
        defer { m.song = nil; SongStore.shared.delete(r.id) }
        m.beginScrub(10)
        m.updateScrub(30)
        m.tickForTesting()
        XCTAssertEqual(m.position, 30, accuracy: 1e-9, "the playhead is at the pointer")
        XCTAssertTrue(m.showsScrubTime)
        XCTAssertEqual(m.engine.status.position, 0, "still one seek per gesture: the engine waits for the release")
        m.endScrub(30)
        m.tickForTesting()
        XCTAssertEqual(m.position, 30, accuracy: 1e-9, "the engine takes over after the release")
        XCTAssertFalse(m.showsScrubTime)
    }

    // MARK: One settings write per action (paritymac WP1)

    /// T10: drawing or resizing a loop on the Map previews in the engine and writes the settings once, on release.
    func testALoopGestureWritesTheSettingsOnce() {
        let m = makeModel()
        var r = record()
        r.id = "t10-loop"
        m.song = r
        defer { m.song = nil; SongStore.shared.delete(r.id) }
        let before = m.settingsChangeCount
        m.previewLoop(2...4)
        m.previewLoop(2...5)
        m.previewLoop(2...6)
        XCTAssertEqual(m.settingsChangeCount, before, "previews never touch the settings")
        m.commitLoop(2...6, seekToStart: true)
        XCTAssertEqual(m.settingsChangeCount - before, 1, "one write per gesture")
        XCTAssertEqual(m.loopRange, 2...6)
        XCTAssertEqual(m.position, 2, accuracy: 1e-9, "a new loop starts from its beginning")
    }

    /// One click or one drag event used to write the settings three times, and every write runs the engine
    /// pushes, the save timer and every view that reads the settings.
    func testLoopActionsWriteTheSettingsOnce() throws {
        let m = makeModel()
        var r = record()
        r.id = "t05-once"
        m.song = r
        defer { m.song = nil; SongStore.shared.delete(r.id) }
        let section = try XCTUnwrap(r.analysis.sections.first)

        var before = m.settingsChangeCount
        m.loopSection(section)
        XCTAssertEqual(m.settingsChangeCount - before, 1, "loopSection")
        XCTAssertEqual(m.loopRange, section.start...section.end)
        XCTAssertTrue(m.settings.loopEnabled)

        before = m.settingsChangeCount
        m.setLoop(start: 2, end: 6)
        XCTAssertEqual(m.settingsChangeCount - before, 1, "setLoop")
        XCTAssertEqual(m.loopRange, 2...6)

        before = m.settingsChangeCount
        m.setLoop(start: 2, end: 6)
        XCTAssertEqual(m.settingsChangeCount - before, 0, "an unchanged loop writes nothing")

        m.choosePlaying(.vocals)
        before = m.settingsChangeCount
        m.hearAll()
        XCTAssertEqual(m.settingsChangeCount - before, 1, "Hear all")
        XCTAssertTrue(m.settings.removed.isEmpty)

        before = m.settingsChangeCount
        m.toggleLoop()
        XCTAssertEqual(m.settingsChangeCount - before, 1, "toggleLoop")
        XCTAssertFalse(m.settings.loopEnabled)
    }

    /// The trainer needs a loop: turning it on starts one, in the same single write. Speed resets write once.
    func testTheTrainerStartsALoopAndResetsWriteOnce() {
        let m = makeModel()
        var r = record()
        r.id = "wp1-trainer"
        m.song = r
        defer { m.song = nil; SongStore.shared.delete(r.id) }
        m.settings.mode = .play
        m.seek(to: 18)
        var before = m.settingsChangeCount
        m.setTrainer(true)
        XCTAssertEqual(m.settingsChangeCount - before, 1, "setTrainer")
        XCTAssertTrue(m.settings.trainer.enabled)
        XCTAssertTrue(m.settings.loopEnabled, "the trainer starts a loop")
        XCTAssertEqual(m.loopRange, 16...24, "the section under the playhead")

        m.stepSpeed(-2)
        XCTAssertFalse(m.settings.trainer.enabled, "a speed step stops the trainer")
        XCTAssertEqual(m.settings.speed, 90)
        m.stepPitch(2)
        before = m.settingsChangeCount
        m.resetSpeedAndPitch()
        XCTAssertEqual(m.settingsChangeCount - before, 1, "resetSpeedAndPitch")
        XCTAssertEqual(m.settings.speed, 100)
        XCTAssertEqual(m.settings.pitch, 0)
    }

    func testChoosingAPartRemovesOnlyThatPartAndTogglesBack() {
        let m = makeModel()
        m.song = record()
        m.settings = SongSettings()
        m.choosePlaying(.guitar)
        XCTAssertEqual(m.settings.removed, [.guitar])
        XCTAssertEqual(m.playingStem, .guitar)
        m.choosePlaying(.guitar)
        XCTAssertTrue(m.settings.removed.isEmpty)
        m.song = nil
    }

    func testBarLoopsSnapToBarLines() {
        let m = makeModel()
        // setMode remembers the mode for the next song: later tests expect to open in Play.
        defer { m.appMode = .play }
        m.song = record()
        m.settings = SongSettings()
        m.setMode(.beats)
        m.seek(to: 5.2)                       // inside the bar that starts at 4 s
        m.loopBars(2)
        XCTAssertEqual(m.loopRange?.lowerBound ?? -1, 4, accuracy: 0.001)
        XCTAssertEqual(m.loopRange?.upperBound ?? -1, 8, accuracy: 0.001)
        XCTAssertEqual(m.loopBarCount, 2)
        m.loopBars(2)                         // the same loop again turns it off
        XCTAssertFalse(m.settings.loopEnabled)
        m.song = nil
    }

    // MARK: Background passes

    /// Bachata dancers need the güira (the kit's hi-hat part). The cleaner pass takes minutes, so the kit is
    /// split from the fast drums first whenever the screen shows kit parts, and only then cleaned.
    func testTheKitGoesBeforeTheCleanerPassWhenTheScreenNeedsIt() throws {
        let fm = FileManager.default
        let folder = ModelStore.directory.appendingPathComponent("\(DrumSeparator.modelName).mlmodelc", isDirectory: true)
        let marker = ModelStore.directory.appendingPathComponent("\(DrumSeparator.modelName).sha256")
        if fm.fileExists(atPath: folder.path) { throw XCTSkip("a real kit model is installed in this container") }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try "test".write(to: marker, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: folder); try? fm.removeItem(at: marker) }

        let m = makeModel()
        var r = record()
        r.id = "kit-first"
        m.song = r
        // Settings changes save the open song to the test container's library: leave nothing behind.
        defer { m.song = nil; SongStore.shared.delete(r.id) }
        m.settings.mode = .dance
        m.settings.danceStyle = .bachata
        XCTAssertTrue(m.kitGoesFirst, "bachata shows the güira: split the kit first")
        XCTAssertEqual(StemKind.hats.label(in: .dance, style: .bachata), "Güira")

        m.settings.danceStyle = .salsa
        XCTAssertFalse(m.kitGoesFirst, "salsa shows no kit parts")
        m.settings.mode = .beats
        XCTAssertTrue(m.kitGoesFirst, "Beats shows the kit")

        m.drumSplitFailedFor = r.id
        XCTAssertFalse(m.kitGoesFirst, "a failed kit split must not hold up the cleaner pass")
        m.drumSplitFailedFor = nil
        m.song?.drumSplit = DrumSplit(method: "t", peaks: [:], scales: [:])
        XCTAssertFalse(m.kitGoesFirst, "a song that has its kit goes straight to the cleaner pass")
    }

    /// A half-copied or half-unpacked model folder must not count as installed: loading it fails, and the
    /// cleaner pass would start (and fail) on it. Only the marker, written last, makes it real.
    func testADownloadedModelCountsOnlyOnceItsMarkerExists() throws {
        let name = "FakeModel-\(UUID().uuidString)"
        let folder = ModelStore.directory.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
        let marker = ModelStore.directory.appendingPathComponent("\(name).sha256")
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: marker) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("weights"), withIntermediateDirectories: true)
        XCTAssertNil(ModelStore.url(name), "a folder without its marker is an unfinished install")
        try "abc".write(to: marker, atomically: true, encoding: .utf8)
        XCTAssertEqual(ModelStore.url(name)?.lastPathComponent, "\(name).mlmodelc")
    }

    // MARK: Library on disk

    func testSongStoreRoundTripAndInterruptedSwap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)/Songs", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = SongStore(root: root)
        var rec = record(stems: [.vocals, .other])
        rec.id = "abc"
        try store.save(rec)
        let tone = StereoAudio(left: (0..<44_100).map { Float(0.4 * sin(Double($0) * 0.05)) },
                               right: (0..<44_100).map { Float(0.3 * sin(Double($0) * 0.07)) }, sampleRate: 44_100)
        for k in rec.stems { try store.writeStem(tone, to: store.stemURL(rec.id, k)) }
        let loaded = store.loadAll()
        XCTAssertEqual(loaded.map(\.id), ["abc"])
        let back = try store.readAudio(store.stemURL("abc", .vocals))
        XCTAssertEqual(back.frameCount, tone.frameCount)
        let err = zip(back.left, tone.left).map { abs($0 - $1) }.max() ?? 1
        XCTAssertLessThan(err, 1.0 / 16_384, "16-bit lossless storage")

        // A swap interrupted after the live folder was set aside: the next launch puts it back.
        let staging = store.staging
        try FileManager.default.createDirectory(at: staging.root, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: store.folder("abc"), to: staging.root.appendingPathComponent("abc-old"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder("abc").path))
        XCTAssertEqual(store.loadAll().map(\.id), ["abc"], "loading the library puts the set-aside folder back")

        // The other half of a swap: the live folder is in place but the set-aside copy is still there. It must
        // not be thrown away while the live song is unreadable, and must be swept once it is readable again.
        let leftover = staging.root.appendingPathComponent("abc-old")
        try FileManager.default.moveItem(at: store.folder("abc"), to: leftover)
        try FileManager.default.createDirectory(at: store.folder("abc"), withIntermediateDirectories: true)
        _ = store.loadAll()
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftover.appendingPathComponent("song.json").path),
                      "an unreadable song keeps its complete set-aside copy")
        try store.save(rec)
        _ = store.loadAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path),
                       "a readable song's leftover copy is cleared")
    }

    /// Deleting a song takes its leftover copy and its cleaner checkpoint with it: either is a whole song's
    /// worth of disk.
    func testDeletingASongClearsItsStagingLeftovers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)/Songs", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = SongStore(root: root)
        var rec = record(stems: [.vocals, .other])
        rec.id = "gone-\(UUID().uuidString)"
        try store.save(rec)
        try FileManager.default.createDirectory(at: store.staging.root, withIntermediateDirectories: true)
        let leftover = store.staging.root.appendingPathComponent(rec.id + "-old")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        let checkpoint = CleanerPartsJob.checkpointDirectory(rec.id)
        try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: true)
        store.delete(rec.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.path), "the cleaner pass's checkpoint goes too")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(rec.id).path))
    }

    /// Only Backline's own recordings and downloads are deleted after a split: a real path prefix, not a
    /// name that merely contains "/Backline/Recordings/".
    func testOwnedFilesAreOnlyOursToDelete() {
        let mine = ImportStaging.recordingsDirectory.appendingPathComponent("x.wav")
        XCTAssertTrue(ImportStaging.isOwned(mine))
        XCTAssertTrue(ImportStaging.isOwned(ImportStaging.downloadsDirectory.appendingPathComponent("y.m4a")))
        XCTAssertFalse(ImportStaging.isOwned(URL(fileURLWithPath: "/Volumes/Music/Backline/Recordings/take.wav")),
                       "the person's own folder of the same name")
        XCTAssertFalse(ImportStaging.isOwned(ImportStaging.recordingsDirectory))   // the folder itself
    }

    func testStagedFileNamesShowNoInternalPrefix() {
        let staged = URL(fileURLWithPath: "/x/8755B6C6-6F83-4881-998D-0B4E0A3970F8-Neon_Lights.mp3")
        XCTAssertEqual(ImportStaging.displayName(for: staged), "Neon Lights")
        XCTAssertEqual(ImportStaging.displayName(for: URL(fileURLWithPath: "/x/My_Song.wav")), "My Song")
        XCTAssertEqual(ImportStaging.displayName(for: URL(fileURLWithPath: "/x/1234-abcd.mp3")), "1234-abcd")
    }

    /// "Not now" closes the failure: back to the open song, or to the start screen when there is none.
    func testNotNowClosesTheFailure() {
        let m = makeModel()
        XCTAssertNil(m.song)
        m.screen = .failed("x")
        m.dismissFailure()
        XCTAssertEqual(m.screen, .empty)
    }

    // MARK: Fader and names

    func testFaderCurve() {
        XCTAssertEqual(AppModel.gain(forVolume: 0), 0)
        XCTAssertEqual(AppModel.gain(forVolume: 80), 1, accuracy: 1e-4)
        XCTAssertEqual(AppModel.gain(forVolume: 100), pow(10, 6.0 / 20), accuracy: 1e-3)   // +6 dB
    }
}
