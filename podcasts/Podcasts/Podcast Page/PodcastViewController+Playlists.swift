import UIKit
import SwiftUI
import PocketCastsDataModel
import DifferenceKit

/// Fork: one row of the podcast page's Playlists tab, so playlist rows can ride the same
/// `episodeInfo` list every other tab uses rather than needing a parallel data source.
final class PodcastPlaylistListItem: ListItem {
    let row: PodcastPlaylistRow

    init(row: PodcastPlaylistRow) {
        self.row = row
    }

    override var differenceIdentifier: String { row.uuid }

    override func handleIsEqual(_ otherItem: ListItem) -> Bool {
        guard let other = otherItem as? PodcastPlaylistListItem else { return false }
        return other.row.uuid == row.uuid
            && other.row.episodeCount == row.episodeCount
            && other.row.name == row.name
    }
}

/// A "Smart Playlists" / "Podcast Sessions" / … heading above the rows of one kind. Its own type
/// rather than a `ListHeader` because the episode headers carry a group actions menu that means
/// nothing above a list of lists — everything else, including the collapse chevron, matches them.
final class PodcastPlaylistsGroupHeaderItem: ListItem {
    let title: String
    let collapsed: Bool

    init(title: String, collapsed: Bool) {
        self.title = title
        self.collapsed = collapsed
    }

    override var differenceIdentifier: String { "podcast-playlists-group-\(title)" }
    override func handleIsEqual(_ otherItem: ListItem) -> Bool {
        guard let other = otherItem as? PodcastPlaylistsGroupHeaderItem else { return false }
        return other.title == title && other.collapsed == collapsed
    }
}

/// Marks "this podcast is in nothing" so the tab can offer a way out of that state. Why it is empty
/// decides what it says: the Show filter narrows what was looked at, and a search narrows it
/// further — claiming "not in any playlists" when the user simply mistyped would be a lie.
final class PodcastPlaylistsEmptyItem: ListItem {
    enum Reason {
        case noPlaylists
        case noSessions
        case neither
        case noSearchMatches

        var title: String {
            switch self {
            case .noPlaylists: return L10n.podcastPlaylistsEmptyTitle
            case .noSessions: return L10n.podcastPlaylistsEmptyTitleSessions
            case .neither: return L10n.podcastPlaylistsEmptyTitleBoth
            case .noSearchMatches: return L10n.podcastPlaylistsSearchNoResults
            }
        }

        var message: String {
            switch self {
            case .noPlaylists: return L10n.podcastPlaylistsEmptyMessage
            case .noSessions: return L10n.podcastPlaylistsEmptyMessageSessions
            case .neither: return L10n.podcastPlaylistsEmptyMessageBoth
            case .noSearchMatches: return L10n.podcastPlaylistsSearchNoResultsMessage
            }
        }

        /// Only a genuinely empty tab offers the way out — "Add to Playlist" would not answer a
        /// search that matched nothing.
        var offersAddToPlaylist: Bool { self != .noSearchMatches }
    }

    let reason: Reason

    init(reason: Reason) {
        self.reason = reason
    }

    override var differenceIdentifier: String { "podcast-playlists-empty" }
    override func handleIsEqual(_ otherItem: ListItem) -> Bool {
        (otherItem as? PodcastPlaylistsEmptyItem)?.reason == reason
    }
}

/// The playlist detail screen wants a creator delegate; opening an EXISTING playlist from here
/// never creates one, so this only has to exist.
extension PodcastViewController: FilterCreatedDelegate {
    func filterCreated(newFilter: EpisodeFilter) {}

    var presentingPlaylistDetail: Bool {
        get { false }
        set {}
    }
}

