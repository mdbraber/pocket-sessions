import PocketCastsUtils
import Foundation
import GRDB

class PlaylistDataManager {
    /// Legacy column names for non-GRDB code path.
    let columnNames = [
        "id",
        "autoDownloadEpisodes",
        "customIcon",
        "filterAllPodcasts",
        "filterAudioVideoType",
        "filterDownloaded",
        "filterFinished",
        "filterNotDownloaded",
        "filterPartiallyPlayed",
        "filterStarred",
        "filterUnplayed",
        "filterHours",
        "playlistName",
        "sortPosition",
        "sortType",
        "uuid",
        "podcastUuids",
        "autoDownloadLimit",
        "syncStatus",
        "wasDeleted",
        "filterDuration",
        "longerThan",
        "shorterThan",
        "manual",
        "playlistUpdateDate",
        "folderUuids",
        "customOrderInsertMode",
        "customOrderLastInsertedUuid"
    ]

    func count(includeDeleted: Bool, dbQueue: PCDBQueue) -> Int {
        var count = 0
        dbQueue.read { db in
            do {
                let query = includeDeleted
                    ? "SELECT COUNT(*) from \(DataManager.playlistsTableName) WHERE \(Self.visiblePlaylistClause)"
                    : "SELECT COUNT(*) from \(DataManager.playlistsTableName) WHERE wasDeleted = 0 AND \(Self.visiblePlaylistClause)"
                let resultSet = try db.executeQuery(query, values: nil)
                defer { resultSet.close() }

                if resultSet.next() {
                    count = resultSet.long(forColumnIndex: 0)
                }
            } catch {
                FileLog.shared.addMessage("PlaylistDataManager.count error: \(error)")
            }
        }
        return count
    }

    func playlistEpisodeCount(clause: PlaylistQueryBuilder.SelectClause, playlist: EpisodeFilter, episodeUuidToAdd: String?, shouldShowArchived: Bool, dbQueue: PCDBQueue) -> Int {
        var count = 0
        dbQueue.read { db in
            do {
                let query = PlaylistQueryBuilder.query(clause: clause, for: playlist, episodeUuidToAdd: episodeUuidToAdd, shouldShowArchived: shouldShowArchived)
                let resultSet = try db.executeQuery(query, values: nil)
                defer { resultSet.close() }

                if resultSet.next() {
                    count = resultSet.long(forColumnIndex: 0)
                }
            } catch {
                FileLog.shared.addMessage("PlaylistDataManager.smartPlaylistEpisodeCount error: \(error)")
            }
        }

        return count
    }

    func playlistContainsPodcast(podcastUuid: String, includeDeleted: Bool = false, dbQueue: PCDBQueue) -> Bool {
        var exists = false
        dbQueue.read { db in
            do {
                let query = PlaylistQueryBuilder.podcastExistsInPlaylistEpisodesQuery(includeDeleted: includeDeleted)
                let resultSet = try db.executeQuery(query, values: [podcastUuid])
                defer { resultSet.close() }

                exists = resultSet.next()
            } catch {
                FileLog.shared.addMessage("PlaylistDataManager.playlistContainsPodcast error: \(error)")
            }
        }

        return exists
    }

    /// Fork: the reserved Inbox playlist is hidden from every UI surface that enumerates
    /// playlists (the Playlists tab, the add-to-playlist chooser, auto-download settings,
    /// CarPlay, Siri, the Watch, the widget, playlist folders — around twenty of them).
    ///
    /// Filtering here rather than at each call site means surfaces upstream adds later are
    /// covered for free. It is safe because sync does NOT enumerate through these APIs: it
    /// uses `allUnsyncedPlaylists`, so the Inbox still syncs normally while being invisible.
    /// `findBy(uuid:)` is likewise unfiltered, so the fork can always fetch the Inbox itself.
    private static let visiblePlaylistClause = "uuid != '\(DataManager.inboxPlaylistUuid)'"

    func allPlaylists(includeDeleted: Bool, dbQueue: PCDBQueue) -> [EpisodeFilter] {
        let query = includeDeleted
            ? "SELECT * from \(DataManager.playlistsTableName) WHERE \(Self.visiblePlaylistClause) ORDER BY sortPosition ASC"
            : "SELECT * from \(DataManager.playlistsTableName) WHERE wasDeleted = 0 AND \(Self.visiblePlaylistClause) ORDER BY sortPosition ASC"
        return allPlaylists(query: query, values: nil, dbQueue: dbQueue)
    }

    func allSmartPlaylists(includeDeleted: Bool, dbQueue: PCDBQueue) -> [EpisodeFilter] {
        let query = includeDeleted
            ? "SELECT * from \(DataManager.playlistsTableName) WHERE manual = 0 AND \(Self.visiblePlaylistClause) ORDER BY sortPosition ASC"
            : "SELECT * from \(DataManager.playlistsTableName) WHERE manual = 0 AND wasDeleted = 0 AND \(Self.visiblePlaylistClause) ORDER BY sortPosition ASC"
        return allPlaylists(query: query, values: nil, dbQueue: dbQueue)
    }

