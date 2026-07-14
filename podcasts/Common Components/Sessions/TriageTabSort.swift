import Foundation
import PocketCastsDataModel

/// Fork: a tab's sort order on the Inbox | Session | Episodes strip.
enum TriageTabSortOrder: Int, CaseIterable {
    case custom = 0
    case newestToOldest = 1
    case oldestToNewest = 2

    var title: String {
        switch self {
        case .custom:
            return PlaylistSort.dragAndDrop.description
        case .newestToOldest:
            return PodcastEpisodeSortOrder.newestToOldest.description
        case .oldestToNewest:
            return PodcastEpisodeSortOrder.oldestToNewest.description
        }
    }
}

/// Fork: per-page, per-tab sort for the Episodes | Session strip — each podcast or
/// playlist page remembers a sort per tab. Defaults are the tab's natural order
/// (Episodes newest first, Session the hand-ordered lineup); the control accents
/// whenever anything else is chosen.
///
/// Sort is deliberately a different scope from the search term: it is a durable
/// preference about a particular show ("this one's serial, always oldest-first"),
/// not a transient lens.
enum TriageTabSort {
    enum Tab: String {
        case session, episodes

        var defaultOrder: TriageTabSortOrder {
            self == .session ? .custom : .newestToOldest
        }

        var options: [TriageTabSortOrder] {
            self == .session ? [.custom, .newestToOldest, .oldestToNewest] : [.newestToOldest, .oldestToNewest]
        }
    }

    static func order(_ tab: Tab, pageUuid: String) -> TriageTabSortOrder {
        guard let raw = UserDefaults.standard.object(forKey: key(tab, pageUuid)) as? Int,
              let order = TriageTabSortOrder(rawValue: raw) else { return tab.defaultOrder }
        return order
    }

    static func setOrder(_ order: TriageTabSortOrder, tab: Tab, pageUuid: String) {
        UserDefaults.standard.set(order.rawValue, forKey: key(tab, pageUuid))
    }

    static func isNonDefault(_ tab: Tab, pageUuid: String) -> Bool {
        order(tab, pageUuid: pageUuid) != tab.defaultOrder
    }

    /// Applies the page's chosen order to a tab's naturally-ordered list. The
    /// default keeps the list untouched; date orders sort by publish date.
    static func arrange(_ episodes: [ListEpisode], tab: Tab, pageUuid: String) -> [ListEpisode] {
        let chosen = order(tab, pageUuid: pageUuid)
        guard chosen != tab.defaultOrder else { return episodes }
        switch chosen {
        case .custom:
            return episodes
        case .newestToOldest:
            return episodes.sorted { ($0.episode.publishedDate ?? .distantPast) > ($1.episode.publishedDate ?? .distantPast) }
        case .oldestToNewest:
            return episodes.sorted { ($0.episode.publishedDate ?? .distantPast) < ($1.episode.publishedDate ?? .distantPast) }
        }
    }

    private static func key(_ tab: Tab, _ pageUuid: String) -> String {
        "SJTabSort-\(tab.rawValue)-\(pageUuid)"
    }
}
