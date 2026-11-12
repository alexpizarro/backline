import BacklineKit
import Foundation
import Synchronization

/// YouTube's player script, for clients whose streams need it (R01a): finds today's player version through
/// `iframe_api`, reads its signature timestamp, and keeps the solver's reduced copy in Caches (newest two
/// versions), so after the first song a solve takes milliseconds instead of a 2.7 MB download and a
/// second and a half of parsing.
nonisolated enum PlayerScript {
    struct Player: Sendable {
        var id: String
        var signatureTimestamp: Int
        /// The solver's reduced player (`ChallengeSolver.Answers.preprocessedPlayer`).
        var preprocessed: String
    }

    enum Failure: Error, Equatable { case noPlayer, noTimestamp, noSolver }

    static let iframeAPI = URL(string: "https://www.youtube.com/iframe_api")!
    static let keep = 2

    /// The bundled yt-dlp-ejs solver, loaded once.
    static let solver: ChallengeSolver? = Bundle.main.resourceURL.flatMap { try? ChallengeSolver(directory: $0) }

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("links/jsc", isDirectory: true)
    }

    /// The player in use today, from the cache when this version has been seen before.
    static func current(session: URLSession, directory: URL = directory, say: @Sendable (String) -> Void) async throws -> Player {
        let id: String
        if let live = try? await playerID(session: session) {
            id = live
        } else if let newest = cachedIDs(in: directory).first {
            // Offline from iframe_api only: the newest version seen is usually still current.
            say("player: iframe_api unavailable, using \(newest)")
            id = newest
        } else {
            throw Failure.noPlayer
        }
        if let player = cached(id, in: directory) { return player }

        say("player: fetching \(id)")
        var request = URLRequest(url: scriptURL(id))
        request.timeoutInterval = 25
        request.setValue(YouTubeExtractor.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.noPlayer }
        let script = String(decoding: data, as: UTF8.self)
        guard let sts = signatureTimestamp(in: script) else { throw Failure.noTimestamp }
        guard let solver else { throw Failure.noSolver }
        guard let preprocessed = try solver.solve(player: script, keepPreprocessed: true).preprocessedPlayer else {
            throw Failure.noPlayer
        }
        let player = Player(id: id, signatureTimestamp: sts, preprocessed: preprocessed)
        store(player, in: directory)
        return player
    }

    /// Answers the format's signature and `n` challenges.
    static func solve(_ player: Player, sig: String?, n: String?) throws -> ChallengeSolver.Answers {
        guard let solver else { throw Failure.noSolver }
        return try solver.solve(preprocessed: player.preprocessed, n: n.map { [$0] } ?? [], sig: sig.map { [$0] } ?? [])
    }

    // MARK: Finding the version

    /// The version `iframe_api` named last, reused for ten minutes: one link can ask for the player up to three
    /// times (the TV client, then once per proof-of-origin try), and YouTube changes it far less often (L11).
    static let playerIDLifetime: TimeInterval = 10 * 60
    private static let lastPlayerID = Mutex<(id: String, at: Date)?>(nil)

    static func playerID(session: URLSession, now: Date = Date()) async throws -> String {
        if let held = lastPlayerID.withLock({ $0 }), now.timeIntervalSince(held.at) < playerIDLifetime { return held.id }
        let id = try await livePlayerID(session: session)
        lastPlayerID.withLock { $0 = (id, now) }
        return id
    }

    static func forgetPlayerID() { lastPlayerID.withLock { $0 = nil } }

    private static func livePlayerID(session: URLSession) async throws -> String {
        var request = URLRequest(url: iframeAPI)
        request.timeoutInterval = 15
        request.setValue(YouTubeExtractor.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let id = playerID(inIframeAPI: String(decoding: data, as: UTF8.self)) else { throw Failure.noPlayer }
        return id
    }

    /// `…/s/player/cbcfbf2f/www-widgetapi.vflset…`, with the slashes escaped as `\/` in the script.
    static func playerID(inIframeAPI text: String) -> String? {
        first(#"player\\?/([0-9a-fA-F]{8})\\?/"#, in: text)
    }

    static func scriptURL(_ id: String) -> URL {
        URL(string: "https://www.youtube.com/s/player/\(id)/player_ias.vflset/en_US/base.js")!
    }

    /// The `signatureTimestamp` the player request must carry for its ciphered streams to unlock.
    static func signatureTimestamp(in script: String) -> Int? {
        first(#"(?:signatureTimestamp|sts)\s*:\s*([0-9]{5})"#, in: script).flatMap { Int($0) }
    }

    private static func first(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    // MARK: Cache

    /// `<id>.js` holds the reduced player, `<id>.sts` its timestamp.
    static func cached(_ id: String, in directory: URL) -> Player? {
        let base = directory.appendingPathComponent(id)
        guard let stsText = try? String(contentsOf: base.appendingPathExtension("sts"), encoding: .utf8),
              let sts = Int(stsText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let preprocessed = try? String(contentsOf: base.appendingPathExtension("js"), encoding: .utf8) else { return nil }
        return Player(id: id, signatureTimestamp: sts, preprocessed: preprocessed)
    }

    /// Cached versions, newest first.
    static func cachedIDs(in directory: URL) -> [String] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "sts" }
            .map { ($0.deletingPathExtension().lastPathComponent,
                    (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    static func store(_ player: Player, in directory: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = directory.appendingPathComponent(player.id)
        // The script first: a timestamp file without its script would read as a cache miss anyway.
        guard (try? player.preprocessed.write(to: base.appendingPathExtension("js"), atomically: true, encoding: .utf8)) != nil,
              (try? String(player.signatureTimestamp).write(to: base.appendingPathExtension("sts"), atomically: true, encoding: .utf8)) != nil
        else { return }
        for old in cachedIDs(in: directory).dropFirst(keep) {
            try? fm.removeItem(at: directory.appendingPathComponent(old).appendingPathExtension("js"))
            try? fm.removeItem(at: directory.appendingPathComponent(old).appendingPathExtension("sts"))
        }
    }
}
