@testable import podcasts
import PocketCastsDataModel
import XCTest

/// Fork: the recovery must be inert on every push except the one it exists for — a payload that
/// names an episode we already hold, or names nothing at all, has to leave the ordinary refresh
/// path completely alone.
final class NewEpisodePushRecoveryTests: XCTestCase {
    private func payload(episode: String?, podcast: String?) -> [AnyHashable: Any] {
        var userInfo = [AnyHashable: Any]()
        if let episode { userInfo["eu"] = episode }
        if let podcast { userInfo["podcast_uuid"] = podcast }
        return userInfo
    }

    /// `completion` always runs — a caller chaining its own refresh behind it must never be stranded.
    private func recoverSynchronously(_ userInfo: [AnyHashable: Any]) -> Bool {
        var completed = false
        NewEpisodePushRecovery.recover(userInfo: userInfo) { completed = true }
        return completed
    }

    func testASilentWakeCarriesNoEpisodeAndIsIgnored() {
        XCTAssertTrue(recoverSynchronously(["pcsCursor": 42]))
    }

    func testAPayloadMissingThePodcastUuidIsIgnored() {
        // PC's own pushes always carry both; a half-payload is not something to act on, since the
        // podcast is what the targeted refresh needs.
        XCTAssertTrue(recoverSynchronously(payload(episode: UUID().uuidString, podcast: nil)))
    }

    func testAPayloadMissingTheEpisodeUuidIsIgnored() {
        XCTAssertTrue(recoverSynchronously(payload(episode: nil, podcast: UUID().uuidString)))
    }

    func testEmptyUuidsAreTreatedAsAbsent() {
        XCTAssertTrue(recoverSynchronously(payload(episode: "", podcast: "")))
    }

    func testAnUnknownPodcastIsIgnored() {
        // The push can name a podcast this device has never subscribed to (another device's
        // subscription). There is nothing to re-anchor against, so it must not fall over.
        XCTAssertTrue(recoverSynchronously(payload(episode: UUID().uuidString, podcast: UUID().uuidString)))
    }

    func testAnEpisodeWeAlreadyHoldIsNotRecovered() throws {
        // The overwhelmingly common case: the ordinary refresh already worked. Recovery must be a
        // no-op so it never re-anchors a podcast that is perfectly up to date.
        let episode = Episode()
        episode.uuid = UUID().uuidString
        episode.podcastUuid = UUID().uuidString
        episode.addedDate = Date()
        episode.publishedDate = Date()
        DataManager.sharedManager.save(episode: episode)
        defer { DataManager.sharedManager.delete(episodeUuid: episode.uuid) }

        XCTAssertNotNil(DataManager.sharedManager.findEpisode(uuid: episode.uuid))
        XCTAssertTrue(recoverSynchronously(payload(episode: episode.uuid, podcast: episode.podcastUuid)))
    }
}
