import BacklineKit
import Foundation
import Synchronization

/// The song service (owner, 6 November 2026): the last resort when Backline can't get a song from a link on the
/// phone. It is the owner's own server (`POST /v1/songs/download`, documented in the server's own repository): it
/// gets a song's audio by its artist and title, or by one YouTube link, keeps a copy so it never fetches
/// the same song twice, and answers with a 30-minute signed link to an AAC `.m4a`. Only those words or that one link
/// leave the phone, never audio and nothing about the person.
///
/// The address and key come from the build (`BLSongServiceBaseURL`, `BLSongServiceKey`, filled by
/// `scripts/song-service-config.sh` from `~/.config/audiointel/`, never from the repository); without them the service
/// is off. It is billed while awake, so it is called only after the phone has failed, never to warm up, and never from
/// tests: under XCTest, and in UI test runs (`--no-downloads`), it is off unless a test hands it a stub.
nonisolated enum SongService {
    /// Kill switch: when false every link fails as it did before.
    static let isAllowed = true

    struct Config: Sendable, Equatable {
        let base: URL
        let key: String

        static func fromBuild(_ info: [String: Any]? = Bundle.main.infoDictionary) -> Config? {
            guard let base = (info?["BLSongServiceBaseURL"] as? String).flatMap(URL.init(string:)), base.scheme == "https",
                  let key = info?["BLSongServiceKey"] as? String, !key.isEmpty, !key.hasPrefix("$(") else { return nil }
            return Config(base: base, key: key)
        }
    }

    static let config: Config? = {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["XCTestSessionIdentifier"] != nil { return nil }
        #if DEBUG
        if CommandLine.arguments.contains("--no-downloads") { return nil }
        #endif
        return Config.fromBuild()
    }()

    static var isEnabled: Bool {
        #if DEBUG
        if SongServiceStub.mode != nil { return true }
        #endif
        return isAllowed && config != nil && !isStopped
    }

    /// A 401 (the key is wrong or was rotated) or a 400 (a client bug) stops the service for the rest of this run, as
    /// its contract asks (§4): rotating the key is the kill switch, so a revoked key mustn't keep calling.
    private static let stopped = Mutex(false)
    static var isStopped: Bool { stopped.withLock { $0 } }
    #if DEBUG
    static func resetStopForTests() { stopped.withLock { $0 = false } }
    #endif

    /// Everything known about the song, sent in one request. Unknown fields are left out.
    struct Ask: Sendable, Equatable, Encodable {
        var artist: String?
        var title: String?
        /// One YouTube video's link, when the phone found the recording but couldn't download it.
        var reference: String?

        init(artist: String? = nil, title: String? = nil, reference: String? = nil) {
            self.artist = artist.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            self.title = title.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            self.reference = reference
        }

        var isUsable: Bool { reference != nil || (artist != nil && title != nil) }
    }

    /// What came back: the audio on the phone, and what the service says it is.
    struct Song: Sendable, Equatable {
        var file: URL
        var title: String?
        var artist: String?
        var seconds: Double?
    }

    enum Failure: Error, Equatable {
        /// 400: the request was malformed (a bug; not retried).
        case badRequest
        /// 401: the key is wrong or missing.
        case unauthorized
        /// 404: the service doesn't hold the song and couldn't find it.
        case notHeld
        /// 502: the source refused this song for now.
        case refused
        /// The audio is another recording: the service said so, or its length is too far from the song's.
        case wrongRecording
        /// Timeouts, 5xx, a route that isn't deployed, a lost connection: after the retries.
        case unavailable
    }

    /// The service's reply (DOWNLOAD-ENDPOINT.md §3); unknown fields are ignored, an unknown identity is unconfirmed.
    struct Reply: Decodable, Sendable, Equatable {
        struct Song: Decodable, Sendable, Equatable {
            var songID: String
            var title: String?
            var artist: String?
            var seconds: Double?
            enum CodingKeys: String, CodingKey { case songID = "song_id", title, artist, seconds = "duration_s" }
        }
        struct Audio: Decodable, Sendable, Equatable {
            var url: URL?
            var sizeBytes: Int?
            enum CodingKeys: String, CodingKey { case url, sizeBytes = "size_bytes" }
        }
        var song: Song
        var audio: Audio
        /// confirmed, unconfirmed or mismatch.
        var identity: String
        var fetched: Bool

        enum CodingKeys: String, CodingKey { case song, audio, identity, processing }
        enum ProcessingKeys: String, CodingKey { case fetched }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            song = try c.decode(Song.self, forKey: .song)
            audio = try c.decode(Audio.self, forKey: .audio)
            identity = (try? c.decode(String.self, forKey: .identity)) ?? "unconfirmed"
            fetched = (try? c.nestedContainer(keyedBy: ProcessingKeys.self, forKey: .processing).decode(Bool.self, forKey: .fetched)) ?? false
        }
    }

    /// The most a returned length may differ from the song's, as in the matcher's rules for asking (plan S03).
    static let lengthTolerance: Double = 8
    /// A 20-minute song at 256 kbps is about 38 MB.
    static let maxBytes = 80_000_000
    /// The platform cuts any request at 240 s.
    static let requestTimeout: TimeInterval = 240

    /// Asks the service for the song and downloads its audio to `directory/song-<id>.m4a`, with the service's own retry
    /// rules (§4): 503 waits `Retry-After` (at most 30 s) and tries once more; a timeout, 500 or 504 tries again after
    /// 5 s, then 15 s. A request the first time often runs past the platform's cut while the service is still fetching,
    /// and the next try finds the song held.
    @concurrent
    static func fetch(_ ask: Ask, expectedSeconds: Double? = nil, config: Config, into directory: URL,
                      session: URLSession? = nil,
                      sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                      progress: @escaping @Sendable (Double) -> Void = { _ in },
                      isCancelled: @escaping @Sendable () -> Bool = { false }) async throws -> Song {
        guard ask.isUsable else { throw Failure.badRequest }
        let ownSession = session == nil
        let session = session ?? makeSession()
        defer { if ownSession { session.finishTasksAndInvalidate() } }

        var transient = 0
        var waitedBusy = false
        let reply: Reply
        while true {
            if isCancelled() || Task.isCancelled { throw CancellationError() }
            switch try await post(ask, config: config, session: session) {
            case .reply(let r):
                reply = r
            case .busy(let wait) where !waitedBusy:
                waitedBusy = true
                try await sleep(min(max(wait, 1), 30))
                continue
            case .transient where transient < 2:
                transient += 1
                try await sleep(transient == 1 ? 5 : 15)
                continue
            case .busy, .transient:
                throw Failure.unavailable
            case .failed(let failure):
                if failure == .unauthorized || failure == .badRequest { stopped.withLock { $0 = true } }
                throw failure
            }
            break
        }
        if reply.identity == "mismatch" { throw Failure.wrongRecording }
        // The length is checked before downloading when the reply says it; when it doesn't (the contract allows
        // null), the audio itself is measured below. An unchecked length is never a pass.
        if let expected = expectedSeconds, let seconds = reply.song.seconds, abs(seconds - expected) > lengthTolerance {
            throw Failure.wrongRecording
        }
        guard let link = reply.audio.url else { throw Failure.unavailable }
        if isCancelled() || Task.isCancelled { throw CancellationError() }

        // The signed link is on the service's storage: fetched without the key, which never leaves for another host.
        // A download task straight to disk, so the bar moves and the song never sits whole in memory (L2).
        let temp: URL
        let response: URLResponse
        do {
            (temp, response) = try await FileLinkDownload.transfer(URLRequest(url: link), configuration: session.configuration,
                                                                   timeout: 120, maxBytes: Int64(maxBytes),
                                                                   progress: progress, isCancelled: isCancelled)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.unavailable
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        let size = ((try? FileManager.default.attributesOfItem(atPath: temp.path)[.size]) as? Int) ?? 0
        guard (response as? HTTPURLResponse)?.statusCode == 200, size > 1_000, size <= maxBytes else {
            throw Failure.unavailable
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeID = reply.song.songID.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        let file = directory.appendingPathComponent("song-\(safeID.isEmpty ? UUID().uuidString : safeID).m4a")
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temp, to: file)
        if let expected = expectedSeconds, reply.song.seconds == nil {
            guard let measured = await AudioDecoder.duration(of: file), abs(measured - expected) <= lengthTolerance else {
                try? FileManager.default.removeItem(at: file)
                throw Failure.wrongRecording
            }
        }
        progress(1)
        AppLog.note("song service: \(reply.fetched ? "fetched" : "held"), identity \(reply.identity), \(size / 1024) KB")
        return Song(file: file, title: reply.song.title, artist: reply.song.artist, seconds: reply.song.seconds)
    }

    enum Attempt: Equatable {
        case reply(Reply)
        case busy(Double)
        case transient
        case failed(Failure)
    }

    static func post(_ ask: Ask, config: Config, session: URLSession) async throws -> Attempt {
        var request = URLRequest(url: config.base.appendingPathComponent("v1/songs/download"))
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.key, forHTTPHeaderField: "X-Api-Key")
        request.httpBody = try JSONEncoder().encode(ask)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .transient }
            return attempt(status: http.statusCode, data: data, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .notConnectedToInternet || error.code == .dataNotAllowed { return .failed(.unavailable) }
            return .transient
        }
    }

    /// One answer by the service's rules (§4).
    static func attempt(status: Int, data: Data, retryAfter: String?) -> Attempt {
        switch status {
        case 200:
            guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return .failed(.unavailable) }
            return .reply(reply)
        case 400: return .failed(.badRequest)
        case 401: return .failed(.unauthorized)
        // The service's own 404 has an "error" body; a framework 404 ("detail") means the route isn't deployed.
        case 404: return .failed(String(decoding: data, as: UTF8.self).contains("\"error\"") ? .notHeld : .unavailable)
        case 502: return .failed(.refused)
        case 503: return .busy(retryAfter.flatMap(Double.init) ?? 5)
        case 500, 504: return .transient
        default: return .failed(.unavailable)
        }
    }

    /// No cookies, no cache, and the key dropped from any request a redirect sends to another host.
    static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = requestTimeout
        c.timeoutIntervalForResource = requestTimeout + 120
        return URLSession(configuration: c, delegate: KeyGuard(), delegateQueue: nil)
    }

    /// The completion-handler form, like `YouTubeExtractor.RedirectGuard` (B05: the `async` form crashes here).
    final class KeyGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(Self.redirect(request, from: task.originalRequest?.url))
        }

        static func redirect(_ request: URLRequest, from original: URL?) -> URLRequest {
            guard request.url?.host?.lowercased() != original?.host?.lowercased() else { return request }
            var next = request
            next.setValue(nil, forHTTPHeaderField: "X-Api-Key")
            return next
        }
    }
}

#if DEBUG
/// UI tests walk the "Trying another way…" path without the service: `--song-service-stub fail` fails after a moment.
nonisolated enum SongServiceStub {
    static let mode: String? = {
        guard let i = CommandLine.arguments.firstIndex(of: "--song-service-stub"), i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }()
}
#endif
