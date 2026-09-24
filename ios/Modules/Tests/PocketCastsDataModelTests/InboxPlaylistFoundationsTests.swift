import XCTest

@testable import PocketCastsDataModel

/// Fork: the DataModel foundations the Inbox-as-playlist model rests on.
///
/// The Inbox is a manual playlist whose membership means "unseen". That imposes four
/// requirements on this layer, and each one is a bug if it regresses:
///
/// 1. The Inbox must be **invisible** to every UI surface that enumerates playlists — but
///    still **sync**, and still be **findable** by the fork.
/// 2. Membership must be readable as a `Set` without hydrating `Episode` objects (the dot
///    reads it once per list load).
/// 3. Applying a synced episode order must be **one pass**, not one full rewrite per episode.
/// 4. Deleting an episode must **cascade** to playlist membership, without touching Up Next.
final class InboxPlaylistFoundationsTests: DataManagerTestCase {

    // MARK: - 1. The Inbox is hidden from enumeration, but not from sync

    func testInboxPlaylistIsHiddenFromEveryEnumerationAPI() throws {
        try runWithBothImplementations { dataManager, name in
            _ = self.createTestPlaylist(uuid: DataManager.inboxPlaylistUuid, name: "Inbox", manual: true, dataManager: dataManager)
            _ = self.createTestPlaylist(name: "A real manual playlist", manual: true, dataManager: dataManager)
            _ = self.createTestPlaylist(name: "A real smart playlist", manual: false, dataManager: dataManager)

            let all = dataManager.allPlaylists(includeDeleted: false).map(\.uuid)
            let manual = dataManager.allManualPlaylists(includeDeleted: false).map(\.uuid)
            let smart = dataManager.allSmartPlaylists(includeDeleted: false).map(\.uuid)

            XCTAssertFalse(all.contains(DataManager.inboxPlaylistUuid), "\(name): allPlaylists must not expose the Inbox")
            XCTAssertFalse(manual.contains(DataManager.inboxPlaylistUuid), "\(name): allManualPlaylists must not expose the Inbox")
            XCTAssertFalse(smart.contains(DataManager.inboxPlaylistUuid), "\(name): allSmartPlaylists must not expose the Inbox")
            XCTAssertEqual(all.count, 2, "\(name): the two real playlists still show")
            XCTAssertEqual(dataManager.playlistsCount(includeDeleted: false), 2, "\(name): the count excludes the Inbox too")
        }
    }

    /// Hiding it from the UI must not hide it from the server — sync enumerates via a
    /// different API, and that is the whole reason the chokepoint is safe.
    func testInboxPlaylistStillSyncsAndIsStillFindable() throws {
        try runWithBothImplementations { dataManager, name in
            _ = self.createTestPlaylist(uuid: DataManager.inboxPlaylistUuid, name: "Inbox", manual: true, syncStatus: SyncStatus.notSynced.rawValue, dataManager: dataManager)

            let unsynced = dataManager.allUnsyncedPlaylists().map(\.uuid)
            XCTAssertTrue(unsynced.contains(DataManager.inboxPlaylistUuid), "\(name): the Inbox MUST still be picked up for sync")
            XCTAssertNotNil(dataManager.findPlaylist(uuid: DataManager.inboxPlaylistUuid), "\(name): the fork must still be able to fetch the Inbox itself")
        }
    }

    // MARK: - 2. Membership as a Set

    func testPlaylistEpisodeUuidsReturnsMembershipWithoutHydratingEpisodes() throws {
        try runWithBothImplementations { dataManager, name in
            let podcast = self.createTestPodcast(dataManager: dataManager)
            let playlist = self.createTestPlaylist(manual: true, dataManager: dataManager)
            let members = (1 ... 3).map { self.createTestEpisode(uuid: "e\($0)", podcast: podcast, dataManager: dataManager) }
            _ = self.createTestEpisode(uuid: "not-a-member", podcast: podcast, dataManager: dataManager)

            XCTAssertTrue(dataManager.add(episodes: members, to: playlist))

            XCTAssertEqual(dataManager.playlistEpisodeUuids(for: playlist.uuid), ["e1", "e2", "e3"], "\(name)")
        }
    }