    func allManualPlaylists(includeDeleted: Bool, dbQueue: PCDBQueue) -> [EpisodeFilter] {
        let query = includeDeleted
            ? "SELECT * from \(DataManager.playlistsTableName) WHERE manual = 1 AND \(Self.visiblePlaylistClause) ORDER BY sortPosition ASC"
            : "SELECT * from \(DataManager.playlistsTableName) WHERE manual = 1 AND wasDeleted = 0 AND \(Self.visiblePlaylistClause) ORDER BY sortPosition ASC"
        return allPlaylists(query: query, values: nil, dbQueue: dbQueue)
    }

    func findBy(uuid: String, dbQueue: PCDBQueue) -> EpisodeFilter? {
        var playlist: EpisodeFilter?
        dbQueue.read { db in
            do {
                let resultSet = try db.executeQuery("SELECT * from \(DataManager.playlistsTableName) WHERE uuid = ?", values: [uuid])
                defer { resultSet.close() }

                if resultSet.next() {
                    playlist = self.createPlaylistFrom(resultSet: resultSet)
                }
            } catch {
                FileLog.shared.addMessage("PlaylistDataManager.findBy error: \(error)")
            }
        }

        return playlist
    }

    func deleteDeletedPlaylists(dbQueue: PCDBQueue) {
        dbQueue.write { db in
            do {
                try db.executeUpdate("DELETE FROM \(DataManager.playlistsTableName) WHERE wasDeleted = 1", values: nil)
            } catch {
                FileLog.shared.addMessage("PlaylistDataManager.deleteDeletedPlaylists error: \(error)")
            }
        }
    }

    func allUnsyncedPlaylists(dbQueue: PCDBQueue) -> [EpisodeFilter] {
        allPlaylists(query: "SELECT * from \(DataManager.playlistsTableName) WHERE syncStatus = ? ORDER BY sortPosition ASC", values: [SyncStatus.notSynced.rawValue], dbQueue: dbQueue)
    }

    func playlistContainsEpisode(episodeUuid: String, includeDeleted: Bool, dbQueue: PCDBQueue) -> Bool {
        var exists = false
        dbQueue.read { db in
            do {
                let query: String
                if includeDeleted {
                    query = "SELECT 1 FROM \(DataManager.playlistEpisodeTableName) WHERE episodeUuid = ? AND playlist_uuid IS NOT NULL LIMIT 1"
                } else {
                    query = "SELECT 1 FROM \(DataManager.playlistEpisodeTableName) WHERE episodeUuid = ? AND wasDeleted = 0 AND playlist_uuid IS NOT NULL LIMIT 1"
                }

                let resultSet = try db.executeQuery(query, values: [episodeUuid])
                defer { resultSet.close() }

                exists = resultSet.next()
            } catch {
                FileLog.shared.addMessage("PlaylistDataManager.playlistContainsEpisode error: \(error)")
            }
        }

        return exists
    }

    func manualPlaylistUUIDs(for episodeUUID: String, dbQueue: PCDBQueue) -> [String] {
        var uuids: [String] = []
        dbQueue.read { db in
            do {
                let query = """
                        SELECT playlist_uuid
                        FROM \(DataManager.playlistEpisodeTableName)
                        WHERE episodeUuid = ?
                        GROUP BY playlist_uuid
                    """
                let resultSet = try db.executeQuery(query, values: [episodeUUID])
                defer { resultSet.close() }

                while resultSet.next() {
                    if let uuid = resultSet.string(forColumn: "playlist_uuid") {
                        uuids.append(uuid)
                    }
                }
            } catch {
                FileLog.shared.addMessage("PlaylistDataManager.manualPlaylistUUIDs error: \(error)")
            }
        }
        return uuids
    }

    func updatePosition(playlist: EpisodeFilter, newPosition: Int32, dbQueue: PCDBQueue) {
        playlist.sortPosition = newPosition
        playlist.syncStatus = SyncStatus.notSynced.rawValue
        dbQueue.write { db in
            do {
                try db.executeUpdate("UPDATE \(DataManager.playlistsTableName) SET sortPosition = ?, syncStatus = ?, playlistUpdateDate = ? WHERE uuid = ?", values: [playlist.sortPosition, playlist.syncStatus, Date.now, playlist.uuid])
            } catch {
                FileLog.shared.addMessage("PlaylistDataManager.updatePosition error: \(error)")
            }
        }
    }

    /// Reorder a specific episode within a manual playlist to a new index
    func moveEpisode(_ episodeUuid: String, in playlist: EpisodeFilter, to newIndex: Int, dbQueue: PCDBQueue) {
        dbQueue.write { db in
            do {
                // Load existing order (id + episodeUuid) for this playlist
                let rs = try db.executeQuery("SELECT id, episodeUuid FROM \(DataManager.playlistEpisodeTableName) WHERE playlist_uuid = ? ORDER BY episodePosition ASC", values: [playlist.uuid])
                defer { rs.close() }

                var items = [(id: Int64, uuid: String)]()
                while rs.next() {
                    items.append((id: rs.longLongInt(forColumn: "id"), uuid: DBUtils.nonNilStringFromColumn(resultSet: rs, columnName: "episodeUuid")))
                }

                guard let currentIndex = items.firstIndex(where: { $0.uuid == episodeUuid }) else { return }

                let clampedTargetIndex = newIndex.clamped(to: 0...max(items.count - 1, 0))
                if clampedTargetIndex == currentIndex { return }

                var reordered = items
                let element = reordered.remove(at: currentIndex)
                let clampedIndex = newIndex.clamped(to: 0...reordered.count)
                reordered.insert(element, at: clampedIndex)

                // Persist new positions
                for (index, item) in reordered.enumerated() {
                    try db.executeUpdate("UPDATE \(DataManager.playlistEpisodeTableName) SET episodePosition = ? WHERE id = ?", values: [index, item.id])
                }

                playlist.syncStatus = SyncStatus.notSynced.rawValue
                try db.executeUpdate("UPDATE \(DataManager.playlistsTableName) SET syncStatus = ?, playlistUpdateDate = ? WHERE uuid = ?", values: [playlist.syncStatus, Date.now, playlist.uuid])
            } catch {
                FileLog.shared.addMessage("PlaylistDataManager.moveEpisode error: \(error)")
            }
        }
    }

