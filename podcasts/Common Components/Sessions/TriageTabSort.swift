import Foundation
import PocketCastsDataModel

/// Fork: a tab's sort order on the Episodes | Session strip.
///
/// The full episode-sort set, so every episode list sorts the same way — the podcast page's stock
/// per-podcast sort already offers all of these (including `serial`, season-then-episode order), and
/// the Session/playlist tabs now match it. `custom` (the hand-ordered lineup) is offered only on the
/// Session tab.
/// Fork: the playlist/session sort vocabulary. Cases 1-7 are byte-identical to
/// `PodcastEpisodeSortOrder.Old` (Enums.swift) and this borrows its labels/semantics;
/// `.custom` (0) is the fork-only drag order. If you add a sort here, add the paired
/// case to PodcastEpisodeSortOrder too (the podcast page persists/syncs through it).
/// SortGroupParityTests guards the alignment.
enum TriageTabSortOrder: Int, CaseIterable {
    case custom = 0
    case newestToOldest = 1
    case oldestToNewest = 2
    case shortestToLongest = 3
    case longestToShortest = 4
    case titleAtoZ = 5
    case titleZtoA = 6
    case serial = 7

    var title: String {
        switch self {
        case .custom: return PlaylistSort.dragAndDrop.description
        case .newestToOldest: return PodcastEpisodeSortOrder.newestToOldest.description
        case .oldestToNewest: return PodcastEpisodeSortOrder.oldestToNewest.description
        case .shortestToLongest: return PodcastEpisodeSortOrder.shortestToLongest.description
        case .longestToShortest: return PodcastEpisodeSortOrder.longestToShortest.description
        case .titleAtoZ: return PodcastEpisodeSortOrder.titleAtoZ.description
        case .titleZtoA: return PodcastEpisodeSortOrder.titleZtoA.description
        case .serial: return PodcastEpisodeSortOrder.serial.description
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
            // The full set; the Session tab additionally offers its hand-ordered `custom`.
            let sorts: [TriageTabSortOrder] = [.newestToOldest, .oldestToNewest, .shortestToLongest, .longestToShortest, .titleAtoZ, .titleZtoA, .serial]
            return self == .session ? [.custom] + sorts : sorts
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
        case .shortestToLongest:
            return episodes.sorted { $0.episode.duration < $1.episode.duration }
        case .longestToShortest:
            return episodes.sorted { $0.episode.duration > $1.episode.duration }
        case .titleAtoZ:
            return episodes.sorted { sortableTitle($0.episode) < sortableTitle($1.episode) }
        case .titleZtoA:
            return episodes.sorted { sortableTitle($0.episode) > sortableTitle($1.episode) }
        case .serial:
            // Season then episode number ascending, tie-broken by publish date — the same
            // `<1 → 9999` rule as the podcast page's SQL, so unnumbered episodes (and any
            // non-`Episode`, e.g. a UserEpisode) sort to the end.
            return episodes.sorted { serialKey($0.episode) < serialKey($1.episode) }
        }
    }

    /// The native page's serial ordering as a comparable tuple: (season, episode, publishedDate),
    /// with season/episode < 1 pushed to 9999 so they land after every numbered episode.
    private static func serialKey(_ episode: BaseEpisode) -> (Int64, Int64, Date) {
        let season = (episode as? Episode)?.seasonNumber ?? -1
        let number = (episode as? Episode)?.episodeNumber ?? -1
        return (season < 1 ? 9999 : season, number < 1 ? 9999 : number, episode.publishedDate ?? .distantPast)
    }

    /// Mirrors the podcast page's title sort: ignore a leading "The "/"A "/"An ", case-insensitively.
    private static func sortableTitle(_ episode: BaseEpisode) -> String {
        let title = episode.displayableTitle().uppercased()
        for prefix in ["THE ", "A ", "AN "] where title.hasPrefix(prefix) {
            return String(title.dropFirst(prefix.count))
        }
        return title
    }

    private static func key(_ tab: Tab, _ pageUuid: String) -> String {
        "SJTabSort-\(tab.rawValue)-\(pageUuid)"
    }
}