    func testPlaylistEpisodeUuidsIsEmptyForAnUnknownPlaylist() throws {
        try runWithBothImplementations { dataManager, name in
            XCTAssertTrue(dataManager.playlistEpisodeUuids(for: "nope").isEmpty, "\(name)")
        }
    }

    // MARK: - 3. Applying a synced order in one pass

    func testApplyEpisodeOrderReordersMembership() throws {
        try runWithBothImplementations { dataManager, name in
            let podcast = self.createTestPodcast(dataManager: dataManager)
            let playlist = self.createTestPlaylist(manual: true, dataManager: dataManager)
            let episodes = ["a", "b", "c", "d"].map { self.createTestEpisode(uuid: $0, podcast: podcast, dataManager: dataManager) }
            XCTAssertTrue(dataManager.add(episodes: episodes, to: playlist))

            dataManager.applyEpisodeOrder(["d", "b", "a", "c"], for: playlist)

            XCTAssertEqual(dataManager.positionedEpisodeUuids(for: playlist), ["d", "b", "a", "c"], "\(name)")
        }
    }

    /// The common case: the server's order already matches. This must not rewrite a thing.
    func testApplyEpisodeOrderIsANoOpWhenTheOrderAlreadyMatches() throws {
        try runWithBothImplementations { dataManager, name in
            let podcast = self.createTestPodcast(dataManager: dataManager)
            let playlist = self.createTestPlaylist(manual: true, dataManager: dataManager)
            let episodes = ["a", "b", "c"].map { self.createTestEpisode(uuid: $0, podcast: podcast, dataManager: dataManager) }
            XCTAssertTrue(dataManager.add(episodes: episodes, to: playlist))

            dataManager.applyEpisodeOrder(["a", "b", "c"], for: playlist)

            XCTAssertEqual(dataManager.positionedEpisodeUuids(for: playlist), ["a", "b", "c"], "\(name)")
        }
    }

    /// Rows the server didn't name keep their relative order, below the ones it did.
    func testApplyEpisodeOrderSinksUnrankedRowsToTheBottomInOrder() throws {
        try runWithBothImplementations { dataManager, name in
            let podcast = self.createTestPodcast(dataManager: dataManager)
            let playlist = self.createTestPlaylist(manual: true, dataManager: dataManager)
            let episodes = ["a", "b", "c", "d"].map { self.createTestEpisode(uuid: $0, podcast: podcast, dataManager: dataManager) }
            XCTAssertTrue(dataManager.add(episodes: episodes, to: playlist))

            dataManager.applyEpisodeOrder(["c", "a"], for: playlist)

            XCTAssertEqual(dataManager.positionedEpisodeUuids(for: playlist), ["c", "a", "b", "d"], "\(name)")
        }
    }

    // MARK: - 4. Cascade on episode delete

    func testDeletingAnEpisodeCascadesToPlaylistMembership() throws {
        try runWithBothImplementations { dataManager, name in
            let podcast = self.createTestPodcast(dataManager: dataManager)
            let playlist = self.createTestPlaylist(manual: true, dataManager: dataManager)
            let doomed = self.createTestEpisode(uuid: "doomed", podcast: podcast, dataManager: dataManager)
            let survivor = self.createTestEpisode(uuid: "survivor", podcast: podcast, dataManager: dataManager)
            XCTAssertTrue(dataManager.add(episodes: [doomed, survivor], to: playlist))

            dataManager.delete(episodeUuid: "doomed")

            XCTAssertEqual(dataManager.playlistEpisodeUuids(for: playlist.uuid), ["survivor"],
                           "\(name): a deleted episode must not leave an orphan membership row behind")
        }
    }

