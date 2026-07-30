import XCTest
@testable import podcasts
@testable import PocketCastsDataModel

/// Fork: naming a new playlist after the route the user took to create it — adding a podcast's
/// Season 2 group offers "Serial - Season 2" instead of the generic default.
final class PlaylistNameSuggestionTests: XCTestCase {

    func testJoinsThePartsOfARoute() {
        XCTAssertEqual(PlaylistNameSuggestion.joined("Serial", "Season 2"), "Serial - Season 2")
    }

    /// Only one part known (a podcast page with no grouping) still names the playlist.
    func testASinglePartIsEnough() {
        XCTAssertEqual(PlaylistNameSuggestion.joined("Serial"), "Serial")
        XCTAssertEqual(PlaylistNameSuggestion.joined(nil, "Season 2"), "Season 2")
    }

    /// Missing and blank parts drop out rather than leaving stray separators like "Serial - ".
    func testSkipsMissingAndBlankParts() {
        XCTAssertEqual(PlaylistNameSuggestion.joined("Serial", nil), "Serial")
        XCTAssertEqual(PlaylistNameSuggestion.joined("Serial", "   "), "Serial")
        XCTAssertEqual(PlaylistNameSuggestion.joined("  Serial  ", "Season 2"), "Serial - Season 2")
    }

    /// Nothing to suggest is nil, not "" — the caller must pass "no suggestion" so the name field
    /// keeps its own default rather than opening blank.
    func testNothingToSuggestIsNil() {
        XCTAssertNil(PlaylistNameSuggestion.joined(nil, nil))
        XCTAssertNil(PlaylistNameSuggestion.joined(""))
        XCTAssertNil(PlaylistNameSuggestion.joined("  "))
    }

    // MARK: - Selections

    private func episode(podcastUuid: String) -> Episode {
        let episode = Episode()
        episode.uuid = UUID().uuidString
        episode.podcastUuid = podcastUuid
        return episode
    }

    /// A selection spanning several podcasts has no single name to inherit — guessing from
    /// whichever episode happened to be first would be worse than suggesting nothing.
    func testAMixedSelectionSuggestsNothing() {
        let episodes = [episode(podcastUuid: "a"), episode(podcastUuid: "b")]
        XCTAssertNil(PlaylistNameSuggestion.forEpisodes(episodes))
    }

    func testAnEmptySelectionSuggestsNothing() {
        XCTAssertNil(PlaylistNameSuggestion.forEpisodes([]))
    }

    /// A selection from ONE podcast has a lineage worth borrowing. (Resolving the podcast's title
    /// needs the database, so this pins the single-podcast branch rather than the resolved name.)
    func testASinglePodcastSelectionIsEligible() {
        let episodes = [episode(podcastUuid: "same"), episode(podcastUuid: "same")]
        XCTAssertNil(PlaylistNameSuggestion.forEpisodes(episodes),
                     "no podcast row exists for this uuid, so there is no title to borrow")
    }
}
