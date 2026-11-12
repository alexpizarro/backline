import BacklineKit
import Foundation

/// "Open a YouTube link": fetches the audio track of one video with a native InnerTube client (iOS can't
/// run yt-dlp) and hands the file to the normal import. Audio only, one video at a time, capped at
/// the device's song length limit (DeviceLimits) and ~150 MB. See `Backline/App/YouTube/` for the extractor and its fallbacks.
nonisolated enum YouTubeImport {
    /// Kill switch: hides every entry point when false.
    static let isEnabled = true

    typealias Video = YouTubeLink

    static func parse(_ text: String) -> Video? { YouTubeLink.parse(text) }
    static func find(in text: String) -> Video? { YouTubeLink.find(in: text) }

    /// The video's own thumbnail (16:9, no bars): the high-res frame when it exists, else the medium one.
    static func thumbnail(for id: String) async -> Data? {
        for name in ["maxresdefault", "mqdefault"] {
            guard let url = URL(string: "https://i.ytimg.com/vi/\(id)/\(name).jpg"),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, data.count > 2_000 else { continue }
            return data
        }
        return nil
    }

    struct Result: Sendable {
        var file: URL
        var title: String?
        var uploader: String?
        /// The InnerTube client that produced the file (tests check which rung did).
        var clientID: String?
    }

    enum Failure: LocalizedError {
        case unsupportedFormat
        case tooLong
        /// YouTube wants a signed-in account (bot check, age limit, members-only, private).
        case needsSignIn
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .unsupportedFormat: "Can't read this video's sound."
            case .tooLong: DeviceLimits.tooLongMessage(seconds: Double(YouTubeExtractor.maxSeconds))
            case .needsSignIn: "This link needs a sign-in."
            case .failed(let m): m
            }
        }
    }

    /// Marker in the failure message the error screen uses to offer "Sign in to YouTube".
    static let signInMessage = Failure.needsSignIn.errorDescription!

    /// Leftovers from an interrupted download (called at launch).
    static func cleanUp() {
        let fm = FileManager.default
        let dir = ImportStaging.downloadsDirectory
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".part") {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// Downloads the audio into `ImportStaging.downloadsDirectory/<id>.m4a`. Signed-in cookies, when given,
    /// are used for the one request chain and never stored or logged.
    @concurrent
    static func download(_ video: Video, cookies: [HTTPCookie] = [],
                         onMetadata: (@Sendable (_ title: String?, _ author: String?) -> Void)? = nil,
                         onStage: (@Sendable (YouTubeExtractor.Stage) -> Void)? = nil,
                         progress: @escaping @Sendable (Double) -> Void,
                         isCancelled: @escaping @Sendable () -> Bool) async throws -> Result {
        #if DEBUG
        if LinkStub.isSlow {
            // `--link-stub slow`: nothing arrives for 20 s, then the phone gives up (L2's UI test).
            onStage?(.connecting)
            let end = Date().addingTimeInterval(LinkStub.slowSeconds)
            while Date() < end {
                if Task.isCancelled || isCancelled() { throw CancellationError() }
                try await Task.sleep(for: .milliseconds(200))
            }
            throw Failure.failed(YouTubeExtractor.genericMessage)
        }
        #endif
        return try await download(video, jar: YouTubeCookies(cookies), into: ImportStaging.downloadsDirectory, onMetadata: onMetadata,
                                  onStage: onStage, progress: progress, isCancelled: isCancelled)
    }

    static func download(_ video: Video, jar: YouTubeCookies, into directory: URL, ladder: [InnerTubeClient]? = nil,
                         routes: YouTubeExtractor.Routes = .any, proofOfOrigin: YouTubeExtractor.ProofOfOrigin? = nil,
                         trace: (@Sendable (String) -> Void)? = nil,
                         onMetadata: (@Sendable (_ title: String?, _ author: String?) -> Void)? = nil,
                         onStage: (@Sendable (YouTubeExtractor.Stage) -> Void)? = nil,
                         progress: @escaping @Sendable (Double) -> Void,
                         isCancelled: @escaping @Sendable () -> Bool) async throws -> Result {
        if isCancelled() { throw CancellationError() }
        progress(0)
        do {
            let out = try await YouTubeExtractor.fetch(videoID: video.id, cookies: jar, destination: directory, ladder: ladder,
                                                       routes: routes, proofOfOrigin: proofOfOrigin, trace: trace, onMetadata: onMetadata,
                                                       onStage: onStage, progress: progress, isCancelled: isCancelled)
            return Result(file: out.file, title: out.title, uploader: out.author, clientID: out.clientID)
        } catch let error as Failure {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw Failure.failed(YouTubeExtractor.networkMessage)
        } catch {
            throw Failure.failed(YouTubeExtractor.genericMessage)
        }
    }
}

#if DEBUG
/// `--link-stub slow`: a YouTube link on which nothing arrives for 20 s and the phone then gives up, so a UI test
/// can watch the Getting-the-song screen's long wait (L2) without the network. With `--song-service-stub` the song
/// service then takes its turn.
nonisolated enum LinkStub {
    static let isSlow: Bool = {
        guard let i = CommandLine.arguments.firstIndex(of: "--link-stub"), i + 1 < CommandLine.arguments.count else { return false }
        return CommandLine.arguments[i + 1] == "slow"
    }()
    static let slowSeconds: Double = 20
}
#endif
