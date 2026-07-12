import Foundation
import PocketCastsDataModel

/// Fork: the one grouping engine behind every "Group By" — the global Inbox and smart
/// playlists share it so the groups (and their limits) come out identical everywhere.
enum EpisodeGroupBy: Int, CaseIterable {
    case none = 0, releaseDate = 1, podcast = 2, folder = 3

    var title: String {
        switch self {
        case .none: return L10n.inboxGroupNone
        case .releaseDate: return L10n.inboxGroupDate
        case .podcast: return L10n.inboxGroupPodcast
        case .folder: return L10n.inboxGroupFolder
        }
    }

    /// Menu order: the useful groupings first, None last.
    static var menuOrder: [EpisodeGroupBy] { [.releaseDate, .podcast, .folder, .none] }
}

enum EpisodeGrouper {
    static let limitOptions = [3, 5, 10, 20]

    /// Groups items in display order; a limit > 0 caps every group (and the ungrouped
    /// list) to its first N items.
    static func group<T>(_ items: [T], by groupBy: EpisodeGroupBy, limit: Int, episode: (T) -> BaseEpisode) -> [(title: String?, items: [T])] {
        let capped: ([T]) -> [T] = { limit > 0 ? Array($0.prefix(limit)) : $0 }

        switch groupBy {
        case .none:
            return items.isEmpty ? [] : [(nil, capped(items))]

        case .podcast:
            var byPodcast = [String: [T]]()
            for item in items {
                let name = (episode(item) as? Episode)?.parentPodcast()?.title ?? ""
                byPodcast[name, default: []].append(item)
            }
            return byPodcast.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
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
            var groups: [(title: String?, items: [T])] = byFolder.keys
                .sorted { (folderNames[$0] ?? "").localizedCaseInsensitiveCompare(folderNames[$1] ?? "") == .orderedAscending }
                .map { (folderNames[$0], capped(byFolder[$0] ?? [])) }
            if !unfoldered.isEmpty {
                groups.append((L10n.inboxGroupNoFolder, capped(unfoldered)))
            }
            return groups

        case .releaseDate:
            let calendar = Calendar.current
            let now = Date()
            var buckets: [(String, [T])] = [
                (L10n.inboxGroupToday, []), (L10n.inboxGroupYesterday, []), (L10n.inboxGroupThisWeek, []),
                (L10n.inboxGroupThisMonth, []), (L10n.inboxGroupOlder, [])
            ]
            for item in items {
                let published = episode(item).publishedDate ?? Date.distantPast
                let index: Int
                if calendar.isDateInToday(published) {
                    index = 0
                } else if calendar.isDateInYesterday(published) {
                    index = 1
                } else if calendar.isDate(published, equalTo: now, toGranularity: .weekOfYear) {
                    index = 2
                } else if calendar.isDate(published, equalTo: now, toGranularity: .month) {
                    index = 3
                } else {
                    index = 4
                }
                buckets[index].1.append(item)
            }
            return buckets.filter { !$0.1.isEmpty }.map { ($0.0, capped($0.1)) }
        }
    }
}
