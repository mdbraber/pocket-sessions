import Foundation
import PocketCastsDataModel

/// Fork: turns a `FilterPreset` into SQL. A **pure function** — no database, no singletons, no page
/// context — which is what makes it testable without a UI or a fixture.
///
/// The page owns its own base predicate (`podcast_id = X`, or a smart playlist's rules) and ANDs
/// this fragment onto it. The preset knows nothing about the page, which is what makes it portable
/// across podcast pages and smart-playlist pages alike.
enum FilterPresetQuery {

    /// How the surrounding query names the episode table.
    ///
    /// A mechanical detail, not page context — but unavoidable. The podcast page runs
    /// `SELECT * FROM SJEpisode WHERE …` (unaliased), while the smart-playlist builder runs
    /// `SELECT episode.* FROM SJEpisode episode LEFT JOIN SJPodcast podcast …`. In the second, bare
    /// `uuid` is **ambiguous** — `SJPodcast` has one too — so the correlated subqueries below would
    /// fail outright. Hence a prefix.
    enum Columns: String {
        /// `SELECT * FROM SJEpisode WHERE …` — bare column names.
        case unaliased = ""
        /// `SELECT episode.* FROM SJEpisode episode …` — qualified as `episode.`.
        case episodeAlias = "episode."
    }

    /// The preset as a WHERE fragment plus its bound arguments.
    ///
    /// - Parameter sessionStoreUuids: every session's store playlist. Passed in rather than read
    ///   from `SessionStore` so this stays a pure function.
    /// - Returns: nil when the preset constrains nothing — the caller then adds no clause at all,
    ///   rather than ANDing on a vacuous `(1 = 1)`.
    static func predicate(
        for preset: FilterPreset,
        sessionStoreUuids: [String],
        inboxPlaylistUuid: String = DataManager.inboxPlaylistUuid,
        columns: Columns = .unaliased,
        now: Date = Date()
    ) -> (sql: String, arguments: [Any])? {
        let e = columns.rawValue
        var blocks = [String]()
        var arguments = [Any]()

        // --- Column rules: a Bool? (nil = any), or a Set ORed together ---

        if let clause = rule(preset.archived, is: "\(e)archived = 1", isNot: "\(e)archived = 0") {
            blocks.append(clause)
        }
        if let clause = rule(preset.starred, is: "\(e)keepEpisode = 1", isNot: "\(e)keepEpisode = 0") {
            blocks.append(clause)
        }
        switch preset.mediaType {
        case .audio: blocks.append("\(e)fileType LIKE 'audio%'")
        case .video: blocks.append("\(e)fileType LIKE 'video%'")
        case nil: break
        }

        if let clause = anyOf(preset.playingStatus, of: PlayingStatusRule.allCases, sql: {
            switch $0 {
            case .unplayed: "\(e)playingStatus = \(PlayingStatus.notPlayed.rawValue)"
            case .inProgress: "\(e)playingStatus = \(PlayingStatus.inProgress.rawValue)"
            case .played: "\(e)playingStatus = \(PlayingStatus.completed.rawValue)"
            }
        }) {
            blocks.append(clause)
        }

        if let clause = anyOf(preset.downloadStatus, of: DownloadStatusRule.allCases, sql: {
            switch $0 {
            case .downloaded:
                "\(e)episodeStatus = \(DownloadStatus.downloaded.rawValue)"
            case .downloading:
                "\(e)episodeStatus IN (\(DownloadStatus.queued.rawValue), \(DownloadStatus.downloading.rawValue))"
            case .notDownloaded:
                "\(e)episodeStatus IN (\(DownloadStatus.notDownloaded.rawValue), \(DownloadStatus.downloadFailed.rawValue), \(DownloadStatus.waitingForWifi.rawValue))"
            }
        }) {
            blocks.append(clause)
        }

        // --- Ranges ---

        if preset.filterDuration {
            // The +59 mirrors the stock builder: "shorter than 20 minutes" should include 20:59,
            // not stop dead at 20:00.
            blocks.append("(\(e)duration >= ? AND \(e)duration <= ?)")
            arguments.append(Int(preset.longerThan) * 60)
            arguments.append(Int(preset.shorterThan) * 60 + 59)
        }

        if preset.filterHours > 0 {
            blocks.append("\(e)publishedDate > ?")
            arguments.append(now.addingTimeInterval(-TimeInterval(preset.filterHours) * 3600))
        }

        // --- The two membership rules ---
        //
        // Correlated EXISTS / NOT EXISTS, never `IN` / `NOT IN`. The composite index
        // (playlist_uuid, episodeUuid) makes these index seeks; `NOT IN` would materialise the
        // whole member set and drag NULL semantics in with it.

        if let clause = membership(preset.unseen, in: [inboxPlaylistUuid], episodeUuid: "\(e)uuid", arguments: &arguments) {
            blocks.append(clause)
        }
        if let clause = membership(preset.inSession, in: sessionStoreUuids, episodeUuid: "\(e)uuid", arguments: &arguments) {
            blocks.append(clause)
        }

        guard !blocks.isEmpty else { return nil }
        return (blocks.joined(separator: " AND "), arguments)
    }

