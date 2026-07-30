import PocketCastsDataModel
import XCTest

@testable import podcasts

/// Fork: the podcast page (native `PodcastEpisodeSortOrder` / `PodcastGrouping`, persisted and
/// synced to Pocket Casts servers) and the fork's playlist/session surfaces (`EpisodeOrder`
/// / `EpisodeGroupBy`) deliberately keep TWO parallel sort/group vocabularies — the podcast page
/// can't abandon the synced schema without breaking cross-platform sync. These tests fail if the
/// two drift, so "add a sort/group option" can't be silently done in only one of them.
final class SortGroupParityTests: XCTestCase {

    /// Every native podcast sort order must have an `EpisodeOrder` equivalent, and the shared
    /// cases must carry the same raw numbering as `PodcastEpisodeSortOrder.Old` (the DB stores
    /// that value; the fork enum reuses it, so they must not diverge).
    func testSortVocabulariesStayAligned() {
        for order in PodcastEpisodeSortOrder.allCases {
            let old = order.old.rawValue
            guard let mirrored = EpisodeOrder(rawValue: Int(old)) else {
                XCTFail("PodcastEpisodeSortOrder.\(order) (Old raw \(old)) has no EpisodeOrder — add it to the fork enum")
                continue
            }
            XCTAssertEqual(mirrored.title, order.description,
                           "\(order): the fork sort label drifted from the native one")
        }

        // The mapping is total in both directions: a lineup has one canonical order, so there is
        // no fork-only "custom" case sitting outside the native vocabulary any more.
        for sort in EpisodeOrder.allCases {
            XCTAssertNotNil(PodcastEpisodeSortOrder.Old(rawValue: Int32(sort.rawValue)),
                            "EpisodeOrder.\(sort) has no PodcastEpisodeSortOrder.Old counterpart")
        }
        XCTAssertEqual(Set(EpisodeOrder.allCases), Set(EpisodeOrder.menuOrder),
                       "EpisodeOrder.menuOrder must offer every case")
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
