import UIKit
import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils

extension PlaylistDetailViewController {
    private enum ActionType {
        case downloadAll
        case queueAll
    }

    @objc func moreTapped() {
        track(.filterOptionsTapped)

        let optionsPicker = OptionsPicker(title: nil)

        let chromecastAction = chromecastAction()
        optionsPicker.addAction(action: chromecastAction)

        let multiSelectAction = multiSelectAction()
        optionsPicker.addAction(action: multiSelectAction)

        // Sort and Group By. Triage pages use the fork's per-tab sort (TriageTabSort); plain
        // playlists use the stock playlist sort. Sort on every tab; Group By only where episodes
        // are browsed (the Session lineup renders in play order and never groups). No group-limit.
        if viewModel.usesTriageTabs {
            let sortTab = viewModel.selectedTriageTab.sortKey
            let triageSort = OptionAction(label: L10n.sortBy, secondaryLabel: TriageTabSort.order(sortTab, pageUuid: viewModel.playlist.uuid).title, icon: "podcastlist_sort") {}
            triageSort.submenu = { [weak self] in
                guard let self else { return nil }
                let picker = OptionsPicker(title: L10n.sortBy.localizedUppercase)
                let current = TriageTabSort.order(sortTab, pageUuid: self.viewModel.playlist.uuid)
                for option in sortTab.options {
                    picker.addAction(action: OptionAction(label: option.title, selected: current == option) {
                        TriageTabSort.setOrder(option, tab: sortTab, pageUuid: self.viewModel.playlist.uuid)
                        self.viewModel.reloadEpisodeList(animated: false)
                    })
                }
                return picker
            }
            optionsPicker.addAction(action: triageSort)

            if viewModel.selectedTriageTab != .lineup {
                let groupAction = OptionAction(label: L10n.inboxGroupBy, secondaryLabel: viewModel.groupBy.title, icon: "option-group") {}
                groupAction.submenu = { [weak self] in
                    guard let self else { return nil }
                    let picker = OptionsPicker(title: L10n.inboxGroupBy.localizedUppercase)
                    for option in EpisodeGroupBy.menuOrder {
                        picker.addAction(action: OptionAction(label: option.title, selected: self.viewModel.groupBy == option) {
                            self.viewModel.groupBy = option
                        })
                    }
                    return picker
                }
                optionsPicker.addAction(action: groupAction)

                if viewModel.groupBy != .none {
                    let limitAction = OptionAction(label: L10n.episodeGroupLimit, secondaryLabel: viewModel.groupLimit > 0 ? "\(viewModel.groupLimit)" : L10n.off, icon: "option-group") {}
                    limitAction.submenu = { [weak self] in
                        guard let self else { return nil }
                        let picker = OptionsPicker(title: L10n.episodeGroupLimit.localizedUppercase)
                        picker.addAction(action: OptionAction(label: L10n.off, selected: self.viewModel.groupLimit == 0) {
                            self.viewModel.groupLimit = 0
                        })
                        for limit in EpisodeGrouper.limitOptions {
                            picker.addAction(action: OptionAction(label: "\(limit)", selected: self.viewModel.groupLimit == limit) {
                                self.viewModel.groupLimit = limit
                            })
                        }
                        return picker
                    }
                    optionsPicker.addAction(action: limitAction)

                    let reverseAction = OptionAction(label: L10n.inboxGroupReverse, selected: viewModel.reverseGroup) { [weak self] in
                        guard let self else { return }
                        self.viewModel.reverseGroup.toggle()
                    }
                    optionsPicker.addAction(action: reverseAction)
                }
            }
        } else {
            optionsPicker.addAction(action: sortAction())
        }

        // "Add to Session" (where adds land in the lineup) sits directly above Download All.
        // The old "New Episodes" (Inbox vs Auto add) option is gone — that choice now lives
        // in each podcast's own Session settings.
        if viewModel.usesCustomOrderOverlay || viewModel.isLensPage {
            optionsPicker.addAction(action: insertModeAction())
        }

        let downloadAllAction = downloadAllOption()
        optionsPicker.addAction(action: downloadAllAction)

        if viewModel.isManualPlaylist {
            let archiveAction = archiveAction()
            optionsPicker.addAction(action: archiveAction)
        }

        optionsPicker.present(from: self)
    }

    // MARK: - Multiselect

    private func multiSelectAction() -> OptionAction {
        OptionAction(label: L10n.selectEpisodes, icon: "option-multiselect") { [weak self] in
            self?.track(.filterSelectEpisodesTapped)
            self?.isMultiSelectEnabled = true
        }
    }

    // MARK: - Chromecast

