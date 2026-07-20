import PocketCastsDataModel
import XCTest

@testable import podcasts

/// Fork: pin bookkeeping for the upstream "Add to Playlist" flows.
///
/// The playlist chooser and the playlist detail "Add Episodes" search add to manual
/// playlists directly through DataManager, bypassing `SessionManager.addToLineup`. When the
/// target playlist is a session's store, that hand-add is still an explicit USER add and
/// must pin — otherwise a smart feeder's prune (`reconcileStoreToFeeder`) sweeps the
/// episode back out. These tests cover the bookkeeping hook those flows call
/// (`pinDirectAdd` / `unpinDirectRemove`).
final class SessionDirectAddPinTests: DBTestCase {

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
    private func makeEpisode(uuid: String = UUID().uuidString) -> Episode {
        let episode = Episode()
        episode.uuid = uuid
        episode.podcastUuid = podcast.uuid
        episode.podcast_id = podcast.id
        episode.addedDate = Date()
        episode.playingStatus = PlayingStatus.notPlayed.rawValue
        dataManager.save(episode: episode)
        return episode
    }

    /// A session with a real store playlist, holding `seed` — created the same way the app does.
    private func makeSession(seed: Episode) -> Session {
        SessionManager.shared.createSession(
            name: "Direct add pin test",
            feeder: .podcast(uuid: podcast.uuid),
            seedEpisodeUuids: [seed.uuid]
        )
    }

    // MARK: - Tests

    /// The invariant: a direct DataManager add into a session's store, followed by the
    /// bookkeeping hook, leaves the episode pinned in that session.
    func testDirectAddIntoSessionStorePins() throws {
        let seed = makeEpisode()
        let session = makeSession(seed: seed)
        let store = try XCTUnwrap(SessionManager.shared.store(for: session))

        // Simulate the chooser: stock add + dirty/save, then the hook.
        let added = makeEpisode(uuid: "hand-added")
        XCTAssertTrue(dataManager.add(episodes: [added], to: store))
        SessionManager.shared.pinDirectAdd(episodeUuids: [added.uuid], storePlaylistUuid: store.uuid)

        let reloaded = try XCTUnwrap(SessionStore.shared.session(uuid: session.uuid))
        XCTAssertTrue(reloaded.pinnedEpisodeUuids.contains(added.uuid), "a hand-add into a session's store must pin")
        XCTAssertFalse(reloaded.pinnedEpisodeUuids.contains(seed.uuid), "seeding is not a direct add — it must stay unpinned")
    }

    /// A playlist that backs no session is untouched — the hook must be a no-op.
    func testDirectAddIntoPlainPlaylistDoesNotPin() throws {
        let seed = makeEpisode()
        let session = makeSession(seed: seed)

        SessionManager.shared.pinDirectAdd(episodeUuids: [makeEpisode().uuid], storePlaylistUuid: "not-a-session-store")

        let reloaded = try XCTUnwrap(SessionStore.shared.session(uuid: session.uuid))
        XCTAssertTrue(reloaded.pinnedEpisodeUuids.isEmpty, "adds to non-session playlists must never pin")
    }

    /// The Inbox guard: even if a session claimed the Inbox playlist as its store, the
    /// hook must refuse to pin against the Inbox uuid.
    func testInboxAddNeverPins() throws {
        var session = makeSession(seed: makeEpisode())
        session.storePlaylistUuid = DataManager.inboxPlaylistUuid
        SessionStore.shared.upsert(session)

        SessionManager.shared.pinDirectAdd(episodeUuids: [makeEpisode().uuid], storePlaylistUuid: DataManager.inboxPlaylistUuid)

        let reloaded = try XCTUnwrap(SessionStore.shared.session(uuid: session.uuid))
        XCTAssertTrue(reloaded.pinnedEpisodeUuids.isEmpty, "Inbox adds must never pin")
    }

    /// The symmetric half: a direct removal (chooser uncheck) drops the pin, so pins never
    /// outlive membership.
    func testDirectRemoveUnpins() throws {
        let seed = makeEpisode()
        let session = makeSession(seed: seed)
        let store = try XCTUnwrap(SessionManager.shared.store(for: session))

        let added = makeEpisode(uuid: "hand-added-then-removed")
        XCTAssertTrue(dataManager.add(episodes: [added], to: store))
        SessionManager.shared.pinDirectAdd(episodeUuids: [added.uuid], storePlaylistUuid: store.uuid)

        dataManager.deleteEpisodes([added.uuid], from: store)
        SessionManager.shared.unpinDirectRemove(episodeUuids: [added.uuid], storePlaylistUuid: store.uuid)

        let reloaded = try XCTUnwrap(SessionStore.shared.session(uuid: session.uuid))
        XCTAssertFalse(reloaded.pinnedEpisodeUuids.contains(added.uuid), "pins must never outlive membership")
    }
}
