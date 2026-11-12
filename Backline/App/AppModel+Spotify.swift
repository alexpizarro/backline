import AppKit
import BacklineKit
import SwiftUI

// Ported from iOS `Backline/App/AppModel+Spotify.swift` (paritymac WP2). The differences are the Mac's: the cover is
// an `NSImage`, there are no haptics, no full-screen player to expand and no screen to keep awake, and a sheet's
// answer waits for the sheet to go before the next one comes (`afterSheet`).

/// Title, artist, artwork and source for a song whose details came from somewhere other than the video
/// (S04): the screens show these while the download runs, and the saved song keeps them.
nonisolated struct ImportMetadata: Sendable {
    var title: String
    var artist: String
    var artwork: Data?
    /// What the saved song's source says, e.g. `spotify:<id>`.
    var source: String
}

/// A link to a song on a music service, from the paste to the download (S04). The state lives here rather
/// than in `AppModel` so the flow is one file: what the Getting-the-song screen is waiting for, the sheet
/// that asks about a close-but-not-certain match, the other candidates behind "Wrong song?", and the
/// "Pick a song" sheet for an album or playlist.
@MainActor @Observable
final class SpotifyFlow {
    /// A match Backline is sure of: kept so "Wrong song?" can offer the next ones.
    struct Matched {
        var song: SpotifySong
        var result: SongMatcher.Result
    }

    /// 3 to 8 s apart: "Is this the song?".
    struct Ask: Identifiable {
        let id = UUID()
        var song: SpotifySong
        var result: SongMatcher.Result
        var choice: SongMatcher.Scored
    }

    /// The other candidates that passed the rules, plus "None of these".
    struct Others: Identifiable {
        let id = UUID()
        var song: SpotifySong
        var choices: [SongMatcher.Scored]
    }

    /// An album or playlist: one song at a time, as everywhere else in Backline.
    struct Picker: Identifiable {
        let id = UUID()
        var list: SpotifyTrackList
    }

    /// True from the paste until the recording is found: "Finding the song…" under the song's name.
    var finding = false
    var ask: Ask?
    var others: Others?
    var picker: Picker?
    var matched: Matched?

    /// The link to try again, and the song the download is for.
    @ObservationIgnored var link: SpotifyRef?
    @ObservationIgnored var song: SpotifySong?
    @ObservationIgnored var sourceName: String?
    /// True while this flow owns the Getting-the-song screen. Once the recording is handed to the YouTube
    /// engine it owns the screen, and its own cancel puts the player back where it was.
    @ObservationIgnored var owning = false
    /// Bumped by every lookup: late work (the cover, a finished search) changes nothing.
    @ObservationIgnored private(set) var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cancelBox = CancelBox()

    /// A new lookup: nothing from the last one is left on screen.
    func begin() -> (generation: Int, isCancelled: @Sendable () -> Bool) {
        task?.cancel()
        cancelBox.value = true
        generation += 1
        let box = CancelBox()
        cancelBox = box
        finding = true
        owning = true
        ask = nil
        others = nil
        picker = nil
        matched = nil
        song = nil
        return (generation, { box.value })
    }

    func run(_ work: @escaping @MainActor () async -> Void) {
        task = Task { await work() }
    }

    /// A fresh cancel check for new work on the same song (the song service after no match, or after "Wrong song?" →
    /// "None of these"). "Wrong song?" cancelled the last one, so reusing its check would stop this work at once;
    /// Cancel from here on stops the new one.
    func renewCancel() -> @Sendable () -> Bool {
        let box = CancelBox()
        cancelBox = box
        return { box.value }
    }

    /// Cancel, from the Getting-the-song screen's Cancel, a dismissed sheet or Reset Backline.
    func cancel() {
        cancelBox.value = true
        task?.cancel()
        task = nil
        finding = false
        ask = nil
        others = nil
        picker = nil
        matched = nil
        owning = false
    }

    /// Nothing is pending any more (the download has taken over, or it failed).
    func settle() {
        finding = false
        ask = nil
        others = nil
        picker = nil
        owning = false
    }

    /// Everything, including the link Try again would use (Reset Backline).
    func reset() {
        cancel()
        link = nil
        song = nil
        sourceName = nil
    }
}

