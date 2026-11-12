import Foundation

/// A link to a song, album or playlist on a music service (S01), reduced to its kind and 22-character id.
/// Only the shapes the service hands out are accepted: `open.spotify.com/track/<id>` (also under
/// `/intl-xx/` and with the `?si=` the share sheet adds), `play.spotify.com/…`, the `spotify:track:<id>`
/// URI, and the `spotify.link` short links, which name nothing until they are followed.
public struct SpotifyLink: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        /// One recording: the kind Backline splits.
        case track
        /// A list of recordings: one of them is picked first.
        case album, playlist
        /// Recognised so the app can say what to do instead (S04); never imported.
        case artist, show, episode

        public var isList: Bool { self == .album || self == .playlist }
    }

    public let kind: Kind
    public let id: String

    public init(kind: Kind, id: String) {
        self.kind = kind
        self.id = id
    }

    /// The page a browser opens.
    public var pageURL: URL { URL(string: "https://open.spotify.com/\(kind.rawValue)/\(id)")! }
    /// The player other websites embed: the same facts as the page in 10 KB of JSON instead of 300 KB.
    public var embedURL: URL { URL(string: "https://open.spotify.com/embed/\(kind.rawValue)/\(id)")! }
    /// The saved song's source, so the same link opens the song again instead of importing it twice.
    public var sourceName: String { "spotify:\(id)" }

    /// Ids are 22 base62 characters.
    public static func isID(_ s: String) -> Bool {
        s.count == 22 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}

/// What a link in some text turned out to be: a link that names its song, or a short link that has to be
/// followed before anything is known. Shared text carries words around the link ("Check out this song on
/// …: https://open.spotify.com/track/…?si=…"), so the text is searched, never parsed as a whole.
public enum SpotifyRef: Equatable, Sendable {
    case link(SpotifyLink)
    case short(URL)

    private static let kinds = SpotifyLink.Kind.allCases.map(\.rawValue).joined(separator: "|")

    /// The first music-service link in `text`, or nil.
    public static func find(in text: String) -> SpotifyRef? {
        // `open.spotify.com/intl-de/track/<id>`, `play.spotify.com/album/<id>`, with or without a scheme.
        let web = "(?:https?://)?(?:open|play)\\.spotify\\.com/(?:intl-[a-z-]+/)?(\(kinds))/([A-Za-z0-9]{22})"
        // `spotify:track:<id>`: what the app's share sheet writes, and what a track list carries.
        let uri = "spotify:(\(kinds)):([A-Za-z0-9]{22})"
        // `spotify.link/<code>` and `spotify.app.link/<code>`: the kind and id are only in the redirect.
        let short = "(?:https?://)?(spotify(?:\\.app)?\\.link)/([A-Za-z0-9_-]{4,})"
        var best: (at: Int, ref: SpotifyRef)?
        for (pattern, isShort) in [(web, false), (uri, false), (short, true)] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            let ref: SpotifyRef?
            if isShort {
                // The link's own host: spotify.link and spotify.app.link may not share their codes.
                ref = part(m, 1, in: text).flatMap { host in part(m, 2, in: text).flatMap { URL(string: "https://\(host.lowercased())/\($0)") } }
                    .map(SpotifyRef.short)
            } else {
                // The kind is written as the service writes it, in lower case.
                ref = part(m, 1, in: text).flatMap { SpotifyLink.Kind(rawValue: $0.lowercased()) }
                    .flatMap { kind in part(m, 2, in: text).map { SpotifyRef.link(SpotifyLink(kind: kind, id: $0)) } }
            }
            guard let ref, best == nil || m.range.location < best!.at else { continue }
            best = (m.range.location, ref)
        }
        return best?.ref
    }

    private static func part(_ m: NSTextCheckingResult, _ i: Int, in text: String) -> String? {
        guard let r = Range(m.range(at: i), in: text) else { return nil }
        return String(text[r])
    }
}

extension SpotifyLink {
    /// Where a short link really points: the URL it ended on (the redirect keeps the kind and id, with
    /// tracking after them), then the landing page's `og:url`, then its canonical link. Anything else — an
    /// app-store page, a sign-in wall — is nothing.
    public static func target(finalURL: URL?, html: String? = nil) -> SpotifyLink? {
        if let finalURL, case .link(let link)? = SpotifyRef.find(in: finalURL.absoluteString) { return link }
        guard let html else { return nil }
        for pattern in [#"<meta[^>]+property=["']og:url["'][^>]+content=["']([^"']+)["']"#,
                        #"<link[^>]+rel=["']canonical["'][^>]+href=["']([^"']+)["']"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for m in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let r = Range(m.range(at: 1), in: html),
                      case .link(let link)? = SpotifyRef.find(in: String(html[r])) else { continue }
                return link
            }
        }
        return nil
    }
}
