import PocketCastsDataModel
import XCTest

@testable import podcasts

/// Fork: the Filter Preset query builder — a pure function, so it can be tested exhaustively with
/// no database, no UI and no fixtures.
///
/// The rules that matter most are the ones about *not* constraining: a preset that means "I don't
/// care about this axis" must emit no clause at all. Get that wrong and a filter silently narrows a
/// list without saying so, which is the exact failure this whole design is built to prevent.
final class FilterPresetQueryTests: XCTestCase {
    private let inbox = "INBOX-UUID"
    private let stores = ["store-1", "store-2"]

    private func sql(_ preset: FilterPreset, columns: FilterPresetQuery.Columns = .unaliased) -> String? {
        FilterPresetQuery.predicate(for: preset, sessionStoreUuids: stores, inboxPlaylistUuid: inbox, columns: columns)?.sql
    }

    private func args(_ preset: FilterPreset) -> [Any] {
        FilterPresetQuery.predicate(for: preset, sessionStoreUuids: stores, inboxPlaylistUuid: inbox)?.arguments ?? []
    }

    // MARK: - Not constraining

    /// A rule with three meanings has three states. nil means "don't care" and must emit nothing.
    func testNilRulesConstrainNothing() {
        let preset = FilterPreset(name: "Anything", archived: nil)

        XCTAssertNil(sql(preset), "a preset with no rules must produce NO clause, not a vacuous one")
    }

    /// The default preset ("All Episodes") isn't literally unconstrained — it hides archived.
    func testTheDefaultPresetHidesArchivedAndNothingElse() {
        XCTAssertEqual(sql(FilterPreset(name: "All Episodes")), "archived = 0")
    }

    /// An empty set means "any", so it emits nothing.
    func testAnEmptySetConstrainsNothing() {
        let preset = FilterPreset(name: "x", playingStatus: [], archived: nil)

        XCTAssertNil(sql(preset))
    }

    /// ...and so does a FULL one. This is what makes "every switch on" in the editor read as
    /// "I don't care" rather than as a constraint that happens to match everything.
    func testAFullSetAlsoConstrainsNothing() {
        let preset = FilterPreset(name: "x", playingStatus: Set(PlayingStatusRule.allCases), archived: nil)

        XCTAssertNil(sql(preset))
    }

    // MARK: - Binary rules, both ways

    /// The point of a tri-state: a lone bool could say "starred only" but never "not starred".
    func testStarredRuleWorksInBothDirections() {
        XCTAssertEqual(sql(FilterPreset(name: "x", starred: true, archived: nil)), "keepEpisode = 1")
        XCTAssertEqual(sql(FilterPreset(name: "x", starred: false, archived: nil)), "keepEpisode = 0")
        XCTAssertNil(sql(FilterPreset(name: "x", starred: nil, archived: nil)))
    }

    /// "Archived only" is sayable, which the stock showArchivedEpisodes bool could not do.
    func testArchivedRuleWorksInBothDirections() {
        XCTAssertEqual(sql(FilterPreset(name: "x", archived: true)), "archived = 1")
        XCTAssertEqual(sql(FilterPreset(name: "x", archived: false)), "archived = 0")
        XCTAssertNil(sql(FilterPreset(name: "x", archived: nil)))
    }

    func testMediaTypeRule() {
        XCTAssertEqual(sql(FilterPreset(name: "x", mediaType: .audio, archived: nil)), "fileType LIKE 'audio%'")
        XCTAssertEqual(sql(FilterPreset(name: "x", mediaType: .video, archived: nil)), "fileType LIKE 'video%'")
    }

    // MARK: - Sets: within a set, OR

    func testASingleStatusEmitsNoRedundantParens() {
        let preset = FilterPreset(name: "x", playingStatus: [.inProgress], archived: nil)

        XCTAssertEqual(sql(preset), "playingStatus = \(PlayingStatus.inProgress.rawValue)")
    }

    func testTwoOfThreeStatusesAreORed() {
        let preset = FilterPreset(name: "x", playingStatus: [.unplayed, .inProgress], archived: nil)

        XCTAssertEqual(
            sql(preset),
            "(playingStatus = \(PlayingStatus.notPlayed.rawValue) OR playingStatus = \(PlayingStatus.inProgress.rawValue))",
            "a Bool? could never express this — which is why these axes are sets"
        )
    }

    /// The SQL must not depend on Set iteration order, or the tests (and any query cache) become
    /// nondeterministic.
    func testSetClauseOrderIsStable() {
        let a = FilterPreset(name: "x", playingStatus: [.played, .unplayed], archived: nil)
        let b = FilterPreset(name: "x", playingStatus: [.unplayed, .played], archived: nil)

        XCTAssertEqual(sql(a), sql(b))
    }

    // MARK: - Across axes: AND

    func testAxesAreAndedTogether() {
        let preset = FilterPreset(name: "x", playingStatus: [.inProgress], starred: true, archived: false)
        let clause = try? XCTUnwrap(sql(preset))

        XCTAssertEqual(clause, "archived = 0 AND keepEpisode = 1 AND playingStatus = \(PlayingStatus.inProgress.rawValue)")
    }

    // MARK: - The two membership rules

    /// NOT EXISTS, never NOT IN. `NOT IN` materialises the whole member set and brings NULL
    /// semantics with it; the correlated form is an index seek on (playlist_uuid, episodeUuid).
    func testUnseenUsesACorrelatedExistsAgainstTheInbox() throws {
        let preset = FilterPreset(name: "Unseen", archived: nil, unseen: true)
        let clause = try XCTUnwrap(sql(preset))

        XCTAssertTrue(clause.hasPrefix("EXISTS (SELECT 1 FROM SJPlaylistEpisode pe"), clause)
        XCTAssertTrue(clause.contains("pe.episodeUuid = uuid"), clause)
        XCTAssertFalse(clause.contains(" IN (SELECT"), "must never use IN/NOT IN against a member set")
        XCTAssertEqual(args(preset) as? [String], [inbox])
    }

