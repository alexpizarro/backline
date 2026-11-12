import Foundation

/// Gets a Vimeo video's sound (R01a). The clip page, which Vimeo serves under any channel path (the route
/// yt-dlp takes for channel links; a plain vimeo.com/<id> page is an empty shell), carries the player's
/// signed config URL. The config gives the title, the channel, a thumbnail and the HLS manifests, and the
/// audio-only rendition (fragmented MP4 AAC) is joined into one file by `HLSAudio`.
nonisolated enum VimeoExtractor {
    struct Output: Sendable {
        var file: URL
        var title: String?
        var author: String?
        var seconds: Double
    }

    enum Failure: LocalizedError, Equatable {
        /// Private, removed, or a page Vimeo won't show without an account.
        case unavailable
        case tooLong
        case network

        var errorDescription: String? {
            switch self {
            case .unavailable: "Can't get a song from this link."
            case .tooLong: YouTubeImport.Failure.tooLong.errorDescription
            case .network: "Can't connect. Check your internet."
            }
        }
    }

    /// What the player config says about the video.
    struct Config: Equatable {
        var title: String?
        var author: String?
        var seconds: Double?
        var thumbnail: URL?
        /// HLS master playlists, the default CDN first.
        var manifests: [URL]
    }

    static let maxSeconds = Double(YouTubeExtractor.maxSeconds)
    static let maxBytes = YouTubeExtractor.maxBytes
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"

    // MARK: Entry point

    /// Downloads the audio into `directory/vimeo-<id>.m4a`. `link` is the page the user gave, tried first
    /// when it is already a clip page (a channel, group or showcase link).
    @concurrent
    static func fetch(id: String, hash: String?, link: URL? = nil, into directory: URL,
                      onMetadata: (@Sendable (_ title: String?, _ author: String?, _ thumbnail: URL?) -> Void)? = nil,
                      progress: @escaping @Sendable (Double) -> Void,
                      isCancelled: @escaping @Sendable () -> Bool) async throws -> Output {
        let session = YouTubeExtractor.makeSession()
        defer { session.finishTasksAndInvalidate() }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let part = directory.appendingPathComponent("vimeo-\(id).m4a.part")
        let final = directory.appendingPathComponent("vimeo-\(id).m4a")
        defer { try? fm.removeItem(at: part) }

        do {
            guard let config = try await playerConfig(id: id, hash: hash, link: link, session: session) else { throw Failure.unavailable }
            if let s = config.seconds, s > maxSeconds { throw Failure.tooLong }
            onMetadata?(config.title, config.author, config.thumbnail)
            for manifest in config.manifests {
                if Task.isCancelled || isCancelled() { throw CancellationError() }
                do {
                    let hls = try await HLSAudio.download(manifest: manifest, session: session, userAgent: userAgent, maxSeconds: maxSeconds,
                                                          to: part, progress: progress, isCancelled: isCancelled)
                    let bytes = (try? fm.attributesOfItem(atPath: part.path)[.size]) as? Int ?? 0
                    if bytes > maxBytes { throw Failure.tooLong }
                    try? fm.removeItem(at: final)
                    try fm.moveItem(at: part, to: final)
                    return Output(file: final, title: config.title, author: config.author, seconds: hls.seconds)
                } catch is HLSAudio.TooLong {
                    throw Failure.tooLong
                } catch is RangedDownload.Failure {
                    // This CDN refused or broke off; the next one may not.
                    try? fm.removeItem(at: part)
                }
            }
            throw Failure.unavailable
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw Failure.network
        }
    }

    // MARK: The config

    /// The clip pages to read the config URL from, the user's own link first when it is one.
    static func clipPages(id: String, hash: String?, link: URL?) -> [URL] {
        var pages: [URL] = []
        if let link, link.host?.lowercased().hasSuffix("vimeo.com") == true, link.host?.lowercased() != "player.vimeo.com",
           ["channels", "groups", "showcase", "album"].contains(link.pathComponents.dropFirst().first ?? "") {
            pages.append(link)
        }
        var c = URLComponents(string: "https://vimeo.com/channels/staffpicks/\(id)")!
        if let hash { c.queryItems = [URLQueryItem(name: "h", value: hash)] }
        pages.append(c.url!)
        return pages
    }

    static func playerConfig(id: String, hash: String?, link: URL?, session: URLSession) async throws -> Config? {
        for page in clipPages(id: id, hash: hash, link: link) {
            guard let html = try await text(page, session: session), let url = configURL(inClipPage: html, id: id) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(page.absoluteString, forHTTPHeaderField: "Referer")
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let config = parseConfig(data), !config.manifests.isEmpty else { continue }
            return config
        }
        return nil
    }

    private static func text(_ url: URL, session: URLSession) async throws -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The signed player config URL in a clip page: `data-config-url="…"` (HTML-escaped) or
    /// `"config_url":"…"` (JSON-escaped). Only this video's config counts.
    static func configURL(inClipPage html: String, id: String) -> URL? {
        let patterns: [(String, (String) -> String)] = [
            (#"data-config-url="([^"]+)""#, { $0.replacingOccurrences(of: "&amp;", with: "&") }),
            (#""config_url":"([^"]+)""#, { $0.replacingOccurrences(of: "\\/", with: "/").replacingOccurrences(of: "\\u0026", with: "&") }),
        ]
        for (pattern, unescape) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for m in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let r = Range(m.range(at: 1), in: html), let url = URL(string: unescape(String(html[r]))),
                      url.host == "player.vimeo.com", url.path == "/video/\(id)/config" else { continue }
                return url
            }
        }
        return nil
    }

    /// The parts of the player config Backline reads.
    static func parseConfig(_ data: Data) -> Config? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let video = root["video"] as? [String: Any] ?? [:]
        let hls = ((root["request"] as? [String: Any])?["files"] as? [String: Any])?["hls"] as? [String: Any] ?? [:]
        let cdns = hls["cdns"] as? [String: [String: Any]] ?? [:]
        let order = [hls["default_cdn"] as? String].compactMap { $0 } + cdns.keys.sorted()
        var manifests: [URL] = []
        for name in order {
            guard let cdn = cdns[name], let url = ((cdn["url"] ?? cdn["avc_url"]) as? String).flatMap(URL.init(string:)),
                  !manifests.contains(url) else { continue }
            manifests.append(url)
        }
        let thumbs = video["thumbs"] as? [String: Any] ?? [:]
        var thumbnail = (video["thumbnail_url"] ?? thumbs["640"] ?? thumbs["base"]) as? String
        // The full-size original runs to most of a megabyte; "_1280" asks the CDN for the YouTube artwork's size.
        if let t = thumbnail, t.hasSuffix("-d") { thumbnail = t + "_1280" }
        return Config(title: video["title"] as? String, author: (video["owner"] as? [String: Any])?["name"] as? String,
                      seconds: (video["duration"] as? NSNumber)?.doubleValue, thumbnail: thumbnail.flatMap(URL.init(string:)),
                      manifests: manifests)
    }

    /// The video's thumbnail, for the song's artwork.
    static func thumbnail(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        return data
    }
}
