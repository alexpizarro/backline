import BacklineKit
import Foundation

/// What a pasted, dropped or shared link is (R01a, native link engine): a music or video file, a YouTube or
/// Vimeo video, a song on a music service, or a page Backline can't get a song from. Only http(s) links
/// count (bar the music service's own `spotify:` URI); free text is searched for the first one.
nonisolated enum WebLink: Equatable, Sendable {
    /// A file AVFoundation reads, by its extension: downloaded as it is.
    case file(URL)
    case youTube(YouTubeLink)
    /// A Vimeo video: its id, and the hash an unlisted video's link carries.
    case vimeo(id: String, hash: String?)
    /// A song, album or playlist on a music service (S01): the song is read from the service, then the same
    /// recording is found and downloaded. A short link only says which song once it has been followed.
    case spotify(SpotifyRef)
    /// Any other web page.
    case unsupported(URL)

    static let fileExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "caf", "mp4", "m4v", "mov"]

    /// The first http(s) link in `text`, classified; nil when there is none.
    static func classify(_ text: String) -> WebLink? {
        if let v = YouTubeLink.find(in: text) { return .youTube(v) }
        // Before the fallback: a music-service link is a web page like any other, and must not be read as one.
        if let s = SpotifyRef.find(in: text) { return .spotify(s) }
        for word in text.split(whereSeparator: { $0.isWhitespace || $0 == "\"" || $0 == "<" || $0 == ">" }) {
            guard let url = webURL(String(word)) else { continue }
            if let v = vimeo(url) { return v }
            if fileExtensions.contains(url.pathExtension.lowercased()) { return .file(url) }
            return .unsupported(url)
        }
        return nil
    }

    /// An http(s) URL with a real host; "vimeo.com/…" without a scheme counts.
    static func webURL(_ word: String) -> URL? {
        let t = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}'"))
        guard !t.isEmpty, !t.hasPrefix("-") else { return nil }
        for candidate in [t, "https://" + t] {
            if let url = URL(string: candidate), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
               let host = url.host, host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") {
                return url
            }
            if t.contains("://") { break }
        }
        return nil
    }

    /// vimeo.com/<id>, vimeo.com/<id>/<hash> (unlisted), vimeo.com/channels/<name>/<id>,
    /// vimeo.com/groups/<name>/videos/<id>, player.vimeo.com/video/<id>?h=<hash>.
    static func vimeo(_ url: URL) -> WebLink? {
        guard let host = url.host?.lowercased(), host == "vimeo.com" || host.hasSuffix(".vimeo.com") else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let i = parts.lastIndex(where: { $0.count >= 6 && $0.allSatisfy(\.isNumber) }) else { return nil }
        var hash = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "h" }?.value
        if hash == nil, i + 1 < parts.count, parts[i + 1].count >= 6,
           parts[i + 1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
            hash = parts[i + 1]
        }
        return .vimeo(id: parts[i], hash: hash)
    }
}
