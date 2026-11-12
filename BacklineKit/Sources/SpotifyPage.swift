import Foundation

/// What the service's public page says about one song (S02): what the Getting-the-song screen shows, what
/// the search looks for, and what the saved song keeps.
public struct SpotifySong: Equatable, Sendable {
    public var id: String?
    public var title: String
    public var artists: [String]
    public var seconds: Double
    /// The cover, at the largest size the page offers.
    public var artwork: URL?

    public init(id: String? = nil, title: String, artists: [String], seconds: Double, artwork: URL? = nil) {
        self.id = id
        self.title = title
        self.artists = artists
        self.seconds = seconds
        self.artwork = artwork
    }

    /// "Artist" or "Artist, Other" for the screens and the saved song.
    public var artist: String { artists.joined(separator: ", ") }
}

/// One row of an album's or a playlist's track list: enough for the "Pick a song" sheet. Picking a row
/// reads that track's own page, so the song keeps its own artists and cover.
public struct SpotifyTrackRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var artists: [String]
    public var seconds: Double

    public init(id: String, title: String, artists: [String], seconds: Double) {
        self.id = id
        self.title = title
        self.artists = artists
        self.seconds = seconds
    }

    public var artist: String { artists.joined(separator: ", ") }
}

/// An album or playlist: its name and the tracks it lists.
public struct SpotifyTrackList: Equatable, Sendable {
    public var name: String
    public var tracks: [SpotifyTrackRow]

    public init(name: String, tracks: [SpotifyTrackRow]) {
        self.name = name
        self.tracks = tracks
    }
}

/// Reads a music service's public pages (S02). The embed player's page carries the song's title, artists,
/// length and cover as JSON in `__NEXT_DATA__`, and an album's or playlist's track list with it. When that
/// page changes shape, a track's own page still carries the Open Graph tags every link preview reads.
/// Parsing only: the fetching is the app's (`SpotifyImport`).
public enum SpotifyPage {
    /// A playlist page returns at most 100 tracks however long the playlist is; the sheet shows what came.
    public static let maxTracks = 100

    // MARK: The embed page

    /// One song from the embed page of a track link.
    public static func song(inEmbed html: String) -> SpotifySong? {
        guard let entity = entity(inEmbed: html) else { return nil }
        let title = (entity["title"] ?? entity["name"]) as? String
        let artists = (entity["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        guard let title, !title.isEmpty, let ms = (entity["duration"] as? NSNumber)?.doubleValue, ms > 0 else { return nil }
        return SpotifySong(id: entity["id"] as? String, title: title, artists: artists, seconds: ms / 1000,
                           artwork: cover(entity))
    }

    /// The track list from the embed page of an album or playlist link.
    public static func trackList(inEmbed html: String) -> SpotifyTrackList? {
        guard let entity = entity(inEmbed: html), let rows = entity["trackList"] as? [[String: Any]] else { return nil }
        let tracks: [SpotifyTrackRow] = rows.prefix(maxTracks).compactMap { row in
            guard let uri = row["uri"] as? String, let id = uri.split(separator: ":").last.map(String.init),
                  SpotifyLink.isID(id), let title = row["title"] as? String, !title.isEmpty,
                  let ms = (row["duration"] as? NSNumber)?.doubleValue, ms > 0 else { return nil }
            // "Artist, Other Artist" in one string on a list row.
            let artists = (row["subtitle"] as? String ?? "").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return SpotifyTrackRow(id: id, title: title, artists: artists, seconds: ms / 1000)
        }
        guard !tracks.isEmpty else { return nil }
        return SpotifyTrackList(name: entity["name"] as? String ?? "", tracks: tracks)
    }

    /// `props.pageProps.state.data.entity` of the page's `__NEXT_DATA__`.
    static func entity(inEmbed html: String) -> [String: Any]? {
        guard let regex = try? NSRegularExpression(pattern: #"<script id="__NEXT_DATA__"[^>]*>(.*?)</script>"#,
                                                   options: [.dotMatchesLineSeparators]),
              let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let r = Range(m.range(at: 1), in: html),
              let root = try? JSONSerialization.jsonObject(with: Data(html[r].utf8)) as? [String: Any] else { return nil }
        let props = root["props"] as? [String: Any]
        let page = props?["pageProps"] as? [String: Any]
        let state = page?["state"] as? [String: Any]
        let data = state?["data"] as? [String: Any]
        return data?["entity"] as? [String: Any]
    }

    /// The biggest cover the page offers (640 pt on a track page), under `visualIdentity` or `coverArt`.
    private static func cover(_ entity: [String: Any]) -> URL? {
        var images: [[String: Any]] = []
        for key in ["visualIdentity", "coverArt"] {
            if let group = entity[key] as? [String: Any], let list = group["image"] as? [[String: Any]] {
                images += list
            }
        }
        let best = images.max { a, b in
            ((a["maxWidth"] as? NSNumber)?.intValue ?? 0) < ((b["maxWidth"] as? NSNumber)?.intValue ?? 0)
        }
        return (best?["url"] as? String).flatMap(URL.init(string:))
    }

    // MARK: The track page's link-preview tags

    /// A song from a track page's Open Graph tags: the fallback when the embed page can't be read.
    /// `music:duration` is in whole seconds there, so the length is a second coarser than the embed's.
    public static func song(inOpenGraph html: String, id: String? = nil) -> SpotifySong? {
        guard let title = tag("og:title", in: html), !title.isEmpty,
              let seconds = tag("music:duration", in: html).flatMap(Double.init), seconds > 0 else { return nil }
        let artists = (tag("music:musician_description", in: html) ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return SpotifySong(id: id, title: title, artists: artists, seconds: seconds,
                           artwork: tag("og:image", in: html).flatMap(URL.init(string:)))
    }

    /// One `<meta property|name="…" content="…">`, whichever way round the two attributes are written.
    static func tag(_ name: String, in html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        for pattern in ["<meta[^>]+(?:property|name)=[\"']\(escaped)[\"'][^>]+content=[\"']([^\"']*)[\"']",
                        "<meta[^>]+content=[\"']([^\"']*)[\"'][^>]+(?:property|name)=[\"']\(escaped)[\"']"] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let r = Range(m.range(at: 1), in: html) else { continue }
            return String(html[r]).replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        }
        return nil
    }
}