    /// `ORDER BY` for a preset. Separate from the predicate because the two compose at different
    /// points in the surrounding query.
    static func orderBy(for preset: FilterPreset, columns: Columns = .unaliased) -> String {
        let e = columns.rawValue
        switch PlaylistSort(rawValue: preset.sortType) {
        case .oldestToNewest:
            return "ORDER BY \(e)publishedDate ASC, \(e)addedDate ASC"
        case .shortestToLongest:
            return "ORDER BY \(e)duration ASC, \(e)addedDate ASC"
        case .longestToShortest:
            return "ORDER BY \(e)duration DESC, \(e)addedDate DESC"
        case .newestToOldest, .dragAndDrop, nil:
            // A preset has no hand-made order to honour, so drag-and-drop degrades to newest-first.
            return "ORDER BY \(e)publishedDate DESC, \(e)addedDate DESC"
        }
    }

    // MARK: - Rule helpers

    /// A binary rule: nil constrains nothing.
    private static func rule(_ rule: Rule, is positive: String, isNot negative: String) -> String? {
        guard let rule else { return nil }
        return rule ? positive : negative
    }

    /// A set rule: the chosen options ORed. Empty constrains nothing — and so does a full set,
    /// which is what makes "every switch on" in the editor mean "I don't care" rather than
    /// accidentally narrowing to everything-at-once.
    private static func anyOf<T: Hashable>(_ chosen: Set<T>, of all: [T], sql: (T) -> String) -> String? {
        guard !chosen.isEmpty, chosen.count < all.count else { return nil }
        let clauses = all.filter(chosen.contains).map(sql) // `all`'s order, so the SQL is stable
        return clauses.count == 1 ? clauses[0] : "(\(clauses.joined(separator: " OR ")))"
    }

    /// A membership rule (`unseen`, `inSession`) as a correlated subquery. nil constrains nothing.
    private static func membership(
        _ rule: Rule,
        in playlistUuids: [String],
        episodeUuid: String,
        arguments: inout [Any]
    ) -> String? {
        guard let rule else { return nil }

        // Nothing to test against: "in one of them" matches nothing, "not in any of them" matches
        // everything. Say so directly rather than emitting an empty `IN ()`.
        guard !playlistUuids.isEmpty else {
            return rule ? "0 = 1" : nil
        }

        let placeholders = playlistUuids.map { _ in "?" }.joined(separator: ",")
        arguments.append(contentsOf: playlistUuids)

        let subquery = """
        SELECT 1 FROM \(DataManager.playlistEpisodeTableName) pe \
        WHERE pe.playlist_uuid IN (\(placeholders)) AND pe.episodeUuid = \(episodeUuid)
        """
        return rule ? "EXISTS (\(subquery))" : "NOT EXISTS (\(subquery))"
    }
}
