import PocketCastsDataModel
import XCTest

@testable import podcasts

/// Fork: the per-podcast "Episodes per session" limit. In every session, a podcast keeps only
/// its newest N episodes; older ones leave the lineup (they are NOT archived). Hand-added
/// episodes neither count nor leave; the playing episode and started ones count but never leave.
final class SessionPodcastLimitTests: DBTestCase {

    private var limitedPodcastUuids: [String] = []
    /// DBTestCase shares one database across the class, so episode uuids get a per-test prefix.
    private var prefix = ""

    override func setUp() async throws {
        try await super.setUp()
        prefix = UUID().uuidString + "-"
        clearSessions()
    }

    override func tearDown() async throws {
        clearSessions()
        for uuid in limitedPodcastUuids {
            Settings.setSessionEpisodeLimit(0, podcastUuid: uuid)
        }
        limitedPodcastUuids = []
        try await super.tearDown()
    }

    private func clearSessions() {
        for session in SessionStore.shared.sessions {
            SessionStore.shared.delete(sessionUuid: session.uuid)
        }
    }

    // MARK: - Helpers

    private func makePodcast(limit: Int = 0) -> Podcast {
        let podcast = Podcast()
        podcast.uuid = UUID().uuidString
        podcast.subscribed = 1
        podcast.addedDate = Date()
        dataManager.save(podcast: podcast)
        if limit > 0 {
            limitedPodcastUuids.append(podcast.uuid)
            Settings.setSessionEpisodeLimit(limit, podcastUuid: podcast.uuid)
        }
        return podcast
    }

    @discardableResult
    private func makeEpisode(_ uuid: String, podcast: Podcast, daysAgo: Int, inProgress: Bool = false) -> Episode {
        let episode = Episode()
        episode.uuid = prefix + uuid
        episode.podcastUuid = podcast.uuid
        episode.podcast_id = podcast.id
        episode.publishedDate = Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(TimeInterval(-daysAgo * 86_400))
        episode.addedDate = Date()
        episode.playingStatus = (inProgress ? PlayingStatus.inProgress : PlayingStatus.notPlayed).rawValue
        if inProgress { episode.playedUpTo = 60 }
        dataManager.save(episode: episode)
        return episode
    }

    private func makeSession(podcast: Podcast) -> Session {
        SessionManager.shared.createSession(name: "Limit test", feeder: .podcast(uuid: podcast.uuid), seedEpisodeUuids: [])
    }

    private func members(_ session: Session) -> Set<String> {
        Set(SessionFeederEngine.storeMemberUuids(for: session).map { String($0.dropFirst(prefix.count)) })
    }

    private func add(_ names: [String], to session: Session, pinning: Bool = false) {
        SessionManager.shared.addToLineup(episodeUuids: names.map { prefix + $0 }, session: fresh(session), pinning: pinning)
    }

    private func fresh(_ session: Session) -> Session {
        SessionStore.shared.session(uuid: session.uuid) ?? session
    }

    // MARK: - Tests

    func testAddingPastTheLimitKeepsOnlyTheNewestEpisodes() {
        let podcast = makePodcast(limit: 2)
        makeEpisode("old", podcast: podcast, daysAgo: 3)
        makeEpisode("mid", podcast: podcast, daysAgo: 2)
        makeEpisode("new", podcast: podcast, daysAgo: 1)
        let session = makeSession(podcast: podcast)

        add(["old", "mid"], to: session)
        add(["new"], to: session)

        XCTAssertEqual(members(session), ["mid", "new"])
    }

    func testAnOlderArrivalDropsStraightBackOut() {
        let podcast = makePodcast(limit: 2)
        makeEpisode("ancient", podcast: podcast, daysAgo: 9)
        makeEpisode("mid", podcast: podcast, daysAgo: 2)
        makeEpisode("new", podcast: podcast, daysAgo: 1)
        let session = makeSession(podcast: podcast)

        add(["mid", "new"], to: session)
        add(["ancient"], to: session)

        XCTAssertEqual(members(session), ["mid", "new"])
    }

