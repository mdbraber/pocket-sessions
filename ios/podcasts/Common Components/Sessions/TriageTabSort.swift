import Foundation
import PocketCastsDataModel

/// Fork: the shared episode-ordering vocabulary — the orders any episode list can be put in.
///
/// Cases are byte-identical to `PodcastEpisodeSortOrder.Old` (Enums.swift) and borrow its
/// labels/semantics, so a stored raw value means the same thing on the podcast page, in a Filter
/// Preset, and here. If you add a case, add the paired one to `PodcastEpisodeSortOrder` too (the
/// podcast page persists/syncs through it). `SortGroupParityTests` guards the alignment.
///
/// There is deliberately no `custom` case. A *browsed* list has no hand order to fall back to, and
/// a *lineup* is hand-ordered by definition — see `LineupReorder`, where these are one-shot
/// re-arrangements rather than a sort you switch on.
enum EpisodeOrder: Int, CaseIterable {
    case newestToOldest = 1
    case oldestToNewest = 2
    case shortestToLongest = 3
    case longestToShortest = 4
    case titleAtoZ = 5
    case titleZtoA = 6
    case serial = 7

    /// Menu order — the same sequence the podcast page's own sort sheet uses.
    static var menuOrder: [EpisodeOrder] {
        [.newestToOldest, .oldestToNewest, .shortestToLongest, .longestToShortest, .titleAtoZ, .titleZtoA, .serial]
    }

    var title: String {
        switch self {
        case .newestToOldest: return PodcastEpisodeSortOrder.newestToOldest.description
        case .oldestToNewest: return PodcastEpisodeSortOrder.oldestToNewest.description
        case .shortestToLongest: return PodcastEpisodeSortOrder.shortestToLongest.description
        case .longestToShortest: return PodcastEpisodeSortOrder.longestToShortest.description
        case .titleAtoZ: return PodcastEpisodeSortOrder.titleAtoZ.description
        case .titleZtoA: return PodcastEpisodeSortOrder.titleZtoA.description
        case .serial: return PodcastEpisodeSortOrder.serial.description
        }
    }

    func sorted<T>(_ items: [T], episode: (T) -> BaseEpisode) -> [T] {
        switch self {
        case .newestToOldest:
            return items.sorted { (episode($0).publishedDate ?? .distantPast) > (episode($1).publishedDate ?? .distantPast) }
        case .oldestToNewest:
            return items.sorted { (episode($0).publishedDate ?? .distantPast) < (episode($1).publishedDate ?? .distantPast) }
        case .shortestToLongest:
            return items.sorted { episode($0).duration < episode($1).duration }
        case .longestToShortest:
            return items.sorted { episode($0).duration > episode($1).duration }
        case .titleAtoZ:
            return items.sorted { Self.sortableTitle(episode($0)) < Self.sortableTitle(episode($1)) }
        case .titleZtoA:
            return items.sorted { Self.sortableTitle(episode($0)) > Self.sortableTitle(episode($1)) }
        case .serial:
            return items.sorted { Self.serialKey(episode($0)) < Self.serialKey(episode($1)) }
        }
    }

    func sorted(_ episodes: [BaseEpisode]) -> [BaseEpisode] {
        sorted(episodes) { $0 }
    }

    /// The native page's serial ordering as a comparable tuple: (season, episode, publishedDate),
    /// with season/episode < 1 pushed to 9999 so they land after every numbered episode — the same
    /// rule as the podcast page's SQL, so unnumbered episodes (and any non-`Episode`, e.g. a
    /// UserEpisode) sort to the end.
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
}

/// Fork: the per-page sort for a BROWSED episode list — a playlist page's Episodes tab. Each page
/// remembers its own order; the default is newest first and the control accents whenever anything
/// else is chosen.
///
/// Sort is deliberately a different scope from the search term: it is a durable preference about a
/// particular show ("this one's serial, always oldest-first"), not a transient lens.
///
/// Only browsed lists appear here. A Session lineup has ONE canonical, saved order and never wears
/// a display sort on top of it — re-arranging one rewrites that order (see `LineupReorder`).
enum TriageTabSort {
    static let defaultOrder: EpisodeOrder = .newestToOldest

    static func order(pageUuid: String) -> EpisodeOrder {
        guard let raw = UserDefaults.standard.object(forKey: key(pageUuid)) as? Int,
              let order = EpisodeOrder(rawValue: raw) else { return defaultOrder }
        return order
    }

    static func setOrder(_ order: EpisodeOrder, pageUuid: String) {
        UserDefaults.standard.set(order.rawValue, forKey: key(pageUuid))
    }

    static func isNonDefault(pageUuid: String) -> Bool {
        order(pageUuid: pageUuid) != defaultOrder
    }

    /// Applies the page's chosen order to a naturally-ordered list. The default keeps the list
    /// untouched (it already arrives newest-first from the query).
    static func arrange(_ episodes: [ListEpisode], pageUuid: String) -> [ListEpisode] {
        let chosen = order(pageUuid: pageUuid)
        guard chosen != defaultOrder else { return episodes }
        return chosen.sorted(episodes) { $0.episode }
    }

    private static func key(_ pageUuid: String) -> String {
        "SJTabSort-episodes-\(pageUuid)"
    }
}
