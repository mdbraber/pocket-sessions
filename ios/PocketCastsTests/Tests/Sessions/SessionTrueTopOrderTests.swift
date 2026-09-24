import PocketCastsDataModel
import XCTest

@testable import podcasts

/// Fork: "true top" moves in a session lineup.
///
/// While a session isn't sounding, its Now Playing card is only "what's next" — so moving a
/// row to the top has to make that episode the session's NEXT episode, not merely the row
/// under the card. That move has two halves: writing the lineup order, and re-priming the
/// player onto the moved episode. Only the order half can be exercised without a live
/// player, so that's what these cover (`UpNextViewController.writeSessionLineupTop`, the
/// single order-writing path both the swipe action and the row-0 drop end up in).
final class SessionTrueTopOrderTests: DBTestCase {

    override func setUp() async throws {
        try await super.setUp()
        clearSessions()
    }

    override func tearDown() async throws {
        clearSessions()
        try await super.tearDown()
    }

    private func clearSessions() {
        for session in SessionStore.shared.sessions {
            SessionStore.shared.delete(sessionUuid: session.uuid)
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func makeEpisode(uuid: String) -> Episode {
        let episode = Episode()
        episode.uuid = uuid
        episode.podcastUuid = podcast.uuid
        episode.podcast_id = podcast.id
        episode.addedDate = Date()
        episode.playingStatus = PlayingStatus.notPlayed.rawValue
        dataManager.save(episode: episode)
        return episode
    }

    /// A session whose store holds `uuids` in exactly that order.
    private func makeSession(order uuids: [String]) throws -> (Session, EpisodeFilter) {
        uuids.forEach { makeEpisode(uuid: $0) }
        let session = SessionManager.shared.createSession(
            name: "True top test",
            feeder: .podcast(uuid: podcast.uuid),
            seedEpisodeUuids: uuids
        )
        let store = try XCTUnwrap(SessionManager.shared.store(for: session))
        SessionManager.shared.setLineupOrder(episodeUuids: uuids, session: session)
        XCTAssertEqual(dataManager.positionedEpisodeUuids(for: store), uuids, "precondition: the lineup starts in seed order")
        return (session, store)
    }

    // MARK: - Tests

    /// The invariant: after a true-top move the moved episode is first in the stored
    /// lineup — ahead of the episode the card was holding, which is what makes it the
    /// session's next episode once the player is re-primed.
    func testTrueTopMoveMakesEpisodeFirstInLineup() throws {
        let (_, store) = try makeSession(order: ["one", "two", "three"])

        // "one" is on the card; "three" is a list row being dragged/swiped to the top.
        UpNextViewController.writeSessionLineupTop(episodeUuid: "three", in: store)

        XCTAssertEqual(dataManager.positionedEpisodeUuids(for: store), ["three", "one", "two"])
    }

    /// The card's own episode moving to the top is a no-op, not a corruption of the order.
    func testTrueTopMoveOfTheFirstEpisodeKeepsOrder() throws {
        let (_, store) = try makeSession(order: ["one", "two", "three"])

        UpNextViewController.writeSessionLineupTop(episodeUuid: "one", in: store)

        XCTAssertEqual(dataManager.positionedEpisodeUuids(for: store), ["one", "two", "three"])
    }

    /// An episode that isn't in the lineup can't reorder it.
    func testTrueTopMoveOfUnknownEpisodeLeavesOrderAlone() throws {
        let (_, store) = try makeSession(order: ["one", "two", "three"])

        UpNextViewController.writeSessionLineupTop(episodeUuid: "not-a-member", in: store)

        XCTAssertEqual(dataManager.positionedEpisodeUuids(for: store), ["one", "two", "three"])
    }
}