    /// Set a specific position for an episode within a manual playlist.
    /// This is equivalent to calling moveEpisode to the given index.
    func updateEpisodePosition(_ episodeUuid: String, in playlist: EpisodeFilter, to position: Int32, dbQueue: PCDBQueue) {
        moveEpisode(episodeUuid, in: playlist, to: Int(position), dbQueue: dbQueue)
    }

    /// Delete specific episodes from a manual playlist and reindex remaining items
    func deleteEpisodes(_ episodeUuids: [String], from playlist: EpisodeFilter, dbQueue: PCDBQueue) {
        guard !episodeUuids.isEmpty else { return }
        dbQueue.write { db in
            do {
                let inClause = DataHelper.convertArrayToInString(episodeUuids)
                try db.executeUpdate("DELETE FROM \(DataManager.playlistEpisodeTableName) WHERE playlist_uuid = ? AND episodeUuid IN (\(inClause))", values: [playlist.uuid])
                let removedCount = db.changes
                if removedCount == 0 { return }

                // Reindex remaining
                let rs = try db.executeQuery("SELECT id FROM \(DataManager.playlistEpisodeTableName) WHERE playlist_uuid = ? ORDER BY episodePosition ASC", values: [playlist.uuid])
                defer { rs.close() }
                var ids = [Int64]()
                while rs.next() { ids.append(rs.longLongInt(forColumn: "id")) }
                for (index, id) in ids.enumerated() {
                    try db.executeUpdate("UPDATE \(DataManager.playlistEpisodeTableName) SET episodePosition = ? WHERE id = ?", values: [index, id])
                }

                playlist.syncStatus = SyncStatus.notSynced.rawValue
                try db.executeUpdate("UPDATE \(DataManager.playlistsTableName) SET syncStatus = ?, playlistUpdateDate = ? WHERE uuid = ?", values: [playlist.syncStatus, Date.now, playlist.uuid])
            } catch {
                FileLog.shared.addMessage("PlaylistDataManager.deleteEpisodes error: \(error)")
            }
        }
    }

    /// Just delete episodes from a playlist and nothing more
    func rawDeleteEpisodes(_ episodeUuids: [String], from playlist: EpisodeFilter, dbQueue: PCDBQueue) {
        guard !episodeUuids.isEmpty else { return }
        dbQueue.write { db in
            do {
                let inClause = DataHelper.convertArrayToInString(episodeUuids)
                try db.executeUpdate("DELETE FROM \(DataManager.playlistEpisodeTableName) WHERE playlist_uuid = ? AND episodeUuid IN (\(inClause))", values: [playlist.uuid])
            } catch {
                FileLog.shared.addMessage("PlaylistDataManager.rawDeleteEpisodes error: \(error)")
            }
        }
    }

    /// Delete all playlist-episode relationships for the given playlist
    func deleteAllEpisodes(in playlist: EpisodeFilter, dbQueue: PCDBQueue) {
        dbQueue.write { db in
            do {
                try db.executeUpdate("DELETE FROM \(DataManager.playlistEpisodeTableName) WHERE playlist_uuid = ? OR playlist_id = ?", values: [playlist.uuid, playlist.id])

                let removedCount = db.changes
                if removedCount > 0 {
                    playlist.syncStatus = SyncStatus.notSynced.rawValue
                    try db.executeUpdate("UPDATE \(DataManager.playlistsTableName) SET syncStatus = ?, playlistUpdateDate = ? WHERE uuid = ?", values: [playlist.syncStatus, Date.now, playlist.uuid])
                }
            } catch {
                FileLog.shared.addMessage("PlaylistDataManager.deleteAllEpisodes error: \(error)")
            }
        }
    }

    func save(playlist: EpisodeFilter, dbQueue: PCDBQueue) {
        let isInsert = playlist.id == 0
        if isInsert {
            playlist.id = DBUtils.generateUniqueId()
        }
        playlist.playlistUpdateDate = .now

        if FeatureFlag.grdbQueryInterface.enabled, let grdbQueue = dbQueue as? GRDBQueue {
            // GRDB path using PersistableRecord
            do {
                try grdbQueue.dbPool.write { db in
                    try playlist.save(db)
                }
            } catch {
                FileLog.shared.addMessage("PlaylistDataManager.save error: \(error)")
            }
        } else {
            // Legacy path
            dbQueue.write { db in
                do {
                    if isInsert {
                        try db.executeUpdate("INSERT INTO \(DataManager.playlistsTableName) (\(self.columnNames.joined(separator: ","))) VALUES \(DBUtils.valuesQuestionMarks(amount: self.columnNames.count))", values: self.createValuesFrom(playlist: playlist, updateDate: .now))
                    } else {
                        let setStatement = "\(self.columnNames.joined(separator: " = ?, ")) = ?"
                        try db.executeUpdate("UPDATE \(DataManager.playlistsTableName) SET \(setStatement) WHERE uuid = ?", values: self.createValuesFrom(playlist: playlist, includeUuidForWhere: true, updateDate: .now))
                    }
                } catch {
                    FileLog.shared.addMessage("PlaylistDataManager.save error: \(error)")
                }
            }
        }
    }

