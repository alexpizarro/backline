import Foundation

/// The parts of a `youtubei/v1/player` response Backline reads: whether the video can be played, who and
/// what it is, and the audio streams.
nonisolated struct PlayerResponse: Sendable {
    enum Playability: Sendable, Equatable {
        case ok
        /// YouTube wants an account: bot check, age gate, private, members-only.
        case loginRequired
        /// Removed, private-to-nobody, region-blocked, never existed.
        case unavailable
        case liveOffline
        /// This client identity was refused ("The page needs to be reloaded", upgrade required).
        case clientRejected
    }

    struct Format: Sendable, Equatable {
        var itag: Int
        var mimeType: String
        var url: String?
        var contentLength: Int?
        var bitrate: Int?
        var durationMs: Int?
        var isDRC = false
        /// A format the player script must unlock: its scrambled signature `s`, the query parameter it goes
        /// in (`sp`) and the URL without it (TV clients send these; R01a).
        var cipher: Cipher?
        /// Dubbed / descriptive audio tracks rank below the original.
        var trackScore = 0

        var isAAC: Bool { mimeType.hasPrefix("audio/mp4") && mimeType.contains("mp4a") }

        /// 140 (AAC-LC 128k) is the target; 141 and 139 are acceptable; any other AAC after that.
        var preference: Int {
            let base: Int
            switch itag {
            case 140: base = 100
            case 141: base = 90
            case 139: base = 80
            default: base = mimeType.contains("mp4a.40.2") ? 60 : 40
            }
            return base + trackScore - (isDRC ? 200 : 0)
        }
    }

    var status = ""
    var reason: String?
    var playability = Playability.clientRejected
    var videoID: String?
    var title: String?
    var author: String?
    var lengthSeconds: Int?
    var isLive = false
    var audioFormats: [Format] = []
    var hlsManifestURL: URL?
    /// Seconds before the streams open: TV clients answer with a pre-roll ad, and googlevideo refuses the
    /// audio until it could have been skipped (or, unskippable, has played).
    var adWaitSeconds: Double = 0

    enum ParseError: Error { case notJSON }

    static func parse(_ data: Data) throws -> PlayerResponse {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParseError.notJSON }
        var r = PlayerResponse()
        let ps = root["playabilityStatus"] as? [String: Any]
        r.status = ps?["status"] as? String ?? ""
        r.reason = ps?["reason"] as? String
        r.playability = classify(status: r.status, reason: r.reason)

        if let d = root["videoDetails"] as? [String: Any] {
            r.videoID = d["videoId"] as? String
            r.title = d["title"] as? String
            r.author = d["author"] as? String
            r.lengthSeconds = int(d["lengthSeconds"])
            let live = (d["isLive"] as? Bool) == true
            let wasLive = (d["isLiveContent"] as? Bool) == true && (r.lengthSeconds ?? 0) == 0
            r.isLive = live || wasLive
        }

        if let sd = root["streamingData"] as? [String: Any] {
            let all = ((sd["adaptiveFormats"] as? [[String: Any]]) ?? []) + ((sd["formats"] as? [[String: Any]]) ?? [])
            r.audioFormats = all.compactMap(format)
            r.hlsManifestURL = (sd["hlsManifestUrl"] as? String).flatMap { URL(string: $0) }
        }
        r.adWaitSeconds = adWait(root)
        return r
    }

    /// yt-dlp's `_get_available_at_timestamp`: every ad that plays before the content, by its skip offset
    /// when it has one, else its length.
    static func adWait(_ root: [String: Any]) -> Double {
        func dict(_ v: Any?, _ keys: String...) -> [String: Any]? {
            keys.reduce(v as? [String: Any]) { $0?[$1] as? [String: Any] }
        }
        var ads: [[String: Any]] = []
        for p in root["adPlacements"] as? [[String: Any]] ?? [] {
            guard dict(p, "adPlacementRenderer", "config", "adPlacementConfig")?["kind"] as? String == "AD_PLACEMENT_KIND_START",
                  let ad = dict(p, "adPlacementRenderer", "renderer", "instreamVideoAdRenderer") else { continue }
            ads.append(ad)
        }
        for slot in root["adSlots"] as? [[String: Any]] ?? [] {
            guard dict(slot, "adSlotRenderer", "adSlotMetadata")?["triggerEvent"] as? String == "SLOT_TRIGGER_EVENT_BEFORE_CONTENT",
                  let content = dict(slot, "adSlotRenderer", "fulfillmentContent", "fulfilledLayout", "playerBytesAdLayoutRenderer",
                                     "renderingContent") else { continue }
            if let ad = dict(content, "instreamVideoAdRenderer") { ads.append(ad) }
            for layout in dict(content, "playerBytesSequentialLayoutRenderer")?["sequentialLayouts"] as? [[String: Any]] ?? [] {
                if let ad = dict(layout, "playerBytesAdLayoutRenderer", "renderingContent", "instreamVideoAdRenderer") { ads.append(ad) }
            }
        }
        return ads.reduce(0) { total, ad in
            if let skip = int(ad["skipOffsetMilliseconds"]) ?? (ad["skipOffsetMilliseconds"] as? Double).map({ Int($0) }) {
                return total + Double(skip) / 1000
            }
            let vars = URLComponents(string: "?" + (ad["playerVars"] as? String ?? ""))?.queryItems ?? []
            return total + Double(vars.last { $0.name == "length_seconds" }?.value.flatMap { Int($0) } ?? 0)
        }
    }

    struct Cipher: Sendable, Equatable {
        var s: String
        var sp: String
        var url: String

        /// `s=…&sp=sig&url=…`, as `signatureCipher` (or the older `cipher`) carries it.
        static func parse(_ text: String) -> Cipher? {
            let items = URLComponents(string: "?" + text)?.queryItems ?? []
            func value(_ k: String) -> String? { items.first { $0.name == k }?.value }
            guard let s = value("s"), let url = value("url") else { return nil }
            return Cipher(s: s, sp: value("sp") ?? "signature", url: url)
        }
    }

    private static func format(_ f: [String: Any]) -> Format? {
        guard let itag = int(f["itag"]), let mime = f["mimeType"] as? String, mime.hasPrefix("audio/") else { return nil }
        var out = Format(itag: itag, mimeType: mime, url: f["url"] as? String,
                         contentLength: int(f["contentLength"]), bitrate: int(f["bitrate"]),
                         durationMs: int(f["approxDurationMs"]))
        out.cipher = ((f["signatureCipher"] ?? f["cipher"]) as? String).flatMap(Cipher.parse)
        out.isDRC = (f["isDrc"] as? Bool) == true
        if let track = f["audioTrack"] as? [String: Any] {
            let name = (track["displayName"] as? String)?.lowercased() ?? ""
            if name.contains("descriptive") { out.trackScore = -50 }
            else if name.contains("original") { out.trackScore = 20 }
            else if (track["audioIsDefault"] as? Bool) == true { out.trackScore = 10 }
            else { out.trackScore = -10 }
        }
        return out
    }

    private static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let s = v as? String { return Int(s) }
        return nil
    }

    static func classify(status: String, reason: String?) -> Playability {
        let r = (reason ?? "").lowercased()
        switch status {
        case "OK": return .ok
        case "LOGIN_REQUIRED", "AGE_CHECK_REQUIRED", "AGE_VERIFICATION_REQUIRED": return .loginRequired
        case "LIVE_STREAM_OFFLINE": return .liveOffline
        case "UNPLAYABLE", "ERROR", "CONTENT_CHECK_REQUIRED":
            if r.contains("reloaded") || r.contains("update") || r.contains("no longer supported") { return .clientRejected }
            if r.contains("sign in") || r.contains("confirm your age") || r.contains("age-restricted")
                || r.contains("inappropriate") || r.contains("members") { return .loginRequired }
            return .unavailable
        default: return .clientRejected
        }
    }

    /// The audio stream to download: AAC in an MP4 container (the kind `AVAudioFile` reads) with a plain URL,
    /// or, when the player script is at hand (`unlocking`), one whose signature it must unlock.
    func bestAAC(unlocking: Bool = false) -> Format? {
        audioFormats.filter { $0.isAAC && ($0.url != nil || (unlocking && $0.cipher != nil)) }.max { $0.preference < $1.preference }
    }

    /// The challenges a format's URL holds for the player script: its scrambled signature, and the `n`
    /// parameter that throttles the download until it is transformed.
    static func challenges(of f: Format) -> (sig: String?, n: String?) {
        let base = f.cipher?.url ?? f.url ?? ""
        let n = URLComponents(string: base)?.queryItems?.first { $0.name == "n" }?.value
        return (f.cipher?.s, n)
    }

    /// The download URL once the player script has answered: the signature in its parameter, `n` replaced.
    /// The stream URL's other parameters keep their encoding byte for byte.
    static func unlockedURL(_ f: Format, sig: [String: String], n: [String: String]) -> URL? {
        guard var c = URLComponents(string: f.cipher?.url ?? f.url ?? "") else { return nil }
        var items = c.percentEncodedQueryItems ?? []
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encoded(_ v: String) -> String { v.addingPercentEncoding(withAllowedCharacters: unreserved) ?? v }
        if let cipher = f.cipher {
            guard let answer = sig[cipher.s] else { return nil }
            items.removeAll { $0.name == cipher.sp }
            items.append(URLQueryItem(name: cipher.sp, value: encoded(answer)))
        }
        if let i = items.firstIndex(where: { $0.name == "n" }), let value = items[i].value?.removingPercentEncoding {
            guard let answer = n[value] else { return nil }
            items[i].value = encoded(answer)
        }
        c.percentEncodedQueryItems = items
        return c.url
    }

    /// The stream URL with a proof-of-origin token in `pot` (R01p).
    static func adding(pot: String, to url: URL) -> URL? {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var items = (c.percentEncodedQueryItems ?? []).filter { $0.name != "pot" }
        guard let encoded = pot.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        items.append(URLQueryItem(name: "pot", value: encoded))
        c.percentEncodedQueryItems = items
        return c.url
    }

    /// True when YouTube offered sound but none of it is AAC (Opus / WebM only).
    var hasOnlyUnreadableAudio: Bool { !audioFormats.isEmpty && !audioFormats.contains { $0.isAAC } }
}
