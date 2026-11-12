import Foundation

/// One InnerTube client identity, as sent to `youtubei/v1/player`. These are snapshots of what yt-dlp
/// sends for each client; YouTube retires versions over time, so this table is the first thing to refresh
/// when downloads start failing.
nonisolated struct InnerTubeClient: Sendable, Equatable {
    var id: String
    var clientName: String
    var clientVersion: String
    var clientNameID: Int
    var userAgent: String
    var deviceMake: String?
    var deviceModel: String?
    var osName: String?
    var osVersion: String?
    var androidSdkVersion: Int?
    /// The client's streams need YouTube's player script: the signature timestamp in the request, and the
    /// signature and `n` challenges solved before download (TV clients).
    var needsPlayer = false
    /// Direct streams need a proof-of-origin token (`pot`); used only by the PO rung (R01p).
    var takesPOToken = false

    static let origin = "https://www.youtube.com"
    static let playerURL = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
    static let visitorIDURL = URL(string: "https://www.youtube.com/youtubei/v1/visitor_id?prettyPrint=false")!

    static let androidVR = InnerTubeClient(
        id: "android_vr", clientName: "ANDROID_VR", clientVersion: "1.65.10", clientNameID: 28,
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
        deviceMake: "Oculus", deviceModel: "Quest 3", osName: "Android", osVersion: "12L", androidSdkVersion: 32)

    static let visionOS = InnerTubeClient(
        id: "visionos", clientName: "VISIONOS", clientVersion: "1.02", clientNameID: 101,
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        deviceMake: "Apple", deviceModel: "RealityDevice17,1", osName: "visionOS", osVersion: "26.5.23O471")

    /// yt-dlp 2026.10.21's `tv_samsung` (one of its two default clients, with `visionos`): no PO token, but
    /// signature and `n` challenges, solved by `PlayerScript`.
    static let tvSamsung = InnerTubeClient(
        id: "tv_samsung", clientName: "TVHTML5", clientVersion: "5.20260707", clientNameID: 7,
        userAgent: "Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/2.4.0 TV Safari/538.1",
        deviceMake: "Samsung", deviceModel: "UKS9800", osName: "Tizen", osVersion: "2.4.0", needsPlayer: true)

    /// yt-dlp 2026.10.21's `mweb`: direct streams need a GVS PO token, which `POTokenMinter` mints. Not in
    /// the ladder: it is the proof-of-origin rung, after everything else (R01p).
    static let mweb = InnerTubeClient(
        id: "mweb", clientName: "MWEB", clientVersion: "2.20260708.05.00", clientNameID: 2,
        userAgent: "Mozilla/5.0 (iPad; CPU OS 16_7_10 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1,gzip(gfe)",
        needsPlayer: true, takesPOToken: true)

    static let ios = InnerTubeClient(
        id: "ios", clientName: "IOS", clientVersion: "21.26.4", clientNameID: 5,
        userAgent: "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
        deviceMake: "Apple", deviceModel: "iPhone16,2", osName: "iPhone", osVersion: "18.3.2.22D82")

    /// Tried in order until one hands back audio that really downloads. `visionos` gives plain DASH URLs
    /// and an HLS manifest. `tv_samsung` is yt-dlp's other default and needs the player script (R01a).
    /// `ios` is SABR-only on most sessions but often still offers the HLS manifest. `android_vr` is cut off
    /// after its first MiB unless the request carries a PO token, so it only gets a turn once everything
    /// else has failed.
    static let ladder = [visionOS, tvSamsung, ios, androidVR]

    /// yt-dlp 2026.10.26's `web_music` (`yt_dlp/extractor/youtube/_base.py`), with the "songs" section of
    /// the search (`_search.py`): one row per recording, with its artists, album and length. Used only to
    /// find the recording a music-service link names (S03) — a search needs no player script, no PO token
    /// and no device fields, so it has its own small shape.
    static let musicSearch = Search(host: "music.youtube.com", clientName: "WEB_REMIX", clientVersion: "1.20260707.12.00",
                                    clientNameID: 67, params: "EgWKAQIIAWoKEAoQAxAEEAkQBQ==")

    /// yt-dlp 2026.10.26's `web` with the search's "videos only" filter (`_search.py`): what a channel
    /// uploaded itself, for the songs the music search doesn't carry.
    static let videoSearch = Search(host: "www.youtube.com", clientName: "WEB", clientVersion: "2.20260707.01.00",
                                    clientNameID: 1, params: "EgIQAfABAQ==")

    /// One InnerTube search identity. `params` is the filter: which section of the results comes back.
    struct Search: Sendable, Equatable {
        var host: String
        var clientName: String
        var clientVersion: String
        var clientNameID: Int
        var params: String
        /// A desktop browser, as the searches are served to one.
        var userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"

        var url: URL { URL(string: "https://\(host)/youtubei/v1/search?prettyPrint=false")! }

        /// `gl` is the device's region, so someone in Australia gets the recording their store offers.
        func requestBody(query: String, region: String) -> Data {
            let body: [String: Any] = [
                "context": ["client": ["clientName": clientName, "clientVersion": clientVersion, "hl": "en", "gl": region]],
                "query": query,
                "params": params,
            ]
            return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        }

        var headers: [String: String] {
            [
                "Content-Type": "application/json",
                "User-Agent": userAgent,
                "Origin": "https://\(host)",
                "X-YouTube-Client-Name": String(clientNameID),
                "X-YouTube-Client-Version": clientVersion,
                "Accept-Language": "en-US,en;q=0.9",
            ]
        }
    }

    /// The `context` object of a player request.
    func context(visitorData: String?) -> [String: Any] {
        var client: [String: Any] = [
            "clientName": clientName, "clientVersion": clientVersion, "userAgent": userAgent,
            "hl": "en", "timeZone": "UTC", "utcOffsetMinutes": 0,
        ]
        if let deviceMake { client["deviceMake"] = deviceMake }
        if let deviceModel { client["deviceModel"] = deviceModel }
        if let osName { client["osName"] = osName }
        if let osVersion { client["osVersion"] = osVersion }
        if let androidSdkVersion { client["androidSdkVersion"] = androidSdkVersion }
        if let visitorData { client["visitorData"] = visitorData }
        return ["client": client]
    }

    func playerRequestBody(videoID: String, visitorData: String?, signatureTimestamp: Int? = nil, poToken: String? = nil) -> Data {
        var playback: [String: Any] = ["html5Preference": "HTML5_PREF_WANTS"]
        if let signatureTimestamp { playback["signatureTimestamp"] = signatureTimestamp }
        var body: [String: Any] = [
            "context": context(visitorData: visitorData),
            "videoId": videoID,
            "playbackContext": ["contentPlaybackContext": playback],
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        if let poToken { body["serviceIntegrityDimensions"] = ["poToken": poToken] }
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    /// Request headers. With a signed-in session the Cookie and SAPISIDHASH `Authorization` ride along.
    func playerHeaders(visitorData: String?, cookies: YouTubeCookies?, now: Date = Date()) -> [String: String] {
        var h = [
            "Content-Type": "application/json",
            "User-Agent": userAgent,
            "X-YouTube-Client-Name": String(clientNameID),
            "X-YouTube-Client-Version": clientVersion,
            "Origin": Self.origin,
            "Accept-Language": "en-US,en;q=0.9",
        ]
        if let visitorData { h["X-Goog-Visitor-Id"] = visitorData }
        if let cookies, cookies.isSignedIn {
            if let cookie = cookies.header(for: Self.playerURL, now: now) { h["Cookie"] = cookie }
            if let auth = cookies.authorization(origin: Self.origin, now: now) {
                h["Authorization"] = auth
                h["X-Origin"] = Self.origin
            }
            h["X-Goog-AuthUser"] = "0"
            h["X-Youtube-Bootstrap-Logged-In"] = "true"
        }
        return h
    }
}
