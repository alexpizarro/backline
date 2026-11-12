import AVFoundation
import XCTest
@testable import Backline

/// R01a step 4: Vimeo links. Parsing is checked on recorded shapes; the live test (skipped when
/// `BACKLINE_SKIP_NETWORK_TESTS` is set) gets the owner's example link end to end.
final class VimeoExtractorTests: XCTestCase {
    // MARK: - Clip page and config

    func testConfigURLFromBothPageForms() throws {
        let html = #"<div class="player" data-config-url="https://player.vimeo.com/video/926983242/config?autopause=0&amp;h=bb9c56fe54&amp;s=d723"></div>"#
        let url = try XCTUnwrap(VimeoExtractor.configURL(inClipPage: html, id: "926983242"))
        XCTAssertEqual(url.absoluteString, "https://player.vimeo.com/video/926983242/config?autopause=0&h=bb9c56fe54&s=d723")

        let json = #"window.x = {"player":{"config_url":"https:\/\/player.vimeo.com\/video\/926983242\/config?h=bb&s=d7"}};"#
        XCTAssertEqual(VimeoExtractor.configURL(inClipPage: json, id: "926983242")?.absoluteString,
                       "https://player.vimeo.com/video/926983242/config?h=bb&s=d7")

        // Another video's config on the same page (a "more from this channel" tile) doesn't count.
        let other = #"<a data-config-url="https://player.vimeo.com/video/111111111/config?s=1"></a>"#
        XCTAssertNil(VimeoExtractor.configURL(inClipPage: other, id: "926983242"))
        XCTAssertNil(VimeoExtractor.configURL(inClipPage: "<html></html>", id: "926983242"))
    }

    func testParseConfigOrdersTheDefaultCDNFirst() throws {
        let json = #"""
        {"request":{"files":{"dash":{},"hls":{"default_cdn":"fastly","cdns":{
          "akamai":{"url":"https://vod-adaptive-ak.vimeocdn.com/a/playlist.m3u8","avc_url":"https://x/a-avc.m3u8"},
          "fastly":{"avc_url":"https://skyfire.vimeocdn.com/f/playlist.m3u8"}}}}},
         "video":{"title":"Empire of the Sun / Changes","duration":281,"owner":{"name":"Michael Maxxis"},
          "thumbnail_url":"https://i.vimeocdn.com/video/1827879006-e385-d"}}
        """#
        let c = try XCTUnwrap(VimeoExtractor.parseConfig(Data(json.utf8)))
        XCTAssertEqual(c.title, "Empire of the Sun / Changes")
        XCTAssertEqual(c.author, "Michael Maxxis")
        XCTAssertEqual(c.seconds, 281)
        XCTAssertEqual(c.thumbnail?.absoluteString, "https://i.vimeocdn.com/video/1827879006-e385-d_1280")
        XCTAssertEqual(c.manifests.map(\.absoluteString),
                       ["https://skyfire.vimeocdn.com/f/playlist.m3u8", "https://vod-adaptive-ak.vimeocdn.com/a/playlist.m3u8"])
        XCTAssertEqual(VimeoExtractor.parseConfig(Data(#"{"video":{}}"#.utf8))?.manifests, [])
        XCTAssertNil(VimeoExtractor.parseConfig(Data("Sorry".utf8)))
    }

    func testClipPages() {
        let channel = URL(string: "https://vimeo.com/channels/musicvideos/926983242")!
        XCTAssertEqual(VimeoExtractor.clipPages(id: "926983242", hash: nil, link: channel).map(\.absoluteString),
                       ["https://vimeo.com/channels/musicvideos/926983242", "https://vimeo.com/channels/staffpicks/926983242"])
        XCTAssertEqual(VimeoExtractor.clipPages(id: "926983242", hash: nil, link: URL(string: "https://vimeo.com/926983242")).map(\.absoluteString),
                       ["https://vimeo.com/channels/staffpicks/926983242"])
        XCTAssertEqual(VimeoExtractor.clipPages(id: "160743502", hash: "abd0e13fb4", link: URL(string: "https://player.vimeo.com/video/160743502?h=abd0e13fb4")).map(\.absoluteString),
                       ["https://vimeo.com/channels/staffpicks/160743502?h=abd0e13fb4"])
    }

    func testMessages() {
        XCTAssertEqual(VimeoExtractor.Failure.unavailable.errorDescription, "Can't get a song from this link.")
        XCTAssertEqual(VimeoExtractor.Failure.tooLong.errorDescription, "Longer than 20 minutes.")
        XCTAssertEqual(VimeoExtractor.Failure.network.errorDescription, "Can't connect. Check your internet.")
    }

    // MARK: - Fragmented MP4 HLS

    func testFragmentedMP4PlaylistParsing() {
        let base = URL(string: "https://vod.vimeocdn.com/x/y/avf/eeceac69/media.m3u8?pathsig=1")!
        let text = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-TARGETDURATION:6
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-MAP:URI="../../range/prot/cmFuZ2U9MC02Nzc/avf/eeceac69.mp4?pathsig=a"
        #EXTINF:5.952000,
        ../../range/prot/cmFuZ2U9MTI3NC0xNDY2NDc/avf/eeceac69.mp4?pathsig=b
        #EXTINF:6.293333,
        ../../range/prot/cmFuZ2U9MTQ2NjQ4LTI5MjAyMA/avf/eeceac69.mp4?pathsig=c
        #EXT-X-ENDLIST
        """
        let list = HLSAudio.playlist(text, base: base)
        XCTAssertEqual(list.initSegment?.absoluteString, "https://vod.vimeocdn.com/x/y/range/prot/cmFuZ2U9MC02Nzc/avf/eeceac69.mp4?pathsig=a")
        XCTAssertEqual(list.segments.count, 2)
        XCTAssertEqual(list.duration, 12.245333, accuracy: 0.0001)
        XCTAssertTrue(list.isComplete)
        XCTAssertFalse(list.usesByteRanges)
        XCTAssertTrue(HLSAudio.playlist("#EXTM3U\n#EXT-X-MAP:URI=\"i.mp4\",BYTERANGE=\"678@0\"\n#EXTINF:6,\ns.mp4\n#EXT-X-ENDLIST",
                                        base: base).usesByteRanges)
        XCTAssertNil(HLSAudio.playlist("#EXTM3U\n#EXTINF:6,\ns.aac\n#EXT-X-ENDLIST", base: base).initSegment, "ADTS playlists have no init segment")
    }

