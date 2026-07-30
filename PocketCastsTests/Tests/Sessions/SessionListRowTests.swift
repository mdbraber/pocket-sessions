import PocketCastsDataModel
import PocketCastsUtils
import XCTest

@testable import podcasts

/// Fork: the session CHOOSER's rows.
///
/// The chooser advertises each session by the episode it would play next, so the row MUST
/// agree with playback: first unfinished episode in lineup order, except that the active
/// session resumes at its last-played episode. These tests pin that resolution, the
/// duration/progress shapes, the empty case, and the ordering rule.
final class SessionListRowTests: DBTestCase {

    override func setUp() async throws {
        try await super.setUp()
        clearSessions()
        clearPlaybackSession()
        resetChooserPreferences()
        PlaybackSession.episodeSource = EpisodesDataManager()
    }

    override func tearDown() async throws {
        clearSessions()
        clearPlaybackSession()
        resetChooserPreferences()
        PlaybackSession.episodeSource = nil
        try await super.tearDown()
    }

    /// `current()` reads the persisted chooser preferences by default, so every test starts
    /// from the shipped defaults rather than whatever a previous test left behind.
    private func resetChooserPreferences() {
        for key in [Settings.sessionListSortKey,
                    Settings.sessionListHideEmptyKey,
                    Settings.sessionListHideUnplayedKey,
                    Settings.sessionListShowPodcastsKey,
                    Settings.sessionListShowPlaylistsKey,
                    Settings.sessionListShowFoldersKey,
                    // The chooser's ⋯ toggles. `hideEmptySessions` is a SECOND hide-empty setting,
                    // read by `SessionListRows.current` directly rather than through
                    // `SessionListFilters` — leaving it set (as using the app does) filtered empty
                    // sessions out of every test, including the ones passing `.unfiltered`.
                    Settings.hideEmptySessionsKey,
                    Settings.hideEmptyUpNextKey,
                    Settings.hidePodcastSessionsInSmartPlaylistKey,
                    // Per-playlist "not a session playlist" opt-outs also hide rows.
                    Settings.playlistsOptedOutOfSessionKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func clearSessions() {
        for session in SessionStore.shared.sessions {
            SessionManager.shared.deleteSession(session)
        }
    }

    private func clearPlaybackSession() {
        Settings.setPlaybackSession(nil)
        Settings.setPlaybackSessionPaused(false)
        Settings.setPlaybackSessionLastEpisodeUuid(nil)
    }

    // MARK: - Helpers

    @discardableResult
    private func makePodcast() -> Podcast {
        let podcast = Podcast()
        podcast.uuid = UUID().uuidString
        podcast.title = "Test Podcast"
        podcast.subscribed = 1
        podcast.addedDate = Date()
        dataManager.save(podcast: podcast)
        return podcast
    }

    @discardableResult
    private func makeEpisode(title: String, podcast: Podcast, duration: Double = 3600, playedUpTo: Double = 0, played: Bool = false, publishedDate: Date = Date()) -> Episode {
        let episode = Episode()
        episode.uuid = UUID().uuidString
        episode.title = title
        episode.podcastUuid = podcast.uuid
        episode.podcast_id = podcast.id
        episode.addedDate = Date()
        episode.publishedDate = publishedDate
        episode.duration = duration
        episode.playedUpTo = playedUpTo
        episode.playingStatus = (played ? PlayingStatus.completed : .notPlayed).rawValue
        dataManager.save(episode: episode)
        return episode
    }

    /// Each session needs its OWN feeder identity. `createSession` mints one canonical uuid per
    /// identity-bearing feeder, so two sessions fed by the SAME podcast are literally the same
    /// session — every test asking for several sessions off one podcast silently got one back.
    /// The episodes still come from whatever podcast the caller passed; only the feeder is distinct.
    @discardableResult
    private func makeSession(name: String, podcast: Podcast, episodes: [Episode]) -> Session {
        SessionManager.shared.createSession(
            name: name,
            feeder: .podcast(uuid: makePodcast().uuid),
            seedEpisodeUuids: episodes.map(\.uuid)
        )
    }

    /// A session with an arbitrary feeder — the type filters key off nothing else.
    @discardableResult
    private func makeSession(name: String, feeder: SessionFeeder, episodes: [Episode] = []) -> Session {
        SessionManager.shared.createSession(name: name, feeder: feeder, seedEpisodeUuids: episodes.map(\.uuid))
    }

    /// The lineup exactly as playback reads it — the tests assert relative to this rather
    /// than assuming how seeding orders a store.
    private func lineup(_ session: Session) -> [BaseEpisode] {
        PlaybackSession(type: .playlist, uuid: session.storePlaylistUuid!).orderedEpisodes()
    }

    private func row(for session: Session, in rows: [SessionListRow]) throws -> SessionListRow {
        try XCTUnwrap(rows.first { $0.sessionUuid == session.uuid })
    }

    private func markPlayed(_ episode: BaseEpisode) {
        guard let episode = dataManager.findEpisode(uuid: episode.uuid) else { return }
        episode.playingStatus = PlayingStatus.completed.rawValue
        dataManager.save(episode: episode)
    }

    private func activate(_ session: Session, paused: Bool = false, lastEpisodeUuid: String? = nil) {
        Settings.setPlaybackSession(PlaybackSession(type: .playlist, uuid: session.storePlaylistUuid!))
        Settings.setPlaybackSessionPaused(paused)
        Settings.setPlaybackSessionLastEpisodeUuid(lastEpisodeUuid)
    }

    // MARK: - Next episode resolution

    /// With nothing played, the row advertises the head of the lineup.
    func testNextEpisodeIsFirstUnfinished() throws {
        let podcast = makePodcast()
        let session = makeSession(name: "Next", podcast: podcast, episodes: [
            makeEpisode(title: "One", podcast: podcast),
            makeEpisode(title: "Two", podcast: podcast)
        ])

        let order = lineup(session)
        XCTAssertEqual(order.count, 2, "precondition: both seeds are in the lineup")

        let row = try row(for: session, in: SessionListRows.current())
        XCTAssertEqual(row.nextEpisodeTitle, order[0].displayableTitle())
        XCTAssertEqual(row.nextEpisodePodcast, "Test Podcast")
        XCTAssertEqual(row.episodeCount, 2)
    }

    /// Played episodes are skipped — they've left the session.
    func testNextEpisodeSkipsPlayed() throws {
        let podcast = makePodcast()
        let session = makeSession(name: "Skips played", podcast: podcast, episodes: [
            makeEpisode(title: "One", podcast: podcast),
            makeEpisode(title: "Two", podcast: podcast)
        ])

        let order = lineup(session)
        markPlayed(order[0])

        let row = try row(for: session, in: SessionListRows.current())
        XCTAssertEqual(row.nextEpisodeTitle, order[1].displayableTitle())
        XCTAssertEqual(row.episodeCount, 1, "a finished episode no longer counts towards the lineup")
    }

    /// The ACTIVE session resumes where it left off, even when that episode sits later in
    /// the lineup — the same rule the paused-session resume row uses.
    func testActiveSessionHonoursResumePointer() throws {
        let podcast = makePodcast()
        let session = makeSession(name: "Resume", podcast: podcast, episodes: [
            makeEpisode(title: "One", podcast: podcast),
            makeEpisode(title: "Two", podcast: podcast)
        ])

        let order = lineup(session)
        activate(session, paused: true, lastEpisodeUuid: order[1].uuid)

        let row = try row(for: session, in: SessionListRows.current())
        XCTAssertEqual(row.nextEpisodeTitle, order[1].displayableTitle(), "the resume pointer wins for the active session")
        XCTAssertFalse(row.isPlaying, "a paused session doesn't own playback")
    }

    /// A stale pointer (finished, or no longer in the lineup) falls back to the head.
    func testResumePointerIgnoredWhenEpisodeIsFinished() throws {
        let podcast = makePodcast()
        let session = makeSession(name: "Stale resume", podcast: podcast, episodes: [
            makeEpisode(title: "One", podcast: podcast),
            makeEpisode(title: "Two", podcast: podcast)
        ])

        let order = lineup(session)
        markPlayed(order[1])
        activate(session, lastEpisodeUuid: order[1].uuid)

        let row = try row(for: session, in: SessionListRows.current())
        XCTAssertEqual(row.nextEpisodeTitle, order[0].displayableTitle())
        XCTAssertTrue(row.isActive, "active and not paused means this session owns the pointer")
        XCTAssertFalse(row.isPlaying, "no audio is sounding in a unit test, so nothing claims to be playing")
    }

    /// Another session's resume pointer never leaks into a row that isn't active.
    func testResumePointerOnlyAppliesToTheActiveSession() throws {
        let podcast = makePodcast()
        let active = makeSession(name: "Active", podcast: podcast, episodes: [makeEpisode(title: "Active head", podcast: podcast)])
        let idle = makeSession(name: "Idle", podcast: podcast, episodes: [
            makeEpisode(title: "Idle one", podcast: podcast),
            makeEpisode(title: "Idle two", podcast: podcast)
        ])

        let idleOrder = lineup(idle)
        activate(active, lastEpisodeUuid: idleOrder[1].uuid)

        let row = try row(for: idle, in: SessionListRows.current())
        XCTAssertEqual(row.nextEpisodeTitle, idleOrder[0].displayableTitle())
    }

    // MARK: - Duration / progress

    func testUntouchedEpisodeShowsPlainDurationAndNoProgress() throws {
        let podcast = makePodcast()
        let session = makeSession(name: "Untouched", podcast: podcast, episodes: [
            makeEpisode(title: "One", podcast: podcast, duration: 3480)
        ])

        let row = try row(for: session, in: SessionListRows.current())
        XCTAssertEqual(row.nextEpisodeDuration, TimeFormatter.shared.multipleUnitFormattedShortTime(time: 3480))
        XCTAssertEqual(row.progress, 0)
        XCTAssertEqual(row.timeLeft, TimeFormatter.shared.multipleUnitFormattedShortTime(time: 3480))
    }

    func testPartPlayedEpisodeShowsTimeLeftAndProgress() throws {
        let podcast = makePodcast()
        let session = makeSession(name: "Part played", podcast: podcast, episodes: [
            makeEpisode(title: "One", podcast: podcast, duration: 3600, playedUpTo: 900)
        ])

        let row = try row(for: session, in: SessionListRows.current())
        XCTAssertEqual(row.nextEpisodeDuration, L10n.queueUpNextHeaderTimeLeft(TimeFormatter.shared.multipleUnitFormattedShortTime(time: 2700)))
        XCTAssertEqual(row.progress, 0.25, accuracy: 0.0001)
        XCTAssertEqual(row.timeLeft, TimeFormatter.shared.multipleUnitFormattedShortTime(time: 2700),
                       "the lineup total counts what's left, not the full duration")
    }

    // MARK: - Empty sessions

    func testEmptySessionHasNoEpisodeFields() throws {
        let podcast = makePodcast()
        let session = makeSession(name: "Empty", podcast: podcast, episodes: [])

        let row = try row(for: session, in: SessionListRows.current())
        XCTAssertNil(row.nextEpisodeTitle)
        XCTAssertNil(row.nextEpisodePodcast)
        XCTAssertNil(row.nextEpisodeDuration)
        XCTAssertNil(row.timeLeft)
        XCTAssertEqual(row.episodeCount, 0)
        XCTAssertEqual(row.progress, 0)
        XCTAssertEqual(row.name, "Empty", "empty sessions are still listed")
    }

    /// A lineup whose every episode is finished reads as empty — those episodes have left.
    func testFullyPlayedSessionReadsAsEmpty() throws {
        let podcast = makePodcast()
        let session = makeSession(name: "Done", podcast: podcast, episodes: [makeEpisode(title: "One", podcast: podcast)])
        lineup(session).forEach { markPlayed($0) }

        let row = try row(for: session, in: SessionListRows.current())
        XCTAssertNil(row.nextEpisodeTitle)
        XCTAssertEqual(row.episodeCount, 0)
    }

    // MARK: - Ordering

    /// Playing first, then most recently used, then never-played (newest created first).
    func testOrdering() throws {
        let podcast = makePodcast()
        let older = makeSession(name: "Older", podcast: podcast, episodes: [makeEpisode(title: "A", podcast: podcast)])
        let recent = makeSession(name: "Recent", podcast: podcast, episodes: [makeEpisode(title: "B", podcast: podcast)])
        let neverOne = makeSession(name: "Never one", podcast: podcast, episodes: [makeEpisode(title: "C", podcast: podcast)])
        let neverTwo = makeSession(name: "Never two", podcast: podcast, episodes: [makeEpisode(title: "D", podcast: podcast)])

        var olderUsed = older
        olderUsed.lastUsed = Date(timeIntervalSince1970: 1_000_000)
        SessionStore.shared.upsert(olderUsed)
        var recentUsed = recent
        recentUsed.lastUsed = Date(timeIntervalSince1970: 2_000_000)
        SessionStore.shared.upsert(recentUsed)

        // No session playing: recency, then never-played newest-first. (Explicit `.recentlyPlayed`:
        // the list's DEFAULT sort is now `.manual`, so this pins the recency ordering it means to test.)
        XCTAssertEqual(SessionListRows.current(sort: .recentlyPlayed).map(\.name), ["Recent", "Older", "Never two", "Never one"])

        // Merely opening a session (active, no audio) must NOT reshuffle the list — `current()` no
        // longer hoists the active session (it's surfaced by the Queue's own row-1 extraction instead).
        activate(older)
        XCTAssertEqual(SessionListRows.current(sort: .recentlyPlayed).map(\.name), ["Recent", "Older", "Never two", "Never one"])

        // Paused likewise leaves the order alone.
        activate(older, paused: true)
        XCTAssertEqual(SessionListRows.current(sort: .recentlyPlayed).map(\.name), ["Recent", "Older", "Never two", "Never one"])

        XCTAssertNotNil(neverOne.storePlaylistUuid)
        XCTAssertNotNil(neverTwo.storePlaylistUuid)
    }

    /// "Last Played" means the SESSION was played — `Session.lastUsed`, stamped when audio starts
    /// for it. It must NOT rank on the next episode's progress: one episode can belong to many
    /// sessions, so doing that floated every session merely CONTAINING a part-played episode above
    /// the session you were actually listening to.
    func testRecencyRanksOnSessionHistoryNotEpisodeProgress() throws {
        let podcast = makePodcast()

        // Genuinely played, but a while ago, and its next episode is untouched.
        let played = makeSession(name: "Played", podcast: podcast, episodes: [makeEpisode(title: "A", podcast: podcast)])
        var playedUsed = played
        playedUsed.lastUsed = Date(timeIntervalSince1970: 1_000_000)
        SessionStore.shared.upsert(playedUsed)

        // Never played as a session — it just happens to contain a part-played episode.
        makeSession(name: "Contains progress", podcast: podcast, episodes: [
            makeEpisode(title: "B", podcast: podcast, playedUpTo: 600)
        ])

        // Never played and nothing started.
        makeSession(name: "Untouched", podcast: podcast, episodes: [makeEpisode(title: "C", podcast: podcast)])

        XCTAssertEqual(SessionListRows.current(sort: .recentlyPlayed).map(\.name),
                       ["Played", "Contains progress", "Untouched"])
    }

    /// With no timestamp on either side, a part-played episode is still the best hint that a
    /// session was touched — the stamp can be missing entirely when progress arrived by sync.
    func testProgressBreaksTiesOnlyWhenNeitherSessionHasBeenPlayed() throws {
        let podcast = makePodcast()

        makeSession(name: "Untouched", podcast: podcast, episodes: [makeEpisode(title: "A", podcast: podcast)])
        makeSession(name: "Contains progress", podcast: podcast, episodes: [
            makeEpisode(title: "B", podcast: podcast, playedUpTo: 600)
        ])

        XCTAssertEqual(SessionListRows.current(sort: .recentlyPlayed).map(\.name),
                       ["Contains progress", "Untouched"])
    }

    /// "Hide Unplayed Sessions" drops sessions never started, but never the active one.
    func testHideUnplayedFilter() throws {
        let podcast = makePodcast()
        let started = makeSession(name: "Started", podcast: podcast, episodes: [makeEpisode(title: "A", podcast: podcast, duration: 600)])
        let untouched = makeSession(name: "Untouched", podcast: podcast, episodes: [makeEpisode(title: "B", podcast: podcast, duration: 600)])

        let episode = try XCTUnwrap(lineup(started).first)
        episode.playedUpTo = 90
        DataManager.sharedManager.save(episode: episode)

        Settings.setSessionListHideUnplayed(true)
        XCTAssertEqual(SessionListRows.current().map(\.name), ["Started"])

        // The session you're in stays listed even when the filter would drop it.
        activate(untouched)
        XCTAssertEqual(Set(SessionListRows.current().map(\.name)), ["Started", "Untouched"])

        // The sheet ignores the chooser's filters entirely.
        XCTAssertEqual(Set(SessionListRows.current(sort: .recentlyPlayed, filters: .unfiltered).map(\.name)), ["Started", "Untouched"])
    }

    /// A newer play timestamp wins over a part-played episode. "Last Played" means the SESSION was
    /// played — an episode can belong to many sessions, so ranking on its progress floated every
    /// session merely containing it above the one actually being listened to.
    func testASessionPlayedMoreRecentlyOutranksOneHoldingAPartPlayedEpisode() throws {
        let podcast = makePodcast()
        let started = makeSession(name: "Started", podcast: podcast, episodes: [makeEpisode(title: "A", podcast: podcast, duration: 600)])
        let untouched = makeSession(name: "Untouched", podcast: podcast, episodes: [makeEpisode(title: "B", podcast: podcast, duration: 600)])

        // The untouched session carries the NEWER timestamp — it played more recently, so it wins.
        var startedUsed = started
        startedUsed.lastUsed = Date(timeIntervalSince1970: 1_000_000)
        SessionStore.shared.upsert(startedUsed)
        var untouchedUsed = untouched
        untouchedUsed.lastUsed = Date(timeIntervalSince1970: 2_000_000)
        SessionStore.shared.upsert(untouchedUsed)

        let episode = try XCTUnwrap(lineup(started).first)
        episode.playedUpTo = 120
        DataManager.sharedManager.save(episode: episode)

        let names = SessionListRows.current(sort: .recentlyPlayed).map(\.name)
        XCTAssertEqual(names, ["Untouched", "Started"])
    }

    // MARK: - Artwork

    /// The row pictures the episode it promises to play, exactly like an Up Next row.
    func testArtworkFollowsTheNextEpisodesPodcast() throws {
        let podcast = makePodcast()
        let session = makeSession(name: "Art", podcast: podcast, episodes: [makeEpisode(title: "One", podcast: podcast)])

        let row = try row(for: session, in: SessionListRows.current())
        XCTAssertEqual(row.nextEpisodePodcastUuid, podcast.uuid)
    }

    func testEmptySessionHasNoArtwork() throws {
        let podcast = makePodcast()
        let session = makeSession(name: "No art", podcast: podcast, episodes: [])

        let row = try row(for: session, in: SessionListRows.current())
        XCTAssertNil(row.nextEpisodePodcastUuid, "no next episode means no episode art")
    }

    // MARK: - Sorting

    private func names(_ sort: SessionListSort) -> [String] {
        SessionListRows.current(sort: sort, filters: .unfiltered).map(\.name)
    }

    /// Case- and diacritic-insensitive, so "apple" and "Ápple" interleave naturally.
    func testSortByName() {
        let podcast = makePodcast()
        makeSession(name: "banana", podcast: podcast, episodes: [makeEpisode(title: "A", podcast: podcast)])
        makeSession(name: "Ápple", podcast: podcast, episodes: [makeEpisode(title: "B", podcast: podcast)])
        makeSession(name: "Cherry", podcast: podcast, episodes: [makeEpisode(title: "C", podcast: podcast)])

        XCTAssertEqual(names(.name), ["Ápple", "banana", "Cherry"])
    }

    /// Shortest lineup first; sessions with nothing left sink to the bottom.
    func testSortByTimeLeftPutsEmptySessionsLast() {
        let podcast = makePodcast()
        makeSession(name: "Long", podcast: podcast, episodes: [makeEpisode(title: "A", podcast: podcast, duration: 7200)])
        makeSession(name: "Short", podcast: podcast, episodes: [makeEpisode(title: "B", podcast: podcast, duration: 600)])
        makeSession(name: "Medium", podcast: podcast, episodes: [makeEpisode(title: "C", podcast: podcast, duration: 3600)])
        makeSession(name: "Empty", podcast: podcast, episodes: [])

        XCTAssertEqual(names(.timeLeft), ["Short", "Medium", "Long", "Empty"])
    }

    /// Newest episode in the lineup first — "which session just gained something".
    func testSortByRecentlyUpdated() {
        let podcast = makePodcast()
        let old = Date(timeIntervalSince1970: 1_000_000)
        let mid = Date(timeIntervalSince1970: 2_000_000)
        let new = Date(timeIntervalSince1970: 3_000_000)

        makeSession(name: "Stale", podcast: podcast, episodes: [makeEpisode(title: "A", podcast: podcast, publishedDate: old)])
        makeSession(name: "Freshest", podcast: podcast, episodes: [
            makeEpisode(title: "B", podcast: podcast, publishedDate: old),
            makeEpisode(title: "C", podcast: podcast, publishedDate: new)
        ])
        makeSession(name: "Middling", podcast: podcast, episodes: [makeEpisode(title: "D", podcast: podcast, publishedDate: mid)])

        XCTAssertEqual(names(.recentlyUpdated), ["Freshest", "Middling", "Stale"])
    }

    /// Opening a session must never reshuffle the chooser: only a SOUNDING session leads,
    /// and activation alone isn't sound. (Actual playback can't be simulated here — there
    /// is no player in a unit test — so this pins the navigation half of the rule.)
    func testOpeningASessionDoesNotReorderTheList() {
        let podcast = makePodcast()
        makeSession(name: "Aaa", podcast: podcast, episodes: [makeEpisode(title: "A", podcast: podcast, duration: 600)])
        let playing = makeSession(name: "Zzz", podcast: podcast, episodes: [makeEpisode(title: "B", podcast: podcast, duration: 7200, publishedDate: Date(timeIntervalSince1970: 1))])

        // Without playback, "Zzz" is last under all three non-default sorts.
        XCTAssertEqual(names(.name).last, "Zzz")
        XCTAssertEqual(names(.timeLeft).last, "Zzz")
        XCTAssertEqual(names(.recentlyUpdated).last, "Zzz")

        // Stepping into it changes nothing about the order.
        activate(playing)
        XCTAssertEqual(names(.name).last, "Zzz", "opening a session must not hoist it under name")
        XCTAssertEqual(names(.timeLeft).last, "Zzz", "opening a session must not hoist it under timeLeft")
        XCTAssertEqual(names(.recentlyUpdated).last, "Zzz", "opening a session must not hoist it under recentlyUpdated")

        // Nor does pausing it — the progress tier, not the pointer, is what raises a session.
        activate(playing, paused: true)
        XCTAssertEqual(names(.name).last, "Zzz")
    }

    /// The persisted preference is what an unqualified `current()` uses.
    func testCurrentUsesThePersistedSortByDefault() {
        let podcast = makePodcast()
        makeSession(name: "Bbb", podcast: podcast, episodes: [makeEpisode(title: "A", podcast: podcast)])
        makeSession(name: "Aaa", podcast: podcast, episodes: [makeEpisode(title: "B", podcast: podcast)])

        Settings.setSessionListSort(.name)
        XCTAssertEqual(SessionListRows.current().map(\.name), ["Aaa", "Bbb"])
    }

    // MARK: - Filters

    func testHideEmptyDropsEmptySessions() {
        let podcast = makePodcast()
        makeSession(name: "Full", podcast: podcast, episodes: [makeEpisode(title: "A", podcast: podcast)])
        makeSession(name: "Empty", podcast: podcast, episodes: [])

        XCTAssertEqual(Set(SessionListRows.current().map(\.name)), ["Full", "Empty"], "shown by default")

        Settings.setSessionListHideEmpty(true)
        XCTAssertEqual(SessionListRows.current().map(\.name), ["Full"])
    }

    /// One type toggle, to pin the feeder→bucket mapping: folder-fed sessions are folders,
    /// and turning folders off leaves the podcast-fed one alone.
    func testTypeFilterHidesFolderFedSessions() {
        let podcast = makePodcast()
        makeSession(name: "From podcast", podcast: podcast, episodes: [makeEpisode(title: "A", podcast: podcast)])
        makeSession(name: "From folder", feeder: .folder(uuid: UUID().uuidString), episodes: [makeEpisode(title: "B", podcast: podcast)])

        XCTAssertEqual(Set(SessionListRows.current().map(\.name)), ["From podcast", "From folder"])

        Settings.setSessionListShowFolders(false)
        XCTAssertEqual(SessionListRows.current().map(\.name), ["From podcast"])
    }

    /// You can't be looking at a chooser that hides what's currently playing.
    func testPlayingSessionSurvivesAFilterThatWouldExcludeIt() {
        let podcast = makePodcast()
        makeSession(name: "From podcast", podcast: podcast, episodes: [makeEpisode(title: "A", podcast: podcast)])
        let folderSession = makeSession(name: "From folder", feeder: .folder(uuid: UUID().uuidString), episodes: [makeEpisode(title: "B", podcast: podcast)])

        Settings.setSessionListShowFolders(false)
        activate(folderSession)

        // The playing session is exempt from the filters (so both still appear); its position is its
        // normal sorted slot — `current()` no longer hoists the active session (the Queue surfaces it
        // via its own row-1 extraction). Default sort is `.manual`, so this is creation order.
        XCTAssertEqual(SessionListRows.current().map(\.name), ["From podcast", "From folder"],
                       "the playing session is exempt from the filters (but is no longer hoisted)")
    }

    /// The Switch Session sheet's call: the persisted preferences must not reach it.
    func testUnfilteredRecencyOverloadIgnoresThePersistedPreferences() {
        let podcast = makePodcast()
        makeSession(name: "Bbb", podcast: podcast, episodes: [makeEpisode(title: "A", podcast: podcast)])
        makeSession(name: "Aaa", podcast: podcast, episodes: [])

        Settings.setSessionListSort(.name)
        Settings.setSessionListHideEmpty(true)

        let rows = SessionListRows.current(sort: .recentlyPlayed, filters: .unfiltered)
        XCTAssertEqual(rows.map(\.name), ["Aaa", "Bbb"], "recency: never-played, newest created first")
    }

    /// A smart playlist can declare itself "not a session playlist". Its session is then never
    /// offered — not in the chooser, not in the Switch Session sheet, not on CarPlay. The session
    /// and its lineup survive untouched, so clearing the flag brings the row back unchanged.
    func testOptedOutSmartPlaylistSessionIsHidden() throws {
        let podcast = makePodcast()
        let playlistUuid = UUID().uuidString
        let optedOut = makeSession(name: "Not a session", feeder: .smartPlaylist(uuid: playlistUuid),
                                   episodes: [makeEpisode(title: "A", podcast: podcast)])
        makeSession(name: "Still a session", feeder: .smartPlaylist(uuid: UUID().uuidString),
                    episodes: [makeEpisode(title: "B", podcast: podcast)])

        XCTAssertEqual(Set(SessionListRows.current().map(\.name)), ["Not a session", "Still a session"],
                       "every smart playlist can be a session by default")

        Settings.setPlaylistOptedOutOfSession(true, uuid: playlistUuid)
        XCTAssertEqual(SessionListRows.current().map(\.name), ["Still a session"])
        XCTAssertEqual(SessionListRows.current(sort: .recentlyPlayed, filters: .unfiltered).map(\.name), ["Still a session"],
                       "the Switch Session sheet's unfiltered call hides it too")
        XCTAssertNotNil(SessionStore.shared.session(forSmartPlaylistFeeder: playlistUuid),
                        "the session itself is preserved, only hidden")

        // Opting back in restores the row, lineup intact.
        Settings.setPlaylistOptedOutOfSession(false, uuid: playlistUuid)
        let restored = try row(for: optedOut, in: SessionListRows.current())
        XCTAssertEqual(restored.name, "Not a session")
        XCTAssertEqual(restored.episodeCount, 1)
    }

    /// The global Inbox is coordination, not a lineup you pick — it never appears.
    func testGlobalInboxIsExcluded() {
        _ = SessionStore.shared.globalInbox
        XCTAssertFalse(SessionListRows.current().contains { $0.sessionUuid == SessionStore.globalInboxUuid })
    }
}
