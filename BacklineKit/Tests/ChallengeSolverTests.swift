import Foundation
import XCTest
@testable import BacklineKit

/// R01a: YouTube's challenges solved by yt-dlp's EJS solver in JavaScriptCore, checked against yt-dlp's own
/// expected answers for a recorded player.
final class ChallengeSolverTests: XCTestCase {
    /// yt-dlp/ejs's own test case for player 631d3938 (src/yt/solver/test/tests.ts).
    static let n631 = [("KBx1qz7jMhxELa8c", "ttPvh7WIptsgSw")]
    static let sig631 = [("\u{00}\u{01}\u{02}\u{03}\u{04}\u{05}\u{06}\u{07}\u{08}\u{09}\u{0a}\u{0b}\u{0c}\u{0d}\u{0e}\u{0f}\u{10}\u{11}\u{12}\u{13}\u{14}\u{15}\u{16}\u{17}\u{18}\u{19}\u{1a}\u{1b}\u{1c}\u{1d}\u{1e}\u{1f}\u{20}\u{21}\u{22}\u{23}\u{24}\u{25}\u{26}\u{27}\u{28}\u{29}\u{2a}\u{2b}\u{2c}\u{2d}\u{2e}\u{2f}\u{30}\u{31}\u{32}\u{33}\u{34}\u{35}\u{36}\u{37}\u{38}\u{39}\u{3a}\u{3b}\u{3c}\u{3d}\u{3e}\u{3f}\u{40}\u{41}\u{42}\u{43}\u{44}\u{45}\u{46}\u{47}\u{48}\u{49}\u{4a}\u{4b}\u{4c}\u{4d}\u{4e}\u{4f}\u{50}\u{51}\u{52}\u{53}\u{54}\u{55}\u{56}\u{57}\u{58}\u{59}\u{5a}\u{5b}\u{5c}\u{5d}\u{5e}\u{5f}\u{60}\u{61}\u{62}\u{63}\u{64}\u{65}\u{66}",
                          "\u{19}\u{01}\u{02}\u{03}\u{04}\u{05}\u{06}\u{07}\u{08}\u{09}\u{0a}\u{0b}\u{0c}\u{0d}\u{0e}\u{0f}\u{10}\u{11}\u{12}\u{13}\u{14}\u{15}\u{16}\u{17}\u{18}\u{00}\u{1a}\u{1b}\u{1c}\u{1d}\u{1e}\u{1f}\u{20}\u{21}\u{22}\u{23}\u{24}\u{25}\u{26}\u{27}\u{28}\u{29}\u{2a}\u{2b}\u{2c}\u{2d}\u{2e}\u{2f}\u{30}\u{31}\u{32}\u{33}\u{34}\u{35}\u{36}\u{37}\u{38}\u{39}\u{3a}\u{3b}\u{3c}\u{3d}\u{3e}\u{3f}\u{40}\u{41}\u{42}\u{43}\u{44}\u{45}\u{46}\u{47}\u{48}\u{49}\u{4a}\u{4b}\u{4c}\u{4d}\u{4e}\u{4f}\u{50}\u{51}\u{52}\u{53}\u{54}\u{55}\u{56}\u{57}\u{58}\u{59}\u{5a}\u{5b}\u{5c}\u{5d}\u{5e}\u{5f}\u{60}\u{61}\u{62}\u{63}")]

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func player() throws -> String {
        let gz = Self.root.appendingPathComponent("BacklineKit/Tests/Fixtures/player-631d3938-main.js.gz")
        let data = try Data(contentsOf: gz)
        try XCTSkipIf(data.starts(with: Data("version https://git-lfs".utf8)), "the recorded player is in Git LFS: git lfs pull")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("player-631d3938.js")
        if !FileManager.default.fileExists(atPath: out.path) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
            p.arguments = ["-c", gz.path]
            let pipe = Pipe()
            p.standardOutput = pipe
            try p.run()
            let js = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            try js.write(to: out)
        }
        return try String(contentsOf: out, encoding: .utf8)
    }

    private func solver() throws -> ChallengeSolver {
        try ChallengeSolver(directory: Self.root.appendingPathComponent("Backline/Resources/ejs"))
    }

    func testSolvesNAndSignatureLikeYtDlp() throws {
        let s = try solver()
        let a = try s.solve(player: try player(), n: Self.n631.map(\.0), sig: Self.sig631.map(\.0), keepPreprocessed: true)
        for (input, expected) in Self.n631 { XCTAssertEqual(a.n[input], expected, "n") }
        for (input, expected) in Self.sig631 { XCTAssertEqual(a.sig[input], expected, "sig") }
        XCTAssertNotNil(a.preprocessedPlayer)
    }

    func testThePreprocessedPlayerGivesTheSameAnswersFaster() throws {
        let s = try solver()
        let js = try player()
        let t0 = Date()
        let first = try s.solve(player: js, n: Self.n631.map(\.0), keepPreprocessed: true)
        let full = Date().timeIntervalSince(t0)
        let t1 = Date()
        let again = try s.solve(preprocessed: first.preprocessedPlayer, n: Self.n631.map(\.0))
        let cached = Date().timeIntervalSince(t1)
        XCTAssertEqual(again.n, first.n)
        XCTAssertLessThan(cached, full, "cached \(cached) s vs \(full) s")
        try? "full \(full) s, cached \(cached) s".write(toFile: "/tmp/solver-times.txt", atomically: true, encoding: .utf8)
    }

    func testAPlayerWithoutTheFunctionsIsAnError() throws {
        XCTAssertThrowsError(try solver().solve(player: "var x = 1;", n: ["abc"]))
    }
}
