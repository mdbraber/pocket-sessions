import PocketCastsDataModel
import XCTest

@testable import podcasts

/// Fork: adding to a session — automatic or your own — leaves the episode in the Inbox (showing
/// the session marker and its unread dot), so it stays there until you mark it seen. Only a
/// podcast set to "When not in Session or Up Next" takes it out.
final class SessionAutoAddInboxTests: DBTestCase {

    private var conditionalPodcastUuids: [String] = []
    private var savedMirrorUpNextToSession = false

    override func setUp() async throws {
        try await super.setUp()
        dataManager.deleteAllEpisodes(in: InboxManager.shared.inboxPlaylist())
        clearSessions()
        savedMirrorUpNextToSession = Settings.mirrorUpNextToSession
    }

    override func tearDown() async throws {
        clearSessions()
        for uuid in conditionalPodcastUuids {
            SessionFeederEngine.setInboxAddPolicy(.always, forPodcast: uuid)
        }
        conditionalPodcastUuids = []
        Settings.mirrorUpNextToSession = savedMirrorUpNextToSession
        try await super.tearDown()
    }

    private func clearSessions() {
        for session in SessionStore.shared.sessions {
            SessionStore.shared.delete(sessionUuid: session.uuid)
        }
    }

    // MARK: - Helpers

    private func makePodcast() -> Podcast {
        let podcast = Podcast()
        podcast.uuid = UUID().uuidString
        podcast.subscribed = 1
        podcast.addedDate = Date()
        dataManager.save(podcast: podcast)
        return podcast
    }

    private func makeEpisode(podcast: Podcast) -> Episode {
        let episode = Episode()
        episode.uuid = UUID().uuidString
        episode.podcastUuid = podcast.uuid
        episode.podcast_id = podcast.id
        episode.publishedDate = Date()
        episode.addedDate = Date()
        episode.playingStatus = PlayingStatus.notPlayed.rawValue
        dataManager.save(episode: episode)
        return episode
    }

    /// An auto-add session for `podcast`, with `episode` new in the Inbox.
    private func makeAutoAddSession(podcast: Podcast, newEpisode episode: Episode) -> Session {
        var session = SessionManager.shared.createSession(name: "Inbox test", feeder: .podcast(uuid: podcast.uuid))
        session.autoAdd = true
        SessionStore.shared.upsert(session)
        InboxManager.shared.markUnseen(episodeUuids: [episode.uuid])
        return session
    }

    private func members(_ session: Session) -> [String] {
        SessionFeederEngine.storeMemberUuids(for: session)
    }

    private func inInbox(_ episode: Episode) -> Bool {
        InboxManager.shared.isUnseen(episodeUuid: episode.uuid)
    }

    // MARK: - Tests

    func testAutoAddKeepsTheEpisodeInTheInbox() {
        let podcast = makePodcast()
        let episode = makeEpisode(podcast: podcast)
        let session = makeAutoAddSession(podcast: podcast, newEpisode: episode)

        SessionManager.shared.ingestAutoAdd(session: session)

        XCTAssertEqual(members(session), [episode.uuid])
        XCTAssertTrue(inInbox(episode), "an auto-added episode must stay in the Inbox")
    }

    func testAnEpisodeRemovedFromTheSessionIsNotAutoAddedAgain() {
        let podcast = makePodcast()
        let episode = makeEpisode(podcast: podcast)
        let session = makeAutoAddSession(podcast: podcast, newEpisode: episode)
        SessionManager.shared.ingestAutoAdd(session: session)

        SessionManager.shared.removeFromLineup(episodeUuids: [episode.uuid], session: session)
        SessionManager.shared.ingestAutoAdd(session: session)

        XCTAssertEqual(members(session), [], "a removal must stick while the episode is still in the Inbox")
    }

    func testAddingItYourselfKeepsItInTheInbox() {
        let podcast = makePodcast()
        let episode = makeEpisode(podcast: podcast)
        let session = makeAutoAddSession(podcast: podcast, newEpisode: episode)

        SessionManager.shared.addToLineup(episodeUuids: [episode.uuid], session: session, pinning: true)

        XCTAssertEqual(members(session), [episode.uuid])
        XCTAssertTrue(inInbox(episode), "adding to a session doesn't mark the episode seen")
    }

    func testWhenNotInSessionPolicyTakesYourOwnAddsOutOfTheInbox() {
        let podcast = makePodcast()
        conditionalPodcastUuids.append(podcast.uuid)
        SessionFeederEngine.setInboxAddPolicy(.whenNotInSessionOrUpNext, forPodcast: podcast.uuid)
        let episode = makeEpisode(podcast: podcast)
        let session = makeAutoAddSession(podcast: podcast, newEpisode: episode)

        SessionManager.shared.addToLineup(episodeUuids: [episode.uuid], session: session, pinning: true)

        XCTAssertFalse(inInbox(episode))
    }

    func testRemovingFromEverySessionKeepsItInTheInbox() {
        let podcast = makePodcast()
        let episode = makeEpisode(podcast: podcast)
        let own = makeAutoAddSession(podcast: podcast, newEpisode: episode)
        let other = SessionManager.shared.createSession(name: "Other", feeder: .none, seedEpisodeUuids: [])
        SessionManager.shared.addToLineup(episodeUuids: [episode.uuid], session: own, pinning: true)
        SessionManager.shared.addToLineup(episodeUuids: [episode.uuid], session: other, pinning: true)

        SessionManager.shared.removeFromAllSessions(episodeUuids: [episode.uuid])

        XCTAssertEqual(members(own), [])
        XCTAssertEqual(members(other), [])
        XCTAssertFalse(SessionMembership.shared.inAnySession.contains(episode.uuid))
        XCTAssertTrue(inInbox(episode), "removing from sessions must not take it out of the Inbox")
    }

    func testWhenNotInSessionPolicyStillTakesAutoAddsOutOfTheInbox() {
        let podcast = makePodcast()
        conditionalPodcastUuids.append(podcast.uuid)
        SessionFeederEngine.setInboxAddPolicy(.whenNotInSessionOrUpNext, forPodcast: podcast.uuid)
        let episode = makeEpisode(podcast: podcast)
        let session = makeAutoAddSession(podcast: podcast, newEpisode: episode)

        SessionManager.shared.ingestAutoAdd(session: session)

        XCTAssertEqual(members(session), [episode.uuid])
        XCTAssertFalse(inInbox(episode), "\"When not in Session or Up Next\" asks for it to leave the Inbox")
    }

    func testTheAutomaticUpNextCopyKeepsTheEpisodeInTheInbox() {
        Settings.mirrorUpNextToSession = true
        let podcast = makePodcast()
        let episode = makeEpisode(podcast: podcast)
        InboxManager.shared.markUnseen(episodeUuids: [episode.uuid])

        SessionLinking.mirrorQueueAdd(episodes: [episode], automatic: true)

        let session = SessionStore.shared.session(forPodcast: podcast.uuid)
        XCTAssertEqual(session.map(members), [episode.uuid])
        XCTAssertTrue(inInbox(episode))
    }
}
