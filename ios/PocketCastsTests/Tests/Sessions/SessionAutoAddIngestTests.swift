import PocketCastsDataModel
import XCTest

@testable import podcasts

/// Fork: the session-playback ballooning regression.
///
/// A session plays its store (a manual playlist), and playback advances by repeatedly asking
/// the session for its ordered episodes. That read MUST be pure. An earlier bug had it pull
/// pending auto-add offers into the store on *every* advance, so a session grew without bound
/// while you listened to it — you'd start a 3-episode session and find 40 items a few episodes
/// later. Auto-add must happen exactly once, when the session starts, and never as a side
/// effect of reading.
final class SessionAutoAddIngestTests: DBTestCase {

    override func setUp() async throws {
        try await super.setUp()
        // DBTestCase reuses one database and the shared singletons across the class, so start
        // from an empty Inbox and no sessions.
        dataManager.deleteAllEpisodes(in: InboxManager.shared.inboxPlaylist())
        clearSessions()
        PlaybackSession.episodeSource = EpisodesDataManager()
    }

    override func tearDown() async throws {
        clearSessions()
        PlaybackSession.episodeSource = nil
        try await super.tearDown()
    }

    private func clearSessions() {
        for session in SessionStore.shared.sessions {
            SessionStore.shared.delete(sessionUuid: session.uuid)
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func makePodcast() -> Podcast {
        let podcast = Podcast()
        podcast.uuid = UUID().uuidString
        podcast.subscribed = 1
        podcast.addedDate = Date()
        dataManager.save(podcast: podcast)
        return podcast
    }

    @discardableResult
    private func makeEpisode(uuid: String = UUID().uuidString, podcast: Podcast, publishedDate: Date) -> Episode {
        let episode = Episode()
        episode.uuid = uuid
        episode.podcastUuid = podcast.uuid
        episode.podcast_id = podcast.id
        episode.publishedDate = publishedDate
        episode.addedDate = Date()
        episode.playingStatus = PlayingStatus.notPlayed.rawValue
        dataManager.save(episode: episode)
        return episode
    }

    private func date(_ daysAgo: Int) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(TimeInterval(-daysAgo * 86_400))
    }

    /// An auto-add session whose store holds `seed`, with `offer` sitting pending in the Inbox
    /// and eligible for the session's feeder.
    private func makeAutoAddSession(podcast: Podcast, seed: Episode, offer: Episode) -> Session {
        var session = SessionManager.shared.createSession(
            name: "Ballooning test",
            feeder: .podcast(uuid: podcast.uuid),
            seedEpisodeUuids: [seed.uuid]
        )
        session.autoAdd = true
        SessionStore.shared.upsert(session)

        // Make `offer` a genuine pending auto-add: in the feeder's domain AND unseen.
        InboxManager.shared.markUnseen(episodeUuids: [offer.uuid])
        return session
    }

    private func storeUuids(_ session: Session) -> [String] {
        guard let store = SessionManager.shared.store(for: session) else { return [] }
        return DataManager.sharedManager.positionedEpisodeUuids(for: store)
    }

    // MARK: - Tests

    /// The regression itself: advancing through a session (many reads) must not ingest the
    /// pending offer. Before the fix, each `orderedEpisodes` call ballooned the store.
    func testAdvancingThroughASessionDoesNotIngestPendingOffers() {
        let podcast = makePodcast()
        let seed = makeEpisode(uuid: "seed", podcast: podcast, publishedDate: date(2))
        let offer = makeEpisode(uuid: "offer", podcast: podcast, publishedDate: date(1))
        let session = makeAutoAddSession(podcast: podcast, seed: seed, offer: offer)

        XCTAssertTrue(
            SessionFeederEngine.inboxEpisodes(for: session).contains { $0.uuid == "offer" },
            "precondition: the offer must be a pending auto-add for this session"
        )
        XCTAssertEqual(storeUuids(session), ["seed"], "precondition: store starts with only the seed")

        let playback = PlaybackSession(type: .playlist, uuid: session.storePlaylistUuid!)
        // Simulate the playback loop reading the session repeatedly as it advances.
        for _ in 0 ..< 5 {
            _ = playback.orderedEpisodes()
            _ = playback.nextEpisode(after: "seed")
        }

        XCTAssertEqual(storeUuids(session), ["seed"], "reading the session must not ingest the pending offer")
    }

    /// Auto-add still works — but only when explicitly triggered (session start / refresh),
    /// not as a side effect of reading.
    func testIngestAutoAddPullsThePendingOfferWhenTriggered() {
        let podcast = makePodcast()
        let seed = makeEpisode(uuid: "seed", podcast: podcast, publishedDate: date(2))
        let offer = makeEpisode(uuid: "offer", podcast: podcast, publishedDate: date(1))
        let session = makeAutoAddSession(podcast: podcast, seed: seed, offer: offer)

        SessionManager.shared.ingestAutoAdd(session: session)

        XCTAssertTrue(
            storeUuids(session).contains("offer"),
            "an explicit ingest must pull the pending offer into the store"
        )
    }

    /// A manual add during playback IS reflected on the next read — the store is the source of
    /// truth and reads are live, so a newly added episode plays without restarting the session.
    func testManualAddDuringPlaybackIsReflectedOnNextRead() {
        let podcast = makePodcast()
        let seed = makeEpisode(uuid: "seed", podcast: podcast, publishedDate: date(2))
        let offer = makeEpisode(uuid: "offer", podcast: podcast, publishedDate: date(1))
        let session = makeAutoAddSession(podcast: podcast, seed: seed, offer: offer)

        let playback = PlaybackSession(type: .playlist, uuid: session.storePlaylistUuid!)
        XCTAssertEqual(playback.orderedEpisodes().map(\.uuid), ["seed"], "precondition: session reads as just the seed")

        // Manual add mid-playback.
        makeEpisode(uuid: "extra", podcast: podcast, publishedDate: date(3))
        SessionManager.shared.addToLineup(episodeUuids: ["extra"], session: session)

        let after = Set(playback.orderedEpisodes().map(\.uuid))
        XCTAssertTrue(after.contains("extra"), "a manual add during playback must be visible on the next read")
    }
}
