import Foundation

/// Netscape `cookies.txt` read/write — the format yt-dlp's `--cookies` loads (Mozilla `MozillaCookieJar`).
/// Pure value code so it can be unit-tested; the app feeds it `HTTPCookie`s from its sign-in web view.
public enum NetscapeCookies {
    public struct Cookie: Equatable, Sendable {
        public var domain: String        // ".youtube.com" (domain cookie) or "www.youtube.com" (host-only)
        public var path: String
        public var secure: Bool
        public var httpOnly: Bool
        public var expires: Date?        // nil = session cookie
        public var name: String
        public var value: String

        public init(domain: String, path: String, secure: Bool, httpOnly: Bool, expires: Date?, name: String, value: String) {
            self.domain = domain; self.path = path; self.secure = secure; self.httpOnly = httpOnly
            self.expires = expires; self.name = name; self.value = value
        }
    }

    /// Domains yt-dlp needs for YouTube sign-in. Nothing else is ever written out.
    /// Regional Google sites (google.com.au, google.co.uk, google.de …) are included; look-alikes aren't.
    public static func isYouTubeAuthDomain(_ domain: String) -> Bool {
        let d = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if ["youtube.com", "google.com"].contains(where: { d == $0 || d.hasSuffix("." + $0) }) { return true }
        // google.<cc> / google.com.<cc> / google.co.<cc>, optionally with subdomains.
        let labels = d.split(separator: ".").map(String.init)
        guard let g = labels.lastIndex(of: "google") else { return false }
        let tail = Array(labels[(g + 1)...])
        let isCC: (String) -> Bool = { $0.count == 2 && $0.allSatisfy(\.isLetter) }
        switch tail.count {
        case 1: return isCC(tail[0])
        case 2: return (tail[0] == "com" || tail[0] == "co") && isCC(tail[1])
        default: return false
        }
    }

    /// Cookies that prove a signed-in YouTube session.
    public static func hasYouTubeLogin(_ cookies: [Cookie]) -> Bool {
        let yt = cookies.filter {
            let d = $0.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return (d == "youtube.com" || d.hasSuffix(".youtube.com")) && !$0.value.isEmpty
        }
        let names = Set(yt.map(\.name))
        return names.contains("LOGIN_INFO") || !names.isDisjoint(with: ["__Secure-3PSID", "SAPISID", "__Secure-1PSID"])
    }

    public static func serialize(_ cookies: [Cookie]) -> String {
        var out = "# Netscape HTTP Cookie File\n# Written by Backline for yt-dlp. Temporary; deleted after use.\n\n"
        for c in cookies where isYouTubeAuthDomain(c.domain) {
            // Tabs or newlines would corrupt the line format — such cookies are skipped, not escaped.
            let fields = [c.domain, c.path, c.name, c.value]
            if fields.contains(where: { $0.contains("\t") || $0.contains("\n") || $0.contains("\r") }) { continue }
            let includeSub = c.domain.hasPrefix(".") ? "TRUE" : "FALSE"
            let expiry = c.expires.map { String(Int64($0.timeIntervalSince1970)) } ?? "0"
            let domain = (c.httpOnly ? "#HttpOnly_" : "") + c.domain
            out += [domain, includeSub, c.path.isEmpty ? "/" : c.path, c.secure ? "TRUE" : "FALSE",
                    expiry, c.name, c.value].joined(separator: "\t") + "\n"
        }
        return out
    }

    public static func parse(_ text: String) -> [Cookie] {
        var result: [Cookie] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = String(raw)
            var httpOnly = false
            if line.hasPrefix("#HttpOnly_") { httpOnly = true; line.removeFirst("#HttpOnly_".count) }
            else if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 7 else { continue }
            let exp = Int64(f[4]) ?? 0
            result.append(Cookie(domain: f[0], path: f[2], secure: f[3].uppercased() == "TRUE", httpOnly: httpOnly,
                                 expires: exp > 0 ? Date(timeIntervalSince1970: TimeInterval(exp)) : nil,
                                 name: f[5], value: f[6]))
        }
        return result
    }
}
