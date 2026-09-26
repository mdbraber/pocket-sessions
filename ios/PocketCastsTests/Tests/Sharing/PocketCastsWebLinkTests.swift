import XCTest
@testable import podcasts

/// Fork: Pocket Casts web links reach the app through `pktc://weblink/<url>` (share sheet, Safari
/// extension), because only the official app can claim pca.st / pocketcasts.com as universal links.
final class PocketCastsWebLinkTests: XCTestCase {

    private let uuid = "da3271a0-69e7-0132-d9fd-5f4c86fd3263"

    // MARK: - Hosts

    func testAcceptsPocketCastsHosts() {
        for host in ["pca.st", "pocketcasts.com", "www.pocketcasts.com", "play.pocketcasts.com", "PCA.ST"] {
            XCTAssertTrue(PocketCastsWebLink.isPocketCastsHost(host), host)
        }
    }

    func testRejectsOtherHosts() {
        for host in ["evil.example", "pca.st.evil.example", "evilpocketcasts.com", "api.pocketcasts.com", ""] {
            XCTAssertFalse(PocketCastsWebLink.isPocketCastsHost(host), host)
        }
        XCTAssertFalse(PocketCastsWebLink.isPocketCastsHost(nil))
    }

    func testAcceptsAnExtraHost() {
        XCTAssertTrue(PocketCastsWebLink.isPocketCastsHost("pcast.pocketcasts.net", extraHosts: ["pcast.pocketcasts.net"]))
        XCTAssertFalse(PocketCastsWebLink.isPocketCastsHost("pcast.pocketcasts.net"))
    }

    // MARK: - pktc://weblink/<url>

    func testRawWebLink() {
        let url = URL(string: "pktc://weblink/https://pca.st/podcast/\(uuid)")!
        XCTAssertEqual(PocketCastsWebLink.webURL(fromPktcWeblink: url)?.absoluteString, "https://pca.st/podcast/\(uuid)")
    }

    func testPercentEncodedWebLinkMatchesRaw() {
        let raw = URL(string: "pktc://weblink/https://pca.st/podcast/\(uuid)")!
        let encoded = URL(string: "pktc://weblink/https%3A%2F%2Fpca.st%2Fpodcast%2F\(uuid)")!
        XCTAssertNotNil(PocketCastsWebLink.webURL(fromPktcWeblink: encoded))
        XCTAssertEqual(PocketCastsWebLink.webURL(fromPktcWeblink: encoded), PocketCastsWebLink.webURL(fromPktcWeblink: raw))
    }

    func testQueryIsPreservedRaw() {
        let url = URL(string: "pktc://weblink/https://pca.st/episode/abc?t=123")!
        let webURL = PocketCastsWebLink.webURL(fromPktcWeblink: url)
        XCTAssertEqual(webURL?.absoluteString, "https://pca.st/episode/abc?t=123")
        XCTAssertEqual(webURL?.query, "t=123")
    }

    func testQueryIsPreservedPercentEncoded() {
        let url = URL(string: "pktc://weblink/https%3A%2F%2Fpca.st%2Fepisode%2Fabc%3Ft%3D123")!
        XCTAssertEqual(PocketCastsWebLink.webURL(fromPktcWeblink: url)?.absoluteString, "https://pca.st/episode/abc?t=123")
    }

    func testOtherPocketCastsHosts() {
        let url = URL(string: "pktc://weblink/https://pocketcasts.com/podcast/some-show/\(uuid)")!
        XCTAssertEqual(PocketCastsWebLink.webURL(fromPktcWeblink: url)?.host, "pocketcasts.com")
    }

    func testForeignHostIsRejected() {
        XCTAssertNil(PocketCastsWebLink.webURL(fromPktcWeblink: URL(string: "pktc://weblink/https://evil.example/podcast/x")!))
        XCTAssertNil(PocketCastsWebLink.webURL(fromPktcWeblink: URL(string: "pktc://weblink/https%3A%2F%2Fevil.example%2Fpodcast%2Fx")!))
        XCTAssertNil(PocketCastsWebLink.webURL(fromPktcWeblink: URL(string: "pktc://weblink/https://pca.st@evil.example/podcast/x")!))
        XCTAssertNil(PocketCastsWebLink.webURL(fromPktcWeblink: URL(string: "pktc://weblink/https://pca.st.evil.example/podcast/x")!))
    }

    func testNonHTTPSIsRejected() {
        XCTAssertNil(PocketCastsWebLink.webURL(fromPktcWeblink: URL(string: "pktc://weblink/http://pca.st/podcast/x")!))
        XCTAssertNil(PocketCastsWebLink.webURL(fromPktcWeblink: URL(string: "pktc://weblink/javascript:alert(1)")!))
    }

    func testMissingOrWrongPrefixIsRejected() {
        XCTAssertNil(PocketCastsWebLink.webURL(fromPktcWeblink: URL(string: "pktc://weblink/")!))
        XCTAssertNil(PocketCastsWebLink.webURL(fromPktcWeblink: URL(string: "pktc://weblink")!))
        XCTAssertNil(PocketCastsWebLink.webURL(fromPktcWeblink: URL(string: "pktc://subscribe/https://pca.st/podcast/x")!))
        XCTAssertNil(PocketCastsWebLink.webURL(fromPktcWeblink: URL(string: "https://weblink/https://pca.st/podcast/x")!))
    }

    // MARK: - pktc://podcast/<uuid>

    func testPodcastUuid() {
        XCTAssertEqual(PocketCastsWebLink.podcastUuid(fromPktcPodcast: URL(string: "pktc://podcast/\(uuid)")!), uuid)
        XCTAssertEqual(PocketCastsWebLink.podcastUuid(fromPktcPodcast: URL(string: "pktc://podcast/\(uuid)/")!), uuid)
    }

    func testPodcastUuidRejectsBadInput() {
        XCTAssertNil(PocketCastsWebLink.podcastUuid(fromPktcPodcast: URL(string: "pktc://podcast/")!))
        XCTAssertNil(PocketCastsWebLink.podcastUuid(fromPktcPodcast: URL(string: "pktc://podcast")!))
        XCTAssertNil(PocketCastsWebLink.podcastUuid(fromPktcPodcast: URL(string: "pktc://podcast/\(uuid)/extra")!))
        XCTAssertNil(PocketCastsWebLink.podcastUuid(fromPktcPodcast: URL(string: "pktc://podcast/not%20a%20uuid")!))
        XCTAssertNil(PocketCastsWebLink.podcastUuid(fromPktcPodcast: URL(string: "pktc://episode/\(uuid)")!))
    }
}
