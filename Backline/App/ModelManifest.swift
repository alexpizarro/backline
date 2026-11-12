import Foundation

/// Where the downloadable models are (R01d, `docs/release/model-hosting.md`): a small manifest on our own
/// domain lists each file's size, SHA-256 and mirrors, so the host can move without an app update. The app
/// decides what it trusts: only entries whose platform, hash and size match a model it already knows are
/// used, and every file is checked against the built-in hash before it is unpacked. The worst a bad
/// manifest can do is stop downloads. Nothing here runs before the user agrees to download (R01b).
nonisolated enum ModelManifest {
    static let url = URL(string: "https://backlinestems.com/models/v1/manifest.json")!
    /// The Mac reads its own entries (`docs/release/model-hosting.md` in the iOS repo foresees them). Until the
    /// manifest lists any, every model comes from the built-in GitHub URL.
    static let platform = "macos"
    /// A last good copy older than this is ignored; the built-in GitHub URL is used instead.
    static let maxAge: TimeInterval = 30 * 86_400
    static let maxURLs = 4

    struct Document: Codable, Equatable, Sendable {
        var format: Int
        var updated: String?
        var withdrawn: [String] = []
        var files: [Entry]

        enum CodingKeys: String, CodingKey { case format, updated, withdrawn, files }
        init(format: Int, updated: String? = nil, withdrawn: [String] = [], files: [Entry]) {
            self.format = format; self.updated = updated; self.withdrawn = withdrawn; self.files = files
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            format = try c.decode(Int.self, forKey: .format)
            updated = try c.decodeIfPresent(String.self, forKey: .updated)
            withdrawn = try c.decodeIfPresent([String].self, forKey: .withdrawn) ?? []
            files = try c.decode([Entry].self, forKey: .files)
        }
    }

    struct Entry: Codable, Equatable, Sendable {
        var platform: String
        var model: String?
        var file: String
        var bytes: Int64
        var sha256: String
        var urls: [String]
    }

    /// Format 1 only; anything else is no manifest.
    static func parse(_ data: Data) -> Document? {
        guard let doc = try? JSONDecoder().decode(Document.self, from: data), doc.format == 1 else { return nil }
        return doc
    }

    /// Where to get `asset`, in order: the https URLs of manifest entries that match it exactly (at most
    /// four), then the built-in URL unless it is already listed.
    static func sources(for asset: ModelAsset, in doc: Document?, fallback: URL) -> [URL] {
        var out: [URL] = []
        for entry in doc?.files ?? [] where entry.platform == platform && entry.sha256 == asset.sha256 && entry.bytes == asset.bytes {
            for text in entry.urls {
                guard out.count < maxURLs, let u = URL(string: text), u.scheme == "https", u.host != nil, !out.contains(u) else { continue }
                out.append(u)
            }
        }
        if !out.contains(fallback) { out.append(fallback) }
        return out
    }

    /// The manifest withdrew this exact file: it isn't offered for download (installed copies keep working).
    static func isWithdrawn(_ asset: ModelAsset, in doc: Document?) -> Bool {
        doc?.withdrawn.contains(asset.sha256) == true
    }

    // MARK: Fetching and the last good copy

    static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("models-manifest.json")
    }

    /// The manifest now, or the last good copy if it is under 30 days old, or nil (then GitHub only).
    static func current(session: URLSession = .shared, cache: URL = cacheURL, now: Date = Date()) async -> Document? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let (data, response) = try? await session.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200, data.count < 256 << 10, let doc = parse(data) {
            try? data.write(to: cache, options: .atomic)
            return doc
        }
        return lastGood(cache: cache, now: now)
    }

    static func lastGood(cache: URL = cacheURL, now: Date = Date()) -> Document? {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: cache.path)[.modificationDate]) as? Date,
              now.timeIntervalSince(modified) < maxAge, let data = try? Data(contentsOf: cache) else { return nil }
        return parse(data)
    }
}
