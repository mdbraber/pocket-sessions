import PocketCastsDataModel
import XCTest

@testable import podcasts

/// Fork: the podcast page (native `PodcastEpisodeSortOrder` / `PodcastGrouping`, persisted and
/// synced to Pocket Casts servers) and the fork's playlist/session surfaces (`TriageTabSortOrder`
/// / `EpisodeGroupBy`) deliberately keep TWO parallel sort/group vocabularies — the podcast page
/// can't abandon the synced schema without breaking cross-platform sync. These tests fail if the
/// two drift, so "add a sort/group option" can't be silently done in only one of them.
final class SortGroupParityTests: XCTestCase {

    /// Every native podcast sort order must have a `TriageTabSortOrder` equivalent, and the
    /// shared cases must carry the same raw numbering as `PodcastEpisodeSortOrder.Old` (the DB
    /// stores that value; the fork enum reuses it, so they must not diverge).
    func testSortVocabulariesStayAligned() {
        for order in PodcastEpisodeSortOrder.allCases {
            let old = order.old.rawValue
            guard let mirrored = TriageTabSortOrder(rawValue: Int(old)) else {
                XCTFail("PodcastEpisodeSortOrder.\(order) (Old raw \(old)) has no TriageTabSortOrder — add it to the fork enum")
                continue
            }
            XCTAssertEqual(mirrored.title, order.description,
                           "\(order): the fork sort label drifted from the native one")
        }

        // `.custom` (drag order) is the one fork-only sort — it has no native equivalent by design.
        XCTAssertEqual(TriageTabSortOrder.custom.rawValue, 0)
        for sort in TriageTabSortOrder.allCases where sort != .custom {
            XCTAssertNotNil(PodcastEpisodeSortOrder.Old(rawValue: Int32(sort.rawValue)),
                            "TriageTabSortOrder.\(sort) has no PodcastEpisodeSortOrder.Old counterpart")
        }
    }

    /// Every grouping the podcast page offers (bar `unplayed`, which the fork's richer `.playing`
    /// subsumes) must exist in `EpisodeGroupBy`, so a grouping added to the podcast page can't be
    /// missing from playlists.
    func testGroupingVocabulariesStayAligned() {
        let forkTitles = Set(EpisodeGroupBy.allCases.map(\.title))
        for grouping in PodcastGrouping.allCases {
            switch grouping {
            case .none, .season, .starred, .downloaded:
                XCTAssertTrue(forkTitles.contains(grouping.groupingTitle),
                              "PodcastGrouping.\(grouping) has no EpisodeGroupBy equivalent — add it to the fork enum")
            case .unplayed:
                // Subsumed by the finer EpisodeGroupBy.playing (Unplayed / In Progress / Played).
                XCTAssertTrue(forkTitles.contains(EpisodeGroupBy.playing.title))
            }
        }
    }
}

private extension PodcastGrouping {
    /// The user-facing label the podcast page shows for this grouping, for comparison against
    /// the fork's `EpisodeGroupBy.title`.
    var groupingTitle: String {
        switch self {
        case .none: return L10n.inboxGroupNone
        case .downloaded: return L10n.statusDownloaded
        case .unplayed: return L10n.statusUnplayed
        case .season: return L10n.inboxGroupSeason
        case .starred: return L10n.inboxGroupStarred
        }
    }
}
