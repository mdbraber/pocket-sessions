@testable import PocketCastsDataModel
@testable import PocketCastsUtils
import XCTest

/// Fork: covers the smart-playlist custom-order overlay — the query that surfaces
/// unpositioned (inbox) episodes ahead of the positioned lineup, and the insert-marker
/// primitives that place episodes into the lineup.
final class SmartPlaylistCustomOrderTests: DataManagerTestCase {

    func testOverlayQueryReturnsInboxFirstThenLineup() throws {
        try runWithDataManager { dataManager in
            let playlist = makeCustomOrderedSmartPlaylist(uuid: "sp-overlay", dataManager: dataManager)

            // e1 oldest … e4 newest
            saveEpisodes(uuids: ["e1", "e2", "e3", "e4"], dataManager: dataManager)

            // Lineup holds e1 then e2; e3/e4 match the rules but are unpositioned (inbox).
            dataManager.setCustomOrder(episodeUuids: ["e1", "e2"], for: playlist)

            let episodes = dataManager.playlistEpisodes(for: playlist).map { $0.uuid }
            XCTAssertEqual(episodes, ["e4", "e3", "e1", "e2"], "inbox newest-first, then lineup order")

            XCTAssertEqual(dataManager.positionedEpisodeUuids(for: playlist), ["e1", "e2"], "lineup uuids in position order")
        }
    }

    func testInsertModeTopReversesConsecutiveInserts() throws {
        try runWithDataManager { dataManager in
            let playlist = makeCustomOrderedSmartPlaylist(uuid: "sp-top", dataManager: dataManager)
            playlist.insertMode = .top
            saveEpisodes(uuids: ["a", "b", "x"], dataManager: dataManager)
            dataManager.setCustomOrder(episodeUuids: ["x"], for: playlist)

            dataManager.insertIntoCustomOrder(episodeUuids: ["a"], for: playlist)
            dataManager.insertIntoCustomOrder(episodeUuids: ["b"], for: playlist)

            XCTAssertEqual(dataManager.positionedEpisodeUuids(for: playlist), ["b", "a", "x"], "pinned top inserts above everything")
        }
    }

    func testInsertModeBottomAppends() throws {
        try runWithDataManager { dataManager in
            let playlist = makeCustomOrderedSmartPlaylist(uuid: "sp-bottom", dataManager: dataManager)
            playlist.insertMode = .bottom
            saveEpisodes(uuids: ["a", "b", "x"], dataManager: dataManager)
            dataManager.setCustomOrder(episodeUuids: ["x"], for: playlist)

            dataManager.insertIntoCustomOrder(episodeUuids: ["a"], for: playlist)
            dataManager.insertIntoCustomOrder(episodeUuids: ["b"], for: playlist)

            XCTAssertEqual(dataManager.positionedEpisodeUuids(for: playlist), ["x", "a", "b"], "bottom mode appends in insert order")
        }
    }

    func testInsertModeAfterLastInsertedPreservesTriageOrder() throws {
        try runWithDataManager { dataManager in
            let playlist = makeCustomOrderedSmartPlaylist(uuid: "sp-after", dataManager: dataManager)
            playlist.insertMode = .afterLastInserted
            saveEpisodes(uuids: ["a", "b", "c", "d", "x"], dataManager: dataManager)
            dataManager.setCustomOrder(episodeUuids: ["x"], for: playlist)

            // No anchor yet: seeds at top, then chains downward.
            dataManager.insertIntoCustomOrder(episodeUuids: ["a"], for: playlist)
            dataManager.insertIntoCustomOrder(episodeUuids: ["b"], for: playlist)
            XCTAssertEqual(dataManager.positionedEpisodeUuids(for: playlist), ["a", "b", "x"], "consecutive inserts chain in triage order")

            // A block insert lands as a block after the anchor.
            dataManager.insertIntoCustomOrder(episodeUuids: ["c", "d"], for: playlist)
            XCTAssertEqual(dataManager.positionedEpisodeUuids(for: playlist), ["a", "b", "c", "d", "x"], "block keeps on-screen order")
            XCTAssertEqual(playlist.customOrderLastInsertedUuid, "d", "marker anchors to the last of the block")
        }
    }

    func testInsertModeBeforeLastInsertedGrowsUpward() throws {
        try runWithDataManager { dataManager in
            let playlist = makeCustomOrderedSmartPlaylist(uuid: "sp-before", dataManager: dataManager)
            playlist.insertMode = .beforeLastInserted
            saveEpisodes(uuids: ["a", "b", "x", "y"], dataManager: dataManager)
            dataManager.setCustomOrder(episodeUuids: ["x", "y"], for: playlist)

            // No anchor: seeds at bottom, then grows upward from the block head.
            dataManager.insertIntoCustomOrder(episodeUuids: ["a"], for: playlist)
            dataManager.insertIntoCustomOrder(episodeUuids: ["b"], for: playlist)

            XCTAssertEqual(dataManager.positionedEpisodeUuids(for: playlist), ["x", "y", "b", "a"], "before-mode block grows upward")
            XCTAssertEqual(playlist.customOrderLastInsertedUuid, "b", "marker anchors to the block head")
        }
    }

