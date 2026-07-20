import CarPlay
import Foundation
import PocketCastsDataModel
import PocketCastsUtils

// MARK: - Podcasts
extension CarPlaySceneDelegate {
    var podcastTabSections: [CPListSection] {
        var podcastItems = [CPListTemplateItem]()

        let gridItems = HomeGridDataHelper.gridItems(orderedBy: Settings.homeFolderSortOrder())

        for item in gridItems {
            if let podcast = item.podcast {
                let item = convertPodcastToListItem(podcast)
                podcastItems.append(item)
            } else if let folder = item.folder {
                let podcastCount = DataManager.sharedManager.countOfPodcastsInFolder(folder: folder)
                let item = CPListItem(text: folder.name, detailText: L10n.podcastCount(podcastCount), image: CarPlayImageHelper.imageForFolder(folder))

                item.accessoryType = .disclosureIndicator
                item.handler = { [weak self] _, completion in
                    self?.folderTapped(folder)
                    completion()
                }
                podcastItems.append(item)
            }
        }

        // Fork: no Up Next row here — the Queue tab owns the now-playing surfaces, so this
        // tab is purely the podcast/folder grid as a list.
        return [CPListSection(items: podcastItems)]
    }

    func createPodcastsTab() -> CPListTemplate {
        return CarPlayListData.template(title: L10n.podcastsPlural, emptyTitle: L10n.watchNoPodcasts, image: UIImage(named: "car_tab_podcasts")) { [weak self] in
            guard let self else { return nil }

            return self.podcastTabSections
        }
    }
}

// MARK: - Filters

extension CarPlaySceneDelegate {
    /// Playlists that are really sessions (their stores and feeder lenses) plus the Inbox — the
    /// Playlists tab is for plain, browsable playlists, so these get filtered out. Sessions have
    /// their own tab.
    private var sessionRelatedPlaylistUuids: Set<String> {
        var uuids = SessionStore.shared.feederPlaylistUuids
        uuids.formUnion(SessionStore.shared.sessions.compactMap(\.storePlaylistUuid))
        uuids.insert(DataManager.inboxPlaylistUuid)
        return uuids
    }

    private var filterTabSections: [CPListSection] {
        var filterItems = [CPListItem]()
        let sessionRelated = sessionRelatedPlaylistUuids
        for filter in DataManager.sharedManager.allPlaylists(includeDeleted: false) where !sessionRelated.contains(filter.uuid) {
            var detail: String? = nil
            if filter.manual == false {
                detail = L10n.smartPlaylist
            }
            let image = filter.grid()
            let item = CPListItem(text: filter.playlistName, detailText: detail, image: image)
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                self?.filterTapped(filter)
                completion()
            }

            filterItems.append(item)
        }

        return [CPListSection(items: filterItems)]
    }

    /// Fork: Playlists lives inside More now (the Queue tab has the tab slot), pushed as a
    /// drill-in list.
    func playlistsTapped() {
        let template = CarPlayListData.template(title: L10n.playlists, emptyTitle: L10n.watchNoFilters) { [weak self] in
            guard let self else { return nil }
            return self.filterTabSections
        }
        interfaceController?.push(template)
    }
}

// MARK: - More

extension CarPlaySceneDelegate {
    func createMoreTab() -> CPListTemplate {
        return CarPlayListData.staticTemplate(title: L10n.carplayMore, image: UIImage(named: "car_tab_more")) {
            // Fork: Playlists and Downloads live here rather than as their own tabs (the Queue
            // tab took the slot).
            let playlistsItem = CPListItem(text: L10n.playlists, detailText: nil, image: UIImage(named: "car_tab_filters"))
            playlistsItem.accessoryType = .disclosureIndicator
            playlistsItem.handler = { [weak self] _, completion in
                self?.playlistsTapped()
                completion()
            }

            let downloadsItem = CPListItem(text: L10n.downloads, detailText: nil, image: UIImage(named: "car_tab_downloads"))
            downloadsItem.accessoryType = .disclosureIndicator
            downloadsItem.handler = { [weak self] _, completion in
                self?.downloadsTapped()
                completion()
            }

            let listeningHistoryItem = CPListItem(text: L10n.listeningHistory, detailText: nil, image: UIImage(named: "car_more_listening_history"))
            listeningHistoryItem.accessoryType = .disclosureIndicator
            listeningHistoryItem.handler = { [weak self] _, completion in
                self?.listeningHistoryTapped()
                completion()
            }

            let filesItem = CPListItem(text: L10n.files, detailText: nil, image: UIImage(named: "car_more_files"))
            filesItem.accessoryType = .disclosureIndicator
            filesItem.handler = { [weak self] _, completion in
                self?.filesTapped()
                completion()
            }

            return [CPListSection(items: [playlistsItem, downloadsItem, listeningHistoryItem, filesItem])]
        }
    }
}
