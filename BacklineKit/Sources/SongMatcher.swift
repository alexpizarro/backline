import Foundation

/// One recording a search offered, with only what the matcher reads (S03).
public struct SongCandidate: Equatable, Sendable {
    /// Which search found it: the music service's songs, or plain videos.
    public enum Source: String, Sendable, Codable {
        case music, video
    }

    public var videoID: String
    public var title: String
    /// The artists ("Artist" on a song row) or the channel ("Artist VEVO" on a video).
    public var by: String
    /// nil when the row didn't say how long it is (a live stream, a shelf header): never a match.
    public var seconds: Double?
    public var source: Source

    public init(videoID: String, title: String, by: String, seconds: Double?, source: Source) {
        self.videoID = videoID
        self.title = title
        self.by = by
        self.seconds = seconds
        self.source = source
    }
}

/// Finds the same recording as the song read from the music service (S03). A one-to-one port of `pick()` in
/// `scripts/spotify-probe.py`, which measured it over 202 tracks: same title once credits and decorations
/// are taken off, an artist in common, the same kind of version, then the closest length. Within 3 s is a
/// match; 3 to 8 s asks; anything else is nothing. Backline never guesses.
///
/// Changing a rule here means re-recording the corpus (`scripts/spotify-probe.py --record`) and
/// re-measuring: `SongMatcherTests` holds this code to the probe's verdict and pick for every track.
public enum SongMatcher {
    public enum Verdict: String, Sendable {
        /// Within 3 s: download it.
        case match
        /// 3 to 8 s: ask "Is this the song?".
        case ask
        /// Nothing passed the rules, or the closest was more than 8 s out.
        case none
    }

    public struct Scored: Equatable, Sendable {
        public let candidate: SongCandidate
        /// Seconds between this recording's length and the song's.
        public let gap: Double
    }

    public struct Result: Equatable, Sendable {
        public var verdict: Verdict
        /// Every candidate that passed the rules, closest length first.
        public var ranked: [Scored]

        public init(verdict: Verdict, ranked: [Scored]) {
            self.verdict = verdict
            self.ranked = ranked
        }

        public var best: Scored? { ranked.first }
        /// The other candidates that passed, for "Wrong song?" (S04).
        public func others(_ limit: Int = 3) -> [Scored] { Array(ranked.dropFirst().prefix(limit)) }
    }