    /// Update the playlistUpdateDate for a specific playlist to the given date (defaults to now)
    func updatePlaylistUpdateDate(for playlist: EpisodeFilter, to date: Date, dbQueue: PCDBQueue) {
        dbQueue.write { db in
            do {
                try db.executeUpdate(
                    "UPDATE \(DataManager.playlistsTableName) SET playlistUpdateDate = ? WHERE uuid = ?",
                    values: [date, playlist.uuid]
                )
            } catch {
                FileLog.shared.addMessage("PlaylistDataManager.updatePlaylistUpdateDate error: \(error)")
            }
        }
    }

    func delete(playlist: EpisodeFilter, dbQueue: PCDBQueue) {
        dbQueue.write { db in
            do {
                try db.executeUpdate("DELETE FROM \(DataManager.playlistsTableName) WHERE uuid = ?", values: [playlist.uuid])
                try db.executeUpdate("DELETE FROM \(DataManager.playlistEpisodeTableName) WHERE playlist_uuid = ? OR playlist_id = ?", values: [playlist.uuid, playlist.id])
            } catch {
                FileLog.shared.addMessage("PlaylistDataManager.delete error: \(error)")
            }
        }
    }

    func markAllSynced(dbQueue: PCDBQueue) {
        dbQueue.write { db in
            do {
                try db.executeUpdate("UPDATE \(DataManager.playlistsTableName) SET syncStatus = ? WHERE syncStatus = ?", values: [SyncStatus.synced.rawValue, SyncStatus.notSynced.rawValue])
            } catch {
                FileLog.shared.addMessage("PlaylistDataManager.markAllSynced error: \(error)")
            }
        }
    }

    func markAllUnsynced(dbQueue: PCDBQueue) {
        dbQueue.write { db in
            do {
                try db.executeUpdate("UPDATE \(DataManager.playlistsTableName) SET syncStatus = ? WHERE syncStatus = ?", values: [SyncStatus.notSynced.rawValue, SyncStatus.synced.rawValue])
            } catch {
                FileLog.shared.addMessage("PlaylistDataManager.markAllUnsynced error: \(error)")
            }
        }
    }

    private func allPlaylists(query: String, values: [Any]?, dbQueue: PCDBQueue) -> [EpisodeFilter] {
        var allPlaylists = [EpisodeFilter]()
        dbQueue.read { db in
            do {
                let resultSet = try db.executeQuery(query, values: values)
                defer { resultSet.close() }

                while resultSet.next() {
                    let filter = self.createPlaylistFrom(resultSet: resultSet)
                    allPlaylists.append(filter)
                }
            } catch {
                FileLog.shared.addMessage("PlaylistDataManager.allPlaylists error: \(error)")
            }
        }
        return allPlaylists
    }

    func nextSortPositionForPlaylist(dbQueue: PCDBQueue) -> Int {
        var highestPosition = 0
        dbQueue.read { db in
            do {
                let query = "SELECT MAX(sortPosition) from \(DataManager.playlistsTableName)"
                let resultSet = try db.executeQuery(query, values: nil)
                defer { resultSet.close() }

                if resultSet.next() {
                    highestPosition = resultSet.long(forColumnIndex: 0)
                }
            } catch {
                FileLog.shared.addMessage("PlaylistDataManager.nextSortPositionForPlaylist error: \(error)")
            }
        }

        return highestPosition + 1
    }

    func firstSortPositionForPlaylist(dbQueue: PCDBQueue) -> Int {
        var lowestPosition = 0
        dbQueue.read { db in
            do {
                let query = "SELECT MIN(sortPosition) from \(DataManager.playlistsTableName)"
                let resultSet = try db.executeQuery(query, values: nil)
                defer { resultSet.close() }

                if resultSet.next() {
                    lowestPosition = resultSet.long(forColumnIndex: 0)
                }
            } catch {
                FileLog.shared.addMessage("PlaylistDataManager.firstSortPositionForPlaylist error: \(error)")
            }
        }

        return lowestPosition
    }

    func bumpSortPositionForAllPlaylists(adding value: Int, dbQueue: PCDBQueue) {
        dbQueue.write { db in
            do {
                try db.executeUpdate("""
                    UPDATE \(DataManager.playlistsTableName)
                    SET sortPosition = sortPosition + \(value),
                        syncStatus = ?
                    WHERE wasDeleted = 0
                """, values: [SyncStatus.notSynced.rawValue])
            } catch {
                FileLog.shared.addMessage("PlaylistDataManager.bumpSortPositionForAllPlaylists error: \(error)")
            }
        }
    }

