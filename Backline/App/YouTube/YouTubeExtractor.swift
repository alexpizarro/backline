import Foundation

/// Gets one video's audio onto disk: asks YouTube's InnerTube API for the stream (trying client identities
/// in turn until one hands back audio that really downloads), then fetches the plain AAC stream in ranged
/// chunks, or the audio-only HLS rendition when the stream is refused.
nonisolated enum YouTubeExtractor {
    struct Output: Sendable {
        var file: URL
        var title: String?
        var author: String?
        var clientID: String
        var route: Route
        var itag: Int
        var bytes: Int
        var claimedSeconds: Double?
    }

    enum Route: String, Sendable { case direct, hls }

    /// Twenty minutes, or less on a device that can't split that much (R04).
    static var maxSeconds: Int { min(1200, Int(DeviceLimits.maxSongSeconds)) }
    static let maxBytes = 150 << 20
    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    static let networkMessage = "Can't connect. Check your internet."
    static let unavailableMessage = "Video not available."
    static let genericMessage = "Nothing came back. Record it instead."

    /// How one client's turn ended when it didn't produce a file.
    enum Miss: Equatable {
        case loginRequired, unavailable, liveOffline, rejected, noAudio, unreadableAudio, forbidden, network
        /// The stream stopped short (android_vr without a token stops after its first MiB).
        case cutOff
    }

    /// Which routes a test or tool wants to exercise.
    enum Routes: Sendable { case any, directOnly, hlsOnly }

    /// The proof-of-origin rung (R01p): as the last resort (`fallback`), never, or alone (tests and tools).
    /// Left out, it is the fallback for the normal ladder and off when a caller forces its own ladder, so a
    /// test of one client can't pass through the rung.
    enum ProofOfOrigin: Sendable { case fallback, off, only }

    /// Tokens for one try of the PO rung.
    struct ProofTokens: Sendable {
        var stream: String
        var player: String
    }

    /// What the extractor is doing while no audio has arrived yet, for the Getting-the-song screen (L2).
    enum Stage: Sendable, Equatable {
        case connecting
        /// A client's answer came with a pre-roll ad: the stream opens once it could have been skipped.
        case waitingForVideo
    }

    private enum Turn {
        case done(Output)
        /// `waitedForAd`: the turn sat out an ad slot first, so asking again would wait for a new one (L1).
        case missed(Miss, waitedForAd: Bool)
    }

    /// Asks for a fresh player answer after a refused stream at most this often per client (L1): googlevideo's
    /// random refusal of fresh URLs needs one; a stream that wants a proof of origin is refused every time.
    static let refusedRetries = 1

    // MARK: Entry point

    /// `ladder` and `routes` override the defaults (tests and tooling); `trace` receives one short line per
    /// step (never URLs or cookie values).
    static func fetch(videoID: String, cookies: YouTubeCookies, destination: URL, ladder: [InnerTubeClient]? = nil,
                      routes: Routes = .any, proofOfOrigin: ProofOfOrigin? = nil, session given: URLSession? = nil,
                      trace: (@Sendable (String) -> Void)? = nil,
                      onMetadata: (@Sendable (_ title: String?, _ author: String?) -> Void)? = nil,
                      onStage: (@Sendable (Stage) -> Void)? = nil,
                      progress: @escaping @Sendable (Double) -> Void,
                      isCancelled: @escaping @Sendable () -> Bool) async throws -> Output {
        let say = trace ?? { _ in }
        let stage = onStage ?? { _ in }
        let proofOfOrigin = proofOfOrigin ?? (ladder == nil ? .fallback : .off)
        let session = given ?? makeSession()
        defer { if given == nil { session.finishTasksAndInvalidate() } }
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let part = destination.appendingPathComponent("\(videoID).m4a.part")
        let final = destination.appendingPathComponent("\(videoID).m4a")
        defer { try? fm.removeItem(at: part) }

        do {
            stage(.connecting)
            var visitor = try await visitorData(session: session, videoID: videoID, cookies: cookies, say: say)
            let clients = proofOfOrigin == .only ? [] : ladder ?? InnerTubeClient.ladder
            var misses: [Miss] = []
            var answered = false
            // Clients whose streams were refused. Once both defaults have been, `android_vr`, which also needs a
            // token for its streams, would only be refused too; `ios` still gets its turn (its HLS rendition isn't
            // gated) (L1).
            var refused: Set<String> = []

            clients: for client in clients {
                if client.id == InnerTubeClient.androidVR.id,
                   refused.isSuperset(of: [InnerTubeClient.visionOS.id, InnerTubeClient.tvSamsung.id]) {
                    say("\(client.id): skipped, the streams want a proof of origin")
                    continue clients
                }
                // A signed-in session goes anonymous first: the cookies are only worth sending if YouTube asks.
                var authentications: [YouTubeCookies?] = [nil]
                if cookies.isSignedIn { authentications.append(cookies) }
                var tries = 0
                var index = 0
                while index < authentications.count {
                    if Task.isCancelled || isCancelled() { throw CancellationError() }
                    tries += 1
                    let turn = try await attempt(client: client, videoID: videoID, visitor: visitor, cookies: authentications[index],
                                                 session: session, part: part, routes: routes, say: say, onMetadata: onMetadata,
                                                 stage: stage, progress: progress, isCancelled: isCancelled)
                    switch turn {
                    case .done(var output):
                        try? fm.removeItem(at: final)
                        try fm.moveItem(at: part, to: final)
                        output.file = final
                        return output
                    case .missed(let miss, let waitedForAd):
                        try? fm.removeItem(at: part)
                        stage(.connecting)
                        if miss == .forbidden || miss == .loginRequired { VisitorCache.shared.drop() }
                        // googlevideo refuses a share of fresh URLs at random; a new player response usually fixes it.
                        // Once, and not after an ad slot: a new answer brings a new ad to wait for (L1).
                        if miss == .forbidden, tries <= refusedRetries, !waitedForAd {
                            say("\(client.id): stream refused, asking again")
                            visitor = try await visitorData(session: session, videoID: videoID, cookies: .none, say: say) ?? visitor
                            continue
                        }
                        if miss == .forbidden { refused.insert(client.id) }
                        if miss == .loginRequired, index + 1 < authentications.count {
                            say("\(client.id): wants a sign-in; retrying with the session")
                            index += 1
                            tries = 0
                            continue
                        }
                        say("\(client.id): \(miss)")
                        if miss != .network { answered = true }
                        misses.append(miss)
                        // Two clients agreeing the video is gone is enough; the rest would only repeat it.
                        if misses.filter({ $0 == .unavailable }).count >= 2, !misses.contains(.loginRequired) { break clients }
                        continue clients
                    }
                }
            }

            // The last resort, after the signed-in path (owner, 22 Oct): YouTube may refuse streams that carry
            // no proof of origin. Mint one in the hidden web view and try the mobile web client with it,
            // anonymously first, then with the session when YouTube wants a sign-in.
            if routes != .hlsOnly, proofOfOrigin == .only
                || (proofOfOrigin == .fallback && POTokenMinter.isEnabled && wantsProofOfOrigin(misses, signedIn: cookies.isSignedIn)) {
                var authentications: [YouTubeCookies?] = [nil]
                if cookies.isSignedIn { authentications.append(cookies) }
                po: for auth in authentications {
                    if Task.isCancelled || isCancelled() { throw CancellationError() }
                    // The player script first: without it the token would be wasted.
                    let player: PlayerScript.Player
                    do {
                        player = try await PlayerScript.current(session: session, say: say)
                    } catch {
                        say("mweb: player script unusable (\(error))")
                        break po
                    }
                    // A stream token is bound to the video, or (outside YouTube's experiment) to the visitor, or to
                    // the account when signed in; both are minted and tried in the order the homepage suggests.
                    let binding = auth == nil ? visitor.map(boundVisitorData)
                        : (try? await dataSyncID(session: session, videoID: videoID, cookies: cookies)) ?? nil
                    let tokens: POTokenMinter.Tokens
                    do {
                        tokens = try await POTokenMinter.mint(streamBinding: binding, videoID: videoID, session: session, say: say)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as URLError {
                        if error.code == .cancelled { throw CancellationError() }
                        misses.append(.network)
                        break po
                    } catch {
                        say("po token: not minted (\(error))")
                        break po
                    }
                    var last = Miss.forbidden
                    for stream in tokens.stream {
                        let turn = try await attempt(client: .mweb, videoID: videoID, visitor: visitor, cookies: auth,
                                                     tokens: ProofTokens(stream: stream, player: tokens.player), presetPlayer: player,
                                                     session: session, part: part, routes: routes, say: say, onMetadata: onMetadata,
                                                     stage: stage, progress: progress, isCancelled: isCancelled)
                        switch turn {
                        case .done(var output):
                            try? fm.removeItem(at: final)
                            try fm.moveItem(at: part, to: final)
                            output.file = final
                            return output
                        case .missed(let miss, _):
                            try? fm.removeItem(at: part)
                            stage(.connecting)
                            say("mweb with po token: \(miss)")
                            last = miss
                        }
                        // Only a refused stream is worth the other binding.
                        if last != .forbidden { break }
                    }
                    if last != .network { answered = true }
                    misses.append(last)
                    // Only a sign-in wall is worth the signed-in try.
                    if last != .loginRequired { break po }
                }
            }
            throw failure(for: misses, answered: answered)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw YouTubeImport.Failure.failed(networkMessage)
        }
    }

    /// Whether the proof-of-origin rung is worth a try: streams were refused or missing (what a token can
    /// fix), the video itself is fine, and any sign-in wall has already met the signed-in session.
    static func wantsProofOfOrigin(_ misses: [Miss], signedIn: Bool) -> Bool {
        if misses.contains(where: { [.unavailable, .liveOffline, .unreadableAudio].contains($0) }) { return false }
        if misses.contains(.loginRequired), !signedIn { return false }
        return misses.contains { [.forbidden, .noAudio, .cutOff, .loginRequired].contains($0) }
    }

    /// Visitor data as YouTube hands it out ("…%3D%3D"), the form a stream token is bound to; the extractor
    /// keeps it decoded.
    static func boundVisitorData(_ visitor: String) -> String {
        visitor.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")) ?? visitor
    }

    /// What to tell the user once every client has had its turn.
    static func failure(for misses: [Miss], answered: Bool) -> YouTubeImport.Failure {
        if misses.contains(.loginRequired) { return .needsSignIn }
        if misses.contains(.unreadableAudio) { return .unsupportedFormat }
        if misses.contains(.liveOffline) { return .failed("Live stream hasn't started.") }
        if misses.contains(.unavailable) { return .failed(unavailableMessage) }
        if !answered, misses.contains(.network) { return .failed(networkMessage) }
        return .failed(genericMessage)
    }

    // MARK: One client's turn

    private static func attempt(client: InnerTubeClient, videoID: String, visitor: String?, cookies: YouTubeCookies?,
                                tokens: ProofTokens? = nil, presetPlayer: PlayerScript.Player? = nil, session: URLSession, part: URL, routes: Routes, say: @Sendable (String) -> Void,
                                onMetadata: (@Sendable (String?, String?) -> Void)? = nil,
                                stage: @Sendable (Stage) -> Void,
                                progress: @escaping @Sendable (Double) -> Void,
                                isCancelled: @escaping @Sendable () -> Bool) async throws -> Turn {
        // TV clients answer with locked streams: the player script's timestamp goes in the request, and the
        // script unlocks the chosen stream below.
        var player = presetPlayer
        if client.needsPlayer, player == nil {
            do {
                player = try await PlayerScript.current(session: session, say: say)
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                return .missed(.network, waitedForAd: false)
            } catch {
                say("\(client.id): player script unusable (\(error))")
                return .missed(.rejected, waitedForAd: false)
            }
        }

        var request = URLRequest(url: InnerTubeClient.playerURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.httpBody = client.playerRequestBody(videoID: videoID, visitorData: visitor,
                                                    signatureTimestamp: player?.signatureTimestamp, poToken: tokens?.player)
        for (k, v) in client.playerHeaders(visitorData: visitor, cookies: cookies) { request.setValue(v, forHTTPHeaderField: k) }

        let data: Data
        do {
            let (body, http) = try await send(session, request)
            guard http.statusCode == 200 else { say("\(client.id): HTTP \(http.statusCode)"); return .missed(.rejected, waitedForAd: false) }
            data = body
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            return .missed(.network, waitedForAd: false)
        }

        guard var response = try? PlayerResponse.parse(data), response.videoID == nil || response.videoID == videoID else {
            return .missed(.rejected, waitedForAd: false)
        }
        switch response.playability {
        case .ok: break
        case .loginRequired: return .missed(.loginRequired, waitedForAd: false)
        case .unavailable: return .missed(.unavailable, waitedForAd: false)
        case .liveOffline: return .missed(.liveOffline, waitedForAd: false)
        case .clientRejected: return .missed(.rejected, waitedForAd: false)
        }
        if response.isLive { throw YouTubeImport.Failure.failed("Live streams can't be split.") }
        if let seconds = response.lengthSeconds, seconds > maxSeconds { throw YouTubeImport.Failure.tooLong }
        // TV clients leave the title and channel out; oEmbed has both.
        if response.title == nil, let named = await oEmbed(videoID: videoID, session: session) {
            response.title = named.title
            response.author = response.author ?? named.author
        }
        // The title is known as soon as YouTube answers: show it while the audio downloads.
        onMetadata?(response.title, response.author)

        // The pre-roll ad's turn: googlevideo refuses the streams until it could have been skipped.
        if response.adWaitSeconds > 0 {
            say("\(client.id): waiting \(Int(response.adWaitSeconds.rounded(.up))) s for the ad slot")
            stage(.waitingForVideo)
            try await wait(response.adWaitSeconds, isCancelled: isCancelled)
            stage(.connecting)
        }
        let waitedForAd = response.adWaitSeconds > 0

        var miss = Miss.noAudio
        if routes != .hlsOnly {
            if let format = response.bestAAC(unlocking: player != nil),
               let unlocked = streamURL(format, player: player, client: client, say: say),
               let url = tokens.map({ PlayerResponse.adding(pot: $0.stream, to: unlocked) }) ?? unlocked {
                say("\(client.id): direct itag \(format.itag)")
                let size = format.contentLength ?? URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "clen" }?.value.flatMap { Int($0) }
                do {
                    let bytes = try await RangedDownload.run(session: session, url: url, userAgent: client.userAgent, knownSize: size,
                                                             maxBytes: maxBytes, to: part, progress: progress, isCancelled: isCancelled)
                    return .done(Output(file: part, title: response.title, author: response.author, clientID: client.id,
                                        route: .direct, itag: format.itag, bytes: bytes,
                                        claimedSeconds: format.durationMs.map { Double($0) / 1000 }))
                } catch RangedDownload.Failure.forbidden {
                    miss = .forbidden
                } catch RangedDownload.Failure.tooLarge {
                    throw YouTubeImport.Failure.tooLong
                } catch let failure as RangedDownload.Failure {
                    say("\(client.id): direct download stopped (\(failure))")
                    miss = failure == .truncated ? .cutOff : .rejected
                } catch let error as URLError {
                    if error.code == .cancelled { throw CancellationError() }
                    miss = .network
                }
                try? FileManager.default.removeItem(at: part)
            } else if response.hasOnlyUnreadableAudio {
                miss = .unreadableAudio
            }
        }

        if routes != .directOnly, let manifest = response.hlsManifestURL {
            say("\(client.id): trying the HLS audio rendition")
            do {
                let hls = try await HLSAudio.download(manifest: manifest, session: session, userAgent: client.userAgent,
                                                      maxSeconds: Double(maxSeconds), to: part, progress: progress,
                                                      isCancelled: isCancelled)
                let bytes = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size]) as? Int ?? 0
                if bytes > maxBytes { throw YouTubeImport.Failure.tooLong }
                return .done(Output(file: part, title: response.title, author: response.author, clientID: client.id,
                                    route: .hls, itag: hls.itag, bytes: bytes, claimedSeconds: hls.seconds))
            } catch is HLSAudio.TooLong {
                throw YouTubeImport.Failure.tooLong
            } catch let failure as RangedDownload.Failure {
                say("\(client.id): HLS stopped (\(failure))")
                miss = failure == .forbidden ? .forbidden : .rejected
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                miss = .network
            } catch let error as AACFileWriter.WriteError {
                say("\(client.id): HLS audio unusable (\(error))")
                miss = .rejected
            }
            try? FileManager.default.removeItem(at: part)
        }
        return .missed(miss, waitedForAd: waitedForAd)
    }

    /// The public oEmbed answer's title and channel name; nil when it doesn't come.
    static func oEmbed(videoID: String, session: URLSession) async -> (title: String?, author: String?)? {
        var c = URLComponents(string: "https://www.youtube.com/oembed")!
        c.queryItems = [URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(videoID)"),
                        URLQueryItem(name: "format", value: "json")]
        guard let url = c.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, http) = try? await send(session, request), http.statusCode == 200 else { return nil }
        return oEmbedNames(data)
    }

    static func oEmbedNames(_ data: Data) -> (title: String?, author: String?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = root["title"] as? String, !title.isEmpty else { return nil }
        return (title, root["author_name"] as? String)
    }

    /// Sleeps in short steps so a cancel lands at once.
    private static func wait(_ seconds: Double, isCancelled: @escaping @Sendable () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds.rounded(.up))
        while Date() < end {
            if Task.isCancelled || isCancelled() { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    /// The format's download URL: as given, or unlocked by the player script (signature and `n`).
    private static func streamURL(_ format: PlayerResponse.Format, player: PlayerScript.Player?, client: InnerTubeClient,
                                  say: @Sendable (String) -> Void) -> URL? {
        guard let player else { return format.url.flatMap { URL(string: $0) } }
        let (sig, n) = PlayerResponse.challenges(of: format)
        if sig == nil, n == nil { return format.url.flatMap { URL(string: $0) } }
        do {
            let answers = try PlayerScript.solve(player, sig: sig, n: n)
            return PlayerResponse.unlockedURL(format, sig: answers.sig, n: answers.n)
        } catch {
            say("\(client.id): challenge unsolved (\(error))")
            return nil
        }
    }

    // MARK: Visitor data

    /// Anonymous visitor data, kept in memory for the app session so a second link skips a round trip (L11). It is
    /// dropped after 30 minutes, and at once when YouTube refuses a stream or wants a sign-in, so a stale one can't
    /// keep tripping a bot check. A signed-in session always takes its own.
    final class VisitorCache: @unchecked Sendable {
        static let shared = VisitorCache()
        static let lifetime: TimeInterval = 30 * 60
        private let lock = NSLock()
        private var held: (task: Task<String?, Never>, at: Date)?

        /// The held value, or the one a fetch already under way will bring.
        func current(now: Date = Date()) -> Task<String?, Never>? {
            lock.withLock {
                guard let held, now.timeIntervalSince(held.at) < Self.lifetime else { return nil }
                return held.task
            }
        }

        func hold(_ task: Task<String?, Never>, now: Date = Date()) { lock.withLock { held = (task, now) } }
        func hold(_ value: String, now: Date = Date()) { hold(Task { value }, now: now) }
        func drop() { lock.withLock { held = nil } }
    }

    /// Visitor data for this link: the held anonymous value when there is one, else a fresh fetch (held for the
    /// next link when anonymous).
    static func visitorData(session: URLSession, videoID: String, cookies: YouTubeCookies,
                            say: @Sendable (String) -> Void) async throws -> String? {
        if !cookies.isSignedIn, let held = VisitorCache.shared.current(), let value = await held.value {
            say("visitor data: reused")
            return value
        }
        let fresh = try await fetchVisitorData(session: session, videoID: videoID, cookies: cookies, say: say)
        if !cookies.isSignedIn, let fresh { VisitorCache.shared.hold(fresh) }
        return fresh
    }

    /// A music-service link's song is known: fetch the visitor data while the search runs, so the download
    /// that follows starts one round trip sooner (L11). Nothing is fetched when one is already held.
    static func prefetchVisitorData() {
        guard VisitorCache.shared.current() == nil else { return }
        let task = Task<String?, Never> {
            let session = makeSession()
            defer { session.finishTasksAndInvalidate() }
            return (try? await anonymousVisitorID(session: session)) ?? nil
        }
        VisitorCache.shared.hold(task)
    }

    /// YouTube's bot check is keyed to a visitor id; a client that sends none is told to sign in. A fresh
    /// anonymous one comes from the `visitor_id` endpoint; a signed-in session takes the one on its own page.
    static func fetchVisitorData(session: URLSession, videoID: String, cookies: YouTubeCookies,
                                 say: @Sendable (String) -> Void) async throws -> String? {
        if cookies.isSignedIn, let v = try? await visitorDataFromWatchPage(session: session, videoID: videoID, cookies: cookies) {
            return v
        }
        do {
            if let v = try await anonymousVisitorID(session: session) { return v }
        } catch let error as URLError {
            // Offline or timing out: the watch page would only wait the same again.
            if error.code == .cancelled { throw CancellationError() }
            throw error
        }
        say("visitor_id unavailable; using the watch page")
        return try await visitorDataFromWatchPage(session: session, videoID: videoID, cookies: .none)
    }

    /// A fresh anonymous visitor id from the `visitor_id` endpoint; nil when it doesn't give one.
    static func anonymousVisitorID(session: URLSession) async throws -> String? {
        var request = URLRequest(url: InnerTubeClient.visitorIDURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "context": ["client": ["clientName": "WEB", "clientVersion": "2.20260708.00.00", "hl": "en"]],
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, http) = try await send(session, request)
        return http.statusCode == 200 ? visitorData(inVisitorIDResponse: data) : nil
    }

    /// The signed-in account's data sync id, which a signed-in stream token is bound to, from the watch page.
    static func dataSyncID(session: URLSession, videoID: String, cookies: YouTubeCookies) async throws -> String? {
        guard cookies.isSignedIn, let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)&bpctr=9999999999&has_verified=1"),
              let header = cookies.header(for: url) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(header, forHTTPHeaderField: "Cookie")
        let (data, http) = try await send(session, request)
        guard http.statusCode == 200 else { return nil }
        return dataSyncID(inWatchPage: String(decoding: data, as: UTF8.self))
    }

    static func dataSyncID(inWatchPage html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #""DATASYNC_ID":"([^"]+)""#),
              let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: html) else { return nil }
        return String(html[r])
    }

    private static func visitorDataFromWatchPage(session: URLSession, videoID: String, cookies: YouTubeCookies) async throws -> String? {
        guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)&bpctr=9999999999&has_verified=1") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        if cookies.isSignedIn, let header = cookies.header(for: url) { request.setValue(header, forHTTPHeaderField: "Cookie") }
        let (data, http) = try await send(session, request)
        guard http.statusCode == 200 else { return nil }
        return visitorData(inWatchPage: String(decoding: data, as: UTF8.self))
    }

    static func visitorData(inVisitorIDResponse data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let context = root["responseContext"] as? [String: Any],
              let raw = context["visitorData"] as? String, !raw.isEmpty else { return nil }
        return raw.removingPercentEncoding ?? raw
    }

    static func visitorData(inWatchPage html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #""visitorData":"([^"]+)""#),
              let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: html) else { return nil }
        let raw = String(html[r])
        return raw.removingPercentEncoding ?? raw
    }

    // MARK: Helpers

    static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 900
        return URLSession(configuration: c, delegate: RedirectGuard(), delegateQueue: nil)
    }

    /// Keeps the signed-in Cookie and SAPISIDHASH headers on the host they were set for: a redirect to
    /// another host (a consent or "sorry" page) carries neither.
    /// The completion-handler form, not the `async` one: with this target's isolation settings the `async`
    /// form crashed the app (SIGSEGV or abort) on every redirect it handled (found 6 November 2026, the first
    /// redirect a test followed).
    final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(Self.redirect(request, from: task.originalRequest?.url))
        }

        static func redirect(_ request: URLRequest, from original: URL?) -> URLRequest {
            guard request.url?.host?.lowercased() != original?.host?.lowercased() else { return request }
            var next = request
            next.setValue(nil, forHTTPHeaderField: "Cookie")
            next.setValue(nil, forHTTPHeaderField: "Authorization")
            return next
        }
    }

    /// One retry for a connection that dropped, nothing fancier.
    private static func send(_ session: URLSession, _ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await perform(session, request)
        } catch let error as URLError where error.code == .networkConnectionLost {
            try await Task.sleep(for: .milliseconds(600))
            return try await perform(session, request)
        }
    }

    private static func perform(_ session: URLSession, _ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}
