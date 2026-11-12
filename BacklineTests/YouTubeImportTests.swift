import AVFoundation
import BacklineKit
import XCTest
@testable import Backline

/// Pure parsing / URL / cookie / container tests, then a few real downloads.
/// The network tests need internet and a reachable YouTube: skip them with
/// `TEST_RUNNER_BACKLINE_SKIP_NETWORK_TESTS=1 xcodebuild … test` (the TEST_RUNNER_ prefix passes it on).
/// `nonisolated` because the target's default MainActor isolation can't subclass XCTestCase.
nonisolated final class YouTubeImportTests: XCTestCase {
    // MARK: - Fixtures

    private let json = { (s: String) in Data(s.utf8) }

    private func response(status: String = "OK", reason: String? = nil, formats: String = "", extra: String = "",
                          details: String = #""videoDetails":{"videoId":"2pXa5jzaOBg","title":"Volatile Reaction","author":"Kevin MacLeod","lengthSeconds":"163"}"#) -> Data {
        let reasonJSON = reason.map { #","reason":"\#($0)""# } ?? ""
        let streaming = formats.isEmpty && extra.isEmpty ? "" : #","streamingData":{"adaptiveFormats":[\#(formats)]\#(extra)}"#
        return json(#"{"playabilityStatus":{"status":"\#(status)"\#(reasonJSON)},\#(details)\#(streaming)}"#)
    }

    private let f140 = #"{"itag":140,"mimeType":"audio/mp4; codecs=\"mp4a.40.2\"","url":"https://rr1.googlevideo.com/videoplayback?itag=140&clen=2645256","contentLength":"2645256","approxDurationMs":"163398","bitrate":130512}"#
    private let f139 = #"{"itag":139,"mimeType":"audio/mp4; codecs=\"mp4a.40.5\"","url":"https://rr1.googlevideo.com/videoplayback?itag=139","contentLength":"997861","bitrate":48000}"#
    private let f251 = #"{"itag":251,"mimeType":"audio/webm; codecs=\"opus\"","url":"https://rr1.googlevideo.com/videoplayback?itag=251","contentLength":"2754870"}"#
    private let f140drc = #"{"itag":140,"mimeType":"audio/mp4; codecs=\"mp4a.40.2\"","url":"https://rr1.googlevideo.com/videoplayback?itag=140&drc=1","isDrc":true}"#
    private let f136 = #"{"itag":136,"mimeType":"video/mp4; codecs=\"avc1.4D401F\"","url":"https://rr1.googlevideo.com/videoplayback?itag=136"}"#

    // MARK: - Player response

    func testPicksAAC140OverOpusAndHEAAC() throws {
        let r = try PlayerResponse.parse(response(formats: [f251, f139, f136, f140].joined(separator: ",")))
        XCTAssertEqual(r.playability, .ok)
        XCTAssertEqual(r.bestAAC()?.itag, 140)
        XCTAssertEqual(r.bestAAC()?.contentLength, 2_645_256)
        XCTAssertEqual(r.bestAAC()?.durationMs, 163_398)
        XCTAssertEqual(r.title, "Volatile Reaction")
        XCTAssertEqual(r.author, "Kevin MacLeod")
        XCTAssertEqual(r.lengthSeconds, 163)
        XCTAssertEqual(r.audioFormats.count, 3, "video-only formats are ignored")
    }

    func testFallsBackToHEAACWhenOnly139() throws {
        let r = try PlayerResponse.parse(response(formats: [f251, f139].joined(separator: ",")))
        XCTAssertEqual(r.bestAAC()?.itag, 139)
    }

    func testIgnoresDynamicRangeCompressedCopy() throws {
        let r = try PlayerResponse.parse(response(formats: [f140drc, f139].joined(separator: ",")))
        XCTAssertEqual(r.bestAAC()?.itag, 139, "the DRC 140 must rank below plain HE-AAC")
    }

    func testOpusOnlyIsUnreadable() throws {
        let r = try PlayerResponse.parse(response(formats: f251))
        XCTAssertNil(r.bestAAC())
        XCTAssertTrue(r.hasOnlyUnreadableAudio)
    }

    func testCipheredFormatsNeedThePlayerScript() throws {
        let cipher = #"{"itag":140,"mimeType":"audio/mp4; codecs=\"mp4a.40.2\"","signatureCipher":"s=%3D%3DAbc&sp=sig&url=https%3A%2F%2Frr1.googlevideo.com%2Fvideoplayback%3Fexpire%3D1%26sparams%3Dexpire%252Cn%26n%3DKBx1qz7jMhxELa8c"}"#
        let r = try PlayerResponse.parse(response(formats: cipher))
        XCTAssertNil(r.bestAAC(), "a ciphered stream is no use without the player script")
        let f = try XCTUnwrap(r.bestAAC(unlocking: true))
        XCTAssertEqual(f.cipher, PlayerResponse.Cipher(s: "==Abc", sp: "sig",
                                                       url: "https://rr1.googlevideo.com/videoplayback?expire=1&sparams=expire%2Cn&n=KBx1qz7jMhxELa8c"))
        let challenges = PlayerResponse.challenges(of: f)
        XCTAssertEqual(challenges.sig, "==Abc")
        XCTAssertEqual(challenges.n, "KBx1qz7jMhxELa8c")
    }

    func testPreRollAdWaitIsTheSkipOffsetOrTheLength() throws {
        let skippable = #"{"adPlacements":[{"adPlacementRenderer":{"config":{"adPlacementConfig":{"kind":"AD_PLACEMENT_KIND_START"}},"renderer":{"instreamVideoAdRenderer":{"playerVars":"length_seconds=10&x=1","skipOffsetMilliseconds":5000}}}},{"adPlacementRenderer":{"config":{"adPlacementConfig":{"kind":"AD_PLACEMENT_KIND_MILLISECONDS"}},"renderer":{"instreamVideoAdRenderer":{"playerVars":"length_seconds=30"}}}}]}"#
        XCTAssertEqual(try PlayerResponse.parse(Data(skippable.utf8)).adWaitSeconds, 5, "a mid-roll doesn't count")
        let slots = #"{"adSlots":[{"adSlotRenderer":{"adSlotMetadata":{"triggerEvent":"SLOT_TRIGGER_EVENT_BEFORE_CONTENT"},"fulfillmentContent":{"fulfilledLayout":{"playerBytesAdLayoutRenderer":{"renderingContent":{"playerBytesSequentialLayoutRenderer":{"sequentialLayouts":[{"playerBytesAdLayoutRenderer":{"renderingContent":{"instreamVideoAdRenderer":{"playerVars":"length_seconds=6"}}}},{"playerBytesAdLayoutRenderer":{"renderingContent":{"instreamVideoAdRenderer":{"playerVars":"length_seconds=15","skipOffsetMilliseconds":5500}}}}]}}}}}}}]}"#
        XCTAssertEqual(try PlayerResponse.parse(Data(slots.utf8)).adWaitSeconds, 11.5, accuracy: 0.001)
        XCTAssertEqual(try PlayerResponse.parse(response(formats: f140)).adWaitSeconds, 0)
    }

    func testUnlockedURLKeepsTheRestOfTheQuery() throws {
        let cipher = PlayerResponse.Cipher(s: "==Abc", sp: "sig",
                                           url: "https://rr1.googlevideo.com/videoplayback?expire=1&sparams=expire%2Cn&n=KBx1qz7jMhxELa8c")
        var f = PlayerResponse.Format(itag: 140, mimeType: "audio/mp4; codecs=\"mp4a.40.2\"", url: nil)
        f.cipher = cipher
        let url = try XCTUnwrap(PlayerResponse.unlockedURL(f, sig: ["==Abc": "AOq0+x/y="], n: ["KBx1qz7jMhxELa8c": "ttPvh7WIptsgSw"]))
        XCTAssertEqual(url.absoluteString,
                       "https://rr1.googlevideo.com/videoplayback?expire=1&sparams=expire%2Cn&n=ttPvh7WIptsgSw&sig=AOq0%2Bx%2Fy%3D")
        XCTAssertNil(PlayerResponse.unlockedURL(f, sig: [:], n: [:]), "no URL without the signature's answer")

        // A plain URL only has its n transformed.
        let plain = PlayerResponse.Format(itag: 140, mimeType: "audio/mp4", url: "https://x.googlevideo.com/v?a=%2C&n=abc")
        XCTAssertEqual(PlayerResponse.unlockedURL(plain, sig: [:], n: ["abc": "xyz"])?.absoluteString, "https://x.googlevideo.com/v?a=%2C&n=xyz")
    }

    func testPlayerScriptVersionAndTimestamp() {
        let iframe = #"var scriptUrl = 'https:\/\/www.youtube.com\/s\/player\/cbcfbf2f\/www-widgetapi.vflset\/www-widgetapi.js';"#
        XCTAssertEqual(PlayerScript.playerID(inIframeAPI: iframe), "cbcfbf2f")
        XCTAssertEqual(PlayerScript.playerID(inIframeAPI: "/s/player/631d3938/player_ias.vflset/en_US/base.js"), "631d3938")
        XCTAssertNil(PlayerScript.playerID(inIframeAPI: "<html></html>"))
        XCTAssertEqual(PlayerScript.scriptURL("cbcfbf2f").absoluteString,
                       "https://www.youtube.com/s/player/cbcfbf2f/player_ias.vflset/en_US/base.js")
        XCTAssertEqual(PlayerScript.signatureTimestamp(in: "a={x:1,signatureTimestamp:20529,y:2}"), 20529)
        XCTAssertEqual(PlayerScript.signatureTimestamp(in: "c.sts = 0; d={sts:20530}"), 20530)
        XCTAssertNil(PlayerScript.signatureTimestamp(in: "nothing here"))
    }

    func testPlayerScriptCacheKeepsTheNewestTwo() throws {
        let dir = try scratchDirectory()
        for (i, id) in ["aaaaaaaa", "bbbbbbbb", "cccccccc"].enumerated() {
            PlayerScript.store(PlayerScript.Player(id: id, signatureTimestamp: 20000 + i, preprocessed: "// \(id)"), in: dir)
            // Back-date each version as it lands, so "newest" is unambiguous when the next store prunes.
            for ext in ["js", "sts"] where i < 2 {
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(i * 60 - 600))],
                                                      ofItemAtPath: dir.appendingPathComponent(id).appendingPathExtension(ext).path)
            }
        }
        XCTAssertEqual(PlayerScript.cachedIDs(in: dir), ["cccccccc", "bbbbbbbb"])
        XCTAssertEqual(PlayerScript.cached("bbbbbbbb", in: dir)?.signatureTimestamp, 20001)
        XCTAssertEqual(PlayerScript.cached("cccccccc", in: dir)?.preprocessed, "// cccccccc")
        XCTAssertNil(PlayerScript.cached("aaaaaaaa", in: dir))
        XCTAssertNotNil(PlayerScript.solver, "the bundled solver loads")
    }

    func testReadsHLSManifest() throws {
        let r = try PlayerResponse.parse(response(formats: f140, extra: #","hlsManifestUrl":"https://manifest.googlevideo.com/api/manifest/hls_variant/x/index.m3u8""#))
        XCTAssertEqual(r.hlsManifestURL?.host, "manifest.googlevideo.com")
    }

    func testAudioTrackPreferenceOriginalOverDubbed() throws {
        let dubbed = #"{"itag":140,"mimeType":"audio/mp4; codecs=\"mp4a.40.2\"","url":"https://x/dub","audioTrack":{"displayName":"French","audioIsDefault":false}}"#
        let original = #"{"itag":140,"mimeType":"audio/mp4; codecs=\"mp4a.40.2\"","url":"https://x/orig","audioTrack":{"displayName":"English (United States) original","audioIsDefault":true}}"#
        let r = try PlayerResponse.parse(response(formats: [dubbed, original].joined(separator: ",")))
        XCTAssertEqual(r.bestAAC()?.url, "https://x/orig")
    }

    func testPlayabilityClassification() throws {
        func play(_ status: String, _ reason: String?) throws -> PlayerResponse.Playability {
            try PlayerResponse.parse(response(status: status, reason: reason)).playability
        }
        XCTAssertEqual(try play("LOGIN_REQUIRED", "Sign in to confirm you’re not a bot"), .loginRequired)
        XCTAssertEqual(try play("LOGIN_REQUIRED", "Sign in to confirm your age"), .loginRequired)
        XCTAssertEqual(try play("LOGIN_REQUIRED", "This video is private"), .loginRequired)
        XCTAssertEqual(try play("UNPLAYABLE", "Sign in to confirm you’re not a bot"), .loginRequired)
        XCTAssertEqual(try play("AGE_VERIFICATION_REQUIRED", nil), .loginRequired)
        XCTAssertEqual(try play("ERROR", "This video is unavailable"), .unavailable)
        XCTAssertEqual(try play("ERROR", "This video has been removed for violating YouTube's policy on hate speech."), .unavailable)
        XCTAssertEqual(try play("UNPLAYABLE", "This video is not available"), .unavailable)
        XCTAssertEqual(try play("UNPLAYABLE", "The page needs to be reloaded."), .clientRejected)
        XCTAssertEqual(try play("LIVE_STREAM_OFFLINE", "This live event will begin in 2 hours."), .liveOffline)
        XCTAssertEqual(try play("SOMETHING_NEW", nil), .clientRejected)
        XCTAssertEqual(try play("OK", nil), .ok)
    }

    func testLiveStreamIsDetected() throws {
        let live = #""videoDetails":{"videoId":"abc","title":"Radio","author":"x","lengthSeconds":"0","isLive":true}"#
        XCTAssertTrue(try PlayerResponse.parse(response(details: live)).isLive)
        let vod = #""videoDetails":{"videoId":"abc","title":"Song","author":"x","lengthSeconds":"200","isLiveContent":true}"#
        XCTAssertFalse(try PlayerResponse.parse(response(details: vod)).isLive, "a finished stream with a length is a normal video")
    }

    func testRejectsNonJSON() {
        XCTAssertThrowsError(try PlayerResponse.parse(Data("<html>".utf8)))
    }

    func testMessagesAndFailureMapping() {
        typealias E = YouTubeExtractor
        guard case .needsSignIn = E.failure(for: [.unavailable, .loginRequired], answered: true) else { return XCTFail("login wins") }
        guard case .unsupportedFormat = E.failure(for: [.unreadableAudio], answered: true) else { return XCTFail() }
        guard case .failed(let m1) = E.failure(for: [.unavailable, .unavailable], answered: true) else { return XCTFail() }
        XCTAssertEqual(m1, "Video not available.")
        guard case .failed(let m2) = E.failure(for: [.network, .network], answered: false) else { return XCTFail() }
        XCTAssertEqual(m2, "Can't connect. Check your internet.")
        guard case .failed(let m3) = E.failure(for: [.forbidden, .noAudio], answered: true) else { return XCTFail() }
        XCTAssertEqual(m3, "Nothing came back. Record it instead.")
        XCTAssertEqual(YouTubeImport.signInMessage, "This link needs a sign-in.")
        XCTAssertEqual(YouTubeImport.Failure.tooLong.errorDescription, "Longer than 20 minutes.")
        XCTAssertEqual(YouTubeImport.Failure.unsupportedFormat.errorDescription, "Can't read this video's sound.")
    }

    // MARK: - Requests

    func testPlayerRequestBody() throws {
        let body = InnerTubeClient.visionOS.playerRequestBody(videoID: "2pXa5jzaOBg", visitorData: "VISITOR==")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(root["videoId"] as? String, "2pXa5jzaOBg")
        XCTAssertEqual(root["contentCheckOk"] as? Bool, true)
        let client = try XCTUnwrap((root["context"] as? [String: Any])?["client"] as? [String: Any])
        XCTAssertEqual(client["clientName"] as? String, "VISIONOS")
        XCTAssertEqual(client["clientVersion"] as? String, "1.02")
        XCTAssertEqual(client["visitorData"] as? String, "VISITOR==")
        XCTAssertEqual(client["hl"] as? String, "en")
        XCTAssertEqual(client["deviceModel"] as? String, "RealityDevice17,1")
        let vr = try XCTUnwrap(((try JSONSerialization.jsonObject(with: InnerTubeClient.androidVR.playerRequestBody(videoID: "x", visitorData: nil)) as? [String: Any])?["context"] as? [String: Any])?["client"] as? [String: Any])
        XCTAssertEqual(vr["androidSdkVersion"] as? Int, 32)
        XCTAssertNil(vr["visitorData"])
        XCTAssertNil(((root["playbackContext"] as? [String: Any])?["contentPlaybackContext"] as? [String: Any])?["signatureTimestamp"])

        let tv = try XCTUnwrap(JSONSerialization.jsonObject(with: InnerTubeClient.tvSamsung.playerRequestBody(videoID: "x", visitorData: nil, signatureTimestamp: 20529)) as? [String: Any])
        let tvClient = try XCTUnwrap((tv["context"] as? [String: Any])?["client"] as? [String: Any])
        XCTAssertEqual(tvClient["clientName"] as? String, "TVHTML5")
        XCTAssertEqual(tvClient["deviceMake"] as? String, "Samsung")
        let playback = try XCTUnwrap((tv["playbackContext"] as? [String: Any])?["contentPlaybackContext"] as? [String: Any])
        XCTAssertEqual(playback["signatureTimestamp"] as? Int, 20529)
        XCTAssertTrue(InnerTubeClient.tvSamsung.needsPlayer)
        XCTAssertFalse(InnerTubeClient.visionOS.needsPlayer)
    }

    func testAnonymousHeadersCarryNoCredentials() {
        let h = InnerTubeClient.visionOS.playerHeaders(visitorData: "V", cookies: nil)
        XCTAssertEqual(h["X-YouTube-Client-Name"], "101")
        XCTAssertEqual(h["X-YouTube-Client-Version"], "1.02")
        XCTAssertEqual(h["X-Goog-Visitor-Id"], "V")
        XCTAssertEqual(h["Origin"], "https://www.youtube.com")
        XCTAssertNil(h["Cookie"])
        XCTAssertNil(h["Authorization"])
    }

    func testSignedInHeadersAddCookieAndSAPISIDHASH() {
        let jar = signedInJar()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let h = InnerTubeClient.visionOS.playerHeaders(visitorData: "V", cookies: jar, now: now)
        XCTAssertNotNil(h["Cookie"])
        XCTAssertEqual(h["X-Origin"], "https://www.youtube.com")
        XCTAssertEqual(h["X-Goog-AuthUser"], "0")
        XCTAssertTrue(h["Authorization"]?.hasPrefix("SAPISIDHASH 1700000000_") == true)
    }

    func testClientLadderOrder() {
        XCTAssertEqual(InnerTubeClient.ladder.map(\.id), ["visionos", "tv_samsung", "ios", "android_vr"])
    }

    func testOEmbedNames() throws {
        let names = try XCTUnwrap(YouTubeExtractor.oEmbedNames(Data(#"{"title":"Volatile Reaction","author_name":"Kevin MacLeod","type":"video"}"#.utf8)))
        XCTAssertEqual(names.title, "Volatile Reaction")
        XCTAssertEqual(names.author, "Kevin MacLeod")
        XCTAssertNil(YouTubeExtractor.oEmbedNames(Data("Not Found".utf8)))
        XCTAssertNil(YouTubeExtractor.oEmbedNames(Data(#"{"title":""}"#.utf8)))
    }

    func testVisitorDataParsing() {
        let visitorID = Data(#"{"responseContext":{"visitorData":"CgtidUw1WmpNVzJoUSiOrcnWBjIKCgJBVRIEGgAgPg%3D%3D","serviceTrackingParams":[]}}"#.utf8)
        XCTAssertEqual(YouTubeExtractor.visitorData(inVisitorIDResponse: visitorID), "CgtidUw1WmpNVzJoUSiOrcnWBjIKCgJBVRIEGgAgPg==")
        XCTAssertNil(YouTubeExtractor.visitorData(inVisitorIDResponse: Data("{}".utf8)))
        let page = #"<script>ytcfg.set({"VISITOR_DATA":"x","visitorData":"CgtNenFS%3D","other":1})</script>"#
        XCTAssertEqual(YouTubeExtractor.visitorData(inWatchPage: page), "CgtNenFS=")
        XCTAssertNil(YouTubeExtractor.visitorData(inWatchPage: "<html></html>"))
    }

    // MARK: - Cookies

    private func cookie(_ name: String, _ value: String, domain: String = ".youtube.com", path: String = "/",
                        secure: Bool = true, expires: Date? = nil) -> HTTPCookie {
        var p: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if secure { p[.secure] = "TRUE" }
        if let expires { p[.expires] = expires }
        return HTTPCookie(properties: p)!
    }

    private func signedInJar(expiring: Date = .distantFuture) -> YouTubeCookies {
        YouTubeCookies([
            cookie("LOGIN_INFO", "login", expires: expiring),
            cookie("SAPISID", "sid123", expires: expiring),
            cookie("__Secure-1PAPISID", "1p789", expires: expiring),
            cookie("__Secure-3PAPISID", "3p456", expires: expiring),
            cookie("NID", "google-only", domain: ".google.com", expires: expiring),
            cookie("tracker", "nope", domain: ".example.com", expires: expiring),
        ])
    }

    func testSAPISIDHASHMatchesTheKnownAlgorithm() {
        XCTAssertEqual(YouTubeCookies.sidHash(sid: "sid123", origin: "https://www.youtube.com", timestamp: 1_700_000_000),
                       "1700000000_4c5baea7909d1a6fa57f506a10773ee4c57257f4")
        let auth = signedInJar().authorization(origin: "https://www.youtube.com", now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(auth, "SAPISIDHASH 1700000000_4c5baea7909d1a6fa57f506a10773ee4c57257f4 "
                       + "SAPISID1PHASH 1700000000_c278a0e7358799fbccedb67cb922c74f19f18be9 "
                       + "SAPISID3PHASH 1700000000_76daad6d5e83cfc19f6c63b40ce936894a6ee749")
    }

    func testSAPISIDHASHFallsBackTo3PAPISID() {
        let jar = YouTubeCookies([cookie("LOGIN_INFO", "x"), cookie("__Secure-3PAPISID", "3p456")])
        let auth = jar.authorization(origin: "https://www.youtube.com", now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(auth?.hasPrefix("SAPISIDHASH 1700000000_76daad6d") == true, "SAPISID missing: 3PAPISID stands in")
        XCTAssertNil(YouTubeCookies([cookie("LOGIN_INFO", "x")]).authorization(origin: "https://www.youtube.com"))
    }

    func testOnlyYouTubeAndGoogleCookiesAreKept() {
        let jar = signedInJar()
        XCTAssertFalse(jar.entries.contains { $0.domain.contains("example.com") })
        XCTAssertTrue(jar.entries.contains { $0.name == "NID" })
        XCTAssertTrue(jar.isSignedIn)
    }

    func testCookieHeaderRespectsDomainPathAndExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let jar = YouTubeCookies([
            cookie("SAPISID", "a", expires: now.addingTimeInterval(60)),
            cookie("OLD", "b", expires: now.addingTimeInterval(-60)),
            cookie("GOOGLE", "c", domain: ".google.com"),
            cookie("HOSTONLY", "d", domain: "www.youtube.com"),
            cookie("OTHERHOST", "e", domain: "music.youtube.com"),
            cookie("ELSEWHERE", "f", path: "/account"),
        ])
        let header = try XCTUnwrap(jar.header(for: URL(string: "https://www.youtube.com/youtubei/v1/player")!, now: now))
        let names = Set(header.split(separator: ";").map { $0.split(separator: "=")[0].trimmingCharacters(in: .whitespaces) })
        XCTAssertEqual(names, ["SAPISID", "HOSTONLY"])
        XCTAssertNil(jar.header(for: URL(string: "http://www.youtube.com/")!, now: now), "never over plain http")
        XCTAssertNil(YouTubeCookies.none.header(for: URL(string: "https://www.youtube.com/")!))
    }

    func testPreferenceCookiesAloneDoNotCountAsSignedIn() {
        let jar = YouTubeCookies([cookie("PREF", "f6=40000000"), cookie("YSC", "abc"), cookie("SOCS", "CAI")])
        XCTAssertFalse(jar.isSignedIn)
        XCTAssertTrue(YouTubeCookies([]).isEmpty)
    }

    func testSignInHostAllowList() {
        for ok in ["accounts.google.com", "www.youtube.com", "youtube.com", "ssl.gstatic.com", "lh3.googleusercontent.com"] {
            XCTAssertTrue(YouTubeSignIn.isAllowed(host: ok), ok)
        }
        for bad in ["evilgoogle.com", "accounts.google.evil.com", "google.com.evil.com", "youtube.com.evil.com", "notyoutube.com", "example.com", ""] {
            XCTAssertFalse(YouTubeSignIn.isAllowed(host: bad), bad)
        }
        XCTAssertTrue(YouTubeSignIn.hasLogin([cookie("LOGIN_INFO", "x"), cookie("SAPISID", "y")]))
        XCTAssertFalse(YouTubeSignIn.hasLogin([cookie("NID", "x", domain: ".google.com")]))
    }

    func testLinkParsingIsTheBacklineKitOne() {
        XCTAssertEqual(YouTubeImport.parse("https://youtu.be/2pXa5jzaOBg")?.id, "2pXa5jzaOBg")
        XCTAssertEqual(YouTubeImport.find(in: "listen: https://www.youtube.com/watch?v=2pXa5jzaOBg&t=3s now")?.id, "2pXa5jzaOBg")
        XCTAssertNil(YouTubeImport.parse("https://evil.com/watch?v=2pXa5jzaOBg"))
    }

    // MARK: - Ranged download plan

    func testRangesCoverTheFileExactly() {
        let total = 25 << 20
        let r = RangedDownload.ranges(total: total)
        XCTAssertEqual(r.count, 3)
        XCTAssertEqual(r.first?.lowerBound, 0)
        XCTAssertEqual(r.last?.upperBound, total - 1)
        for (a, b) in zip(r, r.dropFirst()) { XCTAssertEqual(a.upperBound + 1, b.lowerBound) }
        XCTAssertEqual(RangedDownload.ranges(total: 100), [0...99])
        XCTAssertEqual(RangedDownload.ranges(total: 2_645_256), [0...2_645_255])
        XCTAssertTrue(RangedDownload.ranges(total: 0).isEmpty)
    }

    func testContentRangeTotal() {
        XCTAssertEqual(RangedDownload.contentRangeTotal("bytes 0-1048575/2645256"), 2_645_256)
        XCTAssertNil(RangedDownload.contentRangeTotal("bytes 0-1/*"))
        XCTAssertNil(RangedDownload.contentRangeTotal(nil))
    }

    func testTransientErrorClassification() {
        XCTAssertTrue(RangedDownload.isTransient(URLError(.timedOut)))
        XCTAssertTrue(RangedDownload.isTransient(URLError(.networkConnectionLost)))
        XCTAssertFalse(RangedDownload.isTransient(URLError(.badURL)))
        XCTAssertFalse(RangedDownload.isTransient(URLError(.cancelled)))
    }

    // MARK: - HLS playlists

    func testHLSAttributeParsingKeepsQuotedCommas() {
        let a = HLSAudio.attributes(#"#EXT-X-MEDIA:URI="https://x/y,z/itag/234/",TYPE=AUDIO,GROUP-ID="234",NAME="Default",DEFAULT=YES"#[...])
        XCTAssertEqual(a["URI"], "https://x/y,z/itag/234/")
        XCTAssertEqual(a["TYPE"], "AUDIO")
        XCTAssertEqual(a["DEFAULT"], "YES")
    }

    func testHLSPicksTheBestAudioRendition() throws {
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:URI="https://m.googlevideo.com/hls_playlist/id/a/itag/233/index.m3u8",TYPE=AUDIO,GROUP-ID="233",NAME="Default",DEFAULT=YES
        #EXT-X-MEDIA:URI="https://m.googlevideo.com/hls_playlist/id/a/itag/234/index.m3u8",TYPE=AUDIO,GROUP-ID="234",NAME="Default",DEFAULT=YES
        #EXT-X-STREAM-INF:BANDWIDTH=88210,CODECS="avc1.4D4015,mp4a.40.5",AUDIO="233"
        https://m.googlevideo.com/hls_playlist/id/a/itag/229/index.m3u8
        """
        let best = try XCTUnwrap(HLSAudio.renditions(inMaster: master, base: URL(string: "https://m.googlevideo.com/")!).first)
        XCTAssertEqual(best.itag, 234)
    }

    func testHLSMediaPlaylist() {
        let text = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:5.005,
        https://rr1.googlevideo.com/videoplayback/seg1
        #EXTINF:5.005,
        seg2
        #EXTINF:3.5,
        https://rr1.googlevideo.com/videoplayback/seg3
        #EXT-X-ENDLIST
        """
        let list = HLSAudio.playlist(text, base: URL(string: "https://rr1.googlevideo.com/videoplayback/")!)
        XCTAssertEqual(list.segments.count, 3)
        XCTAssertEqual(list.segments[1].absoluteString, "https://rr1.googlevideo.com/videoplayback/seg2")
        XCTAssertEqual(list.duration, 13.51, accuracy: 0.001)
        XCTAssertTrue(list.isComplete)
        XCTAssertFalse(HLSAudio.playlist("#EXTM3U\n#EXTINF:5,\nseg", base: URL(string: "https://x/")!).isComplete, "a live playlist has no ENDLIST")
    }

    // MARK: - AAC in MP4

    /// A fake ADTS frame: 7-byte header (AAC-LC, 44.1 kHz, stereo) around `payload` bytes.
    private func adts(payload: Int, crc: Bool = false) -> [UInt8] {
        let header = crc ? 9 : 7
        let length = header + payload
        var b: [UInt8] = [0xFF, crc ? 0xF0 : 0xF1, 0x50, UInt8(0x80 | ((length >> 11) & 3)), UInt8((length >> 3) & 0xFF), UInt8(((length & 7) << 5) | 0x1F), 0xFC]
        if crc { b += [0, 0] }
        return b + [UInt8](repeating: 0xAB, count: payload)
    }

    func testADTSHeaderParsing() throws {
        let h = try XCTUnwrap(AACFileWriter.parseADTS(adts(payload: 300), at: 0))
        XCTAssertEqual(h.frameLength, 307)
        XCTAssertEqual(h.headerLength, 7)
        XCTAssertEqual(h.format, AACFileWriter.Format(sampleRate: 44100, channels: 2, objectType: 2, sampleRateIndex: 4))
        XCTAssertEqual(AACFileWriter.parseADTS(adts(payload: 10, crc: true), at: 0)?.headerLength, 9)
        XCTAssertNil(AACFileWriter.parseADTS([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06], at: 0))
        XCTAssertNil(AACFileWriter.parseADTS([0xFF, 0xF1], at: 0))
    }

    func testID3TagLength() {
        var tag: [UInt8] = Array("ID3".utf8) + [3, 0, 0, 0, 0, 0, 63] + [UInt8](repeating: 0, count: 63)
        XCTAssertEqual(AACFileWriter.id3Length(tag, at: 0), 73)
        tag[6] = 0x80
        XCTAssertEqual(AACFileWriter.id3Length(tag, at: 0), 0, "not a valid syncsafe size")
        XCTAssertEqual(AACFileWriter.id3Length(adts(payload: 20), at: 0), 0)
    }

    func testWriterBuildsAConsistentMP4() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aac-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AACFileWriter(url: url)
        let id3: [UInt8] = Array("ID3".utf8) + [3, 0, 0, 0, 0, 0, 10] + [UInt8](repeating: 0, count: 10)
        // Three pieces: a frame cut in half across the first two, and a third that starts with its own ID3 tag.
        let frames = [adts(payload: 100), adts(payload: 250), adts(payload: 180), adts(payload: 90), adts(payload: 60)]
        let stream = frames.prefix(4).flatMap { $0 }
        let cut = frames[0].count + frames[1].count + 40
        try writer.append(Data(id3 + stream[..<cut]))
        try writer.append(Data(stream[cut...]))
        try writer.append(Data(id3 + frames[4]))
        let seconds = try writer.finish()
        XCTAssertEqual(writer.frameCount, 5)
        XCTAssertEqual(seconds, 5120.0 / 44100.0, accuracy: 1e-9)

        // Walk the top-level boxes: ftyp, mdat, moov, and every size must add up to the file.
        let data = try Data(contentsOf: url)
        var offset = 0
        var boxes: [(String, Int, Int)] = []
        while offset < data.count {
            let size = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            let type = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
            boxes.append((type, offset, size))
            XCTAssertGreaterThanOrEqual(size, 8)
            offset += size
        }
        XCTAssertEqual(offset, data.count)
        XCTAssertEqual(boxes.map(\.0), ["ftyp", "mdat", "moov"])
        XCTAssertEqual(boxes[1].2, 8 + 100 + 250 + 180 + 90 + 60, "mdat holds raw AAC frames without ADTS headers or ID3 tags")
        let moov = data[boxes[2].1...]
        for name in ["mvhd", "trak", "mdhd", "stsd", "mp4a", "esds", "stts", "stsc", "stsz", "stco"] {
            XCTAssertNotNil(moov.range(of: Data(name.utf8)), "moov is missing \(name)")
        }
        // stco points at the first payload byte.
        let stco = try XCTUnwrap(moov.range(of: Data("stco".utf8)))
        let base = stco.upperBound + 4 + 4   // version/flags, entry count
        let chunkOffset = Int(moov[base]) << 24 | Int(moov[base + 1]) << 16 | Int(moov[base + 2]) << 8 | Int(moov[base + 3])
        XCTAssertEqual(chunkOffset, boxes[1].1 + 8)
        XCTAssertEqual(data[chunkOffset], 0xAB)
    }

    func testWriterRejectsAStreamWithNoAudio() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aac-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AACFileWriter(url: url)
        try writer.append(Data([1, 2, 3, 4]))
        XCTAssertThrowsError(try writer.finish())
    }

    // MARK: - Live YouTube (skipped when BACKLINE_SKIP_NETWORK_TESTS is set)

    private func requireNetwork() throws {
        if ProcessInfo.processInfo.environment["BACKLINE_SKIP_NETWORK_TESTS"] != nil {
            throw XCTSkip("BACKLINE_SKIP_NETWORK_TESTS is set")
        }
    }

    private func scratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("yt-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func download(_ id: String, ladder: [InnerTubeClient]? = nil, routes: YouTubeExtractor.Routes = .any,
                          cancelAt: Double? = nil, trace: (@Sendable (String) -> Void)? = nil) async throws
        -> (YouTubeImport.Result, URL) {
        let dir = try scratchDirectory()
        let cancelled = Flag()
        let result = try await YouTubeImport.download(YouTubeLink.parse("https://youtu.be/\(id)")!, jar: .none, into: dir,
                                                      ladder: ladder, routes: routes, trace: trace,
                                                      progress: { p in if let cancelAt, p >= cancelAt { cancelled.set() } },
                                                      isCancelled: { cancelled.value })
        return (result, dir)
    }

    private func assertPlayable(_ result: YouTubeImport.Result, in dir: URL, seconds: Double, tolerance: Double = 1.0,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(result.file.deletingLastPathComponent().standardizedFileURL, dir.standardizedFileURL, file: file, line: line)
        XCTAssertEqual(result.file.pathExtension, "m4a", file: file, line: line)
        let audio = try AVAudioFile(forReading: result.file)
        let decoded = Double(audio.length) / audio.processingFormat.sampleRate
        XCTAssertEqual(decoded, seconds, accuracy: tolerance, "decoded duration", file: file, line: line)
        XCTAssertEqual(audio.processingFormat.sampleRate, 44100, file: file, line: line)
        let leftovers = (try FileManager.default.contentsOfDirectory(atPath: dir.path)).filter { $0.hasSuffix(".part") }
        XCTAssertTrue(leftovers.isEmpty, "partial files left behind: \(leftovers)", file: file, line: line)
    }

    func testDownloadsVolatileReaction() async throws {
        try requireNetwork()
        let (result, dir) = try await download("2pXa5jzaOBg")
        XCTAssertEqual(result.title, "Volatile Reaction")
        XCTAssertEqual(result.uploader, "Kevin MacLeod")
        XCTAssertEqual(result.file.lastPathComponent, "2pXa5jzaOBg.m4a")
        try assertPlayable(result, in: dir, seconds: 163.35)
    }

    func testDownloadsViaHLSWhenForced() async throws {
        try requireNetwork()
        let (result, dir) = try await download("2pXa5jzaOBg", routes: .hlsOnly)
        XCTAssertEqual(result.title, "Volatile Reaction")
        XCTAssertNotEqual(result.clientID, "mweb", "HLS runs never use the proof-of-origin rung")
        try assertPlayable(result, in: dir, seconds: 163.30)
    }

    /// The TV rung alone: the player script's timestamp in the request, then its signature and `n` answers
    /// unlock the stream (R01a).
    func testDownloadsThroughTheTVClientWithThePlayerScript() async throws {
        try requireNetwork()
        let lines = Lines()
        let result: YouTubeImport.Result, dir: URL
        do {
            (result, dir) = try await download("2pXa5jzaOBg", ladder: [.tvSamsung], routes: .directOnly, trace: { lines.append($0) })
        } catch {
            XCTFail("\(error)\n" + lines.all.joined(separator: "\n"))
            return
        }
        XCTAssertEqual(result.title, "Volatile Reaction")
        XCTAssertEqual(result.uploader, "Kevin MacLeod")
        XCTAssertEqual(result.clientID, "tv_samsung", "the TV rung itself, not the proof-of-origin fallback")
        XCTAssertTrue(lines.all.contains { $0.hasPrefix("tv_samsung: direct itag") }, lines.all.joined(separator: "\n"))
        try assertPlayable(result, in: dir, seconds: 163.35)
    }

    func testDownloadsAnOrdinaryPopularVideo() async throws {
        try requireNetwork()
        let (result, dir) = try await download("dQw4w9WgXcQ")
        XCTAssertEqual(result.uploader, "Rick Astley")
        try assertPlayable(result, in: dir, seconds: 213.04)
    }

    func testAnInvalidIDIsUnavailable() async throws {
        try requireNetwork()
        do {
            _ = try await download("aaaaaaaaaaa")
            XCTFail("should not download")
        } catch YouTubeImport.Failure.failed(let message) {
            XCTAssertEqual(message, "Video not available.")
        }
    }

    func testARemovedVideoIsUnavailable() async throws {
        try requireNetwork()
        do {
            _ = try await download("6SJNVb0GnPI")
            XCTFail("should not download")
        } catch YouTubeImport.Failure.failed(let message) {
            XCTAssertEqual(message, "Video not available.")
        }
    }

    func testAnAgeRestrictedVideoAsksForSignIn() async throws {
        try requireNetwork()
        do {
            _ = try await download("HtVdAasjOgU")
            XCTFail("should not download")
        } catch YouTubeImport.Failure.needsSignIn {
        }
    }

    func testAnHourLongVideoIsTooLong() async throws {
        try requireNetwork()
        do {
            _ = try await download("Fneuy9H_2o0")
            XCTFail("should not download")
        } catch YouTubeImport.Failure.tooLong {
        }
    }

    func testCancellingLeavesNothingBehind() async throws {
        try requireNetwork()
        let dir = try scratchDirectory()
        let cancelled = Flag()
        do {
            _ = try await YouTubeImport.download(YouTubeLink.parse("https://youtu.be/xAbKnfdXMxM")!, jar: .none, into: dir,
                                                 progress: { p in if p >= 0.3 { cancelled.set() } },
                                                 isCancelled: { cancelled.value })
            XCTFail("should have been cancelled")
        } catch is CancellationError {
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }
}

nonisolated private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

nonisolated private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}