extension PodcastViewController {
    /// Fork: builds the Playlists tab. Counting reads every list's episodes — a smart playlist's
    /// membership is a query, not a table — so it happens off the main thread.
    func loadPodcastPlaylists(podcast: Podcast, animated: Bool) {
        let searchHeader = ListHeader(headerTitle: L10n.search, isSectionHeader: true, sectionNumber: -1)
        let searchTerm = (searchController?.searchTextField?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var rows = PodcastPlaylistRows.current(forPodcast: podcast.uuid)
            if !searchTerm.isEmpty {
                rows = rows.filter { $0.name.localizedCaseInsensitiveContains(searchTerm) }
            }
            rows = PodcastPlaylistsSort.current.sorted(rows)

            DispatchQueue.main.async {
                guard let self, self.showingPodcastPlaylists else { return }
                self.podcastPlaylistRows = rows

                let items: [ListItem] = rows.isEmpty
                    ? [PodcastPlaylistsEmptyItem(reason: Self.emptyReason(searching: !searchTerm.isEmpty))]
                    : Self.groupedItems(from: rows, podcastUuid: podcast.uuid)

                let finalData = [
                    ArraySection<String, ListItem>(model: searchHeader.headerTitle, elements: [searchHeader]),
                    ArraySection<String, ListItem>(model: "playlists", elements: items)
                ]
                self.applyPodcastPlaylists(finalData, animated: animated)
            }
        }
    }

    /// Rows under one heading per kind, in `Kind.groupOrder`. Kinds with nothing in them are left
    /// out entirely rather than shown as an empty heading; a folded-away group keeps its heading and
    /// drops its rows, exactly as a collapsed episode group does.
    private static func groupedItems(from rows: [PodcastPlaylistRow], podcastUuid: String) -> [ListItem] {
        guard PodcastPlaylistsGrouping.current == .type else {
            return rows.map { PodcastPlaylistListItem(row: $0) }
        }
        let collapsed = PodcastPlaylistsCollapsedGroups.current(podcastUuid: podcastUuid)
        var items = [ListItem]()
        for kind in PodcastPlaylistRow.Kind.groupOrder {
            let group = rows.filter { $0.kind == kind }
            guard !group.isEmpty else { continue }
            let isCollapsed = collapsed.contains(kind.groupTitle)
            items.append(PodcastPlaylistsGroupHeaderItem(title: kind.groupTitle, collapsed: isCollapsed))
            guard !isCollapsed else { continue }
            items.append(contentsOf: group.map { PodcastPlaylistListItem(row: $0) })
        }
        return items
    }

    /// Folds one group away (or back), then rebuilds the tab.
    func togglePodcastPlaylistGroup(_ item: PodcastPlaylistsGroupHeaderItem) {
        guard let podcast else { return }
        PodcastPlaylistsCollapsedGroups.toggle(podcastUuid: podcast.uuid, groupTitle: item.title)
        loadPodcastPlaylists(podcast: podcast, animated: true)
    }

    /// What an empty tab is actually saying — see `PodcastPlaylistsEmptyItem.Reason`.
    private static func emptyReason(searching: Bool) -> PodcastPlaylistsEmptyItem.Reason {
        if searching { return .noSearchMatches }
        switch PodcastPlaylistsShow.current {
        case .playlists: return .noPlaylists
        case .sessions: return .noSessions
        case .both: return .neither
        }
    }

    private func applyPodcastPlaylists(_ data: [ArraySection<String, ListItem>], animated: Bool) {
        // The other tabs' load paths end with this; without it the counts line above the list keeps
        // whatever the Episodes tab left there ("35 episodes • All Episodes"), which describes a
        // list this tab isn't showing.
        defer { searchController?.episodesDidReload() }
        if animated {
            let changeSet = StagedChangeset(source: episodeInfo, target: data)
            do {
                try SJCommonUtils.catchException {
                    self.episodesTable.reload(using: changeSet, with: .none) { self.episodeInfo = $0 }
                }
            } catch {
                episodeInfo = data
                reloadData()
            }
        } else {
            episodeInfo = data
            reloadData()
        }
    }

    /// The row is the Playlists screen's own row — same artwork and title — with two substitutions:
    /// the count is THIS podcast's episodes rather than the list's total, and the subtitle names
    /// the kind of list instead of the generic "Smart Playlist".
    func podcastPlaylistCell(for item: PodcastPlaylistListItem, isLastRow: Bool, at indexPath: IndexPath) -> UITableViewCell {
        let cell = episodesTable.dequeueReusableCell(withIdentifier: PlaylistCell.reuseIdentifier, for: indexPath) as! PlaylistCell
        // PlaylistCell is built for the Playlists screen, whose rows sit on primaryUi01. The podcast
        // page's rows are primaryUi02 — without this the tab reads as a lighter patch than every
        // other tab on the same screen.
        cell.style = .primaryUi02
        cell.updateColor()
        cell.configure(
            cellType: .count,
            playlist: item.row.playlist,
            isLastRow: isLastRow,
            analyticsSource: "podcast_playlists_tab",
            overrideCount: item.row.episodeCount,
            // The group heading above already names the kind; repeating it on every row under it
            // would be noise. An empty override reads as "no subtitle" (see PlaylistCellView).
            overrideSubtitle: ""
        )
        return cell
    }