    func testMarkerFallsBackWhenAnchorLeavesPlaylist() throws {
        try runWithDataManager { dataManager in
            let playlist = makeCustomOrderedSmartPlaylist(uuid: "sp-fallback", dataManager: dataManager)
            playlist.insertMode = .afterLastInserted
            playlist.customOrderLastInsertedUuid = "gone"
            saveEpisodes(uuids: ["a", "x"], dataManager: dataManager)
            dataManager.setCustomOrder(episodeUuids: ["x"], for: playlist)

            dataManager.insertIntoCustomOrder(episodeUuids: ["a"], for: playlist)

            XCTAssertEqual(dataManager.positionedEpisodeUuids(for: playlist), ["a", "x"], "after-mode falls back to top when the anchor is gone")
        }
    }

    func testSessionInsertNeverLandsAboveTheHead() throws {
        try runWithDataManager { dataManager in
            let store = makeCustomOrderedSmartPlaylist(uuid: "store-head", dataManager: dataManager)
            saveEpisodes(uuids: ["h", "x", "a", "b", "c"], dataManager: dataManager)
            dataManager.setCustomOrder(episodeUuids: ["x", "h"], for: store)

            // Top mode goes right under the head, not above it.
            dataManager.insertSessionMembers(episodeUuids: ["a"], insertMode: .top, anchorUuid: "", below: "h", for: store)
            XCTAssertEqual(dataManager.positionedEpisodeUuids(for: store), ["x", "h", "a"], "top means just below the head")

            // A missing anchor falls back to just below the head, not to position 0.
            dataManager.insertSessionMembers(episodeUuids: ["b"], insertMode: .afterLastInserted, anchorUuid: "gone", below: "h", for: store)
            XCTAssertEqual(dataManager.positionedEpisodeUuids(for: store), ["x", "h", "b", "a"], "after-mode without its anchor lands below the head")

            // An anchor above the head can't pull an insert above it either.
            dataManager.insertSessionMembers(episodeUuids: ["c"], insertMode: .beforeLastInserted, anchorUuid: "x", below: "h", for: store)
            XCTAssertEqual(dataManager.positionedEpisodeUuids(for: store), ["x", "h", "c", "b", "a"], "before-mode is clamped below the head")
        }
    }

    func testSessionInsertWithoutHeadKeepsTopAndFallback() throws {
        try runWithDataManager { dataManager in
            let store = makeCustomOrderedSmartPlaylist(uuid: "store-nohead", dataManager: dataManager)
            saveEpisodes(uuids: ["x", "a", "b"], dataManager: dataManager)
            dataManager.setCustomOrder(episodeUuids: ["x"], for: store)

            dataManager.insertSessionMembers(episodeUuids: ["a"], insertMode: .top, anchorUuid: "", for: store)
            dataManager.insertSessionMembers(episodeUuids: ["b"], insertMode: .afterLastInserted, anchorUuid: "gone", for: store)

            XCTAssertEqual(dataManager.positionedEpisodeUuids(for: store), ["b", "a", "x"], "no head: top and the missing-anchor fallback are position 0")
        }
    }

    func testReinsertingPositionedEpisodeMovesInsteadOfDuplicating() throws {
        try runWithDataManager { dataManager in
            let playlist = makeCustomOrderedSmartPlaylist(uuid: "sp-move", dataManager: dataManager)
            playlist.insertMode = .top
            saveEpisodes(uuids: ["a", "b", "c"], dataManager: dataManager)
            dataManager.setCustomOrder(episodeUuids: ["a", "b", "c"], for: playlist)

            dataManager.insertIntoCustomOrder(episodeUuids: ["c"], for: playlist)

            XCTAssertEqual(dataManager.positionedEpisodeUuids(for: playlist), ["c", "a", "b"], "re-inserting moves the episode")
        }
    }

    func testPruneKeepsOrderAndReindexes() throws {
        try runWithDataManager { dataManager in
            let playlist = makeCustomOrderedSmartPlaylist(uuid: "sp-prune", dataManager: dataManager)
            saveEpisodes(uuids: ["a", "b", "c", "d"], dataManager: dataManager)
            dataManager.setCustomOrder(episodeUuids: ["a", "b", "c", "d"], for: playlist)

            dataManager.pruneCustomOrder(keepingEpisodeUuids: ["b", "d"], for: playlist)

            XCTAssertEqual(dataManager.positionedEpisodeUuids(for: playlist), ["b", "d"], "pruned lineup keeps relative order")
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