    /// Returns a value indicating whether the episodes were added. If `false`, the playlist is full.
    func add(episodes: [Episode], to playlist: EpisodeFilter, dbQueue: PCDBQueue) -> Bool {
        // If the episodes are empty or already larger than our max size, bail
        if episodes.isEmpty || episodes.count > EpisodeDataManager.Constants.Limits.maxPlaylistItems {
            return false
        }

        // Ensure the filter exists and has a valid id before inserting playlist items
        if playlist.id == 0 {
            save(playlist: playlist, dbQueue: dbQueue)
        }

        // Check that the current episode count + new episodes wouldn't overflow, otherwise bail.
        // Callers should generally
        let playlistCount = playlistEpisodeCount(clause: .allEpisodeCount, playlist: playlist, episodeUuidToAdd: nil, shouldShowArchived: true, dbQueue: dbQueue)
        let isFull = playlistCount + episodes.count > EpisodeDataManager.Constants.Limits.maxPlaylistItems

        if isFull { return false }

        dbQueue.write { db in
            do {
                // Find current max position for this playlist (by playlist_uuid)
                var startPosition: Int32 = 0
                do {
                    let rs = try db.executeQuery("SELECT COALESCE(MAX(episodePosition), 0) FROM \(DataManager.playlistEpisodeTableName) WHERE playlist_uuid = ?", values: [playlist.uuid])
                    defer { rs.close() }
                    if rs.next() {
                        startPosition = rs.int(forColumnIndex: 0)
                    }
                }

                var nextPosition = startPosition

                // Insert each episode, avoiding duplicates for this playlist
                for episode in episodes {
                    // Ensure uniqueness within this playlist
                    try db.executeUpdate("DELETE FROM \(DataManager.playlistEpisodeTableName) WHERE playlist_uuid = ? AND episodeUuid = ?", values: [playlist.uuid, episode.uuid])

                    nextPosition += 1
                    let insertColumns = [
                        "id",
                        "episodePosition",
                        "episodeUuid",
                        "playlist_id",
                        "title",
                        "podcastUuid",
                        "playlist_uuid"
                    ].joined(separator: ",")

                    let values: [Any] = [
                        DBUtils.generateUniqueId(),
                        nextPosition,
                        episode.uuid,
                        playlist.id,
                        episode.displayableTitle(),
                        episode.podcastUuid,
                        playlist.uuid
                    ]

                    try db.executeUpdate("INSERT INTO \(DataManager.playlistEpisodeTableName) (\(insertColumns)) VALUES (?,?,?,?,?,?,?)", values: values)
                }

                // Fork: membership changes must mark the playlist dirty, exactly as
                // deleteEpisodes/moveEpisode already do. Upstream left this to the caller,
                // so an add that forgot it never reached the server. Sync-originated adds
                // set `synced` after calling this, so they are unaffected.
                playlist.syncStatus = SyncStatus.notSynced.rawValue
                try db.executeUpdate("UPDATE \(DataManager.playlistsTableName) SET syncStatus = ?, playlistUpdateDate = ? WHERE uuid = ?", values: [playlist.syncStatus, Date.now, playlist.uuid])
            } catch {
                FileLog.shared.addMessage("EpisodeFilterDataManager.addEpisodes error: \(error)")
            }
        }

        return true
    }

    // MARK: - Fork: smart playlist custom-order overlay

    /// Fork: apply a whole episode order in ONE pass.
    ///
    /// Sync import used to call `moveEpisode` once per episode, and `moveEpisode` reloads the
    /// playlist and rewrites EVERY row's position — so importing an n-member playlist cost
    /// O(n²) updates (a 200-member playlist ≈ 40,000 UPDATEs on any sync where the order
    /// changed). This does it in one transaction: read the rows once, sort, write each row's
    /// position at most once — and write nothing at all if the order already matches.
    ///
    /// Rows the server didn't name keep their relative order, after the ones it did.
    func applyEpisodeOrder(_ orderedUuids: [String], for playlist: EpisodeFilter, dbQueue: PCDBQueue) {
        guard !orderedUuids.isEmpty else { return }

        dbQueue.write { db in
            do {
                let rs = try db.executeQuery("SELECT id, episodeUuid FROM \(DataManager.playlistEpisodeTableName) WHERE playlist_uuid = ? ORDER BY episodePosition ASC", values: [playlist.uuid])
                var rows = [(id: Int64, uuid: String)]()
                while rs.next() {
                    rows.append((id: rs.longLongInt(forColumn: "id"), uuid: DBUtils.nonNilStringFromColumn(resultSet: rs, columnName: "episodeUuid")))
                }
                rs.close()
                guard !rows.isEmpty else { return }

                var rank = [String: Int]()
                for (index, uuid) in orderedUuids.enumerated() where rank[uuid] == nil {
                    rank[uuid] = index
                }

                let sorted = rows.enumerated().sorted { lhs, rhs in
                    switch (rank[lhs.element.uuid], rank[rhs.element.uuid]) {
                    case let (left?, right?): return left < right
                    case (nil, _?): return false // unranked rows sink below ranked ones
                    case (_?, nil): return true
                    case (nil, nil): return lhs.offset < rhs.offset // stable
                    }
                }

                // Already in this order? Then the whole import is a no-op — don't churn the DB.
                guard sorted.map(\.element.uuid) != rows.map(\.uuid) else { return }

                for (position, row) in sorted.enumerated() {
                    try db.executeUpdate("UPDATE \(DataManager.playlistEpisodeTableName) SET episodePosition = ? WHERE id = ?", values: [position, row.element.id])
                }
            } catch {
                FileLog.shared.addMessage("PlaylistDataManager.applyEpisodeOrder error: \(error)")
            }
        }
    }

