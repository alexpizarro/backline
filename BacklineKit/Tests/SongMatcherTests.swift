import Foundation
import XCTest
@testable import BacklineKit

/// S03: finding the same recording. The rules on their own, the two search responses as recorded on
/// 5 November 2026, and the corpus: 202 tracks of the three playlists in `docs/release-1.1-plan.md`, where
/// this matcher must reach the same verdict and the same pick as `scripts/spotify-probe.py` did.
final class SongMatcherTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    // MARK: The rules

    func testTitlesLoseAccentsPunctuationAndCredits() {
        XCTAssertEqual(SongMatcher.norm("Devórame"), "devorame")
        XCTAssertEqual(SongMatcher.norm("Hey Jude (feat. Someone)"), "hey jude")
        XCTAssertEqual(SongMatcher.norm("Hey Jude (with Someone Else)"), "hey jude")
        XCTAssertEqual(SongMatcher.norm("Imagine - Remastered 2011"), "imagine")
        XCTAssertEqual(SongMatcher.norm("Imagine (Remastered)"), "imagine")
        XCTAssertEqual(SongMatcher.norm("Song feat. Someone"), "song")
        XCTAssertEqual(SongMatcher.norm("¿Y Qué Pasó? / Nada!"), "y que paso nada")
        XCTAssertEqual(SongMatcher.norm("Amantes De Novela 2"), "amantes de novela 2", "a number is part of the title")
    }

    func testDecorationsComeOffAVideoTitle() {
        let dressed = "Artist - The Song (Official Audio) [Lyrics] | Letra #bachata"
        XCTAssertEqual(SongMatcher.norm(dressed.replacing(SongMatcher.decoration)), "artist the song letra")
    }

    func testLengths() {
        XCTAssertEqual(SongMatcher.seconds("3:14"), 194)
        XCTAssertEqual(SongMatcher.seconds("1:02:03"), 3723)
        XCTAssertNil(SongMatcher.seconds("3:4"))
        XCTAssertNil(SongMatcher.seconds("Album"))
        XCTAssertNil(SongMatcher.seconds(nil))
    }

    private func song(_ title: String, _ artists: [String], _ seconds: Double) -> SpotifySong {
        SpotifySong(title: title, artists: artists, seconds: seconds)
    }

    private func music(_ title: String, _ by: String, _ seconds: Double?, id: String = "aaaaaaaaaaa") -> SongCandidate {
        SongCandidate(videoID: id, title: title, by: by, seconds: seconds, source: .music)
    }

    private func video(_ title: String, _ by: String, _ seconds: Double?, id: String = "bbbbbbbbbbb") -> SongCandidate {
        SongCandidate(videoID: id, title: title, by: by, seconds: seconds, source: .video)
    }

    func testTheThreeBands() {
        let wanted = song("Volatile Reaction", ["Kevin MacLeod"], 165.355)
        XCTAssertEqual(SongMatcher.result(for: wanted, candidates: [music("Volatile Reaction", "Kevin MacLeod", 166)]).verdict, .match,
                       "within 3 s")
        XCTAssertEqual(SongMatcher.result(for: wanted, candidates: [music("Volatile Reaction", "Kevin MacLeod", 171)]).verdict, .ask,
                       "3 to 8 s asks")
        XCTAssertEqual(SongMatcher.result(for: wanted, candidates: [music("Volatile Reaction", "Kevin MacLeod", 180)]).verdict, .none,
                       "more than 8 s is nothing")
        XCTAssertEqual(SongMatcher.result(for: wanted, candidates: [music("Volatile Reaction", "Kevin MacLeod", nil)]).verdict, .none,
                       "a row with no length is never a match")
    }

    func testTheRulesRefuseTheWrongRecording() {
        let wanted = song("Amantes de Novela", ["Aventura"], 240)
        XCTAssertEqual(SongMatcher.result(for: wanted, candidates: [music("Amantes De Novela 2", "Aventura", 252)]).verdict, .none,
                       "a different song whose name starts the same is caught by its length (the plan's near miss)")
        XCTAssertEqual(SongMatcher.result(for: wanted, candidates: [music("Amantes de Novela", "Someone Else", 240)]).verdict, .none,
                       "no artist in common")
        XCTAssertEqual(SongMatcher.result(for: wanted, candidates: [music("Amantes de Novela (Live)", "Aventura", 240)]).verdict, .none,
                       "a live version is another recording")
        XCTAssertEqual(SongMatcher.result(for: song("Amantes de Novela - Remix", ["Aventura"], 240),
                                          candidates: [music("Amantes de Novela (Remix)", "Aventura", 241)]).verdict, .match,
                       "a remix matches the same remix, however the tag is written")
    }

    func testAVideoTitleCarriesTheSongInside() {
        let wanted = song("Devórame", ["Chris Paradise"], 262.944)
        let candidates = [video("Chris Paradise - Devorame (Official Video) #bachata", "Chris Paradise", 263)]
        XCTAssertEqual(SongMatcher.result(for: wanted, candidates: candidates).verdict, .match)
        XCTAssertEqual(SongMatcher.result(for: wanted, candidates: [video("Devorame - Chris Paradise (Karaoke)", "Karaoke Hits", 263)]).verdict,
                       .none, "a karaoke upload is not the recording")
    }

    func testOnlyTheFirstEightOfASearchAreConsidered() {
        let wanted = song("A Song", ["An Artist"], 200)
        var candidates = (0..<8).map { music("Something Else \($0)", "An Artist", 200) }
        candidates.append(music("A Song", "An Artist", 200))
        XCTAssertEqual(SongMatcher.result(for: wanted, candidates: candidates).verdict, .none, "the ninth row is never read")
    }

    func testTheClosestLengthWinsAndTheOthersStayInOrder() {
        let wanted = song("A Song", ["An Artist"], 200)
        let result = SongMatcher.result(for: wanted, candidates: [
            music("A Song", "An Artist", 205, id: "five"),
            music("A Song", "An Artist", 201, id: "one"),
            music("A Song", "An Artist", 203, id: "three"),
        ])
        XCTAssertEqual(result.verdict, .match)
        XCTAssertEqual(result.best?.candidate.videoID, "one")
        XCTAssertEqual(result.others().map(\.candidate.videoID), ["three", "five"], "the rest, closest first")
    }

    func testAnEquallyCloseCandidateKeepsTheSearchsOwnOrder() {
        let wanted = song("A Song", ["An Artist"], 200)
        let result = SongMatcher.result(for: wanted, candidates: [
            music("A Song", "An Artist", 202, id: "first"),
            music("A Song", "An Artist", 198, id: "second"),
        ])
        XCTAssertEqual(result.best?.candidate.videoID, "first", "the probe keeps its first best on a tie")
    }

    func testVideosOnlyWinWhenTheSongsFoundNothing() {
        let wanted = song("A Song", ["An Artist"], 200)
        let askFromMusic = SongMatcher.result(for: wanted, candidates: [music("A Song", "An Artist", 205)])
        let matchFromVideo = SongMatcher.result(for: wanted, candidates: [video("An Artist - A Song", "An Artist", 200)])
        let askFromVideo = SongMatcher.result(for: wanted, candidates: [video("An Artist - A Song", "An Artist", 205)])
        let nothing = SongMatcher.result(for: wanted, candidates: [])
        XCTAssertEqual(SongMatcher.combine(music: askFromMusic, video: matchFromVideo).best?.candidate.source, .video)
        XCTAssertEqual(SongMatcher.combine(music: askFromMusic, video: askFromVideo).best?.candidate.source, .music,
                       "an ask from the songs is kept over an ask from the videos")
        XCTAssertEqual(SongMatcher.combine(music: nothing, video: askFromVideo).best?.candidate.source, .video)
        XCTAssertEqual(SongMatcher.combine(music: matchFromVideo, video: nil).verdict, .match, "a match never searches videos")
    }

    // MARK: The recorded search responses

    func testReadingASongSearchResponse() throws {
        let candidates = SongSearchResponse.musicCandidates(try Self.gunzip("youtube-music-search.json.gz"))
        XCTAssertEqual(candidates.count, 20)
        XCTAssertEqual(candidates[0].videoID, "lfAiVYhL8SY")
        XCTAssertEqual(candidates[0].title, "Volatile Reaction")
        XCTAssertEqual(candidates[0].by, "Kevin MacLeod")
        XCTAssertEqual(candidates[0].seconds, 166)
        XCTAssertTrue(candidates.allSatisfy { $0.source == .music && !$0.videoID.isEmpty })
        XCTAssertEqual(SongMatcher.result(for: SpotifySong(title: "Volatile Reaction", artists: ["Kevin MacLeod"], seconds: 165.355),
                                          candidates: candidates).best?.candidate.videoID, "lfAiVYhL8SY")
    }

    func testReadingAVideoSearchResponse() throws {
        let candidates = SongSearchResponse.videoCandidates(try Self.gunzip("youtube-video-search.json.gz"))
        XCTAssertEqual(candidates.count, 20)
        XCTAssertTrue(candidates.allSatisfy { $0.source == .video && !$0.videoID.isEmpty })
        XCTAssertEqual(candidates[0].videoID, "2pXa5jzaOBg")
        XCTAssertEqual(candidates[0].title, "Volatile Reaction")
        XCTAssertEqual(candidates[0].seconds, 164)
        XCTAssertTrue(candidates.allSatisfy { !$0.title.isEmpty }, "every row has its words")
        XCTAssertTrue(candidates.filter { $0.seconds != nil }.count >= 15, "most rows say how long they are")
        // The video search is the fallback: the same recording, on somebody's channel instead of the songs.
        // The closest length wins, not the first result (the probe picks the same one, 0.6 s off).
        let result = SongMatcher.result(for: SpotifySong(title: "Volatile Reaction", artists: ["Kevin MacLeod"], seconds: 165.355),
                                        candidates: candidates)
        XCTAssertEqual(result.verdict, .match)
        XCTAssertEqual(result.best?.candidate.videoID, "u3Jr9t_jFcE")
        XCTAssertFalse(result.ranked.contains { $0.candidate.title.localizedCaseInsensitiveContains("piano cover") },
                       "a cover is not the recording")
    }

    func testAnEmptyOrBrokenResponseFindsNothing() {
        XCTAssertTrue(SongSearchResponse.musicCandidates(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(SongSearchResponse.videoCandidates(Data(#"{"contents":{}}"#.utf8)).isEmpty)
    }

    // MARK: The corpus

    private struct Corpus: Decodable {
        struct Candidate: Decodable {
            let video: String?
            let title: String
            let by: String
            let seconds: Double?
            let source: SongCandidate.Source
        }
        struct Track: Decodable {
            let title: String
            let artists: [String]
            let seconds: Double
            let musicQuery: String
            let music: [Candidate]
            let video: [Candidate]?
            let verdict: String
            let pick: Candidate?
            let gap: Double?
        }
        struct Playlist: Decodable {
            let link: String
            let name: String
            let tracks: [Track]
        }
        let recorded: String
        let playlists: [Playlist]
    }

    /// Every track of the three playlists: the Swift matcher reaches the probe's verdict and its pick.
    func testTheCorpusMatchesTheProbe() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("spotify-corpus.json"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: data)
        var tally: [String: Int] = [:]
        var tracks = 0
        for playlist in corpus.playlists {
            for track in playlist.tracks {
                tracks += 1
                let wanted = SpotifySong(title: track.title, artists: track.artists, seconds: track.seconds)
                XCTAssertEqual(SongMatcher.musicQuery(wanted), track.musicQuery, "the song search's words for \(track.title)")
                let music = SongMatcher.result(for: wanted, candidates: track.music.map(Self.candidate))
                // The probe only searched videos when the songs hadn't matched; so does this.
                XCTAssertEqual(music.verdict == .match, track.video == nil,
                               "\(track.title): the video search runs exactly when the song search found no match")
                let video = track.video.map { SongMatcher.result(for: wanted, candidates: $0.map(Self.candidate)) }
                let result = SongMatcher.combine(music: music, video: video)
                XCTAssertEqual(result.verdict.rawValue, track.verdict, "\(playlist.name) / \(track.title): the verdict")
                XCTAssertEqual(result.best?.candidate.videoID, track.pick?.video, "\(playlist.name) / \(track.title): the pick")
                if let gap = track.gap, let best = result.best {
                    XCTAssertEqual(best.gap, gap, accuracy: 0.0015, "\(track.title): how far off the pick is")
                }
                tally[track.verdict, default: 0] += 1
            }
        }
        XCTAssertEqual(tracks, 202, "the three playlists of the plan, recorded \(corpus.recorded)")
        XCTAssertEqual(tally["match"], 197)
        XCTAssertEqual(tally["none"], 5)
        XCTAssertNil(tally["ask"], "nothing in the corpus landed in the asking band")
    }

    private static func candidate(_ c: Corpus.Candidate) -> SongCandidate {
        SongCandidate(videoID: c.video ?? "", title: c.title, by: c.by, seconds: c.seconds, source: c.source)
    }

    // MARK: Fixtures

    /// The recorded responses are kept gzipped (they are a quarter of a megabyte each).
    static func gunzip(_ name: String) throws -> Data {
        let url = fixtures.appendingPathComponent(name)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        p.arguments = ["-c", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }
}

private extension String {
    /// The same `DECOR.sub(" ", title)` the matcher does before normalising a video's words.
    func replacing(_ regex: NSRegularExpression) -> String {
        regex.stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self), withTemplate: " ")
    }
}

extension SongMatcherTests {
    /// A video result without an id can't be downloaded, so it is never a candidate (review L5).
    func testAVideoWithoutAnIDIsNoCandidate() {
        let json = #"{"contents": [{"videoRenderer": {"title": {"runs": [{"text": "Volatile Reaction"}]}, "lengthText": {"simpleText": "2:45"}}},"#
            + #"{"videoRenderer": {"videoId": "abc123", "title": {"runs": [{"text": "Volatile Reaction"}]}, "ownerText": {"runs": [{"text": "Kevin MacLeod"}]}, "lengthText": {"simpleText": "2:46"}}}]}"#
        let found = SongSearchResponse.videoCandidates(Data(json.utf8))
        XCTAssertEqual(found.map { $0.videoID }, ["abc123"])
    }
}

