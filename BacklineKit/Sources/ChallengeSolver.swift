import Foundation
import JavaScriptCore

/// YouTube's "n" and signature challenges, solved in this process by yt-dlp's EJS solver: two pinned,
/// public-domain JavaScript files (`lib.min.js`, `core.min.js`) run in Apple's JavaScriptCore. No other
/// program and no interpreter is involved (release plan, Decision 8).
///
/// The solver reads YouTube's player script and returns the answers. It can also hand back a
/// "preprocessed player" (the two functions it found), which makes later solves for the same player
/// version about twenty times faster; callers keep it on disk.
public final class ChallengeSolver: @unchecked Sendable {
    public struct Answers: Sendable, Equatable {
        public var n: [String: String] = [:]
        public var sig: [String: String] = [:]
        /// Present when asked for: the player reduced to what the solver needs, for the next solve.
        public var preprocessedPlayer: String?
    }

    public enum Failure: Error, Equatable {
        /// The solver couldn't find or run the player's functions (YouTube changed its player).
        case solver(String)
    }

    private let lock = NSLock()
    private let context: JSContext

    /// `lib` and `core` are the contents of yt-dlp-ejs's `lib.min.js` and `core.min.js`.
    public init(lib: String, core: String) throws {
        guard let context = JSContext() else { throw Failure.solver("no JavaScript context") }
        self.context = context
        var thrown: String?
        context.exceptionHandler = { _, e in thrown = e?.toString() }
        context.evaluateScript(lib + "\nObject.assign(globalThis, lib);\n" + core)
        context.exceptionHandler = nil
        if let thrown { throw Failure.solver("loading the solver: \(thrown)") }
        guard context.objectForKeyedSubscript("jsc")?.isObject == true else { throw Failure.solver("no jsc function") }
    }

    /// Loads the bundled solver files from `directory` (`lib.min.js`, `core.min.js`).
    public convenience init(directory: URL) throws {
        try self.init(lib: String(contentsOf: directory.appendingPathComponent("lib.min.js"), encoding: .utf8),
                      core: String(contentsOf: directory.appendingPathComponent("core.min.js"), encoding: .utf8))
    }

    /// Solves `n` and `sig` challenges with the player script, or with a preprocessed player from an
    /// earlier solve (faster). Set `keepPreprocessed` to get one back.
    public func solve(player: String? = nil, preprocessed: String? = nil, n: [String] = [], sig: [String] = [],
                      keepPreprocessed: Bool = false) throws -> Answers {
        var requests: [[String: Any]] = []
        if !n.isEmpty { requests.append(["type": "n", "challenges": n]) }
        if !sig.isEmpty { requests.append(["type": "sig", "challenges": sig]) }
        var input: [String: Any] = ["requests": requests]
        if let preprocessed {
            input["type"] = "preprocessed"
            input["preprocessed_player"] = preprocessed
        } else if let player {
            input["type"] = "player"
            input["player"] = player
            input["output_preprocessed"] = keepPreprocessed
        } else {
            throw Failure.solver("no player")
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)

        return try lock.withLock {
            var thrown: String?
            context.exceptionHandler = { _, e in thrown = e?.toString() }
            defer { context.exceptionHandler = nil }
            let parse = context.objectForKeyedSubscript("JSON").objectForKeyedSubscript("parse")
            let stringify = context.objectForKeyedSubscript("JSON").objectForKeyedSubscript("stringify")
            guard let arg = parse?.call(withArguments: [json]),
                  let result = context.objectForKeyedSubscript("jsc").call(withArguments: [arg]),
                  let text = stringify?.call(withArguments: [result])?.toString(), thrown == nil,
                  let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                throw Failure.solver(thrown ?? "no result")
            }
            guard root["type"] as? String == "result", let responses = root["responses"] as? [[String: Any]] else {
                throw Failure.solver(root["error"] as? String ?? "unexpected result")
            }
            var answers = Answers(preprocessedPlayer: root["preprocessed_player"] as? String)
            for (request, response) in zip(requests, responses) {
                guard response["type"] as? String == "result", let data = response["data"] as? [String: String] else {
                    throw Failure.solver(response["error"] as? String ?? "no answer")
                }
                if request["type"] as? String == "n" { answers.n = data } else { answers.sig = data }
            }
            return answers
        }
    }
}
