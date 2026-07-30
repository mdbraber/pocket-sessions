@testable import podcasts
import XCTest

/// Fork: video chapters for our own private feeds are found by recognising the companion server's
/// enclosure shape. The pattern is the whole mechanism, so it is worth pinning — a false positive
/// would send a stranger's episode to our chapters host, and a false negative silently costs the
/// episode its chapters.
final class VideoChaptersTests: XCTestCase {
    private func videoId(_ url: String) -> String? {
        ShowInfoCoordinator.videoChaptersVideoId(fromEnclosure: url)
    }

    func testMatchesTheCompanionEnclosureShape() {
        XCTAssertEqual(videoId("https://owntube-media.home.example.com/enclosure/dQw4w9WgXcQ.m4a"), "dQw4w9WgXcQ")
        XCTAssertEqual(videoId("https://owntube-media.home.example.com/enclosure/dQw4w9WgXcQ.mp4"), "dQw4w9WgXcQ")
    }

    func testMatchesOnAnyHost() {
        // The media origin and the feed origin differ, and either may move, so the host is not part
        // of the match.
        XCTAssertEqual(videoId("http://192.168.1.10:8080/enclosure/abcdefghijk.mp4"), "abcdefghijk")
    }

    func testIgnoresAQueryString() {
        // A signed or tokenised enclosure must still match — the extension anchor is applied to the
        // path, not the whole url.
        XCTAssertEqual(videoId("https://host/enclosure/dQw4w9WgXcQ.mp4?token=abc123"), "dQw4w9WgXcQ")
        XCTAssertEqual(videoId("https://host/enclosure/dQw4w9WgXcQ.m4a#t=10"), "dQw4w9WgXcQ")
    }

    func testAcceptsTheFullYouTubeIdAlphabet() {
        XCTAssertEqual(videoId("https://host/enclosure/-_aB9zZ0x1Y.mp4"), "-_aB9zZ0x1Y")
    }

    // MARK: - Non-matches

    func testRejectsAnOrdinaryPodcastEnclosure() {
        XCTAssertNil(videoId("https://traffic.megaphone.fm/ADL1234567890.mp3"))
        XCTAssertNil(videoId("https://media.transistor.fm/93b685cf/7dd0b750.mp3"))
    }

    func testRejectsTheWrongIdLength() {
        // 11 characters exactly — a shorter or longer segment is not a YouTube id, and guessing
        // would point us at a chapters url that cannot exist.
        XCTAssertNil(videoId("https://host/enclosure/tooshort.mp4"))
        XCTAssertNil(videoId("https://host/enclosure/waytoolongforanid.mp4"))
    }

    func testRejectsAnUnsupportedExtension() {
        XCTAssertNil(videoId("https://host/enclosure/dQw4w9WgXcQ.mp3"))
        XCTAssertNil(videoId("https://host/enclosure/dQw4w9WgXcQ.webm"))
    }

    func testRejectsADifferentPathSegment() {
        XCTAssertNil(videoId("https://host/media/dQw4w9WgXcQ.mp4"))
        XCTAssertNil(videoId("https://host/enclosures/dQw4w9WgXcQ.mp4"))
    }

    func testRejectsTrailingPathAfterTheExtension() {
        // The extension anchors the end of the path; anything after it is a different resource.
        XCTAssertNil(videoId("https://host/enclosure/dQw4w9WgXcQ.mp4/extra"))
    }
}
