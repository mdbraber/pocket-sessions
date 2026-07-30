@testable import podcasts
import XCTest

/// Fork: the ladder is derived, not advertised, so the derivation IS the feature. A wrong match
/// sends playback at a url that cannot exist; a missed match silently costs the quality the whole
/// thing is for.
final class DerivedHLSStreamTests: XCTestCase {
    func testDerivesTheLadderFromAProgressiveEnclosure() {
        XCTAssertEqual(
            DerivedHLSStream.url(forEnclosure: "https://owntube-media.home.example.com/enclosure/dQw4w9WgXcQ.mp4")?.absoluteString,
            "https://owntube-media.home.example.com/hls/dQw4w9WgXcQ/master.m3u8"
        )
    }

    func testKeepsTheEnclosureHostSchemeAndPort() {
        // The ladder is served by whichever origin served the enclosure, so nothing about the
        // origin is assumed — a host or port change has to carry across untouched.
        XCTAssertEqual(
            DerivedHLSStream.url(forEnclosure: "http://192.168.1.10:8080/enclosure/abcdefghijk.mp4")?.absoluteString,
            "http://192.168.1.10:8080/hls/abcdefghijk/master.m3u8"
        )
    }

    func testDropsAQueryAndFragment() {
        // A token on the progressive file does not authorise the manifest, and carrying it over
        // would produce a url the origin has never seen.
        XCTAssertEqual(
            DerivedHLSStream.url(forEnclosure: "https://host/enclosure/dQw4w9WgXcQ.mp4?token=abc#t=10")?.absoluteString,
            "https://host/hls/dQw4w9WgXcQ/master.m3u8"
        )
    }

    func testLeavesAudioEnclosuresAlone() {
        // .m4a is audio-only: a ladder buys no quality there and only adds a manifest round-trip.
        XCTAssertNil(DerivedHLSStream.url(forEnclosure: "https://host/enclosure/dQw4w9WgXcQ.m4a"))
    }

    func testLeavesOtherPodcastsAlone() {
        XCTAssertNil(DerivedHLSStream.url(forEnclosure: "https://traffic.megaphone.fm/ADL1234567890.mp3"))
        XCTAssertNil(DerivedHLSStream.url(forEnclosure: "https://media.transistor.fm/93b685cf/7dd0b750.mp3"))
        XCTAssertNil(DerivedHLSStream.url(forEnclosure: "https://host/media/dQw4w9WgXcQ.mp4"))
    }

    func testRequiresAnExactElevenCharacterId() {
        XCTAssertNil(DerivedHLSStream.url(forEnclosure: "https://host/enclosure/tooshort.mp4"))
        XCTAssertNil(DerivedHLSStream.url(forEnclosure: "https://host/enclosure/waytoolongforanid.mp4"))
    }

    func testRejectsATrailingPathSegment() {
        XCTAssertNil(DerivedHLSStream.url(forEnclosure: "https://host/enclosure/dQw4w9WgXcQ.mp4/extra"))
    }

    // MARK: - Failure memory (the fallback to the progressive file)

    func testAFailedLadderIsRemembered() {
        let uuid = UUID().uuidString
        XCTAssertFalse(DerivedHLSStream.hasFailed(episodeUuid: uuid))
        DerivedHLSStream.markFailed(episodeUuid: uuid)
        XCTAssertTrue(DerivedHLSStream.hasFailed(episodeUuid: uuid))
    }

    func testMarkingTwiceDoesNotDuplicate() {
        let uuid = UUID().uuidString
        DerivedHLSStream.markFailed(episodeUuid: uuid)
        DerivedHLSStream.markFailed(episodeUuid: uuid)
        XCTAssertTrue(DerivedHLSStream.hasFailed(episodeUuid: uuid))
    }

    func testTheFailureListStaysBounded() {
        // A run of failures must not grow the defaults without limit.
        let uuids = (0 ..< 130).map { _ in UUID().uuidString }
        uuids.forEach { DerivedHLSStream.markFailed(episodeUuid: $0) }
        let stored = UserDefaults.standard.stringArray(forKey: "SJDerivedHLSFailed") ?? []
        XCTAssertLessThanOrEqual(stored.count, 100)
        // The most recent failures are the ones worth keeping.
        XCTAssertTrue(DerivedHLSStream.hasFailed(episodeUuid: uuids.last!))
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "SJDerivedHLSFailed")
        super.tearDown()
    }
}
