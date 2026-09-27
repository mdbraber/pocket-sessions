import PocketCastsDataModel
import XCTest

@testable import podcasts

/// Fork: every manual playlist IS a session — the playlist itself is the session's store, so
/// there is still one playlist, and it shows up in the Queue page's session list. Unlike other
/// sessions it keeps its played and archived episodes (a whole season stays a whole season).
final class SessionManualPlaylistAdoptTests: DBTestCase {

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

    private func makeManualPlaylist(name: String = "Manual adopt test") -> EpisodeFilter {
        let playlist = PlaylistManager.createNewPlaylist()
        playlist.playlistName = name
        playlist.manual = true
        dataManager.save(playlist: playlist)
        return playlist
    }

    @discardableResult
    private func makeEpisode(played: Bool = false, archived: Bool = false) -> Episode {
        let episode = Episode()
        episode.uuid = UUID().uuidString
        episode.podcastUuid = podcast.uuid
        episode.podcast_id = podcast.id
        episode.addedDate = Date()
        episode.playingStatus = (played ? PlayingStatus.completed : PlayingStatus.notPlayed).rawValue
        episode.archived = archived
        dataManager.save(episode: episode)
        return episode
    }

    func testAdoptsManualPlaylistAsItsOwnStore() throws {
        let playlist = makeManualPlaylist()
        let playlistCount = dataManager.allManualPlaylists(includeDeleted: false).count

        let session = try XCTUnwrap(SessionManager.shared.findOrCreateSession(forManualPlaylist: playlist))

        XCTAssertEqual(session.storePlaylistUuid, playlist.uuid, "the playlist itself is the session's store")
        XCTAssertEqual(session.feeder, SessionFeeder.none)
        XCTAssertEqual(dataManager.allManualPlaylists(includeDeleted: false).count, playlistCount, "no second playlist is created")
        XCTAssertEqual(SessionStore.shared.session(forStore: playlist.uuid)?.uuid, session.uuid)
    }

    func testAdoptingTwiceReturnsTheSameSession() throws {
        let playlist = makeManualPlaylist()

        let first = try XCTUnwrap(SessionManager.shared.findOrCreateSession(forManualPlaylist: playlist))
        let second = try XCTUnwrap(SessionManager.shared.findOrCreateSession(forManualPlaylist: playlist))

        XCTAssertEqual(first.uuid, second.uuid)
        XCTAssertEqual(SessionStore.shared.sessions.filter { $0.storePlaylistUuid == playlist.uuid }.count, 1)
    }

    func testSmartPlaylistIsNotAdoptedAsManualSession() {
        let playlist = PlaylistManager.createNewPlaylist()
        playlist.manual = false
        dataManager.save(playlist: playlist)

        XCTAssertNil(SessionManager.shared.findOrCreateSession(forManualPlaylist: playlist))
    }

    func testAdoptManualPlaylistsGivesEveryManualPlaylistASession() {
        let a = makeManualPlaylist(name: "A")
        let b = makeManualPlaylist(name: "B")

        SessionManager.shared.adoptManualPlaylists()
        SessionManager.shared.adoptManualPlaylists() // idempotent

        for playlist in [a, b] {
            XCTAssertEqual(SessionStore.shared.sessions.filter { $0.storePlaylistUuid == playlist.uuid }.count, 1)
        }
        XCTAssertNil(SessionStore.shared.session(forStore: DataManager.inboxPlaylistUuid), "the Inbox is never adopted")
    }

    /// Devices adopting the same playlist mint the same record, so there is nothing to fork.
    func testAdoptedSessionUuidIsDerivedFromThePlaylist() throws {
        let playlist = makeManualPlaylist()
        let session = try XCTUnwrap(SessionManager.shared.findOrCreateSession(forManualPlaylist: playlist))
        XCTAssertEqual(session.uuid, SessionFeeder.canonicalManualSessionUuid(storePlaylistUuid: playlist.uuid))
    }

    /// Two records over one playlist (e.g. adopted on an older build with a random uuid) merge
    /// into one — and the playlist, shared by both, must survive the merge.
    func testDuplicateRecordsOverOnePlaylistMergeWithoutDeletingIt() throws {
        let playlist = makeManualPlaylist()
        let episode = makeEpisode()
        XCTAssertTrue(dataManager.add(episodes: [episode], to: playlist))
        SessionStore.shared.upsert(Session(uuid: UUID().uuidString, storePlaylistUuid: playlist.uuid, feeder: .none))
        SessionStore.shared.upsert(Session(uuid: SessionFeeder.canonicalManualSessionUuid(storePlaylistUuid: playlist.uuid), storePlaylistUuid: playlist.uuid, feeder: .none))

        SessionManager.shared.dedupeSessionsByIdentity()

        let remaining = SessionStore.shared.sessions.filter { $0.storePlaylistUuid == playlist.uuid }
        XCTAssertEqual(remaining.map(\.uuid), [SessionFeeder.canonicalManualSessionUuid(storePlaylistUuid: playlist.uuid)])
        let stored = try XCTUnwrap(dataManager.findPlaylist(uuid: playlist.uuid))
        XCTAssertFalse(stored.wasDeleted, "the shared playlist must survive the merge")
        XCTAssertEqual(dataManager.positionedEpisodeUuids(for: stored), [episode.uuid])
    }

    func testManualSessionKeepsPlayedEpisodes() throws {
        let playlist = makeManualPlaylist()
        let played = makeEpisode(played: true)
        let unplayed = makeEpisode()
        XCTAssertTrue(dataManager.add(episodes: [played, unplayed], to: playlist))
        _ = try XCTUnwrap(SessionManager.shared.findOrCreateSession(forManualPlaylist: playlist))

        SessionManager.shared.sweepLineups(decidedFilter: nil)

        XCTAssertEqual(Set(dataManager.positionedEpisodeUuids(for: playlist)), [played.uuid, unplayed.uuid])
    }

    /// Kept in the list, but never played: playback skips played AND archived episodes.
    func testPlaybackSkipsPlayedAndArchivedEpisodes() throws {
        let playlist = makeManualPlaylist()
        let played = makeEpisode(played: true)
        let archived = makeEpisode(archived: true)
        let unplayed = makeEpisode()
        XCTAssertTrue(dataManager.add(episodes: [played, archived, unplayed], to: playlist))
        dataManager.setCustomOrder(episodeUuids: [played.uuid, archived.uuid, unplayed.uuid], for: playlist)

        PlaybackSession.episodeSource = EpisodesDataManager()
        defer { PlaybackSession.episodeSource = nil }
        let playback = PlaybackSession(type: .playlist, uuid: playlist.uuid)

        XCTAssertEqual(playback.nextEpisode(after: nil)?.uuid, unplayed.uuid)
        XCTAssertEqual(playback.remainingEpisodes(excluding: nil).map(\.uuid), [unplayed.uuid])
    }
}