    /// Fork: just the membership of a manual playlist, as a Set — no `Episode` objects.
    /// This is what the unseen dot reads: fetched ONCE per list load and checked per row.
    /// `playlistEpisodes(for:)` hydrates full Episodes, which is pure waste when all you
    /// want is "is this uuid a member". Hits the (playlist_uuid, episodeUuid) composite index.
    func playlistEpisodeUuids(for playlistUuid: String, dbQueue: PCDBQueue) -> Set<String> {
        var uuids = Set<String>()
        dbQueue.read { db in
            do {
                let rs = try db.executeQuery("SELECT episodeUuid FROM \(DataManager.playlistEpisodeTableName) WHERE playlist_uuid = ?", values: [playlistUuid])
                defer { rs.close() }
                while rs.next() {
                    uuids.insert(DBUtils.nonNilStringFromColumn(resultSet: rs, columnName: "episodeUuid"))
                }
            } catch {
                FileLog.shared.addMessage("PlaylistDataManager.playlistEpisodeUuids error: \(error)")
            }
        }
        return uuids
    }

    /// Fork: membership across SEVERAL playlists at once, as one Set — one query, not one per
    /// playlist. Used for "is this episode in any session", which the old code answered with a
    /// full playlist query per session, on every list load.
    func playlistEpisodeUuids(forPlaylistUuids playlistUuids: [String], dbQueue: PCDBQueue) -> Set<String> {
        guard !playlistUuids.isEmpty else { return [] }
        var uuids = Set<String>()
        dbQueue.read { db in
            do {
                let placeholders = playlistUuids.map { _ in "?" }.joined(separator: ",")
                let rs = try db.executeQuery("SELECT episodeUuid FROM \(DataManager.playlistEpisodeTableName) WHERE playlist_uuid IN (\(placeholders))", values: playlistUuids)
                defer { rs.close() }
                while rs.next() {
                    uuids.insert(DBUtils.nonNilStringFromColumn(resultSet: rs, columnName: "episodeUuid"))
                }
            } catch {
                FileLog.shared.addMessage("PlaylistDataManager.playlistEpisodeUuids(forPlaylistUuids:) error: \(error)")
            }
        }
        return uuids
    }

    /// Fork: how many unarchived members this playlist holds, per podcast — in ONE grouped
    /// query. This is the unseen badge for every podcast at once. The per-podcast version of
    /// this made the whole app sluggish once; the grid recomputes badges on every triage event.
    func playlistEpisodeCountsByPodcast(for playlistUuid: String, dbQueue: PCDBQueue) -> [String: Int] {
        var counts = [String: Int]()
        dbQueue.read { db in
            do {
                let query = """
                SELECT e.podcastUuid AS podcastUuid, COUNT(*) AS total
                FROM \(DataManager.episodeTableName) e
                JOIN \(DataManager.playlistEpisodeTableName) pe
                  ON pe.episodeUuid = e.uuid AND pe.playlist_uuid = ?
                WHERE e.archived = 0
                GROUP BY e.podcastUuid
                """
                let rs = try db.executeQuery(query, values: [playlistUuid])
                defer { rs.close() }
                while rs.next() {
                    counts[DBUtils.nonNilStringFromColumn(resultSet: rs, columnName: "podcastUuid")] = rs.long(forColumn: "total")
                }
            } catch {
                FileLog.shared.addMessage("PlaylistDataManager.playlistEpisodeCountsByPodcast error: \(error)")
            }
        }
        return counts
    }

    /// Episode uuids that have a position row for this playlist — the "Lineup" — in order.
    func positionedEpisodeUuids(for playlist: EpisodeFilter, dbQueue: PCDBQueue) -> [String] {
        var uuids = [String]()
        dbQueue.read { db in
            do {
                let rs = try db.executeQuery("SELECT episodeUuid FROM \(DataManager.playlistEpisodeTableName) WHERE playlist_uuid = ? ORDER BY episodePosition ASC", values: [playlist.uuid])
                defer { rs.close() }
                while rs.next() {
                    uuids.append(DBUtils.nonNilStringFromColumn(resultSet: rs, columnName: "episodeUuid"))
                }
            } catch {
                FileLog.shared.addMessage("PlaylistDataManager.positionedEpisodeUuids error: \(error)")
            }
        }
        return uuids
    }

    /// Replaces the playlist's custom order with the given uuid list (used to seed the
    /// overlay when a smart playlist switches to drag-and-drop sort).
    func setCustomOrder(episodeUuids: [String], for playlist: EpisodeFilter, dbQueue: PCDBQueue) {
        dbQueue.write { db in
            do {
                try db.executeUpdate("DELETE FROM \(DataManager.playlistEpisodeTableName) WHERE playlist_uuid = ?", values: [playlist.uuid])
                try self.insertPositionRows(episodeUuids: episodeUuids, startingAt: 0, for: playlist, db: db)
                try db.executeUpdate("UPDATE \(DataManager.playlistsTableName) SET playlistUpdateDate = ? WHERE uuid = ?", values: [Date.now, playlist.uuid])
            } catch {
                FileLog.shared.addMessage("PlaylistDataManager.setCustomOrder error: \(error)")
            }
        }
    }

