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
        // A podcast page shows one podcast, so podcast/folder-limited presets don't apply here. The
        // Session tab keeps its own preset (it narrows what the lineup shows, never what plays).
        let scope = presetScope
        searchController.actionTitle = FilterPresets.active(scope, singlePodcast: true).name
        searchController.styleActionButton { FilterPresetPicker.style($0, scope: scope, singlePodcast: true) }
    }

    /// The preset scope of the tab on screen: the Session tab keeps its own selection.
    var presetScope: FilterScope { showingSession ? .session : .episodes }

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
        let onSessionTab = showingSession
        FilterPresetPicker.present(
            from: self,
            scope: presetScope,
            singlePodcast: true,
            searchActive: !controller.searchText.isEmpty,
            onSelect: { [weak self] preset in
                // On the Session tab a preset seeds the session's arrangement (it sets play order).
                if onSessionTab {
                    if let session = self?.lineupSession { LineupSort.applySeeds(of: preset, to: session) }
                } else {
                    self?.applyPresetSortAndGroup(preset)
                }
            }
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