extension AppModel {
    /// A link to a song, album or playlist on a music service → the song's name, artist and length from the
    /// service → the same recording on YouTube → the usual download and split.
    func openSpotify(_ ref: SpotifyRef) {
        guard !resetting, SpotifyImport.isEnabled else { return }
        // An artist, a show or an episode is recognised, and says what to do instead. A short link only
        // says which it is once it has been followed, so that one is refused further down.
        if case .link(let link) = ref, let toast = Self.spotifyRefusal(link.kind) {
            showToast(Toast(text: toast, isError: true))
            return
        }
        // Already in the library: open it instead of importing it twice.
        if case .link(let link) = ref, link.kind == .track,
           let existing = library.first(where: { $0.sourceName == link.sourceName }) {
            select(existing)
            return
        }
        lastYouTube = nil
        lastLink = .spotify(ref)
        lastImportURL = nil
        persistCurrent()
        stopPlayback()
        pauseBackgroundWork()
        // A link download still running ends quietly: its result is no longer wanted (links L8).
        cancelBox = CancelBox()
        // The screen shows the song's own name, artist and cover as soon as the service has said them.
        importTitle = ""
        importArtist = ""
        importArtwork = nil
        importArtworkOverride = nil
        importProgress = ImportProgress(phase: 0, fraction: 0, secondsRemaining: nil)
        downloadingFromYouTube = true
        spotify.link = ref
        let (generation, isCancelled) = spotify.begin()
        withAnimation(.smooth(duration: 0.35)) { screen = .analyzing }
        let epoch = ResetBackline.epoch
        spotify.run { [weak self] in
            let stop: @Sendable () -> Bool = { isCancelled() || !ResetBackline.isCurrent(epoch) }
            do {
                let link: SpotifyLink
                switch ref {
                case .link(let l): link = l
                case .short(let url): link = try await SpotifyImport.resolve(url, isCancelled: stop)
                }
                guard let self, self.spotify.generation == generation, ResetBackline.isCurrent(epoch) else { return }
                if let toast = Self.spotifyRefusal(link.kind) {
                    self.giveUpOnSpotify(toast: toast)
                    return
                }
                if link.kind == .track, let existing = self.library.first(where: { $0.sourceName == link.sourceName }) {
                    self.spotify.settle()
                    self.downloadingFromYouTube = false
                    self.select(existing)
                    return
                }
                let found = try await self.readSpotify(link, stop: stop)
                guard self.spotify.generation == generation, ResetBackline.isCurrent(epoch) else { return }
                switch found {
                case .list(let list):
                    // One song at a time: the sheet asks which, over the Getting-the-song screen.
                    self.spotify.picker = SpotifyFlow.Picker(list: list)
                case .song(let song):
                    self.spotify.song = song
                    self.spotify.sourceName = link.sourceName
                    self.importTitle = song.title
                    self.importArtist = song.artist
                    self.fetchSpotifyArtwork(song, generation: generation)
                    #if DEBUG
                    let stubbed = SpotifyStub.isActive
                    #else
                    let stubbed = false
                    #endif
                    // The download that follows needs visitor data: fetched beside the search, not after it (L11).
                    // A signed-in session takes its own, from the watch page, so there is nothing to fetch early for it.
                    let signedIn = YouTubeSignIn.isEnabled && YouTubeSignIn.isSignedIn
                    if YouTubeImport.isEnabled, !stubbed, !signedIn { YouTubeExtractor.prefetchVisitorData() }
                    let outcome = try await self.searchSpotify(song, stop: stop)
                    guard self.spotify.generation == generation, ResetBackline.isCurrent(epoch) else { return }
                    self.settleSpotify(song: song, result: outcome.result)
                }
            } catch is CancellationError {
                guard let self, self.spotify.generation == generation, ResetBackline.isCurrent(epoch) else { return }
                self.cancelSpotifyIfRunning()
            } catch {
                guard let self, self.spotify.generation == generation, ResetBackline.isCurrent(epoch) else { return }
                // The song is known but the search for its recording failed: the song service fetches by name, so a
                // search outage isn't a dead end (L3). Offline, nothing can help.
                if self.spotify.song != nil, Self.searchFailureTriesAnotherWay(error) {
                    self.rescueSpotifyOrFail(otherwise: error.localizedDescription)
                    return
                }
                self.failSpotify(error.localizedDescription)
            }
        }
    }

    /// A failed search the song service may get round: refused or rate-limited, or a request that didn't get
    /// through while the phone is online (L3).
    nonisolated static func searchFailureTriesAnotherWay(_ error: Error) -> Bool {
        guard let failure = error as? SpotifyImport.Failure else { return false }
        return failure == .searchFailed || failure == .network || failure == .unreadable
    }

    /// What to say about a link Backline can't split.
    static func spotifyRefusal(_ kind: SpotifyLink.Kind) -> String? {
        switch kind {
        case .artist: "Pick a song, album or playlist."
        case .show, .episode: "Podcasts can't be added."
        case .track, .album, .playlist: nil
        }
    }

