import UIKit
import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils

extension PlaylistDetailViewController {
    @objc func moreTapped() {
        track(.filterOptionsTapped)

        let optionsPicker = OptionsPicker(title: nil)

        optionsPicker.addAction(action: EpisodeListMenu.chromecastAction { [weak self] in
            self?.track(.filterChromeCastTapped)
            self?.castButtonTapped()
        })

        optionsPicker.addAction(action: EpisodeListMenu.multiSelectAction { [weak self] in
            self?.track(.filterSelectEpisodesTapped)
            self?.isMultiSelectEnabled = true
        })

        // Fork: a LINEUP is re-ordered, a BROWSED list is sorted — two different verbs for two
        // different things. A lineup (the Session tab, or a plain manual playlist) has exactly one
        // saved order, so its menu re-arranges that order once and nothing sticks. Browsed lists
        // (the Episodes tab, a smart playlist) keep the ordinary sticky sort.
        if showsLineupReorder, let session = viewModel.lineupSession {
            // A session's lineup: a sticky Sort By and Group By, saved on the session — they set
            // the play order.
            EpisodeListMenu.addLineupArrangementActions(to: optionsPicker, session: session, onChange: { [weak self] in
                self?.viewModel.reloadEpisodeList(animated: false)
            }, onReorderEpisodes: { [weak self] in
                self?.enterLineupReorderMode()
            })
        } else if showsLineupReorder {
            optionsPicker.addAction(action: EpisodeListMenu.lineupReorderAction(onReorderEpisodes: { [weak self] in
                self?.enterLineupReorderMode()
            }, onReorder: { [weak self] option in
                self?.track(.filterSortByChanged, properties: ["sort_order": option.rawValue])
                self?.viewModel.reorderLineup(option)
            }))
        } else if viewModel.usesTriageTabs {
            optionsPicker.addAction(action: EpisodeListMenu.browseSortAction(pageUuid: viewModel.playlist.uuid) { [weak self] in
                self?.viewModel.reloadEpisodeList(animated: false)
            })
        } else {
            optionsPicker.addAction(action: sortAction())
        }

        // Group By is offered wherever episodes are browsed — any plain or smart playlist's
        // episode list. The Session lineup has its own, saved on the session (added above).
        if !viewModel.usesTriageTabs || viewModel.selectedTriageTab != .lineup {
            EpisodeListMenu.addGroupByActions(to: optionsPicker, grouping: viewModel.grouping) { [weak self] in
                self?.viewModel.reloadEpisodeList(animated: false)
            }
        }

        optionsPicker.addAction(action: EpisodeListMenu.downloadAllAction(episodes: { [weak self] in
            self?.viewModel.episodes.map(\.episode) ?? []
        }, onTap: { [weak self] in
            self?.track(.filterDownloadAllTapped)
        }))

        if viewModel.isManualPlaylist {
            let archiveAction = archiveAction()
            optionsPicker.addAction(action: archiveAction)
        }

        optionsPicker.present(from: self)
    }

    // MARK: - Fork: Reorder (lineups)

    /// Whether this page's episode list is a LINEUP — one canonical, saved order — rather than a
    /// browsed list. Session/lens pages on the Session tab, and plain manual playlists, both are.
    var showsLineupReorder: Bool {
        if viewModel.usesTriageTabs { return viewModel.selectedTriageTab == .lineup }
        return viewModel.isManualPlaylist
    }

    // MARK: - Sort

    private func sortAction() -> OptionAction {
        let currentSort = PlaylistSort(rawValue: viewModel.playlist.sortType)?.description ?? ""
        let action = OptionAction(label: L10n.sortBy, secondaryLabel: currentSort, icon: "podcastlist_sort") { [weak self] in
            self?.track(.filterSortByTapped)
        }
        action.submenu = { [weak self] in self?.makeSortByPicker() }
        return action
    }

