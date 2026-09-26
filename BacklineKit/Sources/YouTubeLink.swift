import Foundation

/// A YouTube video link reduced to its 11-character id. Only watch / youtu.be / shorts / live / embed /
/// music / mobile links are accepted; everything else (playlists without a video, channels, other hosts,
/// option-like strings) is rejected, and downloads always use a canonical URL rebuilt from the id.
public struct YouTubeLink: Equatable, Sendable {
    public let id: String
    public var canonicalURL: URL { URL(string: "https://www.youtube.com/watch?v=\(id)")! }

    public static func parse(_ text: String) -> YouTubeLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("-"), !trimmed.contains(" "),
              let url = URL(string: trimmed.lowercased().hasPrefix("http") ? trimmed : "https://" + trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return nil }
        let hosts = ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be", "www.youtu.be"]
        guard hosts.contains(host) else { return nil }
        var candidate: String?
        if host.hasSuffix("youtu.be") {
            candidate = url.pathComponents.dropFirst().first
        } else if url.path == "/watch" {
            candidate = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
        } else if url.pathComponents.count >= 3, ["shorts", "live", "embed"].contains(url.pathComponents[1]) {
            candidate = url.pathComponents[2]
        }
        guard let id = candidate, id.count == 11,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return YouTubeLink(id: id)
    }

    /// Finds the first YouTube video link in free text (e.g. text dragged from a browser).
    public static func find(in text: String) -> YouTubeLink? {
        for word in text.split(whereSeparator: { $0.isWhitespace || $0 == "\"" || $0 == "<" || $0 == ">" }) {
            if let v = parse(String(word)) { return v }
        }
        return nil
    }
}
