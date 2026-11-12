import AVFoundation
import BacklineKit
import XCTest
@testable import Backline

/// S01–S04, against the real services. Every test here needs internet and a reachable music service and
/// YouTube; skip them with `TEST_RUNNER_BACKLINE_SKIP_NETWORK_TESTS=1 xcodebuild … test` (the TEST_RUNNER_
/// prefix passes it on). The song is Kevin MacLeod's "Volatile Reaction" (CC BY): a track with one artist,
/// a known length (165.355 s) and a matching upload, which is why the plan uses it.
@MainActor
final class SpotifyLinkTests: XCTestCase {
    /// `open.spotify.com/track/558kPt5dAK4XskceUBSnqi`.
    static let ccTrack = SpotifyLink(kind: .track, id: "558kPt5dAK4XskceUBSnqi")
    static let ccSeconds = 165.355
    /// A real short link, shared from the service's own app (someone else's song: only its shape matters).
    static let shortLink = URL(string: "https://spotify.link/hRkBrwub9xb")!

    private func requireNetwork() throws {
        if ProcessInfo.processInfo.environment["BACKLINE_SKIP_NETWORK_TESTS"] != nil {
            throw XCTSkip("BACKLINE_SKIP_NETWORK_TESTS is set")
        }
    }

    // MARK: S02 reading the song

    func testReadsTheSongFromTheEmbedPage() async throws {
        try requireNetwork()
        let found = try await SpotifyImport.read(Self.ccTrack)
        guard case .song(let song) = found else { return XCTFail("a track link should give one song, got \(found)") }
        XCTAssertEqual(song.title, "Volatile Reaction")
        XCTAssertEqual(song.artists, ["Kevin MacLeod"])
        XCTAssertEqual(song.seconds, Self.ccSeconds, accuracy: 0.001)
        XCTAssertEqual(song.id, Self.ccTrack.id)
        XCTAssertNotNil(song.artwork, "the cover the saved song keeps")
        let artwork = await SpotifyImport.artwork(try XCTUnwrap(song.artwork))
        XCTAssertNotNil(artwork)
        XCTAssertNotNil(NSImage(data: try XCTUnwrap(artwork)))
    }

    /// The fallback the plan keeps for the day the embed page changes shape.
    func testReadsTheSongFromTheLinkPreviewTags() async throws {
        try requireNetwork()
        let session = YouTubeExtractor.makeSession()
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: Self.ccTrack.pageURL)
        request.setValue(SpotifyImport.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let song = SpotifyPage.song(inOpenGraph: String(decoding: data, as: UTF8.self), id: Self.ccTrack.id)
        XCTAssertEqual(song?.title, "Volatile Reaction")
        XCTAssertEqual(song?.artists, ["Kevin MacLeod"])
        XCTAssertEqual(song?.seconds ?? 0, Self.ccSeconds, accuracy: 1, "whole seconds in the preview tags")
    }

    func testReadsAnAlbumsTracks() async throws {
        try requireNetwork()
        // Rick Astley, "Whenever You Need Somebody": 10 tracks (the plan's measurement).
        let found = try await SpotifyImport.read(SpotifyLink(kind: .album, id: "6N9PS4QXF1D0OWPk0Sxtb4"))
        guard case .list(let list) = found else { return XCTFail("an album link should give a track list, got \(found)") }
        XCTAssertEqual(list.tracks.count, 10)
        XCTAssertEqual(list.tracks.first?.title, "Never Gonna Give You Up")
        XCTAssertTrue(list.tracks.allSatisfy { $0.seconds > 0 && !$0.id.isEmpty })
    }

    func testAPlaylistStopsAtAHundredTracks() async throws {
        try requireNetwork()
        // The plan's 117-track playlist returned 100.
        let found = try await SpotifyImport.read(SpotifyLink(kind: .playlist, id: "7gL7aSlx7910WAXJCUh0Su"))
        guard case .list(let list) = found else { return XCTFail("a playlist link should give a track list, got \(found)") }
        XCTAssertEqual(list.tracks.count, 100)
    }

    /// S01, the one thing the plan could not verify: a real short link resolves to the song it stands for.
    func testAShortLinkResolves() async throws {
        try requireNetwork()
        let link = try await SpotifyImport.resolve(Self.shortLink)
        XCTAssertEqual(link.kind, .track)
        XCTAssertTrue(SpotifyLink.isID(link.id), "a 22-character id, not a short code: \(link.id)")
        let found = try await SpotifyImport.read(link)
        guard case .song(let song) = found else { return XCTFail("the song behind the short link, got \(found)") }
        XCTAssertFalse(song.title.isEmpty)
        XCTAssertGreaterThan(song.seconds, 0)
    }

    // MARK: S03 finding the same recording

