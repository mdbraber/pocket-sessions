@testable import PocketCastsDataModel
@testable import PocketCastsUtils
import XCTest

/// Fork: covers the smart-playlist custom-order overlay — the query that surfaces
/// unpositioned (inbox) episodes ahead of the positioned lineup, and the insert-marker
/// primitives that place episodes into the lineup.
final class SmartPlaylistCustomOrderTests: DataManagerTestCase {

    func testOverlayQueryReturnsInboxFirstThenLineup() throws {
        try runWithBothImplementations { dataManager, impl in
            let playlist = makeCustomOrderedSmartPlaylist(uuid: "sp-overlay", dataManager: dataManager)

            // e1 oldest … e4 newest
            saveEpisodes(uuids: ["e1", "e2", "e3", "e4"], dataManager: dataManager)

            // Lineup holds e1 then e2; e3/e4 match the rules but are unpositioned (inbox).
            dataManager.setCustomOrder(episodeUuids: ["e1", "e2"], for: playlist)

            let episodes = dataManager.playlistEpisodes(for: playlist).map { $0.uuid }
            XCTAssertEqual(episodes, ["e4", "e3", "e1", "e2"], "\(impl): inbox newest-first, then lineup order")

            XCTAssertEqual(dataManager.positionedEpisodeUuids(for: playlist), ["e1", "e2"], "\(impl): lineup uuids in position order")
        }
    }

    func testInsertModeTopReversesConsecutiveInserts() throws {
        try runWithBothImplementations { dataManager, impl in
            let playlist = makeCustomOrderedSmartPlaylist(uuid: "sp-top", dataManager: dataManager)
            playlist.insertMode = .top
            saveEpisodes(uuids: ["a", "b", "x"], dataManager: dataManager)
            dataManager.setCustomOrder(episodeUuids: ["x"], for: playlist)

            dataManager.insertIntoCustomOrder(episodeUuids: ["a"], for: playlist)
            dataManager.insertIntoCustomOrder(episodeUuids: ["b"], for: playlist)

            XCTAssertEqual(dataManager.positionedEpisodeUuids(for: playlist), ["b", "a", "x"], "\(impl): pinned top inserts above everything")
        }
    }

    func testInsertModeBottomAppends() throws {
        try runWithBothImplementations { dataManager, impl in
            let playlist = makeCustomOrderedSmartPlaylist(uuid: "sp-bottom", dataManager: dataManager)
            playlist.insertMode = .bottom
            saveEpisodes(uuids: ["a", "b", "x"], dataManager: dataManager)
            dataManager.setCustomOrder(episodeUuids: ["x"], for: playlist)

            dataManager.insertIntoCustomOrder(episodeUuids: ["a"], for: playlist)
            dataManager.insertIntoCustomOrder(episodeUuids: ["b"], for: playlist)

            XCTAssertEqual(dataManager.positionedEpisodeUuids(for: playlist), ["x", "a", "b"], "\(impl): bottom mode appends in insert order")
        }
    }

    func testInsertModeAfterLastInsertedPreservesTriageOrder() throws {
        try runWithBothImplementations { dataManager, impl in
            let playlist = makeCustomOrderedSmartPlaylist(uuid: "sp-after", dataManager: dataManager)
            playlist.insertMode = .afterLastInserted
            saveEpisodes(uuids: ["a", "b", "c", "d", "x"], dataManager: dataManager)
            dataManager.setCustomOrder(episodeUuids: ["x"], for: playlist)

            // No anchor yet: seeds at top, then chains downward.
            dataManager.insertIntoCustomOrder(episodeUuids: ["a"], for: playlist)
            dataManager.insertIntoCustomOrder(episodeUuids: ["b"], for: playlist)
            XCTAssertEqual(dataManager.positionedEpisodeUuids(for: playlist), ["a", "b", "x"], "\(impl): consecutive inserts chain in triage order")

            // A block insert lands as a block after the anchor.
            dataManager.insertIntoCustomOrder(episodeUuids: ["c", "d"], for: playlist)
            XCTAssertEqual(dataManager.positionedEpisodeUuids(for: playlist), ["a", "b", "c", "d", "x"], "\(impl): block keeps on-screen order")
            XCTAssertEqual(playlist.customOrderLastInsertedUuid, "d", "\(impl): marker anchors to the last of the block")
        }
    }

    func testInsertModeBeforeLastInsertedGrowsUpward() throws {
        try runWithBothImplementations { dataManager, impl in
            let playlist = makeCustomOrderedSmartPlaylist(uuid: "sp-before", dataManager: dataManager)
            playlist.insertMode = .beforeLastInserted
            saveEpisodes(uuids: ["a", "b", "x", "y"], dataManager: dataManager)
            dataManager.setCustomOrder(episodeUuids: ["x", "y"], for: playlist)

            // No anchor: seeds at bottom, then grows upward from the block head.
            dataManager.insertIntoCustomOrder(episodeUuids: ["a"], for: playlist)
            dataManager.insertIntoCustomOrder(episodeUuids: ["b"], for: playlist)

            XCTAssertEqual(dataManager.positionedEpisodeUuids(for: playlist), ["x", "y", "b", "a"], "\(impl): before-mode block grows upward")
            XCTAssertEqual(playlist.customOrderLastInsertedUuid, "b", "\(impl): marker anchors to the block head")
        }
    }