    private func chromecastAction() -> OptionAction {
        OptionAction(label: "Chromecast", icon: "nav_cast_off") { [weak self] in
            self?.track(.filterChromeCastTapped)
            self?.castButtonTapped()
        }
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

    // MARK: - Fork: custom-order overlay settings

    private func insertModeAction() -> OptionAction {
        let sessionInsertMode = currentInsertMode()
        let action = OptionAction(label: L10n.sessionPositionHeading, secondaryLabel: sessionInsertMode.description, icon: "rectangle.stack") { }
        action.submenu = { [weak self] in self?.makeInsertModePicker() }
        return action
    }

    private func currentInsertMode() -> PlaylistInsertMode {
        guard let session = viewModel.insertModeSession else { return .top }
        return PlaylistInsertMode(rawValue: session.insertMode) ?? .top
    }

    private func makeInsertModePicker() -> OptionsPicker {
        let currentInsertMode = currentInsertMode()
        let optionsPicker = OptionsPicker(title: L10n.sessionPositionHeading.localizedUppercase)
        for mode in PlaylistInsertMode.allCases {
            let action = OptionAction(label: mode.description, selected: currentInsertMode == mode) { [weak self] in
                self?.viewModel.updatePlaylist(insertMode: mode)
            }
            optionsPicker.addAction(action: action)
        }
        return optionsPicker
    }

    private func savePlaylist() {
        let playlist = self.viewModel.playlist
        playlist.syncStatus = SyncStatus.notSynced.rawValue
        viewModel.update(playlist: playlist)
        DataManager.sharedManager.save(playlist: viewModel.playlist)
        NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged, object: viewModel.playlist)
    }

    // MARK: - Download

    private func downloadAllOption() -> OptionAction {
        let action = OptionAction(label: L10n.downloadAll, icon: "filter_downloaded") { [weak self] in
            self?.track(.filterDownloadAllTapped)
        }
        action.submenu = { [weak self] in self?.makeDownloadAllPicker() }
        return action
    }

    private func makeDownloadAllPicker() -> OptionsPicker? {
        let downloadableCount = downloadableCount(listEpisodes: viewModel.episodes)
        let downloadLimitExceeded = downloadableCount > Constants.Limits.maxBulkDownloads
        let actualDownloadCount = downloadLimitExceeded ? Constants.Limits.maxBulkDownloads : downloadableCount
        if actualDownloadCount == 0 { return nil }
        let downloadText = L10n.downloadCountPrompt(actualDownloadCount)
        let downloadAction = OptionAction(label: downloadText, icon: nil) { [weak self] in
            self?.downloadAll()
        }

        let confirmPicker = OptionsPicker(title: nil)
        var warningMessage = downloadLimitExceeded ? L10n.bulkDownloadMax : ""

        if NetworkUtils.shared.isConnectedToUnexpensiveConnection() {
            confirmPicker.addDescriptiveActions(title: L10n.downloadAll, message: warningMessage, icon: "filter_downloaded", actions: [downloadAction])
        } else {
            downloadAction.destructive = true

            let queueAction = OptionAction(label: L10n.queueForLater, icon: nil) { [weak self] in
                self?.queueAll()
            }

            if !Settings.mobileDataAllowed() {
                warningMessage = L10n.downloadDataWarningWithSettingsLink("pktc://settings/storage-and-data") + "\n" + warningMessage
            }

            confirmPicker.addAttributedDescriptiveActions(title: L10n.notOnWifi, message: warningMessage, icon: "option-alert", actions: [downloadAction, queueAction])
        }
        return confirmPicker
    }

    private func downloadableCount(listEpisodes: [ListEpisode]) -> Int {
        if listEpisodes.isEmpty { return 0 }
        var count = 0

        for listEpisode in listEpisodes {
            if !listEpisode.episode.downloaded(pathFinder: DownloadManager.shared), !listEpisode.episode.downloading(), !listEpisode.episode.queued() {
                count += 1
            }
        }
        return count
    }

    private func downloadAll() {
        start(action: .downloadAll, forAllEpisodes: viewModel.episodes)
    }

    private func queueAll() {
        start(action: .queueAll, forAllEpisodes: viewModel.episodes)
    }

    private func start(action: ActionType, forAllEpisodes episodes: [ListEpisode]) {
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }

            if self.viewModel.episodes.isEmpty { return }

            var queuedEpisodes = 0
            for listEpisode in episodes {
                if listEpisode.episode.downloading() || listEpisode.episode.downloaded(pathFinder: DownloadManager.shared) || listEpisode.episode.queued() {
                    continue
                }

                switch action {
                case .downloadAll:
                    DownloadManager.shared.addToQueue(episodeUuid: listEpisode.episode.uuid, fireNotification: true, autoDownloadStatus: .notSpecified)
                case .queueAll:
                    DownloadManager.shared.queueForLaterDownload(episodeUuid: listEpisode.episode.uuid, fireNotification: true, autoDownloadStatus: .notSpecified)
                }

                queuedEpisodes += 1
                if queuedEpisodes == Constants.Limits.maxBulkDownloads {
                    return
                }
            }
        }
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
        let host = PCHostingController(rootView: chooseView.environmentObject(Theme.sharedTheme))
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
