import BacklineKit
import XCTest
@testable import Backline

/// The link import's screen while a video downloads (links L8), with the download stood in for: the video's
/// title shows before the audio is down, and a link pasted straight after Cancel is not covered by the old
/// download's ending.
@MainActor
final class LinkImportTests: XCTestCase {
    /// As in AppLogicTests: the model lives for the whole process.
    private static var keepAlive: [AppModel] = []
    /// Waits for the launch read of the Library (UIP-05, off the main thread): until then a link waits for it.
    private func makeModel() async -> AppModel {
        let m = AppModel()
        Self.keepAlive.append(m)
        await m.libraryReady()
        return m
    }

    override func tearDown() {
        AppModel.youTubeDownloadForTesting = nil
        super.tearDown()
    }

    /// Ids no library holds, so the import isn't answered by reopening a song.
    private let first = YouTubeLink.parse("https://youtu.be/AAAAAAAAAAA")!
    private let second = YouTubeLink.parse("https://youtu.be/BBBBBBBBBBB")!

    private func waitUntil(_ what: String, timeout: Double = 3, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Sleeps on another queue, so a cancelled task still waits (like a download that takes a moment to stop).
    nonisolated private static func pause(_ seconds: Double) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { c.resume() }
        }
    }

    nonisolated private static func untilCancelled(_ isCancelled: @Sendable () -> Bool) async {
        while !isCancelled() { await pause(0.02) }
    }

    func testTheVideoTitleShowsWhileTheAudioDownloads() async throws {
        let m = await makeModel()
        AppModel.youTubeDownloadForTesting = { _, onMetadata, isCancelled in
            onMetadata("Volatile Reaction", "Kevin MacLeod")
            await Self.untilCancelled(isCancelled)
            throw CancellationError()
        }
        m.openYouTube(first)
        XCTAssertEqual(m.screen, .analyzing)
        try await waitUntil("the title") { m.importTitle == "Volatile Reaction" }
        XCTAssertEqual(m.importArtist, "Kevin MacLeod")
        XCTAssertTrue(m.downloadingFromYouTube, "the title arrives while the audio is still downloading")
        m.cancelImport()
        try await waitUntil("the start screen") { m.screen == .empty }
        XCTAssertFalse(m.downloadingFromYouTube)
    }

    func testALinkPastedRightAfterCancelIsNotCoveredByTheOldOne() async throws {
        let m = await makeModel()
        let firstID = first.id
        AppModel.youTubeDownloadForTesting = { video, onMetadata, isCancelled in
            if video.id == firstID {
                // The old download stops slowly, then fails the way a killed download did.
                await Self.untilCancelled(isCancelled)
                await Self.pause(0.3)
                throw YouTubeImport.Failure.failed("Nothing came back. Record it instead.")
            }
            onMetadata("Second song", nil)
            await Self.untilCancelled(isCancelled)
            throw CancellationError()
        }
        m.openYouTube(first)
        try await Task.sleep(for: .milliseconds(100))
        m.cancelImport()
        m.openYouTube(second)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(m.screen, .analyzing, "the new link's download is still on screen")
        XCTAssertTrue(m.downloadingFromYouTube)
        XCTAssertEqual(m.importTitle, "Second song")
        m.cancelImport()
        try await waitUntil("the start screen") { m.screen == .empty }
    }

    func testAFailedDownloadShowsTheFailure() async throws {
        let m = await makeModel()
        AppModel.youTubeDownloadForTesting = { _, _, _ in throw YouTubeImport.Failure.failed("Video not available.") }
        m.openYouTube(first)
        try await waitUntil("the failure") { m.screen == .failed("Video not available.") }
        XCTAssertFalse(m.downloadingFromYouTube)
    }

    // MARK: paritymac WP2: every link gets an answer (ported from iOS AppLogicTests where they exist there)

    func testTheLinkFieldTakesAnyWebLink() {
        XCTAssertNotNil(LinkField.link(in: "https://youtu.be/zpzdgmqIHOQ?si=ua9Hg8NTG57YZUv9"))
        XCTAssertNotNil(LinkField.link(in: "Watch this https://www.youtube.com/watch?v=dQw4w9WgXcQ"), "a link inside shared text")
        XCTAssertEqual(LinkField.link(in: " https://vimeo.com/channels/musicvideos/926983242 \n"),
                       "https://vimeo.com/channels/musicvideos/926983242")
        XCTAssertEqual(LinkField.link(in: "soundcloud.com/artist/song"), "https://soundcloud.com/artist/song", "no scheme")
        XCTAssertNotNil(LinkField.link(in: "http://192.168.1.4:8000/song.mp3"))
        XCTAssertNil(LinkField.link(in: ""))
        XCTAssertNil(LinkField.link(in: "my favourite song"))
        XCTAssertNil(LinkField.link(in: "hello"))
        XCTAssertNil(LinkField.link(in: "ftp://example.com/song.mp3"))
        XCTAssertNil(LinkField.link(in: "file:///tmp/song.mp3"))
    }

    /// The Getting-the-song line: what the link is doing, never a service's name.
    func testTheGettingTheSongLine() {
        func p(_ f: Double, _ s: Double?) -> ImportProgress { ImportProgress(phase: 2, fraction: f, secondsRemaining: s) }
        XCTAssertEqual(AnalyzingView.eta(p(0, nil), getting: true), "Connecting…")
        XCTAssertEqual(AnalyzingView.eta(p(0.3, nil), getting: true), "Downloading…")
        XCTAssertEqual(AnalyzingView.eta(p(0, nil), getting: true, finding: true), "Finding the song…")
        XCTAssertEqual(AnalyzingView.eta(p(0, nil), getting: true, finding: true, anotherWay: true), "Trying another way…")
        XCTAssertNil(AnalyzingView.eta(p(0.3, nil), getting: false), "no estimate yet: nothing")
        XCTAssertNil(AnalyzingView.eta(p(0.04, 40), getting: false), "too early to trust the estimate")
        XCTAssertEqual(AnalyzingView.eta(p(0.42, 39.2), getting: false), "about 40 seconds left")
    }

    /// A failed split offers Try again; a failed link offers signing in (never forced) unless offline or already
    /// signed in; a song on a music service that wasn't found offers recording it instead.
    func testTheFailureScreenOffersTheRightWayOut() {
        let split = FailureView.content(message: "Can't read this file.", fromLink: false, canSignIn: true)
        XCTAssertEqual(split.title, "Couldn't split it")
        XCTAssertEqual(split.line, "Can't read this file.")
        XCTAssertEqual([split.primary, split.secondary], [.tryAgain, .anotherSong])

        let link = FailureView.content(message: YouTubeExtractor.genericMessage, fromLink: true, canSignIn: true)
        XCTAssertEqual(link.title, "Couldn't get it")
        XCTAssertEqual(link.line, "Signing in to Google can help.")
        XCTAssertEqual([link.primary, link.secondary], [.signIn, .notNow])

        let gated = FailureView.content(message: YouTubeImport.signInMessage, fromLink: true, canSignIn: true)
        XCTAssertEqual(gated.title, "Sign in to get this one")
        XCTAssertEqual([gated.primary, gated.secondary], [.signIn, .notNow])

        let offline = FailureView.content(message: YouTubeExtractor.networkMessage, fromLink: true, canSignIn: true)
        XCTAssertEqual([offline.primary, offline.secondary], [.tryAgain, .notNow], "signing in can't fix no internet")

        let signedIn = FailureView.content(message: YouTubeExtractor.genericMessage, fromLink: true, canSignIn: false)
        XCTAssertEqual([signedIn.primary, signedIn.secondary], [.tryAgain, .recordInstead])

        let notFound = FailureView.content(message: SpotifyImport.noMatchMessage, fromLink: true, canSignIn: true)
        XCTAssertEqual(notFound.title, "Couldn't find it")
        XCTAssertEqual(notFound.line, "Record it while it plays.", "says what to do, not the title again (iOS iosux F9)")
        XCTAssertEqual([notFound.primary, notFound.secondary], [.recordInstead, .notNow])

        for reason in [DeviceLimits.tooLongMessage(seconds: 1200), "Live streams can't be split.", YouTubeExtractor.unavailableMessage] {
            let known = FailureView.content(message: reason, fromLink: true, canSignIn: true)
            XCTAssertEqual(known.line, reason)
            XCTAssertEqual([known.primary, known.secondary], [.tryAgain, .recordInstead], reason)
        }
    }

    /// "Not now" closes the failure: back to the start screen when no song is open.
    func testNotNowClosesTheFailure() async {
        let m = await makeModel()
        XCTAssertNil(m.song)
        m.screen = .failed("x")
        m.dismissFailure()
        XCTAssertEqual(m.screen, .empty)
    }

    /// Before 1.1 the Mac took YouTube links only and did nothing with the rest. Now a page that has no song says
    /// so (the caller's toast), and an artist or podcast link says what to do instead.
    func testEveryLinkGetsAnAnswer() async {
        let m = await makeModel()
        XCTAssertFalse(m.openText("https://example.com/about"), "a web page: the caller says it can't get a song")
        XCTAssertFalse(m.openText("my favourite song"))
        XCTAssertEqual(m.screen, .empty)

        XCTAssertTrue(m.openText("https://open.spotify.com/artist/0LcJLqbBmaGUft1e9Mm8HV"))
        XCTAssertEqual(m.screen, .empty, "nothing to split: the screen stays")
        XCTAssertEqual(m.toast?.text, "Pick a song, album or playlist.")
        XCTAssertTrue(m.toast?.isError == true)

        XCTAssertTrue(m.openText("https://open.spotify.com/show/5CfCWKI5pZ28U0uOzXkDHe"))
        XCTAssertEqual(m.toast?.text, "Podcasts can't be added.")
    }

    /// A music-service link shows "Finding the song…" at once, and Cancel puts the start screen back with nothing
    /// fetched (the lookup checks Cancel before its first request).
    func testCancelWhileFindingTheSong() async throws {
        let m = await makeModel()
        XCTAssertTrue(m.openText("Listen: https://open.spotify.com/track/558kPt5dAK4XskceUBSnqi?si=abc"))
        XCTAssertEqual(m.screen, .analyzing)
        XCTAssertTrue(m.spotify.finding)
        XCTAssertTrue(m.downloadingFromYouTube)
        XCTAssertNil(m.lastYouTube)
        m.cancelImport()
        XCTAssertEqual(m.screen, .empty)
        XCTAssertFalse(m.spotify.finding)
        XCTAssertFalse(m.downloadingFromYouTube)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(m.screen, .empty, "the cancelled lookup changes nothing when it ends")
        XCTAssertNil(m.spotify.ask)
        XCTAssertNil(m.spotify.picker)
    }

    /// Try again opens the same kind of link again: a file link downloads again, a Vimeo link fetches again.
    func testTryAgainReopensTheLastLink() async {
        let m = await makeModel()
        let file = URL(string: "https://stub.invalid/song.mp3")!
        m.lastLink = .file(file)
        m.lastYouTube = nil
        m.lastImportURL = nil
        m.retryImport()
        XCTAssertEqual(m.screen, .analyzing)
        XCTAssertEqual(m.lastLink, .file(file))
        XCTAssertEqual(m.importTitle, "song")
        m.cancelImport()
    }

    /// The song service is never called by a test, and the failure path stays the old one when it is off.
    func testTheSongServiceIsOffSoAFailureIsShownAsItIs() async throws {
        XCTAssertFalse(SongService.isEnabled)
        let m = await makeModel()
        AppModel.youTubeDownloadForTesting = { _, _, _ in throw YouTubeImport.Failure.failed(YouTubeExtractor.genericMessage) }
        m.openYouTube(first)
        try await waitUntil("the failure") { m.screen == .failed(YouTubeExtractor.genericMessage) }
        XCTAssertFalse(m.tryingAnotherWay)
    }
}
