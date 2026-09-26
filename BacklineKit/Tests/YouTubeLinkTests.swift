import XCTest
@testable import BacklineKit

final class YouTubeLinkTests: XCTestCase {
    func testAcceptsCommonForms() {
        let id = "2pXa5jzaOBg"
        for s in ["https://www.youtube.com/watch?v=\(id)", "https://youtube.com/watch?v=\(id)&t=42s",
                  "https://www.youtube.com/watch?v=\(id)&list=RD\(id)&index=1", "youtu.be/\(id)",
                  "https://youtu.be/\(id)?si=abcdef", "https://m.youtube.com/watch?v=\(id)",
                  "https://music.youtube.com/watch?v=\(id)&feature=share", "https://www.youtube.com/shorts/\(id)",
                  "https://www.youtube.com/live/\(id)", "https://www.youtube.com/embed/\(id)", "  \(" https://youtu.be/")\(id)\n"] {
            XCTAssertEqual(YouTubeLink.parse(s)?.id, id, s)
        }
        XCTAssertEqual(YouTubeLink.parse("https://youtu.be/\(id)")?.canonicalURL.absoluteString,
                       "https://www.youtube.com/watch?v=\(id)")
    }

    func testRejectsEverythingElse() {
        for s in ["", "hello", "--exec rm -rf ~", "-o /etc/passwd https://youtu.be/2pXa5jzaOBg",
                  "https://www.youtube.com/playlist?list=PL123", "https://www.youtube.com/@SomeChannel",
                  "https://vimeo.com/123456789", "https://evil.com/watch?v=2pXa5jzaOBg",
                  "https://youtube.com.evil.com/watch?v=2pXa5jzaOBg", "file:///etc/hosts",
                  "https://www.youtube.com/watch?v=short", "https://www.youtube.com/watch?v=2pXa5jzaOBg%20--exec",
                  "https://youtu.be/2pXa5jzaOB$", "ftp://youtu.be/2pXa5jzaOBg"] {
            XCTAssertNil(YouTubeLink.parse(s), s)
        }
    }

    func testFindsLinkInDraggedText() {
        XCTAssertEqual(YouTubeLink.find(in: "Check this <https://youtu.be/2pXa5jzaOBg> out")?.id, "2pXa5jzaOBg")
        XCTAssertNil(YouTubeLink.find(in: "no links here"))
    }
}
