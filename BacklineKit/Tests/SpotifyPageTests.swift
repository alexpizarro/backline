import Foundation
import XCTest
@testable import BacklineKit

/// S01 and S02: the link shapes a music service hands out (as pasted, shared and dropped), and what its
/// public pages say about a song, read from pages recorded on 5 November 2026.
final class SpotifyPageTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: Self.fixtures.appendingPathComponent(name), encoding: .utf8)
    }

    // MARK: S01 the link shapes

    func testTheLinkShapes() {
        XCTAssertEqual(SpotifyRef.find(in: "https://open.spotify.com/track/558kPt5dAK4XskceUBSnqi"),
                       .link(SpotifyLink(kind: .track, id: "558kPt5dAK4XskceUBSnqi")))
        XCTAssertEqual(SpotifyRef.find(in: "https://open.spotify.com/intl-de/album/6N9PS4QXF1D0OWPk0Sxtb4?si=abc"),
                       .link(SpotifyLink(kind: .album, id: "6N9PS4QXF1D0OWPk0Sxtb4")), "an /intl-xx/ link with ?si=")
        XCTAssertEqual(SpotifyRef.find(in: "https://play.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M"),
                       .link(SpotifyLink(kind: .playlist, id: "37i9dQZF1DXcBWIGoYBM5M")))
        XCTAssertEqual(SpotifyRef.find(in: "open.spotify.com/track/558kPt5dAK4XskceUBSnqi"),
                       .link(SpotifyLink(kind: .track, id: "558kPt5dAK4XskceUBSnqi")), "no scheme, as dropped")
        XCTAssertEqual(SpotifyRef.find(in: "spotify:track:558kPt5dAK4XskceUBSnqi"),
                       .link(SpotifyLink(kind: .track, id: "558kPt5dAK4XskceUBSnqi")), "the app's own URI")
        XCTAssertEqual(SpotifyRef.find(in: "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M"),
                       .link(SpotifyLink(kind: .playlist, id: "37i9dQZF1DXcBWIGoYBM5M")))
    }

    /// What the share sheet puts on the clipboard: words, then the link, sometimes a full stop after it.
    func testALinkInsideSharedText() {
        XCTAssertEqual(SpotifyRef.find(in: "Check out this song on Spotify: https://open.spotify.com/track/558kPt5dAK4XskceUBSnqi?si=9f1"),
                       .link(SpotifyLink(kind: .track, id: "558kPt5dAK4XskceUBSnqi")))
        XCTAssertEqual(SpotifyRef.find(in: "listen to https://open.spotify.com/track/558kPt5dAK4XskceUBSnqi. it's good"),
                       .link(SpotifyLink(kind: .track, id: "558kPt5dAK4XskceUBSnqi")), "a full stop after the link")
        XCTAssertEqual(SpotifyRef.find(in: "<a href=\"https://open.spotify.com/album/6N9PS4QXF1D0OWPk0Sxtb4\">x</a>"),
                       .link(SpotifyLink(kind: .album, id: "6N9PS4QXF1D0OWPk0Sxtb4")), "dragged from a browser")
        XCTAssertEqual(SpotifyRef.find(in: "first https://open.spotify.com/track/558kPt5dAK4XskceUBSnqi then https://spotify.link/abcd"),
                       .link(SpotifyLink(kind: .track, id: "558kPt5dAK4XskceUBSnqi")), "the first link in the text wins")
    }

    func testTheKindsThatCannotBeSplit() {
        XCTAssertEqual(SpotifyRef.find(in: "https://open.spotify.com/artist/4fSMtiyC6lF5BUO1tUMWMs"),
                       .link(SpotifyLink(kind: .artist, id: "4fSMtiyC6lF5BUO1tUMWMs")))
        XCTAssertEqual(SpotifyRef.find(in: "https://open.spotify.com/show/4rOoJ6Egrf8K2IrywzwOMk"),
                       .link(SpotifyLink(kind: .show, id: "4rOoJ6Egrf8K2IrywzwOMk")))
        XCTAssertEqual(SpotifyRef.find(in: "https://open.spotify.com/episode/5Vg4Zg8sGE1c0yTOm5bCvO"),
                       .link(SpotifyLink(kind: .episode, id: "5Vg4Zg8sGE1c0yTOm5bCvO")))
    }

    func testShortLinks() {
        XCTAssertEqual(SpotifyRef.find(in: "https://spotify.link/hRkBrwub9xb"),
                       .short(URL(string: "https://spotify.link/hRkBrwub9xb")!))
        XCTAssertEqual(SpotifyRef.find(in: "https://spotify.app.link/hRkBrwub9xb?_p=x"),
                       .short(URL(string: "https://spotify.app.link/hRkBrwub9xb")!), "each host keeps its own codes")
    }

    func testWhatIsNotAMusicLink() {
        XCTAssertNil(SpotifyRef.find(in: "https://open.spotify.com/track/tooshort"))
        XCTAssertNil(SpotifyRef.find(in: "https://open.spotify.com/concert/558kPt5dAK4XskceUBSnqi"), "not a kind Backline knows")
        XCTAssertNil(SpotifyRef.find(in: "https://notspotify.com/track/558kPt5dAK4XskceUBSnqi"))
        XCTAssertNil(SpotifyRef.find(in: "my favourite song"))
    }

    func testTheLinksBacklineBuilds() {
        let link = SpotifyLink(kind: .track, id: "558kPt5dAK4XskceUBSnqi")
        XCTAssertEqual(link.embedURL.absoluteString, "https://open.spotify.com/embed/track/558kPt5dAK4XskceUBSnqi")
        XCTAssertEqual(link.pageURL.absoluteString, "https://open.spotify.com/track/558kPt5dAK4XskceUBSnqi")
        XCTAssertEqual(link.sourceName, "spotify:558kPt5dAK4XskceUBSnqi")
    }

    /// A short link is followed, and the link it lands on is read from the URL, `og:url` or the canonical link.
    func testWhereAShortLinkLands() throws {
        let landed = URL(string: "https://open.spotify.com/track/7xtG2Kac0KPcd1ThPEGbZw?si=kSF&utm_source=copy-link&nd=1")!
        XCTAssertEqual(SpotifyLink.target(finalURL: landed), SpotifyLink(kind: .track, id: "7xtG2Kac0KPcd1ThPEGbZw"),
                       "the redirect keeps the kind and id, with tracking after them")
        let page = try fixture("spotify-track-page-head.html")
        XCTAssertEqual(SpotifyLink.target(finalURL: URL(string: "https://spotify.link/hRkBrwub9xb")!, html: page),
                       SpotifyLink(kind: .track, id: "558kPt5dAK4XskceUBSnqi"),
                       "a short link that didn't redirect: the page says where it is")
        XCTAssertNil(SpotifyLink.target(finalURL: URL(string: "https://apps.apple.com/app/spotify/id324684580")!,
                                        html: "<html><head></head></html>"))
    }

    // MARK: S02 what the page says

    func testASongFromTheEmbedPage() throws {
        let song = try XCTUnwrap(SpotifyPage.song(inEmbed: fixture("spotify-embed-track.html")))
        XCTAssertEqual(song.title, "Volatile Reaction")
        XCTAssertEqual(song.artists, ["Kevin MacLeod"])
        XCTAssertEqual(song.seconds, 165.355, accuracy: 0.001)
        XCTAssertEqual(song.id, "558kPt5dAK4XskceUBSnqi")
        XCTAssertEqual(song.artwork?.absoluteString,
                       "https://image-cdn-ak.spotifycdn.com/image/ab67616d0000b27381082d64f0c8c1c721d3bff0",
                       "the biggest cover the page offers")
    }

    func testAnAlbumsTracks() throws {
        let list = try XCTUnwrap(SpotifyPage.trackList(inEmbed: fixture("spotify-embed-album.html")))
        XCTAssertEqual(list.name, "Whenever You Need Somebody")
        XCTAssertEqual(list.tracks.count, 10)
        XCTAssertEqual(list.tracks[0].title, "Never Gonna Give You Up")
        XCTAssertEqual(list.tracks[0].artists, ["Rick Astley"])
        XCTAssertEqual(list.tracks[0].id, "4uLU6hMCjMI75M1A2tKUQC")
        XCTAssertEqual(list.tracks[0].seconds, 213.573, accuracy: 0.001)
    }

    func testAPlaylistStopsAtAHundredTracks() throws {
        let list = try XCTUnwrap(SpotifyPage.trackList(inEmbed: fixture("spotify-embed-playlist.html")))
        XCTAssertEqual(list.tracks.count, 100, "the page itself returns no more than 100")
        XCTAssertTrue(list.name.hasPrefix("BACHATA SENSUAL HITS 2026"))
        XCTAssertEqual(list.tracks[0].title, "Devórame")
        XCTAssertEqual(list.tracks[0].artist, "Chris Paradise")
        XCTAssertTrue(list.tracks.allSatisfy { !$0.title.isEmpty && $0.seconds > 0 && $0.id.count == 22 })
    }

    func testATrackPageIsNotATrackList() throws {
        XCTAssertNil(SpotifyPage.trackList(inEmbed: try fixture("spotify-embed-track.html")))
        XCTAssertNil(SpotifyPage.song(inEmbed: "<html><body>nothing here</body></html>"))
    }

    /// The fallback when the embed page can't be read: the tags a link preview shows.
    func testASongFromTheLinkPreviewTags() throws {
        let song = try XCTUnwrap(SpotifyPage.song(inOpenGraph: fixture("spotify-track-page-head.html"),
                                                  id: "558kPt5dAK4XskceUBSnqi"))
        XCTAssertEqual(song.title, "Volatile Reaction")
        XCTAssertEqual(song.artists, ["Kevin MacLeod"])
        XCTAssertEqual(song.seconds, 165, "whole seconds there, a second coarser than the embed page")
        XCTAssertEqual(song.artwork?.absoluteString, "https://i.scdn.co/image/ab67616d0000b27381082d64f0c8c1c721d3bff0")
    }

    func testTagsAreReadWhicheverWayRoundTheyAreWritten() {
        let html = #"<meta content="Two Artists, Three Artists" name="music:musician_description"><meta property="og:title" content="A &amp; B"><meta name="music:duration" content="201">"#
        let song = SpotifyPage.song(inOpenGraph: html)
        XCTAssertEqual(song?.title, "A & B")
        XCTAssertEqual(song?.artists, ["Two Artists", "Three Artists"])
        XCTAssertEqual(song?.seconds, 201)
        XCTAssertNil(SpotifyPage.song(inOpenGraph: #"<meta property="og:title" content="No length">"#), "a song needs a length")
    }
}
