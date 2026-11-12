#if DEBUG
import AVFoundation
import Foundation

/// `--link-smoke` (R01a, R01p): gets one link of each kind the app opens, without splitting, and prints a
/// `[smoke]` line for each: a Creative Commons YouTube video through the normal ladder, the same video
/// through the TV rung alone (it times the player script and a JavaScriptCore solve, which runs without
/// JIT on an iPhone), through the proof-of-origin rung alone (a token minted in the hidden web view), the
/// owner's Vimeo example and a direct mp3.
nonisolated enum LinkSmoke {
    /// Kevin MacLeod, "Volatile Reaction" (CC BY 4.0).
    static let youTube = "https://youtu.be/2pXa5jzaOBg"
    static let vimeo = "https://vimeo.com/channels/musicvideos/926983242"
    /// Kevin MacLeod, "Cattails" (CC BY 3.0) on Wikimedia Commons. His own site takes over 20 s to send the
    /// first byte, past the file-link timeout.
    static let mp3 = "https://upload.wikimedia.org/wikipedia/commons/4/4c/Kevin_MacLeod_-_Cattails.mp3"

    /// Runs every case and returns how many worked.
    @concurrent
    static func run() async -> Int {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("link-smoke", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        var ok = 0
        let never: @Sendable () -> Bool = { false }

        ok += await step("youtube") {
            let r = try await YouTubeImport.download(YouTubeImport.parse(youTube)!, jar: .none, into: dir, progress: { _ in }, isCancelled: never)
            return (r.file, r.title)
        }

        let session = YouTubeExtractor.makeSession()
        do {
            var start = Date()
            let player = try await PlayerScript.current(session: session, say: { _ in })
            let ready = Date().timeIntervalSince(start)
            start = Date()
            _ = try PlayerScript.solve(player, sig: nil, n: "KBx1qz7jMhxELa8c")
            print("[smoke] player \(player.id) ready in \(String(format: "%.2f", ready)) s, n solved in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        } catch {
            print("[smoke] player FAILED: \(error)")
        }
        session.finishTasksAndInvalidate()

        ok += await step("youtube-tv") {
            let r = try await YouTubeImport.download(YouTubeImport.parse(youTube)!, jar: .none, into: dir.appendingPathComponent("tv"),
                                                     ladder: [.tvSamsung], routes: .directOnly, progress: { _ in }, isCancelled: never)
            return (r.file, r.title)
        }
        ok += await step("youtube-po") {
            let r = try await YouTubeImport.download(YouTubeImport.parse(youTube)!, jar: .none, into: dir.appendingPathComponent("po"),
                                                     routes: .directOnly, proofOfOrigin: .only,
                                                     trace: { if $0.hasPrefix("po token") { print("[smoke] \($0)") } },
                                                     progress: { _ in }, isCancelled: never)
            return (r.file, r.title)
        }
        ok += await step("vimeo") {
            guard case .vimeo(let id, let hash) = WebLink.classify(vimeo) else { throw VimeoExtractor.Failure.unavailable }
            let r = try await VimeoExtractor.fetch(id: id, hash: hash, link: URL(string: vimeo), into: dir, progress: { _ in }, isCancelled: never)
            return (r.file, r.title)
        }
        ok += await step("mp3") {
            let file = try await FileLinkDownload.download(URL(string: mp3)!, into: dir, progress: { _ in }, isCancelled: never)
            return (file, file.lastPathComponent)
        }
        print("[smoke] done \(ok)/5")
        return ok
    }

    /// One case: its time, the decoded length and size of what came down, or why it failed.
    private static func step(_ name: String, _ body: () async throws -> (URL, String?)) async -> Int {
        let start = Date()
        do {
            let (file, title) = try await body()
            let audio = try AVAudioFile(forReading: file)
            let seconds = Double(audio.length) / audio.processingFormat.sampleRate
            let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? Int ?? 0
            print("[smoke] \(name) ok in \(String(format: "%.1f", Date().timeIntervalSince(start))) s: \"\(title ?? "?")\" "
                  + "\(String(format: "%.1f", seconds)) s of audio, \(bytes / 1024) KB")
            return 1
        } catch {
            print("[smoke] \(name) FAILED after \(String(format: "%.1f", Date().timeIntervalSince(start))) s: \(error.localizedDescription)")
            return 0
        }
    }
}
#endif
