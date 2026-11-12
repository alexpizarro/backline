import BacklineKit
import Foundation

/// Reads a song from a link to a music service (S02). The service's streams are encrypted and Backline
/// never touches them: it reads the song's name, artist and length from the public page the service serves
/// to every link preview and embedded player, and `SongSearch` then finds the same recording on YouTube,
/// which the existing engine downloads. One page per link, on a session of its own that keeps no cookies
/// and no cache. Parsing lives in BacklineKit (`SpotifyPage`); this is the fetching.
nonisolated enum SpotifyImport {
    /// Kill switch (S04): when false a music-service link says "Can't get a song from this link.", as
    /// before 1.1.
    static let isEnabled = true

    /// A browser, because that is what these pages are for.
    static let userAgent = VimeoExtractor.userAgent
    static let timeout: TimeInterval = 20

    /// What a link turned out to hold: one song, or a list to pick from.
    enum Found: Sendable, Equatable {
        case song(SpotifySong)
        case list(SpotifyTrackList)
    }

    enum Failure: LocalizedError, Equatable {
        /// The page didn't say what the song is (the service changed it, or the link is gone).
        case unreadable
        /// Nothing on YouTube passed the matching rules.
        case noMatch
        /// The search for the recording was refused or rate-limited (what a bot wall looks like, L3).
        case searchFailed
        /// A request didn't get through (a timeout, a dropped connection).
        case network
        /// The phone is offline: nothing else can help either.
        case offline

        var errorDescription: String? {
            switch self {
            case .unreadable: "Can't get a song from this link."
            case .noMatch: "Couldn't find this song."
            case .searchFailed: "Couldn't search for this song. Try again."
            case .network, .offline: YouTubeExtractor.networkMessage
            }
        }

        /// A URL error as one of these: offline is its own case, so the song service is never asked then.
        static func from(_ error: URLError) -> Failure {
            error.code == .notConnectedToInternet || error.code == .dataNotAllowed ? .offline : .network
        }
    }

    /// The failure screen shows this one with "Record instead" (S04).
    static let noMatchMessage = Failure.noMatch.errorDescription!

    // MARK: Reading the link

    /// The song behind a track link, or the tracks of an album or playlist link. The embed player's page
    /// first (10 KB of JSON); for a single track, the page's own link-preview tags as a fallback (300 KB,
    /// and a length rounded to the second).
    @concurrent
    static func read(_ link: SpotifyLink, isCancelled: @escaping @Sendable () -> Bool = { false }) async throws -> Found {
        let session = YouTubeExtractor.makeSession()
        defer { session.finishTasksAndInvalidate() }
        do {
            if isCancelled() { throw CancellationError() }
            if let html = try await text(link.embedURL, session: session) {
                if link.kind.isList, let list = SpotifyPage.trackList(inEmbed: html) { return .list(list) }
                if link.kind == .track, var song = SpotifyPage.song(inEmbed: html) {
                    song.id = song.id ?? link.id
                    return .song(song)
                }
            }
            if isCancelled() { throw CancellationError() }
            if link.kind == .track, let html = try await text(link.pageURL, session: session),
               let song = SpotifyPage.song(inOpenGraph: html, id: link.id) {
                return .song(song)
            }
            throw Failure.unreadable
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw Failure.network
        }
    }

    /// Where a short link points. It is followed (two redirects in practice), and the link it lands on is
    /// read from the final URL, then the landing page's `og:url`, then its canonical link.
    @concurrent
    static func resolve(_ short: URL, isCancelled: @escaping @Sendable () -> Bool = { false }) async throws -> SpotifyLink {
        let session = YouTubeExtractor.makeSession()
        defer { session.finishTasksAndInvalidate() }
        do {
            if isCancelled() { throw CancellationError() }
            var request = URLRequest(url: short)
            request.timeoutInterval = timeout
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            let (data, response) = try await session.data(for: request)
            let html = String(decoding: data.prefix(400_000), as: UTF8.self)
            guard let link = SpotifyLink.target(finalURL: response.url ?? short, html: html) else { throw Failure.unreadable }
            return link
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw Failure.network
        }
    }

    /// The song's cover, which the saved song keeps. Nothing is shown if it doesn't arrive.
    static func artwork(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let session = YouTubeExtractor.makeSession()
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count > 2_000, data.count < 4_000_000 else { return nil }
        return data
    }

    private static func text(_ url: URL, session: URLSession) async throws -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
