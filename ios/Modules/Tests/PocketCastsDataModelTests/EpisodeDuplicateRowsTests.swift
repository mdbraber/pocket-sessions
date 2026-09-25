@testable import PocketCastsDataModel
import GRDB
import XCTest

/// Fork: one row per episode uuid. Sync imports run concurrently, and each "missing episode"
/// insert used to check-then-insert in separate transactions — so two importers (e.g. two synced
/// playlists holding the same unknown episode) could both insert, leaving duplicate rows.
final class EpisodeDuplicateRowsTests: DataManagerTestCase {

    func testInsertIfAbsentSkipsAnExistingEpisode() throws {
        try runWithDataManager { dataManager in
            XCTAssertTrue(dataManager.insertIfAbsent(episode: makeEpisode(uuid: "e1", title: "first")))
            XCTAssertFalse(dataManager.insertIfAbsent(episode: makeEpisode(uuid: "e1", title: "second")))

            XCTAssertEqual(try rows(uuid: "e1", dataManager: dataManager).count, 1)
            XCTAssertEqual(dataManager.findEpisode(uuid: "e1")?.title, "first", "the existing row is kept")
        }
    }

    func testRealEpisodeReplacesSyncPlaceholderKeepingItsRow() throws {
        try runWithDataManager { dataManager in
            let placeholder = makeEpisode(uuid: "e1", title: "placeholder")
            placeholder.wasDeleted = true
            XCTAssertTrue(dataManager.insertIfAbsent(episode: placeholder))
            let placeholderId = try XCTUnwrap(dataManager.findEpisode(uuid: "e1")?.id)

            XCTAssertTrue(dataManager.insertIfAbsent(episode: makeEpisode(uuid: "e1", title: "real")))

            let stored = try rows(uuid: "e1", dataManager: dataManager)
            XCTAssertEqual(stored.count, 1)
            XCTAssertEqual(stored.first?["id"], placeholderId, "the placeholder's row is reused")
            XCTAssertEqual(dataManager.findEpisode(uuid: "e1")?.title, "real")
            XCTAssertEqual(dataManager.findEpisode(uuid: "e1")?.wasDeleted, false)
        }
    }

    func testBulkInsertIfAbsentReturnsOnlyInsertedEpisodes() throws {
        try runWithDataManager { dataManager in
            dataManager.insertIfAbsent(episode: makeEpisode(uuid: "e1", title: "existing"))

            let inserted = dataManager.bulkInsertIfAbsent(episodes: [makeEpisode(uuid: "e1", title: "dupe"), makeEpisode(uuid: "e2", title: "new")])

            XCTAssertEqual(inserted.map(\.uuid), ["e2"])
            XCTAssertEqual(try rows(uuid: "e1", dataManager: dataManager).count, 1)
        }
    }

    func testRemoveDuplicateEpisodesKeepsTheRealRowAndRepairsPlaceholders() throws {
        try runWithDataManager { dataManager in
            // e1: a real, played row plus two placeholders (as the concurrent import left them).
            try insertRaw(id: 1, uuid: "e1", playingStatus: 0, episodeStatus: 0, wasDeleted: true, dataManager: dataManager)
            try insertRaw(id: 2, uuid: "e1", playingStatus: PlayingStatus.inProgress.rawValue, episodeStatus: DownloadStatus.notDownloaded.rawValue, wasDeleted: false, dataManager: dataManager)
            try insertRaw(id: 3, uuid: "e1", playingStatus: 0, episodeStatus: 0, wasDeleted: false, dataManager: dataManager)
            // e2: only placeholders, never resolved to a real row.
            try insertRaw(id: 4, uuid: "e2", playingStatus: 0, episodeStatus: 0, wasDeleted: true, dataManager: dataManager)
            try insertRaw(id: 5, uuid: "e2", playingStatus: 0, episodeStatus: 0, wasDeleted: true, dataManager: dataManager)

            XCTAssertEqual(dataManager.removeDuplicateEpisodes(), 3)

            let e1 = try rows(uuid: "e1", dataManager: dataManager)
            XCTAssertEqual(e1.map { $0["id"] as Int64 }, [2], "the played, undeleted row survives")
            let e2 = try rows(uuid: "e2", dataManager: dataManager)
            XCTAssertEqual(e2.count, 1)
            XCTAssertEqual(e2.first?["playingStatus"], PlayingStatus.notPlayed.rawValue, "a leftover placeholder gets a valid play status")
            XCTAssertEqual(e2.first?["episodeStatus"], DownloadStatus.notDownloaded.rawValue, "and a valid download status")
        }
    }

    // MARK: - Helpers

    private func makeEpisode(uuid: String, title: String) -> Episode {
        let episode = Episode()
        episode.uuid = uuid
        episode.podcastUuid = "p1"
        episode.title = title
        episode.addedDate = Date()
        episode.playingStatus = PlayingStatus.notPlayed.rawValue
        episode.episodeStatus = DownloadStatus.notDownloaded.rawValue
        return episode
    }

    private func insertRaw(id: Int64, uuid: String, playingStatus: Int32, episodeStatus: Int32, wasDeleted: Bool, dataManager: DataManager) throws {
        let episode = makeEpisode(uuid: uuid, title: uuid)
        episode.id = id
        episode.playingStatus = playingStatus
        episode.episodeStatus = episodeStatus
        episode.wasDeleted = wasDeleted
        try dataManager.dbQueue.dbPool.write { db in try episode.insert(db) }
    }

    private func rows(uuid: String, dataManager: DataManager) throws -> [Row] {
        try dataManager.dbQueue.dbPool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM \(DataManager.episodeTableName) WHERE uuid = ? ORDER BY id", arguments: [uuid])
        }
    }
}
