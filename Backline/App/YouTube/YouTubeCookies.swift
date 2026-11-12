import BacklineKit
import CryptoKit
import Foundation

/// The signed-in session as plain values. Built from the cookies the sign-in web view holds; only
/// YouTube / Google auth domains are kept. Values are never logged or written anywhere.
nonisolated struct YouTubeCookies: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var secure: Bool
        var expires: Date?
    }

    private(set) var entries: [Entry]

    static let none = YouTubeCookies(entries: [])

    init(entries: [Entry]) { self.entries = entries }

    init(_ cookies: [HTTPCookie]) {
        entries = cookies.filter { NetscapeCookies.isYouTubeAuthDomain($0.domain) && !$0.value.isEmpty }.map {
            Entry(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path.isEmpty ? "/" : $0.path,
                  secure: $0.isSecure, expires: $0.expiresDate)
        }
    }

    var isEmpty: Bool { entries.isEmpty }

    /// True when the cookies prove a signed-in YouTube account (not just consent / preference cookies).
    var isSignedIn: Bool {
        NetscapeCookies.hasYouTubeLogin(entries.map {
            NetscapeCookies.Cookie(domain: $0.domain, path: $0.path, secure: $0.secure, httpOnly: false,
                                   expires: $0.expires, name: $0.name, value: $0.value)
        })
    }

    /// The `Cookie` request header for `url` (domain, path and expiry rules of RFC 6265), or nil.
    func header(for url: URL, now: Date = Date()) -> String? {
        guard let host = url.host?.lowercased(), url.scheme == "https" else { return nil }
        let path = url.path.isEmpty ? "/" : url.path
        let sent = entries.filter {
            Self.domainMatches(cookieDomain: $0.domain, host: host)
                && path.hasPrefix($0.path)
                && ($0.expires.map { $0 > now } ?? true)
        }
        guard !sent.isEmpty else { return nil }
        return sent.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    static func domainMatches(cookieDomain: String, host: String) -> Bool {
        let d = cookieDomain.lowercased()
        if d.hasPrefix(".") {
            let bare = String(d.dropFirst())
            return host == bare || host.hasSuffix("." + bare)
        }
        return host == d
    }

    private func value(of name: String) -> String? {
        entries.first { $0.name == name && ($0.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")).hasSuffix("youtube.com")) }?.value
    }

    /// `SAPISIDHASH <time>_<sha1>` (plus the 1P / 3P variants) for `origin`, the way YouTube's own web
    /// pages authorise their API calls. Nil without a SAPISID-family cookie.
    func authorization(origin: String, now: Date = Date()) -> String? {
        let timestamp = Int(now.timeIntervalSince1970.rounded())
        let sapisid = value(of: "SAPISID") ?? value(of: "__Secure-3PAPISID")
        let parts: [(String, String?)] = [
            ("SAPISIDHASH", sapisid),
            ("SAPISID1PHASH", value(of: "__Secure-1PAPISID")),
            ("SAPISID3PHASH", value(of: "__Secure-3PAPISID")),
        ]
        let hashes = parts.compactMap { scheme, sid in
            sid.map { "\(scheme) \(Self.sidHash(sid: $0, origin: origin, timestamp: timestamp))" }
        }
        return hashes.isEmpty ? nil : hashes.joined(separator: " ")
    }

    /// `<timestamp>_<sha1("<timestamp> <sid> <origin>")>`
    static func sidHash(sid: String, origin: String, timestamp: Int) -> String {
        let digest = Insecure.SHA1.hash(data: Data("\(timestamp) \(sid) \(origin)".utf8))
        return "\(timestamp)_" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
