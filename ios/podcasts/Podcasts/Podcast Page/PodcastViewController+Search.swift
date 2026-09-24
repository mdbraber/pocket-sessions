import Foundation
import PocketCastsServer

extension PodcastViewController {
    func setupSearchController() {
        let controller = EpisodeListSearchController()
        controller.placeholder = L10n.searchEpisodes
        controller.searchDebounce = Settings.episodeSearchDebounceTime()
        controller.delegate = self

        addChild(controller)
        controller.didMove(toParent: self)
        searchController = controller

        NotificationCenter.default.addObserver(self, selector: #selector(filtersWereReset), name: FilterPresets.resetAll, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(filterPresetChanged), name: FilterPresetStore.changed, object: nil)

        updateSearchHeader()
    }

    /// Updates the episode count and the filter preset button of the search header
    func updateSearchHeader() {
        guard let searchController, let podcast else { return }

        searchController.placeholder = showingPodcastPlaylists ? L10n.podcastPlaylistsSearch : L10n.searchEpisodes

        if showingPodcastPlaylists {
            searchController.info = nil
            searchController.actionTitle = nil
            searchController.isInfoRowCollapsed = true
            return
        }
        searchController.isInfoRowCollapsed = false

        if showingSession {
            let count = SessionStore.shared.session(forPodcast: podcast.uuid)
                .map { SessionFeederEngine.storeMemberUuids(for: $0).count } ?? 0
            if count > 0 {
                let text = count == 1 ? L10n.podcastEpisodeCountSingular : L10n.podcastEpisodeCountPluralFormat(count.localized())
                searchController.info = NSAttributedString(string: text, attributes: [.foregroundColor: AppTheme.colorForStyle(.primaryText02)])
            } else {
                searchController.info = nil
            }
            searchController.actionTitle = nil
            return
        }

        let hasEpisodeLimit = (podcast.autoArchiveEpisodeLimit > 0 && podcast.overrideGlobalArchive)
        let count = episodeCount()

        let infoText = count == 1 ? L10n.podcastEpisodeCountSingular : L10n.podcastEpisodeCountPluralFormat(count.localized())
        let info = NSMutableAttributedString(string: infoText, attributes: [.foregroundColor: AppTheme.colorForStyle(.primaryText02)])
        if hasEpisodeLimit {
            info.append(NSAttributedString(string: " • " + L10n.podcastEpisodeLimitCountFormat(podcast.autoArchiveEpisodeLimit.localized()), attributes: [.foregroundColor: AppTheme.colorForStyle(.support08)]))
        }
        let unseenCount = unseenEpisodeCount()
        if unseenCount > 0 {
            info.append(NSAttributedString(string: " • \(L10n.inboxUnseenCountFormat(unseenCount.localized()))", attributes: [.foregroundColor: AppTheme.colorForStyle(.primaryText02)]))
        }

        searchController.info = info
        searchController.actionTitle = FilterPresets.active().name
        searchController.styleActionButton { FilterPresetPicker.style($0) }
    }

    @objc func filterPresetChanged() {
        updateSearchHeader()
        episodesDidChange()
    }

    @objc func filtersWereReset() {
        guard let searchController, !searchController.searchText.isEmpty else { return }
        searchController.searchText = ""
        searchEpisodes(query: "")
    }

    func performEpisodeSearch(query: String) {
        guard let podcast else { return }

        let search = CacheServerHandler.EpisodeSearchQuery(podcastUuid: podcast.uuid, searchTerm: query)
        CacheServerHandler.shared.searchEpisodesInPodcast(search: search) { [weak self] results in
            self?.showSearchResults(results)
        }
    }

    func showSearchResults(_ result: CacheServerHandler.EpisodeSearchResult?) {
        DispatchQueue.main.async { [weak self] in
            self?.searchController?.isLoading = false
        }

        guard let podcast, let result else { return }

        uuidsThatMatchSearch.removeAll()

        for episode in result.episodes {
            uuidsThatMatchSearch.append(episode.uuid)
        }

        loadLocalEpisodes(podcast: podcast, animated: true)
    }
}

// MARK: - EpisodeListSearchControllerDelegate

extension PodcastViewController: EpisodeListSearchControllerDelegate {
    func episodeListSearchController(_ controller: EpisodeListSearchController, didChangeSearchTerm searchTerm: String) {
        searchEpisodes(query: searchTerm)
    }

    func episodeListSearchController(_ controller: EpisodeListSearchController, didSubmitSearchTerm searchTerm: String) {
        searchEpisodes(query: searchTerm)
    }

    func episodeListSearchControllerDidBeginEditing(_ controller: EpisodeListSearchController) {
        didActivateSearch()
    }

    func episodeListSearchControllerDidTapAction(_ controller: EpisodeListSearchController) {
        FilterPresetPicker.present(
            from: self,
            searchActive: !controller.searchText.isEmpty,
            onSelect: { [weak self] preset in self?.applyPresetSortAndGroup(preset) }
        ) { [weak self] in
            self?.episodesDidChange()
        }
    }

    func episodeListSearchControllerDidTapOverflow(_ controller: EpisodeListSearchController) {
        if showingPodcastPlaylists {
            let optionPicker = OptionsPicker(title: nil)
            optionPicker.addActions(podcastPlaylistsMenuOptions())
            optionPicker.present(from: self)
            return
        }
        showEpisodeOptions()
    }
}