    /// Inserts episodes into the playlist's custom order as a block at the insert marker,
    /// honoring the playlist's insert mode and advancing the marker (customOrderLastInsertedUuid).
    /// Episodes already positioned are moved rather than duplicated. Positions are not synced,
    /// so this deliberately leaves syncStatus untouched.
    func insertIntoCustomOrder(episodeUuids: [String], for playlist: EpisodeFilter, dbQueue: PCDBQueue) {
        guard !episodeUuids.isEmpty else { return }

        dbQueue.write { db in
            do {
                let rs = try db.executeQuery("SELECT id, episodeUuid FROM \(DataManager.playlistEpisodeTableName) WHERE playlist_uuid = ? ORDER BY episodePosition ASC", values: [playlist.uuid])
                var existing = [(id: Int64, uuid: String)]()
                while rs.next() {
                    existing.append((id: rs.longLongInt(forColumn: "id"), uuid: DBUtils.nonNilStringFromColumn(resultSet: rs, columnName: "episodeUuid")))
                }
                rs.close()

                // Re-placing an already-positioned episode moves it: drop the old rows first.
                let incoming = Set(episodeUuids)
                let moved = existing.filter { incoming.contains($0.uuid) }
                if !moved.isEmpty {
                    let inClause = DataHelper.convertArrayToInString(moved.map { $0.uuid })
                    try db.executeUpdate("DELETE FROM \(DataManager.playlistEpisodeTableName) WHERE playlist_uuid = ? AND episodeUuid IN (\(inClause))", values: [playlist.uuid])
                    existing.removeAll { incoming.contains($0.uuid) }
                }

                let insertIndex = playlist.insertMarkerIndex(inLineup: existing.map { $0.uuid })

                // Shift rows at/after the insertion point to make room, keeping order stable.
                for (index, item) in existing.enumerated() {
                    let newPosition = index < insertIndex ? index : index + episodeUuids.count
                    try db.executeUpdate("UPDATE \(DataManager.playlistEpisodeTableName) SET episodePosition = ? WHERE id = ?", values: [newPosition, item.id])
                }

                try self.insertPositionRows(episodeUuids: episodeUuids, startingAt: insertIndex, for: playlist, db: db)

                // Advance the marker: after-mode chains below the block, before-mode stays
                // above it (the block grows upward). Pinned modes keep the anchor fresh so
                // switching to a floating mode later continues from the last insert.
                switch playlist.insertMode {
                case .beforeLastInserted:
                    playlist.customOrderLastInsertedUuid = episodeUuids.first ?? ""
                case .top, .bottom, .afterLastInserted:
                    playlist.customOrderLastInsertedUuid = episodeUuids.last ?? ""
                }
                try db.executeUpdate("UPDATE \(DataManager.playlistsTableName) SET customOrderLastInsertedUuid = ?, playlistUpdateDate = ? WHERE uuid = ?", values: [playlist.customOrderLastInsertedUuid, Date.now, playlist.uuid])
            } catch {
                FileLog.shared.addMessage("PlaylistDataManager.insertIntoCustomOrder error: \(error)")
            }
        }
    }

    /// Drops position rows for episodes that are no longer members of the playlist
    /// (its smart rules stopped matching them). Keeps rows for current members so a
    /// hand-made order survives switching sort away and back.
    func pruneCustomOrder(keepingEpisodeUuids: [String], for playlist: EpisodeFilter, dbQueue: PCDBQueue) {
        dbQueue.write { db in
            do {
                let inClause = DataHelper.convertArrayToInString(keepingEpisodeUuids)
                try db.executeUpdate("DELETE FROM \(DataManager.playlistEpisodeTableName) WHERE playlist_uuid = ? AND episodeUuid NOT IN (\(inClause))", values: [playlist.uuid])
                guard db.changes > 0 else { return }

                // Reindex to keep positions contiguous.
                let rs = try db.executeQuery("SELECT id FROM \(DataManager.playlistEpisodeTableName) WHERE playlist_uuid = ? ORDER BY episodePosition ASC", values: [playlist.uuid])
                defer { rs.close() }
                var ids = [Int64]()
                while rs.next() { ids.append(rs.longLongInt(forColumn: "id")) }
                for (index, id) in ids.enumerated() {
                    try db.executeUpdate("UPDATE \(DataManager.playlistEpisodeTableName) SET episodePosition = ? WHERE id = ?", values: [index, id])
                }
            } catch {
                FileLog.shared.addMessage("PlaylistDataManager.pruneCustomOrder error: \(error)")
            }
        }
    }