    /// The verdict: download it, ask about it, or say it wasn't found. Nothing is ever guessed.
    private func settleSpotify(song: SpotifySong, result: SongMatcher.Result) {
        switch result.verdict {
        case .match:
            guard let best = result.best else { failSpotify(SpotifyImport.noMatchMessage); return }
            spotify.matched = SpotifyFlow.Matched(song: song, result: result)
            spotify.finding = false
            downloadSpotify(best.candidate)
        case .ask:
            guard let best = result.best else { failSpotify(SpotifyImport.noMatchMessage); return }
            spotify.ask = SpotifyFlow.Ask(song: song, result: result, choice: best)
        case .none:
            // Nothing passed the rules: the song service may know the song by its name.
            rescueSpotifyOrFail()
        }
    }

    /// Hands the recording to the YouTube engine, which already handles every download path, the
    /// proof-of-origin step and signing in. The song keeps the service's name, artist and cover.
    func downloadSpotify(_ candidate: SongCandidate) {
        guard let song = spotify.song, let video = YouTubeImport.parse("https://www.youtube.com/watch?v=\(candidate.videoID)") else {
            failSpotify(SpotifyImport.noMatchMessage)
            return
        }
        spotify.settle()
        #if DEBUG
        if SpotifyStub.isActive {
            // The stub stops here: the harness walks the screens without a download, and Cancel still
            // belongs to this flow.
            downloadingFromYouTube = true
            importProgress = ImportProgress(phase: 0, fraction: 0.1, secondsRemaining: nil)
            spotify.owning = true
            print("[harness] spotify-stub downloading \(candidate.videoID) for \"\(song.title)\"")
            return
        }
        #endif
        // From here the download owns the screen: its own cancel and failure handling take over.
        spotify.owning = false
        openYouTube(video, metadata: ImportMetadata(title: song.title, artist: song.artist,
                                                    artwork: importArtworkOverride,
                                                    source: spotify.sourceName ?? "spotify:\(song.id ?? "")"))
    }

    // MARK: The sheets

    /// "Use it" on "Is this the song?", or one of the other recordings: download that one.
    func useSpotifyCandidate(_ scored: SongMatcher.Scored, from result: SongMatcher.Result? = nil) {
        guard let song = spotify.song else { return }
        spotify.matched = SpotifyFlow.Matched(song: song, result: result ?? SongMatcher.Result(verdict: .match, ranked: [scored]))
        spotify.finding = false
        downloadSpotify(scored.candidate)
    }

    /// "Not this": the other candidates that passed the rules, or nothing found.
    func refuseSpotifyCandidate(_ ask: SpotifyFlow.Ask) {
        let others = ask.result.ranked.filter { $0.candidate.videoID != ask.choice.candidate.videoID }
        spotify.ask = nil
        guard !others.isEmpty else {
            rescueSpotifyOrFail()
            return
        }
        spotify.others = SpotifyFlow.Others(song: ask.song, choices: Array(others.prefix(3)))
    }

    /// "Wrong song?" on the Getting-the-song screen: stops the download and offers the next candidates.
    func showOtherSpotifyCandidates() {
        guard let matched = spotify.matched, !matched.result.others().isEmpty else { return }
        cancelImport()
        spotify.others = SpotifyFlow.Others(song: matched.song, choices: matched.result.others())
    }

    /// "None of these", or a dismissed "Is this the song?" sheet.
    func noSpotifyMatch() {
        spotify.others = nil
        spotify.ask = nil
        rescueSpotifyOrFail()
    }

    /// One click in "Pick a song": that track's own page is read, so the song keeps its own artists and cover.
    func pickSpotifyTrack(_ row: SpotifyTrackRow) {
        spotify.picker = nil
        openSpotify(.link(SpotifyLink(kind: .track, id: row.id)))
    }

    /// A sheet of this flow was closed with Cancel or Escape: nothing was chosen, so nothing is guessed. The same
    /// as Cancel on the Getting-the-song screen.
    func dismissSpotifySheet() {
        spotify.ask = nil
        spotify.others = nil
        spotify.picker = nil
        cancelSpotifyIfRunning()
    }

