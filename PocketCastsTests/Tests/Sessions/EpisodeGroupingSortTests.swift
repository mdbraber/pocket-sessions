import XCTest
import UIKit
@testable import podcasts
@testable import PocketCastsDataModel

/// Fork: parity with the native podcast page's Season grouping and Serial sort, now offered on the
/// playlist/session pages too. These cover the two new cases added to `EpisodeGroupBy` / `EpisodeOrder`.
final class EpisodeGroupingSortTests: XCTestCase {

    private func episode(_ uuid: String, season: Int64, number: Int64, published: Date? = nil) -> Episode {
        let episode = Episode()
        episode.uuid = uuid
        episode.seasonNumber = season
        episode.episodeNumber = number
        episode.publishedDate = published
        return episode
    }

    private func date(_ daysFromNow: Double) -> Date {
        Date(timeIntervalSince1970: 1_000_000 + daysFromNow * 86_400)
    }

    // MARK: - Season grouping

    func testGroupBySeasonBucketsWithNoSeasonLast() {
        let episodes = [
            episode("s2e1", season: 2, number: 1),
            episode("none-a", season: 0, number: 0),
            episode("s1e1", season: 1, number: 1),
            episode("none-b", season: -1, number: -1),
            episode("s1e2", season: 1, number: 2),
        ]

        let groups = EpisodeGrouper.group(episodes, by: .season, limit: 0) { $0 }

        XCTAssertEqual(groups.map(\.title), [
            L10n.podcastSeasonFormat(String(1)),
            L10n.podcastSeasonFormat(String(2)),
            L10n.podcastNoSeason,
        ])
        XCTAssertEqual(groups[0].items.map(\.uuid), ["s1e1", "s1e2"])
        XCTAssertEqual(groups[1].items.map(\.uuid), ["s2e1"])
        // Both the season-0 and season-(-1) episodes collapse into the single No-Season bucket.
        XCTAssertEqual(groups[2].items.map(\.uuid), ["none-a", "none-b"])
    }

    // MARK: - Serial sort

    func testSerialSortOrdersBySeasonThenEpisodeThenNoSeasonLast() {
        let pageUuid = "test-serial-\(UUID().uuidString)"
        TriageTabSort.setOrder(.serial, pageUuid: pageUuid)
        defer { UserDefaults.standard.removeObject(forKey: "SJTabSort-episodes-\(pageUuid)") }

        let items = [
            episode("s2e1", season: 2, number: 1, published: date(1)),
            episode("none", season: 0, number: 0, published: date(2)),
            episode("s1e2", season: 1, number: 2, published: date(3)),
            episode("s1e1", season: 1, number: 1, published: date(4)),
        ].map { ListEpisode(episode: $0, tintColor: .clear) }

        let arranged = TriageTabSort.arrange(items, pageUuid: pageUuid)

        XCTAssertEqual(arranged.map { $0.episode.uuid }, ["s1e1", "s1e2", "s2e1", "none"])
    }
}