    func testFragmentedMP4SegmentsAreJoinedBehindTheInitSegment() async throws {
        RouteStub.routes = [
            "/master.m3u8": Data("""
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-high",NAME="English",DEFAULT=YES,URI="audio/media.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=551775,CODECS="avc1.640015,mp4a.40.2",AUDIO="audio-high"
            video/media.m3u8
            """.utf8),
            "/audio/media.m3u8": Data("#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:6.0,\nseg1.mp4\n#EXTINF:4.5,\nseg2.mp4\n#EXT-X-ENDLIST\n".utf8),
            "/audio/init.mp4": Data("INIT".utf8),
            "/audio/seg1.mp4": Data("ONE".utf8),
            "/audio/seg2.mp4": Data("TWO".utf8),
        ]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RouteStub.self]
        let session = URLSession(configuration: config)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vimeo-test-\(UUID().uuidString).m4a")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let out = try await HLSAudio.download(manifest: URL(string: "https://stub.vimeocdn.com/master.m3u8")!, session: session,
                                              userAgent: "test", maxSeconds: 1200, to: file, progress: { _ in }, isCancelled: { false })
        XCTAssertEqual(try Data(contentsOf: file), Data("INITONETWO".utf8))
        XCTAssertEqual(out.seconds, 10.5, accuracy: 0.001)
        XCTAssertEqual(out.segments, 2)
    }

    // MARK: - Live (skipped when BACKLINE_SKIP_NETWORK_TESTS is set)

    /// The owner's example link: channel page → signed config → the audio rendition, about 7 MB.
    func testGetsTheOwnersVimeoLink() async throws {
        if ProcessInfo.processInfo.environment["BACKLINE_SKIP_NETWORK_TESTS"] != nil { throw XCTSkip("BACKLINE_SKIP_NETWORK_TESTS is set") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vimeo-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let link = "https://vimeo.com/channels/musicvideos/926983242"
        guard case .vimeo(let id, let hash) = WebLink.classify(link) else { return XCTFail("not a Vimeo link") }
        let out = try await VimeoExtractor.fetch(id: id, hash: hash, link: URL(string: link), into: dir,
                                                 progress: { _ in }, isCancelled: { false })
        XCTAssertEqual(out.title, "Empire of the Sun / Changes")
        XCTAssertEqual(out.author, "Michael Maxxis")
        XCTAssertEqual(out.file.lastPathComponent, "vimeo-926983242.m4a")
        let audio = try AVAudioFile(forReading: out.file)
        XCTAssertEqual(Double(audio.length) / audio.processingFormat.sampleRate, 282, accuracy: 1.5)
        XCTAssertEqual(audio.processingFormat.channelCount, 2)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".part") }
        XCTAssertTrue(leftovers.isEmpty, "partial files left behind: \(leftovers)")

        // A plain vimeo.com/<id> link (an empty page shell) goes through the clip page route too.
        let plain = try await VimeoExtractor.playerConfig(id: id, hash: nil, link: URL(string: "https://vimeo.com/926983242"),
                                                          session: YouTubeExtractor.makeSession())
        XCTAssertEqual(plain?.title, "Empire of the Sun / Changes")
    }
}

/// Serves fixed bodies by URL path.
final class RouteStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: Data] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let body = Self.routes[request.url?.path ?? ""]
        let response = HTTPURLResponse(url: request.url!, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}