    func testSeenUsesNotExists() throws {
        let clause = try XCTUnwrap(sql(FilterPreset(name: "Seen", archived: nil, unseen: false)))

        XCTAssertTrue(clause.hasPrefix("NOT EXISTS ("), clause)
    }

    /// inSession is global — it tests EVERY session's store, not the page's.
    func testInSessionTestsEverySessionStore() throws {
        let preset = FilterPreset(name: "x", archived: nil, inSession: true)
        let clause = try XCTUnwrap(sql(preset))

        XCTAssertTrue(clause.contains("pe.playlist_uuid IN (?,?)"), clause)
        XCTAssertEqual(args(preset) as? [String], stores)
    }

    /// With no sessions at all, "in a session" matches nothing and "not in a session" matches
    /// everything. Neither may emit an empty `IN ()`, which is a syntax error.
    func testSessionRulesDegradeCleanlyWhenNoSessionsExist() {
        let inSession = FilterPreset(name: "x", archived: nil, inSession: true)
        let notInSession = FilterPreset(name: "x", archived: nil, inSession: false)

        let inClause = FilterPresetQuery.predicate(for: inSession, sessionStoreUuids: [], inboxPlaylistUuid: inbox)
        let notInClause = FilterPresetQuery.predicate(for: notInSession, sessionStoreUuids: [], inboxPlaylistUuid: inbox)

        XCTAssertEqual(inClause?.sql, "0 = 1", "nothing is in a session when there are none")
        XCTAssertNil(notInClause, "everything is 'not in a session' when there are none — no clause needed")
    }

    // MARK: - Podcast/folder scope

    /// Scope is passed in resolved (folders already expanded), because the builder is pure. A
    /// non-empty set becomes an IN clause.
    func testScopeBecomesAPodcastInClause() throws {
        let preset = FilterPreset(name: "News", archived: nil)
        let result = FilterPresetQuery.predicate(for: preset, sessionStoreUuids: stores, scopePodcastUuids: ["pod-a", "pod-b"])

        XCTAssertEqual(result?.sql, "podcastUuid IN (?,?)")
        XCTAssertEqual(result?.arguments as? [String], ["pod-a", "pod-b"])
    }

    /// The single-podcast-page exemption: nil scope emits no clause even when the preset is scoped.
    func testNilScopeEmitsNoClause() {
        // A preset that IS scoped, but rendered on a surface that ignores scope (nil passed).
        let preset = FilterPreset(name: "News", archived: nil, podcastUuids: ["pod-a"])

        XCTAssertNil(sql(preset), "a single-podcast surface passes nil scope and must emit nothing")
    }

    /// Scope set but resolving to no podcasts (an empty folder) must match nothing, not emit a
    /// syntactically broken empty IN ().
    func testEmptyResolvedScopeMatchesNothing() {
        let preset = FilterPreset(name: "Empty Folder", archived: nil)
        let result = FilterPresetQuery.predicate(for: preset, sessionStoreUuids: stores, scopePodcastUuids: [])

        XCTAssertEqual(result?.sql, "0 = 1")
    }

    // MARK: - Ranges

    func testDurationRangeIsBoundAndInclusiveOfTheFinalMinute() {
        let preset = FilterPreset(name: "Long Reads", archived: nil, filterDuration: true, longerThan: 20, shorterThan: 60)

        XCTAssertEqual(sql(preset), "(duration >= ? AND duration <= ?)")
        XCTAssertEqual(args(preset) as? [Int], [20 * 60, 60 * 60 + 59], "shorter-than 60 must still include 60:59")
    }

    func testReleaseWindowIsBoundAsADate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let preset = FilterPreset(name: "This week", archived: nil, filterHours: 24)

        let result = FilterPresetQuery.predicate(for: preset, sessionStoreUuids: stores, inboxPlaylistUuid: inbox, now: now)

        XCTAssertEqual(result?.sql, "publishedDate > ?")
        XCTAssertEqual(result?.arguments.first as? Date, now.addingTimeInterval(-24 * 3600))
    }

    // MARK: - Column aliasing

    /// In the smart-playlist query, SJEpisode is aliased and SJPodcast is joined — so a bare `uuid`
    /// is ambiguous and the whole statement fails. Every column must be qualified there.
    func testEveryColumnIsQualifiedInTheAliasedContext() throws {
        let preset = FilterPreset(name: "x", playingStatus: [.unplayed], starred: true, archived: false, unseen: true)
        let clause = try XCTUnwrap(sql(preset, columns: .episodeAlias))

        XCTAssertTrue(clause.contains("episode.archived = 0"), clause)
        XCTAssertTrue(clause.contains("episode.keepEpisode = 1"), clause)
        XCTAssertTrue(clause.contains("episode.playingStatus"), clause)
        XCTAssertTrue(clause.contains("pe.episodeUuid = episode.uuid"), clause)
    }

    // MARK: - Sort

    func testSortMapsToOrderBy() {
        let oldest = FilterPreset(name: "x", sortType: PlaylistSort.oldestToNewest.rawValue)
        XCTAssertEqual(FilterPresetQuery.orderBy(for: oldest), "ORDER BY publishedDate ASC, addedDate ASC")

        // A preset has no hand-made order to honour, so drag-and-drop degrades to newest-first.
        let dragged = FilterPreset(name: "x", sortType: PlaylistSort.dragAndDrop.rawValue)
        XCTAssertEqual(FilterPresetQuery.orderBy(for: dragged), "ORDER BY publishedDate DESC, addedDate DESC")
    }
}