    func testMarkerFallsBackWhenAnchorLeavesPlaylist() throws {
        try runWithBothImplementations { dataManager, impl in
            let playlist = makeCustomOrderedSmartPlaylist(uuid: "sp-fallback", dataManager: dataManager)
            playlist.insertMode = .afterLastInserted
            playlist.customOrderLastInsertedUuid = "gone"
            saveEpisodes(uuids: ["a", "x"], dataManager: dataManager)
            dataManager.setCustomOrder(episodeUuids: ["x"], for: playlist)

            dataManager.insertIntoCustomOrder(episodeUuids: ["a"], for: playlist)

            XCTAssertEqual(dataManager.positionedEpisodeUuids(for: playlist), ["a", "x"], "\(impl): after-mode falls back to top when the anchor is gone")
        }
    }

    func testReinsertingPositionedEpisodeMovesInsteadOfDuplicating() throws {
        try runWithBothImplementations { dataManager, impl in
            let playlist = makeCustomOrderedSmartPlaylist(uuid: "sp-move", dataManager: dataManager)
            playlist.insertMode = .top
            saveEpisodes(uuids: ["a", "b", "c"], dataManager: dataManager)
            dataManager.setCustomOrder(episodeUuids: ["a", "b", "c"], for: playlist)

            dataManager.insertIntoCustomOrder(episodeUuids: ["c"], for: playlist)

            XCTAssertEqual(dataManager.positionedEpisodeUuids(for: playlist), ["c", "a", "b"], "\(impl): re-inserting moves the episode")
        }
    }

    func testPruneKeepsOrderAndReindexes() throws {
        try runWithBothImplementations { dataManager, impl in
            let playlist = makeCustomOrderedSmartPlaylist(uuid: "sp-prune", dataManager: dataManager)
            saveEpisodes(uuids: ["a", "b", "c", "d"], dataManager: dataManager)
            dataManager.setCustomOrder(episodeUuids: ["a", "b", "c", "d"], for: playlist)

            dataManager.pruneCustomOrder(keepingEpisodeUuids: ["b", "d"], for: playlist)

            XCTAssertEqual(dataManager.positionedEpisodeUuids(for: playlist), ["b", "d"], "\(impl): pruned lineup keeps relative order")
        }
    }

    func testInsertMarkerIndex() {
        let playlist = EpisodeFilter()
        let lineup = ["a", "b", "c"]

        playlist.insertMode = .top
        XCTAssertEqual(playlist.insertMarkerIndex(inLineup: lineup), 0)

        playlist.insertMode = .bottom
        XCTAssertEqual(playlist.insertMarkerIndex(inLineup: lineup), 3)

        playlist.insertMode = .afterLastInserted
        playlist.customOrderLastInsertedUuid = "b"
        XCTAssertEqual(playlist.insertMarkerIndex(inLineup: lineup), 2)
        playlist.customOrderLastInsertedUuid = "missing"
        XCTAssertEqual(playlist.insertMarkerIndex(inLineup: lineup), 0, "after-mode falls back to top")

        playlist.insertMode = .beforeLastInserted
        playlist.customOrderLastInsertedUuid = "b"
        XCTAssertEqual(playlist.insertMarkerIndex(inLineup: lineup), 1)
        playlist.customOrderLastInsertedUuid = "missing"
        XCTAssertEqual(playlist.insertMarkerIndex(inLineup: lineup), 3, "before-mode falls back to bottom")
    }

    // MARK: - Helpers

    /// A non-manual (smart) playlist with match-everything rules and drag-and-drop sort.
    private func makeCustomOrderedSmartPlaylist(uuid: String, dataManager: DataManager) -> EpisodeFilter {
        let playlist = EpisodeFilter.makeDefault()
        playlist.uuid = uuid
        playlist.playlistName = uuid
        playlist.sortType = PlaylistSort.dragAndDrop.rawValue
        dataManager.save(playlist: playlist)
        return playlist
    }

    /// Saves episodes with ascending published dates (later uuids are newer).
    private func saveEpisodes(uuids: [String], dataManager: DataManager) {
        for (index, uuid) in uuids.enumerated() {
            let episode = Episode()
            episode.uuid = uuid
            episode.podcastUuid = "p1"
            episode.title = uuid
            episode.publishedDate = Date(timeIntervalSince1970: TimeInterval(1000 + index))
            episode.addedDate = Date(timeIntervalSince1970: TimeInterval(1000 + index))
            dataManager.save(episode: episode)
        }
    }
}