    /// Inserts fresh position rows for the given uuids starting at the given position,
    /// filling title/podcastUuid from the episode table where available.
    private func insertPositionRows(episodeUuids: [String], startingAt startPosition: Int, for playlist: EpisodeFilter, db: PCDatabase) throws {
        guard !episodeUuids.isEmpty else { return }

        var episodeInfo = [String: (title: String, podcastUuid: String)]()
        let inClause = DataHelper.convertArrayToInString(episodeUuids)
        let rs = try db.executeQuery("SELECT uuid, title, podcastUuid FROM \(DataManager.episodeTableName) WHERE uuid IN (\(inClause))", values: nil)
        while rs.next() {
            let uuid = DBUtils.nonNilStringFromColumn(resultSet: rs, columnName: "uuid")
            episodeInfo[uuid] = (
                title: DBUtils.nonNilStringFromColumn(resultSet: rs, columnName: "title"),
                podcastUuid: DBUtils.nonNilStringFromColumn(resultSet: rs, columnName: "podcastUuid")
            )
        }
        rs.close()

        let insertColumns = ["id", "episodePosition", "episodeUuid", "playlist_id", "title", "podcastUuid", "playlist_uuid"].joined(separator: ",")
        for (offset, episodeUuid) in episodeUuids.enumerated() {
            let info = episodeInfo[episodeUuid]
            let values: [Any] = [
                DBUtils.generateUniqueId(),
                startPosition + offset,
                episodeUuid,
                playlist.id,
                info?.title ?? "",
                info?.podcastUuid ?? "",
                playlist.uuid
            ]
            try db.executeUpdate("INSERT INTO \(DataManager.playlistEpisodeTableName) (\(insertColumns)) VALUES (?,?,?,?,?,?,?)", values: values)
        }
    }

    // MARK: - Conversion

    private func createPlaylistFrom(resultSet rs: PCDBResultSet) -> EpisodeFilter {
        let playlist = EpisodeFilter()
        playlist.id = rs.longLongInt(forColumn: "id")
        playlist.autoDownloadEpisodes = rs.bool(forColumn: "autoDownloadEpisodes")
        playlist.customIcon = rs.int(forColumn: "customIcon")
        playlist.filterAllPodcasts = rs.bool(forColumn: "filterAllPodcasts")
        playlist.filterAudioVideoType = rs.int(forColumn: "filterAudioVideoType")
        playlist.filterDownloaded = rs.bool(forColumn: "filterDownloaded")
        playlist.filterFinished = rs.bool(forColumn: "filterFinished")
        playlist.filterNotDownloaded = rs.bool(forColumn: "filterNotDownloaded")
        playlist.filterPartiallyPlayed = rs.bool(forColumn: "filterPartiallyPlayed")
        playlist.filterStarred = rs.bool(forColumn: "filterStarred")
        playlist.filterUnplayed = rs.bool(forColumn: "filterUnplayed")
        playlist.filterHours = rs.int(forColumn: "filterHours")
        playlist.playlistName = DBUtils.nonNilStringFromColumn(resultSet: rs, columnName: "playlistName")
        playlist.sortPosition = rs.int(forColumn: "sortPosition")
        playlist.sortType = rs.int(forColumn: "sortType")
        playlist.uuid = DBUtils.nonNilStringFromColumn(resultSet: rs, columnName: "uuid")
        playlist.podcastUuids = DBUtils.nonNilStringFromColumn(resultSet: rs, columnName: "podcastUuids")
        playlist.autoDownloadLimit = rs.int(forColumn: "autoDownloadLimit")
        playlist.syncStatus = rs.int(forColumn: "syncStatus")
        playlist.wasDeleted = rs.bool(forColumn: "wasDeleted")
        playlist.filterDuration = rs.bool(forColumn: "filterDuration")
        playlist.longerThan = rs.int(forColumn: "longerThan")
        playlist.shorterThan = rs.int(forColumn: "shorterThan")
        playlist.manual = rs.bool(forColumn: "manual")
        playlist.playlistUpdateDate = DBUtils.convertDate(value: rs.double(forColumn: "playlistUpdateDate"))
        playlist.folderUuids = DBUtils.nonNilStringFromColumn(resultSet: rs, columnName: "folderUuids")
        playlist.customOrderInsertMode = rs.int(forColumn: "customOrderInsertMode")
        playlist.customOrderLastInsertedUuid = DBUtils.nonNilStringFromColumn(resultSet: rs, columnName: "customOrderLastInsertedUuid")

        return playlist
    }

    private func createValuesFrom(playlist: EpisodeFilter, includeUuidForWhere: Bool = false, updateDate: Date? = nil) -> [Any] {
        var values = [Any]()
        values.append(playlist.id)
        values.append(playlist.autoDownloadEpisodes)
        values.append(playlist.customIcon)
        values.append(playlist.filterAllPodcasts)
        values.append(playlist.filterAudioVideoType)
        values.append(playlist.filterDownloaded)
        values.append(playlist.filterFinished)
        values.append(playlist.filterNotDownloaded)
        values.append(playlist.filterPartiallyPlayed)
        values.append(playlist.filterStarred)
        values.append(playlist.filterUnplayed)
        values.append(playlist.filterHours)
        values.append(playlist.playlistName)
        values.append(playlist.sortPosition)
        values.append(playlist.sortType)
        values.append(playlist.uuid)
        values.append(playlist.podcastUuids)
        values.append(playlist.autoDownloadLimit)
        values.append(playlist.syncStatus)
        values.append(playlist.wasDeleted)
        values.append(playlist.filterDuration)
        values.append(playlist.longerThan)
        values.append(playlist.shorterThan)
        values.append(playlist.manual)
        values.append(DBUtils.nullIfNil(value: updateDate ?? playlist.playlistUpdateDate))
        values.append(playlist.folderUuids)
        values.append(playlist.customOrderInsertMode)
        values.append(playlist.customOrderLastInsertedUuid)

        if includeUuidForWhere {
            values.append(playlist.uuid)
        }

        return values
    }
}