    func testTrimmedEpisodesAreNotArchived() {
        let podcast = makePodcast(limit: 1)
        makeEpisode("old", podcast: podcast, daysAgo: 2)
        makeEpisode("new", podcast: podcast, daysAgo: 1)
        let session = makeSession(podcast: podcast)

        add(["old", "new"], to: session)

        XCTAssertEqual(members(session), ["new"])
        XCTAssertEqual(dataManager.findEpisode(uuid: prefix + "old")?.archived, false)
    }

    func testPodcastsWithoutALimitAreUntouched() {
        let limited = makePodcast(limit: 1)
        let unlimited = makePodcast()
        makeEpisode("limitedOld", podcast: limited, daysAgo: 2)
        makeEpisode("limitedNew", podcast: limited, daysAgo: 1)
        makeEpisode("free1", podcast: unlimited, daysAgo: 3)
        makeEpisode("free2", podcast: unlimited, daysAgo: 4)
        let session = SessionManager.shared.createSession(name: "Mixed", feeder: .none, seedEpisodeUuids: [])

        add(["limitedOld", "limitedNew", "free1", "free2"], to: session)

        XCTAssertEqual(members(session), ["limitedNew", "free1", "free2"])
    }

    func testHandAddedEpisodesNeitherCountNorLeave() {
        let podcast = makePodcast(limit: 1)
        makeEpisode("pinnedOld", podcast: podcast, daysAgo: 5)
        makeEpisode("autoOld", podcast: podcast, daysAgo: 2)
        makeEpisode("autoNew", podcast: podcast, daysAgo: 1)
        let session = makeSession(podcast: podcast)

        add(["pinnedOld"], to: session, pinning: true)
        add(["autoOld", "autoNew"], to: session)

        XCTAssertEqual(members(session), ["pinnedOld", "autoNew"])
    }

    func testStartedEpisodesStayAndTakeASlot() {
        let podcast = makePodcast(limit: 2)
        makeEpisode("started", podcast: podcast, daysAgo: 5, inProgress: true)
        makeEpisode("mid", podcast: podcast, daysAgo: 2)
        makeEpisode("new", podcast: podcast, daysAgo: 1)
        let session = makeSession(podcast: podcast)

        add(["started", "mid", "new"], to: session)

        XCTAssertEqual(members(session), ["started", "new"])
    }

    func testTheLimitAppliesInEverySession() {
        let podcast = makePodcast(limit: 1)
        makeEpisode("old", podcast: podcast, daysAgo: 2)
        makeEpisode("new", podcast: podcast, daysAgo: 1)
        let own = makeSession(podcast: podcast)
        let other = SessionManager.shared.createSession(name: "Other", feeder: .none, seedEpisodeUuids: [])

        add(["old", "new"], to: own)
        add(["old", "new"], to: other)

        XCTAssertEqual(members(own), ["new"])
        XCTAssertEqual(members(other), ["new"])
    }

    func testLoweringTheLimitTrimsExistingSessions() {
        let podcast = makePodcast()
        makeEpisode("old", podcast: podcast, daysAgo: 3)
        makeEpisode("mid", podcast: podcast, daysAgo: 2)
        makeEpisode("new", podcast: podcast, daysAgo: 1)
        let session = makeSession(podcast: podcast)
        add(["old", "mid", "new"], to: session)
        XCTAssertEqual(members(session).count, 3, "precondition: no limit yet")

        limitedPodcastUuids.append(podcast.uuid)
        Settings.setSessionEpisodeLimit(1, podcastUuid: podcast.uuid)
        SessionManager.shared.enforceEpisodeLimit(podcastUuid: podcast.uuid)

        XCTAssertEqual(members(session), ["new"])
    }
}