    /// Up Next lives in the same table (playlist_uuid IS NULL) but has its own sync. The
    /// cascade must not reach into it.
    func testDeletingAnEpisodeLeavesTheUpNextQueueAlone() throws {
        try runWithBothImplementations { dataManager, name in
            let podcast = self.createTestPodcast(dataManager: dataManager)
            _ = self.createTestEpisode(uuid: "queued", podcast: podcast, dataManager: dataManager)
            let other = self.createTestEpisode(uuid: "other", podcast: podcast, dataManager: dataManager)
            self.addToUpNextBottom(episodeUuid: "queued", podcastUuid: podcast.uuid, dataManager: dataManager)

            dataManager.delete(episodeUuid: other.uuid)

            XCTAssertEqual(dataManager.allUpNextEpisodes().map(\.uuid), ["queued"],
                           "\(name): deleting an unrelated episode must not disturb Up Next")
        }
    }

    func testDeletingAllEpisodesInAPodcastCascadesToPlaylistMembership() throws {
        try runWithBothImplementations { dataManager, name in
            let podcast = self.createTestPodcast(dataManager: dataManager)
            let keeper = self.createTestPodcast(uuid: "keeper-podcast", dataManager: dataManager)
            let playlist = self.createTestPlaylist(manual: true, dataManager: dataManager)
            let doomed = (1 ... 2).map { self.createTestEpisode(uuid: "d\($0)", podcast: podcast, dataManager: dataManager) }
            let kept = self.createTestEpisode(uuid: "kept", podcast: keeper, dataManager: dataManager)
            XCTAssertTrue(dataManager.add(episodes: doomed + [kept], to: playlist))

            dataManager.deleteAllEpisodesInPodcast(podcastId: podcast.id)

            XCTAssertEqual(dataManager.playlistEpisodeUuids(for: playlist.uuid), ["kept"], "\(name)")
        }
    }

    // MARK: - 5. add() marks the playlist dirty

    /// Upstream left this to the caller, so an add that forgot it never reached the server.
    func testAddingEpisodesMarksThePlaylistUnsynced() throws {
        try runWithBothImplementations { dataManager, name in
            let podcast = self.createTestPodcast(dataManager: dataManager)
            let playlist = self.createTestPlaylist(manual: true, syncStatus: SyncStatus.synced.rawValue, dataManager: dataManager)
            let episode = self.createTestEpisode(podcast: podcast, dataManager: dataManager)

            XCTAssertTrue(dataManager.add(episodes: [episode], to: playlist))

            let reloaded = try XCTUnwrap(dataManager.findPlaylist(uuid: playlist.uuid))
            XCTAssertEqual(reloaded.syncStatus, SyncStatus.notSynced.rawValue,
                           "\(name): a membership change must mark the playlist dirty, or it never syncs")
        }
    }

    // MARK: - 6. extraWhere composes onto a playlist's own rules

    func testExtraWhereIsAndedOntoThePlaylistQuery() throws {
        try runWithBothImplementations { dataManager, name in
            let podcast = self.createTestPodcast(dataManager: dataManager)
            _ = self.createTestEpisode(uuid: "wanted", podcast: podcast, dataManager: dataManager)
            _ = self.createTestEpisode(uuid: "unwanted", podcast: podcast, dataManager: dataManager)
            // A match-everything smart playlist. Note a bare `EpisodeFilter()` is NOT that:
            // `filterDownloading` is hardcoded true while the other two download flags default
            // to false, so the builder emits a download-status clause. All three on (or all
            // three off) is what makes the block unconstrained.
            let playlist = self.createTestPlaylist(manual: false, dataManager: dataManager)
            playlist.filterAllPodcasts = true
            playlist.filterDownloaded = true
            playlist.filterNotDownloaded = true
            dataManager.save(playlist: playlist)

            let unfiltered = dataManager.playlistEpisodes(for: playlist).map(\.uuid)
            XCTAssertEqual(Set(unfiltered), ["wanted", "unwanted"], "\(name): sanity — both match the bare playlist")

            let filtered = dataManager.playlistEpisodes(for: playlist, matching: "episode.uuid = 'wanted'").map(\.uuid)
            XCTAssertEqual(filtered, ["wanted"], "\(name): the preset fragment must AND onto the playlist's own rules")
        }
    }
}
