@testable import podcasts
import PocketCastsDataModel
import XCTest

/// Fork: the podcast page's Playlists tab groups its rows by kind, so the grouping has to stay in
/// step with the kinds themselves — a kind missing from `groupOrder` would silently vanish from the
/// tab rather than fail loudly.
final class PodcastPlaylistRowsTests: XCTestCase {
    func testGroupOrderCoversEveryKind() {
        XCTAssertEqual(
            Set(PodcastPlaylistRow.Kind.groupOrder),
            Set(PodcastPlaylistRow.Kind.allCases),
            "A kind outside groupOrder never gets a heading, so its rows never render."
        )
    }

    func testGroupOrderListsEachKindOnce() {
        let order = PodcastPlaylistRow.Kind.groupOrder
        XCTAssertEqual(order.count, Set(order).count)
    }

    func testGroupOrderPutsPlaylistsBeforeSessions() {
        let order = PodcastPlaylistRow.Kind.groupOrder
        let lastPlaylist = order.lastIndex { !$0.isSession }
        let firstSession = order.firstIndex { $0.isSession }
        XCTAssertNotNil(lastPlaylist)
        XCTAssertNotNil(firstSession)
        XCTAssertLessThan(lastPlaylist!, firstSession!)
    }

    func testEveryKindHasItsOwnHeading() {
        let titles = PodcastPlaylistRow.Kind.allCases.map(\.groupTitle)
        XCTAssertFalse(titles.contains(where: \.isEmpty))
        XCTAssertEqual(titles.count, Set(titles).count, "Two kinds sharing a heading would merge into one group.")
    }

    // MARK: - Empty state

    func testEmptyReasonMatchesTheShowFilter() {
        XCTAssertEqual(PodcastPlaylistsEmptyItem.Reason.noPlaylists.title, L10n.podcastPlaylistsEmptyTitle)
        XCTAssertEqual(PodcastPlaylistsEmptyItem.Reason.noSessions.title, L10n.podcastPlaylistsEmptyTitleSessions)
        XCTAssertEqual(PodcastPlaylistsEmptyItem.Reason.neither.title, L10n.podcastPlaylistsEmptyTitleBoth)
    }

    func testEveryEmptyReasonReadsDifferently() {
        let reasons: [PodcastPlaylistsEmptyItem.Reason] = [.noPlaylists, .noSessions, .neither, .noSearchMatches]
        let titles = reasons.map(\.title)
        let messages = reasons.map(\.message)
        XCTAssertEqual(titles.count, Set(titles).count)
        XCTAssertEqual(messages.count, Set(messages).count)
    }

    func testOnlyAGenuinelyEmptyTabOffersAddToPlaylist() {
        XCTAssertTrue(PodcastPlaylistsEmptyItem.Reason.noPlaylists.offersAddToPlaylist)
        XCTAssertTrue(PodcastPlaylistsEmptyItem.Reason.noSessions.offersAddToPlaylist)
        XCTAssertTrue(PodcastPlaylistsEmptyItem.Reason.neither.offersAddToPlaylist)
        // Adding episodes to a playlist would not answer "your search matched nothing".
        XCTAssertFalse(PodcastPlaylistsEmptyItem.Reason.noSearchMatches.offersAddToPlaylist)
    }

    func testEmptyItemsDifferWhenTheirReasonDiffers() {
        let searchMiss = PodcastPlaylistsEmptyItem(reason: .noSearchMatches)
        XCTAssertFalse(searchMiss.handleIsEqual(PodcastPlaylistsEmptyItem(reason: .neither)))
        XCTAssertTrue(searchMiss.handleIsEqual(PodcastPlaylistsEmptyItem(reason: .noSearchMatches)))
    }

    // MARK: - Sorting

    private func row(_ name: String, kind: PodcastPlaylistRow.Kind = .smartPlaylist) -> PodcastPlaylistRow {
        let playlist = EpisodeFilter()
        playlist.playlistName = name
        return PodcastPlaylistRow(playlist: playlist, kind: kind, episodeCount: 1)
    }

    func testSortsByTitleAscendingIgnoringCase() {
        let rows = [row("nieuws"), row("All"), row("Shorts")]
        XCTAssertEqual(PodcastPlaylistsSort.titleAToZ.sorted(rows).map(\.name), ["All", "nieuws", "Shorts"])
    }

    func testSortsByTitleDescending() {
        let rows = [row("nieuws"), row("All"), row("Shorts")]
        XCTAssertEqual(PodcastPlaylistsSort.titleZToA.sorted(rows).map(\.name), ["Shorts", "nieuws", "All"])
    }

    // MARK: - Collapsed groups

    func testCollapsingAGroupIsPerPodcast() {
        let podcastA = UUID().uuidString
        let podcastB = UUID().uuidString
        let group = PodcastPlaylistRow.Kind.smartPlaylist.groupTitle
        defer {
            PodcastPlaylistsCollapsedGroups.toggle(podcastUuid: podcastA, groupTitle: group)
        }

        PodcastPlaylistsCollapsedGroups.toggle(podcastUuid: podcastA, groupTitle: group)
        XCTAssertTrue(PodcastPlaylistsCollapsedGroups.current(podcastUuid: podcastA).contains(group))
        XCTAssertFalse(PodcastPlaylistsCollapsedGroups.current(podcastUuid: podcastB).contains(group))
    }

    func testTogglingTwiceExpandsAgain() {
        let podcastUuid = UUID().uuidString
        let group = PodcastPlaylistRow.Kind.manualPlaylist.groupTitle
        PodcastPlaylistsCollapsedGroups.toggle(podcastUuid: podcastUuid, groupTitle: group)
        PodcastPlaylistsCollapsedGroups.toggle(podcastUuid: podcastUuid, groupTitle: group)
        XCTAssertTrue(PodcastPlaylistsCollapsedGroups.current(podcastUuid: podcastUuid).isEmpty)
    }

    // MARK: - Headers

    func testAHeaderChangingCollapseStateIsNotEqual() {
        let expanded = PodcastPlaylistsGroupHeaderItem(title: "Smart Playlists", collapsed: false)
        let collapsed = PodcastPlaylistsGroupHeaderItem(title: "Smart Playlists", collapsed: true)
        XCTAssertEqual(expanded.differenceIdentifier, collapsed.differenceIdentifier)
        XCTAssertFalse(expanded.handleIsEqual(collapsed), "The chevron has to redraw when the group folds.")
    }

    func testGroupHeadersAreIdentifiedByTitle() {
        let smart = PodcastPlaylistsGroupHeaderItem(title: PodcastPlaylistRow.Kind.smartPlaylist.groupTitle, collapsed: false)
        let manual = PodcastPlaylistsGroupHeaderItem(title: PodcastPlaylistRow.Kind.manualPlaylist.groupTitle, collapsed: false)
        XCTAssertNotEqual(smart.differenceIdentifier, manual.differenceIdentifier)
        XCTAssertFalse(smart.handleIsEqual(manual))
    }
}