    /// A sheet's answer, once the sheet has gone: a Mac window shows one sheet at a time, so the next one (or the
    /// failure screen behind it) waits for this one to close.
    func afterSheet(_ action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { action() } }
    }

    // MARK: Ends

    /// Cancel while a music-service link is in flight (the screen's Cancel, Reset Backline, a sheet the
    /// person backed out of). Once the download has started it is the YouTube import's to cancel, and its
    /// own handler puts the screen back, so this leaves the screen alone.
    func cancelSpotifyIfRunning() {
        guard spotify.owning else { return }
        spotify.cancel()
        downloadingFromYouTube = false
        withAnimation(.smooth) { screen = song == nil ? .empty : .mixer }
    }

    /// A link Backline can't split: back where we were, with one line that says what to do instead.
    private func giveUpOnSpotify(toast: String) {
        spotify.settle()
        downloadingFromYouTube = false
        withAnimation(.smooth) { screen = song == nil ? .empty : .mixer }
        showToast(Toast(text: toast, isError: true))
    }

    /// "Couldn't find this song." (the song service is off, or it didn't have it either).
    func failSpotifyNoMatch() {
        failSpotify(SpotifyImport.noMatchMessage)
    }

    func failSpotify(_ message: String) {
        spotify.settle()
        downloadingFromYouTube = false
        withAnimation(.smooth) { screen = .failed(message) }
    }

    // MARK: The network, or the stub in a harness run

    private func readSpotify(_ link: SpotifyLink, stop: @escaping @Sendable () -> Bool) async throws -> SpotifyImport.Found {
        #if DEBUG
        if let found = SpotifyStub.found(for: link) { return found }
        #endif
        return try await SpotifyImport.read(link, isCancelled: stop)
    }

    private func searchSpotify(_ song: SpotifySong, stop: @escaping @Sendable () -> Bool) async throws -> SongSearch.Outcome {
        #if DEBUG
        if SpotifyStub.mode == "searchfail" { throw SpotifyImport.Failure.searchFailed }
        if let outcome = SpotifyStub.outcome(for: song) { return outcome }
        #endif
        return try await SongSearch.find(song, isCancelled: stop)
    }

    /// The cover, fetched beside the search so the screen fills in at once. Late is fine: the saved song
    /// reads it when the split finishes.
    private func fetchSpotifyArtwork(_ song: SpotifySong, generation: Int) {
        guard let url = song.artwork else { return }
        Task { [weak self] in
            guard let data = await SpotifyImport.artwork(url), let self, self.spotify.generation == generation else { return }
            self.importArtworkOverride = data
            // Decoded small, off the main thread (UIP-10).
            if let image = await Self.artworkImage(data), self.spotify.generation == generation { self.importArtwork = image }
        }
    }
}

#if DEBUG
/// `--spotify-stub match|ask|none|playlist|searchfail`: the whole lookup answered from memory, so the harness walks
/// each path without the network. The candidates still go through the real matching rules.
enum SpotifyStub {
    static var mode: String? {
        guard let i = CommandLine.arguments.firstIndex(of: "--spotify-stub"), i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }
    static var isActive: Bool { mode != nil }

    /// The Creative Commons track the live tests use (Kevin MacLeod, CC BY).
    static let song = SpotifySong(id: "558kPt5dAK4XskceUBSnqi", title: "Volatile Reaction",
                                  artists: ["Kevin MacLeod"], seconds: 165.355)

    static let list = SpotifyTrackList(name: "Gamers Hits vol.3", tracks: [
        SpotifyTrackRow(id: "558kPt5dAK4XskceUBSnqi", title: "Volatile Reaction", artists: ["Kevin MacLeod"], seconds: 165.355),
        SpotifyTrackRow(id: "1oHHUMRfLHQdAx0UlHNnOt", title: "Dirt Rhodes", artists: ["Kevin MacLeod"], seconds: 121),
        SpotifyTrackRow(id: "2sMLyeJMEMlSqlTPNbpLwK", title: "The Drive", artists: ["Kevin MacLeod"], seconds: 149),
    ])

    static func found(for link: SpotifyLink) -> SpotifyImport.Found? {
        guard let mode else { return nil }
        if link.kind.isList, mode == "playlist" { return .list(list) }
        // A song picked from the list is read like any other track link, so the clicked one is the one that
        // gets imported.
        if let row = list.tracks.first(where: { $0.id == link.id }), row.id != song.id {
            return .song(SpotifySong(id: row.id, title: row.title, artists: row.artists, seconds: row.seconds))
        }
        return .song(song)
    }

    /// Candidates measured from whichever song was picked, so a song from the list matches too.
    static func outcome(for song: SpotifySong) -> SongSearch.Outcome? {
        guard let mode else { return nil }
        let offsets: [Double]
        switch mode {
        case "ask": offsets = [5.6, 7.6]            // "Is this the song?"
        case "none": offsets = []
        default: offsets = [0.6, 1.6, 3.6]          // a match, with two more that passed the rules
        }
        let candidates = zip(["lfAiVYhL8SY", "QrPebFQd6uE", "AoW7FycMFsg"], offsets).map {
            SongCandidate(videoID: $0, title: song.title, by: song.artist, seconds: (song.seconds + $1).rounded(), source: .music)
        }
        return SongSearch.Outcome(result: SongMatcher.result(for: song, candidates: candidates), searchedVideos: false)
    }
}
#endif
