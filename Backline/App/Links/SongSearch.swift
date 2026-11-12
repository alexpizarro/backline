import BacklineKit
import Foundation

/// Finds the recording a music-service link names (S03): the music search's songs first, and plain videos
/// only when nothing there matched. The rules that judge the results are `SongMatcher` in BacklineKit, a
/// one-to-one port of `scripts/spotify-probe.py`; this is the two requests.
nonisolated enum SongSearch {
    /// The searches' `gl`. The region the phone is set to, so the result is the one this store offers.
    static var region: String {
        Locale.current.region?.identifier.uppercased() ?? "US"
    }

    /// Every candidate both searches offered, kept so "Wrong song?" can show the next ones (S04).
    struct Outcome: Sendable {
        var result: SongMatcher.Result
        /// True when the video search was needed (the music search found no match).
        var searchedVideos: Bool
    }

    /// Throws `SpotifyImport.Failure.searchFailed` when a search is refused (any answer but 200), `.offline` when
    /// the phone is offline, and `.network` for any other request that didn't get through (L3).
    @concurrent
    static func find(_ song: SpotifySong, region: String = region, session given: URLSession? = nil,
                     isCancelled: @escaping @Sendable () -> Bool = { false }) async throws -> Outcome {
        let session = given ?? YouTubeExtractor.makeSession()
        defer { if given == nil { session.finishTasksAndInvalidate() } }
        do {
            if isCancelled() { throw CancellationError() }
            let music = SongMatcher.result(for: song, candidates: SongSearchResponse.musicCandidates(
                try await search(InnerTubeClient.musicSearch, query: SongMatcher.musicQuery(song), region: region, session: session)))
            if music.verdict == .match { return Outcome(result: music, searchedVideos: false) }
            if isCancelled() { throw CancellationError() }
            let videos = SongMatcher.result(for: song, candidates: SongSearchResponse.videoCandidates(
                try await search(InnerTubeClient.videoSearch, query: SongMatcher.videoQuery(song), region: region, session: session)))
            return Outcome(result: SongMatcher.combine(music: music, video: videos), searchedVideos: true)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw SpotifyImport.Failure.from(error)
        }
    }

    private static func search(_ client: InnerTubeClient.Search, query: String, region: String,
                               session: URLSession) async throws -> Data {
        var request = URLRequest(url: client.url)
        request.httpMethod = "POST"
        request.timeoutInterval = SpotifyImport.timeout
        request.httpBody = client.requestBody(query: query, region: region)
        for (k, v) in client.headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SpotifyImport.Failure.searchFailed }
        return data
    }
}
