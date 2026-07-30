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

/// Marks "this podcast is in nothing" so the tab can offer a way out of that state.
final class PodcastPlaylistsEmptyItem: ListItem {
    override var differenceIdentifier: String { "podcast-playlists-empty" }
    override func handleIsEqual(_ otherItem: ListItem) -> Bool { otherItem is PodcastPlaylistsEmptyItem }
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

            DispatchQueue.main.async {
                guard let self, self.showingPodcastPlaylists else { return }
                self.podcastPlaylistRows = rows

                let items: [ListItem] = rows.isEmpty
                    ? [PodcastPlaylistsEmptyItem()]
                    : rows.map { PodcastPlaylistListItem(row: $0) }

                let finalData = [
                    ArraySection<String, ListItem>(model: searchHeader.headerTitle, elements: [searchHeader]),
                    ArraySection<String, ListItem>(model: "playlists", elements: items)
                ]
                self.applyPodcastPlaylists(finalData, animated: animated)
            }
        }
    }

    private func applyPodcastPlaylists(_ data: [ArraySection<String, ListItem>], animated: Bool) {
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
        cell.configure(
            cellType: .count,
            playlist: item.row.playlist,
            isLastRow: isLastRow,
            analyticsSource: "podcast_playlists_tab",
            overrideCount: item.row.episodeCount,
            overrideSubtitle: item.row.kind.title
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
    func podcastPlaylistsEmptyCell(at indexPath: IndexPath) -> UITableViewCell {
        let cell = episodesTable.dequeueReusableCell(withIdentifier: EmptyStateCell.reuseIdentifier, for: indexPath) as! EmptyStateCell
        cell.configure(
            title: L10n.podcastPlaylistsEmptyTitle,
            message: L10n.podcastPlaylistsEmptyMessage,
            icon: { Image(systemName: "rectangle.stack") },
            actions: [
                .init(title: L10n.playlistManualEpisodeAddToPlaylist, action: { [weak self] in
                    self?.addPodcastEpisodesToPlaylist()
                })
            ]
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
        let action = OptionAction(label: L10n.podcastPlaylistsShow, secondaryLabel: show.title, icon: "podcastlist_sort") {}
        action.submenu = { [weak self] in
            let picker = OptionsPicker(title: L10n.podcastPlaylistsShow.localizedUppercase)
            for option in PodcastPlaylistsShow.allCases {
                picker.addAction(action: OptionAction(label: option.title, selected: show == option) {
                    PodcastPlaylistsShow.current = option
                    self?.episodesDidChange()
                })
            }
            return picker
        }
        return [action]
    }
}