    private func makeSortByPicker() -> OptionsPicker {
        let optionsPicker = OptionsPicker(title: L10n.sortBy.localizedUppercase)

        addSortAction(to: optionsPicker, sortOrder: .newestToOldest)
        addSortAction(to: optionsPicker, sortOrder: .oldestToNewest)
        addSortAction(to: optionsPicker, sortOrder: .shortestToLongest)
        addSortAction(to: optionsPicker, sortOrder: .longestToShortest)

        // Fork: custom order is available on smart playlists too (Lineup + New inbox overlay)
        addSortAction(to: optionsPicker, sortOrder: .dragAndDrop)

        return optionsPicker
    }

    private func addSortAction(to optionPicker: OptionsPicker, sortOrder: PlaylistSort) {
        let action = OptionAction(label: sortOrder.description, selected: viewModel.playlist.sortType == sortOrder.rawValue) { [weak self] in
            guard let self else { return }
            self.track(.filterSortByChanged, properties: ["sort_order": sortOrder])
            // Routed through the view model so a smart playlist switching to custom order
            // seeds its lineup from the currently displayed order.
            self.viewModel.updatePlaylist(sortType: sortOrder)
            NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged, object: self.viewModel.playlist)
        }
        optionPicker.addAction(action: action)
    }

    // MARK: - Archive

    private func archiveAction() -> OptionAction {
        let unarchivedCount = viewModel.unarchivedEpisodesCount()

        if unarchivedCount > 0 {
            return OptionAction(label: L10n.podcastArchiveAll, icon: "podcast-archiveall") { [weak self] in
                self?.track(.filterArchiveAllTapped)
                self?.archiveAllPlaylistEpisodes()
            }
        }
        return OptionAction(label: L10n.podcastUnarchiveAll, icon: "list_unarchive") { [weak self] in
            self?.track(.filterUnarchiveAllTapped)
            self?.unarchiveAllPlaylistEpisodes()
        }
    }

    private func archiveAllPlaylistEpisodes() {
        let episodes = viewModel.episodes.map { $0.episode }
        EpisodeManager.bulkArchive(episodes: episodes, updateSyncFlag: true)
    }

    private func unarchiveAllPlaylistEpisodes() {
        Task { [weak self] in
            guard let self else { return }
            let newData = self.viewModel.episodesDataManager.playlistEpisodes(for: self.viewModel.playlist)
            let episodes = newData.map { $0.episode }
            EpisodeManager.bulkUnarchive(episodes: episodes)
        }
    }

    // MARK: - Fork: Playlist Folder

    func playlistFolderTapped() {
        let playlistUuid = viewModel.playlist.uuid
        if let folderUuid = PlaylistFolderManager.shared.folderUuid(forPlaylist: playlistUuid),
           let folder = PlaylistFolderManager.shared.folder(uuid: folderUuid) {
            let optionPicker = OptionsPicker(title: folder.name.localizedUppercase)

            optionPicker.addAction(action: OptionAction(label: L10n.folderRemoveFrom, icon: "folder-remove") {
                PlaylistFolderManager.shared.setFolder(nil, forPlaylist: playlistUuid)
            })
            optionPicker.addAction(action: OptionAction(label: L10n.folderChange, icon: "folder-arrow") { [weak self] in
                self?.showPlaylistFolderPicker()
            })
            optionPicker.addAction(action: OptionAction(label: L10n.folderGoTo, icon: "folder-goto") { [weak self] in
                self?.navigationController?.pushViewController(PlaylistFolderViewController(folderUuid: folderUuid), animated: true)
            })

            optionPicker.present(from: self)
        } else {
            showPlaylistFolderPicker()
        }
    }

    private func showPlaylistFolderPicker() {
        let chooseView = ChoosePlaylistFolderView(playlistUuid: viewModel.playlist.uuid) { [weak self] in
            self?.dismiss(animated: true)
        }
        let host = PCHostingController(rootView: chooseView.environmentObject(Theme.shared))
        present(host, animated: true)
    }

    // MARK: - Edit

    func playlistOptionsTapped() {
        track(.filterOptionsButtonTapped)
        let filterEditController = FilterEditOptionsViewController()
        filterEditController.filterToEdit = viewModel.playlist
        navigationController?.pushViewController(filterEditController, animated: true)
    }
}
