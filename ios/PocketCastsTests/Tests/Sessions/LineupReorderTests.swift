import XCTest
@testable import podcasts
@testable import PocketCastsDataModel

/// Fork: a lineup has ONE canonical, saved order — it is re-arranged, never sorted over. These
/// cover the orders themselves (`EpisodeOrder.sorted`), which every reorder writes into the stored
/// positions, and the "what's playing stays first" rule the re-arrangement has to respect.
final class LineupReorderTests: XCTestCase {

    private func episode(_ uuid: String,
                         title: String = "Title",
                         duration: Double = 3600,
                         published: Date? = nil,
                         season: Int64 = -1,
                         number: Int64 = -1) -> Episode {
        let episode = Episode()
        episode.uuid = uuid
        episode.title = title
        episode.duration = duration
        episode.publishedDate = published
        episode.seasonNumber = season
        episode.episodeNumber = number
        return episode
    }

    private func date(_ day: Double) -> Date {
        Date(timeIntervalSince1970: 1_000_000 + day * 86_400)
    }

    // MARK: - Date orders

    func testNewestToOldestOrdersByPublishDateDescending() {
        let items = [episode("a", published: date(1)), episode("b", published: date(3)), episode("c", published: date(2))]
        XCTAssertEqual(EpisodeOrder.newestToOldest.sorted(items).map(\.uuid), ["b", "c", "a"])
    }

    func testOldestToNewestOrdersByPublishDateAscending() {
        let items = [episode("a", published: date(1)), episode("b", published: date(3)), episode("c", published: date(2))]
        XCTAssertEqual(EpisodeOrder.oldestToNewest.sorted(items).map(\.uuid), ["a", "c", "b"])
    }

    /// An episode with no publish date sorts as the oldest thing there is, rather than landing
    /// somewhere arbitrary in the middle.
    func testMissingPublishDateSortsAsOldest() {
        let items = [episode("dated", published: date(1)), episode("undated")]
        XCTAssertEqual(EpisodeOrder.newestToOldest.sorted(items).map(\.uuid), ["dated", "undated"])
        XCTAssertEqual(EpisodeOrder.oldestToNewest.sorted(items).map(\.uuid), ["undated", "dated"])
    }

    // MARK: - Duration orders

    func testDurationOrders() {
        let items = [episode("long", duration: 7200), episode("short", duration: 600), episode("mid", duration: 3600)]
        XCTAssertEqual(EpisodeOrder.shortestToLongest.sorted(items).map(\.uuid), ["short", "mid", "long"])
        XCTAssertEqual(EpisodeOrder.longestToShortest.sorted(items).map(\.uuid), ["long", "mid", "short"])
    }

    // MARK: - Title orders

    /// Matches the podcast page: a leading "The "/"A "/"An " is ignored, case-insensitively, so
    /// titles file where a reader would look for them.
    func testTitleOrderIgnoresLeadingArticles() {
        let items = [
            episode("beta", title: "Beta"),
            episode("theAlpha", title: "The Alpha"),
            episode("anEcho", title: "An Echo"),
            episode("delta", title: "delta")
        ]
        XCTAssertEqual(EpisodeOrder.titleAtoZ.sorted(items).map(\.uuid), ["theAlpha", "beta", "delta", "anEcho"])
        XCTAssertEqual(EpisodeOrder.titleZtoA.sorted(items).map(\.uuid), ["anEcho", "delta", "beta", "theAlpha"])
    }

    // MARK: - Serial order

    /// Season then episode ascending, with unnumbered episodes after every numbered one — the same
    /// `< 1 → 9999` rule the podcast page's SQL uses.
    func testSerialOrdersBySeasonThenEpisodeWithUnnumberedLast() {
        let items = [
            episode("s2e1", published: date(1), season: 2, number: 1),
            episode("none", published: date(2), season: 0, number: 0),
            episode("s1e2", published: date(3), season: 1, number: 2),
            episode("s1e1", published: date(4), season: 1, number: 1)
        ]
        XCTAssertEqual(EpisodeOrder.serial.sorted(items).map(\.uuid), ["s1e1", "s1e2", "s2e1", "none"])
    }

    // MARK: - Menu shape

    /// Reordering is one-shot, so there is no "custom"/"manual" entry to fall back to — hand-ordered
    /// IS the base state. Every case is offered.
    func testEveryOrderIsOffered() {
        XCTAssertEqual(Set(LineupReorder.options), Set(EpisodeOrder.allCases))
        XCTAssertEqual(LineupReorder.options.count, EpisodeOrder.allCases.count)
    }

    /// A stable sort keeps equal elements in their existing order, so re-applying the same
    /// arrangement can't shuffle a lineup that already satisfies it.
    func testReapplyingAnOrderIsStable() {
        let items = [episode("a", duration: 600), episode("b", duration: 600), episode("c", duration: 600)]
        let once = EpisodeOrder.shortestToLongest.sorted(items)
        let twice = EpisodeOrder.shortestToLongest.sorted(once)
        XCTAssertEqual(once.map(\.uuid), twice.map(\.uuid))
    }
}