    /// A remix, live, acoustic … version only ever matches the same kind of version.
    static let variant = try! NSRegularExpression(
        pattern: #"\b(remix|live|acoustic|instrumental|sped ?up|slowed|karaoke|cover|8d|nightcore|reverb|edit|version|demo|mashup)\b"#)
    /// What video uploaders add to a title: "(Official Audio)", "(Lyrics)", "| Letra", hashtags.
    static let decoration = try! NSRegularExpression(
        pattern: #"[\(\[][^\)\]]*\b(official|audio|video|lyrics?|letra|visuali[sz]er|hd|4k|videoclip)\b[^\)\]]*[\)\]]|#\S+"#,
        options: [.caseInsensitive])
    private static let credits = try! NSRegularExpression(
        pattern: #"[\(\[][^\)\]]*\b(feat|ft|with|remaster(ed)?|from)\b[^\)\]]*[\)\]]"#)
    private static let dashRemaster = try! NSRegularExpression(pattern: #"\s-\s.*\bremaster(ed)?\b.*$"#)
    private static let trailingFeat = try! NSRegularExpression(pattern: #"\b(feat|ft)\.?\s.*$"#)
    private static let notLetterOrNumber = try! NSRegularExpression(pattern: "[^a-z0-9]+")

    /// Lower case, no accents or punctuation, without "(feat. …)", "- Remastered 2011" and the like.
    public static func norm(_ s: String) -> String {
        // Accents are decomposed and then dropped, so "Devórame" and "Devorame" are the same title.
        var t = String(String.UnicodeScalarView(s.decomposedStringWithCompatibilityMapping.unicodeScalars.filter(\.isASCII)))
            .lowercased()
        t = replace(credits, in: t)
        t = replace(dashRemaster, in: t)
        t = replace(trailingFeat, in: t)
        return replace(notLetterOrNumber, in: t).trimmingCharacters(in: .whitespaces)
    }

    private static func replace(_ regex: NSRegularExpression, in s: String) -> String {
        regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
    }

    private static func has(_ regex: NSRegularExpression, _ s: String) -> Bool {
        regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// "1:23" in seconds; nil for anything that isn't a length.
    public static func seconds(_ text: String?) -> Double? {
        guard let text, let regex = try? NSRegularExpression(pattern: #"^\d+(:\d\d)+$"#),
              regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { return nil }
        var total = 0.0
        for part in text.split(separator: ":") {
            guard let v = Double(part) else { return nil }
            total = total * 60 + v
        }
        return total
    }

    // MARK: The queries

    /// "Artist Other Artist Title": the song search takes up to two artists.
    public static func musicQuery(_ song: SpotifySong) -> String {
        "\(song.artists.prefix(2).joined(separator: " ")) \(song.title)"
    }

    /// "Artist Title": the video search takes one, so a long credit list doesn't bury the title.
    public static func videoQuery(_ song: SpotifySong) -> String {
        "\(song.artists.first ?? "") \(song.title)"
    }

    // MARK: The rules

    /// The candidates that pass the rules, closest length first, and the verdict the closest one earns.
    /// Only the first 8 of a search are considered, as the probe does.
    public static func result(for song: SpotifySong, candidates: [SongCandidate]) -> Result {
        let title = norm(song.title)
        let artists = song.artists.map(norm)
        var scored: [(scored: Scored, at: Int)] = []
        for (at, c) in candidates.prefix(8).enumerated() {
            guard let length = c.seconds else { continue }
            let name = norm(replace(decoration, in: c.title))
            let by = norm(c.by)
            let sameTitle: Bool
            let rest: String
            if c.source == .music {
                // A song row's title is the title, give or take a tag one side bears and the other doesn't.
                sameTitle = name == title
                    || (min(name.count, title.count) >= 4 && (name.hasPrefix(title) || title.hasPrefix(name)))
                rest = name
            } else {
                // "Artist - Title (Official Audio)": the title appears inside the video's own words.
                sameTitle = !title.isEmpty && name.contains(title)
                rest = title.isEmpty ? name : name.replacingOccurrences(of: title, with: " ")
            }
            // A video whose words say nothing about a version is taken as the plain recording.
            let sameKind = has(variant, rest) == has(variant, title) || (c.source == .video && !has(variant, rest))
            let sharesArtist = artists.contains { !$0.isEmpty && (by.contains($0) || name.contains($0)) }
            guard sameTitle, sameKind, sharesArtist else { continue }
            scored.append((Scored(candidate: c, gap: abs(length - song.seconds)), at))
        }
        // Closest first; an equally close candidate the search put first stays first (the probe keeps its
        // first best, since it only replaces on a strictly smaller gap).
        let ranked = scored.sorted { a, b in a.scored.gap == b.scored.gap ? a.at < b.at : a.scored.gap < b.scored.gap }
            .map(\.scored)
        guard let gap = ranked.first?.gap else { return Result(verdict: .none, ranked: []) }
        return Result(verdict: gap <= 3 ? .match : (gap <= 8 ? .ask : .none), ranked: ranked)
    }

    /// The music service's songs are searched first; plain videos only when nothing there matched, and they
    /// win only with a match of their own (or an "ask" where the songs had nothing at all).
    public static func combine(music: Result, video: Result?) -> Result {
        guard music.verdict != .match, let video else { return music }
        if video.verdict == .match || (video.verdict == .ask && music.verdict == .none) { return video }
        return music
    }
}

// MARK: - Reading a search response

/// The two InnerTube search responses, as the matcher needs them (S03). The renderers are picked out of the
/// whole tree, as yt-dlp does, so a new shelf around the results changes nothing.
public enum SongSearchResponse {
    /// The music service's "songs": the official audio of each recording, with its artists and length.
    public static func musicCandidates(_ data: Data) -> [SongCandidate] {
        renderers(data, "musicResponsiveListItemRenderer").compactMap { r in
            let columns = (r["flexColumns"] as? [[String: Any]] ?? []).map { column -> String in
                let text = (column["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any])?["text"] as? [String: Any]
                let runs = text?["runs"] as? [[String: Any]] ?? []
                return runs.map { $0["text"] as? String ?? "" }.joined(separator: " ")
            }
            guard let videoID = (r["playlistItemData"] as? [String: Any])?["videoId"] as? String, columns.count >= 2 else { return nil }
            // "Artist • Album • 3:14", or "Artist • 3:14" on a single.
            let parts = columns[1].components(separatedBy: "•").map { $0.trimmingCharacters(in: .whitespaces) }
            return SongCandidate(videoID: videoID, title: columns[0], by: parts.first ?? "",
                                 seconds: SongMatcher.seconds(parts.last), source: .music)
        }
    }

    /// Plain videos: titles like "Artist - Title (Official Audio) #tag", from the artist's channel or anyone's.
    public static func videoCandidates(_ data: Data) -> [SongCandidate] {
        renderers(data, "videoRenderer").compactMap { v in
            // A result without an id can't be downloaded, so it mustn't win the ranking.
            guard let id = v["videoId"] as? String, !id.isEmpty else { return nil }
            let runs = (v["title"] as? [String: Any])?["runs"] as? [[String: Any]] ?? []
            let owner = (v["ownerText"] as? [String: Any])?["runs"] as? [[String: Any]] ?? []
            let length = (v["lengthText"] as? [String: Any])?["simpleText"] as? String
            return SongCandidate(videoID: id,
                                 title: runs.map { $0["text"] as? String ?? "" }.joined(),
                                 by: owner.map { $0["text"] as? String ?? "" }.joined(),
                                 seconds: SongMatcher.seconds(length), source: .video)
        }
    }

    /// Every `key` in the tree, in reading order, without descending into one that was found. JSON objects
    /// come out of `JSONSerialization` unordered, so keys are walked in alphabetical order: that is
    /// repeatable, and the results (`contents`) sort before the rest of a response either way.
    static func renderers(_ data: Data, _ key: String) -> [[String: Any]] {
        var found: [[String: Any]] = []
        func walk(_ node: Any) {
            if let object = node as? [String: Any] {
                if let own = object[key] {
                    if let hit = own as? [String: Any] { found.append(hit) }
                    return
                }
                for k in object.keys.sorted() { walk(object[k]!) }
            } else if let list = node as? [Any] {
                for v in list { walk(v) }
            }
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        walk(root)
        return found
    }
}