    /// The plan's acceptance: the CC track finds a recording within 3 s. On 5 November that was
    /// `lfAiVYhL8SY` (0.6 s off); the id is not asserted, because YouTube's results change.
    func testFindsTheSameRecordingWithinThreeSeconds() async throws {
        try requireNetwork()
        guard case .song(let song) = try await SpotifyImport.read(Self.ccTrack) else { return XCTFail("no song") }
        let outcome = try await SongSearch.find(song, region: "US")
        XCTAssertEqual(outcome.result.verdict, .match, "ranked: \(outcome.result.ranked)")
        let best = try XCTUnwrap(outcome.result.best)
        XCTAssertLessThanOrEqual(best.gap, 3)
        XCTAssertEqual(best.candidate.source, .music, "the music search carries this one")
        XCTAssertFalse(best.candidate.videoID.isEmpty)
        print("[spotify] US pick \(best.candidate.videoID) \"\(best.candidate.title)\" by \"\(best.candidate.by)\", "
              + String(format: "%.1f", best.gap) + " s off")
    }

    /// The device's region is passed on; the plan measured the same results in US and AU.
    func testTheRegionIsPassedOnAndFindsTheSameRecording() async throws {
        try requireNetwork()
        guard case .song(let song) = try await SpotifyImport.read(Self.ccTrack) else { return XCTFail("no song") }
        let outcome = try await SongSearch.find(song, region: "AU")
        XCTAssertEqual(outcome.result.verdict, .match)
        XCTAssertLessThanOrEqual(try XCTUnwrap(outcome.result.best).gap, 3)
        XCTAssertFalse(SongSearch.region.isEmpty, "the device's own region is a two-letter code")
    }

    /// The recording the matcher picked really is the song: it downloads and decodes to the same length.
    func testTheMatchedRecordingDownloadsAndIsTheSameLength() async throws {
        try requireNetwork()
        guard case .song(let song) = try await SpotifyImport.read(Self.ccTrack) else { return XCTFail("no song") }
        let outcome = try await SongSearch.find(song, region: "US")
        let best = try XCTUnwrap(outcome.result.best)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spotify-live-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = try XCTUnwrap(YouTubeImport.parse("https://www.youtube.com/watch?v=\(best.candidate.videoID)"))
        let result = try await YouTubeImport.download(video, jar: .none, into: dir, progress: { _ in }, isCancelled: { false })
        let audio = try AVAudioFile(forReading: result.file)
        XCTAssertEqual(Double(audio.length) / audio.processingFormat.sampleRate, song.seconds, accuracy: 3.5,
                       "the downloaded recording is as long as the song the link named")
    }

    // MARK: S04 the import, end to end

    /// The app model lives for the whole process; deallocating one trips a Swift runtime bug in isolated
    /// deinit, so tests keep theirs alive (as `AppLogicTests` does).
    private static var keepAlive: [AppModel] = []

    /// Paste the link, get the song: the whole way through the real services, the real download and a real
    /// split, and the saved song keeps the service's title, artist, cover and `spotify:<id>` source.
    func testImportsTheCCTrackEndToEnd() async throws {
        try requireNetwork()
        let model = AppModel()
        Self.keepAlive.append(model)
        await model.libraryReady()          // launch reads the Library off the main thread (UIP-05)
        let source = Self.ccTrack.sourceName
        // A song left by an earlier run would be reopened instead of imported.
        for existing in model.library where existing.sourceName == source { model.remove(existing) }
        let started = Date()
        XCTAssertTrue(model.openText("Check out this song on Spotify: \(Self.ccTrack.pageURL.absoluteString)?si=abc"),
                      "a shared sentence is a link Backline takes")
        XCTAssertEqual(model.screen, .analyzing)
        XCTAssertTrue(model.spotify.finding, "“Finding the song…” until the recording is found")

        // The service's own title and artist show before the download starts.
        try await until(60, "the song's name") { model.importTitle == "Volatile Reaction" }
        XCTAssertEqual(model.importArtist, "Kevin MacLeod")
        try await until(60, "a match") { !model.spotify.finding }
        XCTAssertNil(model.spotify.ask, "this one is well within 3 s: nothing to ask")
        XCTAssertNotNil(model.spotify.matched)
        XCTAssertNotNil(model.lastYouTube, "the recording was handed to the YouTube engine")

        try await until(900, "the split to finish") { model.screen == .mixer }
        let song = try XCTUnwrap(model.song)
        XCTAssertEqual(song.title, "Volatile Reaction")
        XCTAssertEqual(song.artist, "Kevin MacLeod")
        XCTAssertEqual(song.sourceName, source, "the song's source is the music-service link, not the video")
        XCTAssertTrue(song.hasArtwork, "the cover came from the service")
        XCTAssertEqual(song.duration, Self.ccSeconds, accuracy: 4)
        XCTAssertTrue(model.library.contains { $0.id == song.id })
        print("[spotify] end to end in \(Int(Date().timeIntervalSince(started))) s: \(song.stems.count) parts")

        // The same link again opens the song that is already there instead of importing it twice.
        model.screen = .empty
        XCTAssertTrue(model.openText(Self.ccTrack.pageURL.absoluteString))
        XCTAssertEqual(model.screen, .mixer, "a song already in the library opens at once")
        XCTAssertEqual(model.song?.id, song.id)
        model.remove(song)
    }

    private struct TimedOut: Error { let what: String }

    private func until(_ seconds: Double, _ what: String, file: StaticString = #filePath, line: UInt = #line,
                       _ done: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() {
            if Date() > deadline {
                XCTFail("waited \(Int(seconds)) s for \(what)", file: file, line: line)
                throw TimedOut(what: what)
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }
}
