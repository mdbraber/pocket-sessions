import Foundation
import PocketCastsDataModel

/// Fork: the one grouping engine behind every "Group By" — the global Inbox and smart
/// playlists share it so the groups (and their limits) come out identical everywhere.
enum EpisodeGroupBy: Int, CaseIterable {
    case none = 0, releaseDate = 1, podcast = 2, folder = 3
    case archived = 4, session = 5, starred = 6, playing = 7, duration = 8

    var title: String {
        switch self {
        case .none: return L10n.inboxGroupNone
        case .releaseDate: return L10n.inboxGroupDate
        case .podcast: return L10n.inboxGroupPodcast
        case .folder: return L10n.inboxGroupFolder
        case .archived: return L10n.inboxGroupArchived
        case .session: return L10n.inboxGroupSession
        case .starred: return L10n.inboxGroupStarred
        case .playing: return L10n.inboxGroupPlaying
        case .duration: return L10n.inboxGroupDuration
        }
    }

    /// Menu order: the useful groupings first, None last.
    static var menuOrder: [EpisodeGroupBy] {
        [.releaseDate, .podcast, .folder, .playing, .duration, .starred, .archived, .session, .none]
    }
}

enum EpisodeGrouper {
    static let limitOptions = [5, 10, 20, 50]

    /// Groups items in display order; a limit > 0 caps every group (and the ungrouped
    /// list) to its first N items. `reversed` flips the order the groups appear in (the
    /// items inside each group keep the list's sort order).
    static func group<T>(_ items: [T], by groupBy: EpisodeGroupBy, limit: Int, reversed: Bool = false, episode: (T) -> BaseEpisode) -> [(title: String?, items: [T])] {
        let capped: ([T]) -> [T] = { limit > 0 ? Array($0.prefix(limit)) : $0 }

        /// Splits into a fixed sequence of named buckets by an index function; drops empties.
        func bucketed(_ titles: [String], index: (BaseEpisode) -> Int) -> [(title: String?, items: [T])] {
            var buckets: [[T]] = Array(repeating: [], count: titles.count)
            for item in items { buckets[index(episode(item))].append(item) }
            return zip(titles, buckets).filter { !$0.1.isEmpty }.map { ($0.0, capped($0.1)) }
        }

        let groups: [(title: String?, items: [T])]

        switch groupBy {
        case .none:
            return items.isEmpty ? [] : [(nil, capped(items))]

        case .podcast:
            var byPodcast = [String: [T]]()
            for item in items {
                let name = (episode(item) as? Episode)?.parentPodcast()?.title ?? ""
                byPodcast[name, default: []].append(item)
            }
            groups = byPodcast.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                .map { ($0, capped(byPodcast[$0] ?? [])) }

        case .folder:
            var byFolder = [String: [T]]()
            var unfoldered = [T]()
            var folderNames = [String: String]()
            for item in items {
                if let folderUuid = (episode(item) as? Episode)?.parentPodcast()?.folderUuid, !folderUuid.isEmpty,
                   let folder = DataManager.sharedManager.findFolder(uuid: folderUuid) {
                    byFolder[folderUuid, default: []].append(item)
                    folderNames[folderUuid] = folder.name
                } else {
                    unfoldered.append(item)
                }
            }
            var folderGroups: [(title: String?, items: [T])] = byFolder.keys
                .sorted { (folderNames[$0] ?? "").localizedCaseInsensitiveCompare(folderNames[$1] ?? "") == .orderedAscending }
                .map { (folderNames[$0], capped(byFolder[$0] ?? [])) }
            if !unfoldered.isEmpty {
                folderGroups.append((L10n.inboxGroupNoFolder, capped(unfoldered)))
            }
            groups = folderGroups

        case .releaseDate:
            let calendar = Calendar.current
            let now = Date()
            // Cumulative age buckets: today, then within a week, a month, a year, else older.
            groups = bucketed([L10n.inboxGroupToday, L10n.inboxGroupLast7Days, L10n.inboxGroupLastMonth, L10n.inboxGroupLastYear, L10n.inboxGroupOlder]) { ep in
                let published = ep.publishedDate ?? Date.distantPast
                if calendar.isDateInToday(published) { return 0 }
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: published), to: calendar.startOfDay(for: now)).day ?? .max
                if days < 0 { return 0 } // future-dated → today
                if days <= 7 { return 1 }
                if days <= 31 { return 2 }
                if days <= 365 { return 3 }
                return 4
            }

        case .duration:
            // Cumulative length buckets: <10, <30, <60, <120, else longer.
            groups = bucketed([L10n.inboxGroupDurationUnder10, L10n.inboxGroupDuration10to30, L10n.inboxGroupDuration30to60, L10n.inboxGroupDuration60to120, L10n.inboxGroupDurationOver120]) { ep in
                let minutes = ep.duration / 60
                if minutes < 10 { return 0 }
                if minutes < 30 { return 1 }
                if minutes < 60 { return 2 }
                if minutes < 120 { return 3 }
                return 4
            }

        case .playing:
            groups = bucketed([L10n.statusUnplayed, L10n.inProgress, L10n.statusPlayed]) { ep in
                if ep.played() { return 2 }
                if ep.inProgress() { return 1 }
                return 0
            }

        case .starred:
            groups = bucketed([L10n.statusStarred, L10n.statusNotStarred]) { $0.keepEpisode ? 0 : 1 }

        case .archived:
            groups = bucketed([L10n.podcastArchived, L10n.filterPresetNotArchived]) { $0.archived ? 0 : 1 }

        case .session:
            let inSession = SessionMembership.shared.inAnySession
            groups = bucketed([L10n.filterPresetInSession, L10n.filterPresetNotInSession]) { inSession.contains($0.uuid) ? 0 : 1 }
        }

        return reversed ? groups.reversed() : groups
    }
}
