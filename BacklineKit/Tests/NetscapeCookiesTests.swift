import Foundation
import Testing
@testable import BacklineKit

struct NetscapeCookiesTests {
    typealias C = NetscapeCookies.Cookie

    @Test func writesOnlyYouTubeAndGoogleCookiesInNetscapeFormat() {
        let exp = Date(timeIntervalSince1970: 1_900_000_000)
        let cookies = [
            C(domain: ".youtube.com", path: "/", secure: true, httpOnly: true, expires: exp, name: "__Secure-3PSID", value: "abc"),
            C(domain: "www.youtube.com", path: "/", secure: false, httpOnly: false, expires: nil, name: "PREF", value: "f6=8"),
            C(domain: ".google.com", path: "/", secure: true, httpOnly: false, expires: exp, name: "SAPISID", value: "xyz"),
            C(domain: ".evil-youtube.com", path: "/", secure: true, httpOnly: false, expires: exp, name: "X", value: "1"),
            C(domain: ".bank.com", path: "/", secure: true, httpOnly: false, expires: exp, name: "S", value: "2"),
            C(domain: ".youtube.com", path: "/", secure: true, httpOnly: false, expires: exp, name: "BAD", value: "a\tb"),
        ]
        let text = NetscapeCookies.serialize(cookies)
        #expect(text.hasPrefix("# Netscape HTTP Cookie File"))
        let lines = text.split(separator: "\n").filter { !$0.hasPrefix("# ") && !$0.isEmpty && $0 != "#" }
        #expect(lines.count == 3)
        #expect(lines.contains("#HttpOnly_.youtube.com\tTRUE\t/\tTRUE\t1900000000\t__Secure-3PSID\tabc"))
        #expect(lines.contains("www.youtube.com\tFALSE\t/\tFALSE\t0\tPREF\tf6=8"))
        #expect(!text.contains("bank.com") && !text.contains("evil-youtube") && !text.contains("BAD"))
    }

    @Test func domainFilterAcceptsRegionalGoogleAndRejectsLookAlikes() {
        for ok in [".youtube.com", "www.youtube.com", ".google.com", "accounts.google.com", ".google.com.au",
                   ".google.co.uk", "accounts.google.de"] { #expect(NetscapeCookies.isYouTubeAuthDomain(ok), "\(ok)") }
        for bad in [".evil-youtube.com", "youtube.com.evil.com", ".google.evil.com", "accounts.google.com.evil.io",
                    ".notgoogle.com", ".google.company", "google", ".google.co.evil"] {
            #expect(!NetscapeCookies.isYouTubeAuthDomain(bad), "\(bad)")
        }
    }

    @Test func roundTripsAndDetectsLogin() {
        let exp = Date(timeIntervalSince1970: 1_900_000_000)
        let signedIn = [C(domain: ".youtube.com", path: "/", secure: true, httpOnly: true, expires: exp, name: "LOGIN_INFO", value: "v")]
        let parsed = NetscapeCookies.parse(NetscapeCookies.serialize(signedIn))
        #expect(parsed == signedIn)
        #expect(NetscapeCookies.hasYouTubeLogin(parsed))
        let anonymous = [C(domain: ".youtube.com", path: "/", secure: true, httpOnly: false, expires: exp, name: "VISITOR_INFO1_LIVE", value: "v")]
        #expect(!NetscapeCookies.hasYouTubeLogin(anonymous))
        // A login cookie on Google alone isn't a YouTube session.
        #expect(!NetscapeCookies.hasYouTubeLogin([C(domain: ".google.com", path: "/", secure: true, httpOnly: false, expires: exp, name: "SAPISID", value: "v")]))
        #expect(!NetscapeCookies.hasYouTubeLogin([C(domain: ".notyoutube.com", path: "/", secure: true, httpOnly: false, expires: exp, name: "LOGIN_INFO", value: "v")]))
    }
}