    /// Tapping a row opens that playlist, the same as tapping it on the Playlists screen.
    func openPodcastPlaylist(_ item: PodcastPlaylistListItem) {
        let controller = PlaylistDetailViewController(playlist: item.row.playlist, delegate: self)
        navigationController?.pushViewController(controller, animated: true)
    }

    /// "Not in any playlists", with the way out attached — the same shape as every other empty
    /// state in the app, so the tab is never a dead end.
    func podcastPlaylistsEmptyCell(for item: PodcastPlaylistsEmptyItem, at indexPath: IndexPath) -> UITableViewCell {
        let cell = episodesTable.dequeueReusableCell(withIdentifier: EmptyStateCell.reuseIdentifier, for: indexPath) as! EmptyStateCell
        cell.configure(
            title: item.reason.title,
            message: item.reason.message,
            icon: { Image(systemName: "rectangle.stack") },
            actions: item.reason.offersAddToPlaylist ? [
                .init(title: L10n.playlistManualEpisodeAddToPlaylist, action: { [weak self] in
                    self?.addPodcastEpisodesToPlaylist()
                })
            ] : []
        )
        return cell
    }

    /// From the empty state: the podcast's episodes go to a playlist of the user's choosing, named
    /// after the podcast by default (see `PlaylistNameSuggestion`).
    private func addPodcastEpisodesToPlaylist() {
        guard let podcast else { return }
        let episodes = episodeInfo
            .flatMap(\.elements)
            .compactMap { ($0 as? ListEpisode)?.episode as? Episode }
        let all = episodes.isEmpty
            ? DataManager.sharedManager.allEpisodesForPodcast(id: podcast.id).compactMap { $0 as? Episode }
            : episodes
        guard !all.isEmpty else { return }
        let chooser = ManualPlaylistsChooserViewController(
            episodes: all,
            analyticsSource: "podcast_playlists_tab",
            suggestedName: PlaylistNameSuggestion.joined(podcast.title)
        )
        present(UINavigationController(rootViewController: chooser), animated: true)
    }

    /// Fork: the Playlists tab's ⋯ options. Only what applies here — the tab lists LISTS, so the
    /// episode-shaped options (sort, group, download, archive) would all be lies.
    func podcastPlaylistsMenuOptions() -> [OptionAction] {
        let show = PodcastPlaylistsShow.current
        let showAction = OptionAction(label: L10n.podcastPlaylistsShow, secondaryLabel: show.title, icon: "podcastlist_sort") {}
        showAction.submenu = { [weak self] in
            let picker = OptionsPicker(title: L10n.podcastPlaylistsShow.localizedUppercase)
            for option in PodcastPlaylistsShow.allCases {
                picker.addAction(action: OptionAction(label: option.title, selected: show == option) {
                    PodcastPlaylistsShow.current = option
                    self?.episodesDidChange()
                })
            }
            return picker
        }

        let sort = PodcastPlaylistsSort.current
        let sortAction = OptionAction(label: L10n.sortBy, secondaryLabel: sort.title, icon: "podcastlist_sort") {}
        sortAction.submenu = { [weak self] in
            let picker = OptionsPicker(title: L10n.sortBy.localizedUppercase)
            for option in PodcastPlaylistsSort.allCases {
                picker.addAction(action: OptionAction(label: option.title, selected: sort == option) {
                    PodcastPlaylistsSort.current = option
                    self?.episodesDidChange()
                })
            }
            return picker
        }

        let grouping = PodcastPlaylistsGrouping.current
        let groupAction = OptionAction(label: L10n.inboxGroupBy, secondaryLabel: grouping.title, icon: "option-group") {}
        groupAction.submenu = { [weak self] in
            let picker = OptionsPicker(title: L10n.inboxGroupBy.localizedUppercase)
            for option in PodcastPlaylistsGrouping.allCases {
                picker.addAction(action: OptionAction(label: option.title, selected: grouping == option) {
                    PodcastPlaylistsGrouping.current = option
                    self?.episodesDidChange()
                })
            }
            return picker
        }

        return [sortAction, groupAction, showAction]
    }
}
