import PocketCastsDataModel
import PocketCastsUtils
import PocketCastsServer
import SwiftUI

extension UpNextViewController: UITableViewDelegate, UITableViewDataSource {
    // MARK: - TableView DataSource

    func numberOfSections(in tableView: UITableView) -> Int {
        tableData.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let section = tableData[section]
        switch section {
        case .nowPlayingSection:
            return 1
        case .sessionSection:
            return sessionEpisodes?.count ?? 0
        case .upNextSection:
            if PlaybackManager.shared.queue.upNextCount() == 0 { return 1 } // empty state cell
            if isShowingFilterEmptyNotice { return 1 }
            return visibleUpNextCount
        }
    }

    // MARK: - Section Headers

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        // During a session its header sits above the Now Playing card — the playing episode
        // belongs to the session. The session's remaining rows follow the card, headerless.
        if tableData[section] == .nowPlayingSection, sessionEpisodes != nil {
            updateSessionHeader()
            return sessionHeaderView
        }
        if tableData[section] == .sessionSection {
            if PlaybackManager.shared.currentEpisode() == nil {
                updateSessionHeader()
                return sessionHeaderView
            }
            return nil
        }
        guard tableData[section] == .upNextSection, tableData.count > 1 else { return nil }
        let headerView = self.headerView

        updateTimeRemainingLabel()

        if FeatureFlag.upNextShuffle.enabled {
            clearQueueButton.isHidden = true
            shuffleButton.isHidden = PlaybackManager.shared.queue.upNextCount() == 0
        } else {
            clearQueueButton.isHidden = false
            shuffleButton.isHidden = true
            clearQueueButton.isEnabled = PlaybackManager.shared.queue.upNextCount() > 0
        }
        if FeatureFlag.upNextSort.enabled {
            sortButton.isHidden = PlaybackManager.shared.queue.upNextCount() == 0
        }
        updateFilterHeaderButtons()
        return headerView
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        let section = tableData[section]
        let metrics = UIFontMetrics(forTextStyle: .footnote)
        switch section {
        case .nowPlayingSection:
            return sessionEpisodes != nil ? metrics.scaledValue(for: 40) : 16
        case .sessionSection:
            // The session header lives above the Now Playing card; this is just a spacer
            // (unless nothing is playing, in which case the header falls back here).
            return PlaybackManager.shared.currentEpisode() == nil ? metrics.scaledValue(for: 40) : 8
        case .upNextSection:
            let filterRowVisible = FeatureFlag.upNextFilter.enabled && Settings.upNextFilter() != nil && PlaybackManager.shared.queue.upNextCount() > 0
            return metrics.scaledValue(for: 48) + (filterRowVisible ? 26 : 0)
        }
    }

    // MARK: - Cell Population

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let section = tableData[indexPath.section]
        if section == .nowPlayingSection {
            let nowPlayingCell = tableView.dequeueReusableCell(withIdentifier: UpNextViewController.nowPlayingCell, for: indexPath) as! UpNextNowPlayingCell
            nowPlayingCell.themeOverride = themeOverride
            if let episode = PlaybackManager.shared.currentEpisode() {
                nowPlayingCell.populateFrom(episode: episode)
            }
            return nowPlayingCell
        }

        if section == .sessionSection {
            let playerCell = tableView.dequeueReusableCell(withIdentifier: UpNextViewController.playerCell, for: indexPath) as! PlayerCell
            playerCell.themeOverride = themeOverride
            playerCell.shouldShowSelect(show: false, animate: false)
            playerCell.delegate = self
            if let episode = sessionEpisodes?[safe: indexPath.row] {
                playerCell.populateFrom(episode: episode)
            }
            playerCell.showTick = false
            playerCell.contentView.alpha = 1
            return playerCell
        }

        if PlaybackManager.shared.queue.upNextCount() == 0 {
            let emptyCell = tableView.dequeueReusableCell(withIdentifier: UpNextViewController.emptyStateCell, for: indexPath) as! EmptyStateCell
            emptyCell.configure(title: L10n.upNextEmptyTitle,
                                message: L10n.upNextEmptyDescription,
                                icon: { Image("upnext") },
                actions: [
                    .init(title: L10n.goToDiscover) {
                        Analytics.track(.upNextDiscoverButtonTapped)
                        NavigationManager.sharedManager.navigateTo(NavigationManager.discoverPageKey)
                    }
                ])
            return emptyCell
        }

        if isShowingFilterEmptyNotice {
            let emptyCell = tableView.dequeueReusableCell(withIdentifier: UpNextViewController.emptyStateCell, for: indexPath) as! EmptyStateCell
            emptyCell.configure(title: L10n.upNextFilterEmptyTitle,
                                message: L10n.upNextFilterEmptyDescription(Settings.upNextFilter()?.title ?? ""),
                                icon: { Image(systemName: "funnel") },
                actions: [
                    .init(title: L10n.upNextFilterClear) {
                        Settings.setUpNextFilter(nil)
                    },
                    .init(title: L10n.upNextFilterShowSkipped) {
                        Settings.setUpNextFilterHideSkipped(false)
                    }
                ])
            return emptyCell
        }

        let playerCell = tableView.dequeueReusableCell(withIdentifier: UpNextViewController.playerCell, for: indexPath) as! PlayerCell
        playerCell.themeOverride = themeOverride
        playerCell.shouldShowSelect(show: isMultiSelectEnabled, animate: false)
        playerCell.delegate = self

        if let episode = PlaybackManager.shared.queue.episodeAt(index: queueIndex(forVisibleRow: indexPath.row)) {
            playerCell.populateFrom(episode: episode)
            playerCell.showTick = selectedEpisodesContains(uuid: episode.uuid)
            // With an Up Next filter active, dim episodes playback will skip. They stay fully
            // interactive: reorder, swipe, and tap-to-play are unaffected by the filter.
            if let matchingUuids = upNextFilterMatchingUuids {
                playerCell.contentView.alpha = matchingUuids.contains(episode.uuid) ? 1 : 0.35
            } else {
                playerCell.contentView.alpha = 1
            }
        }
        return playerCell
    }

    // MARK: - Selection

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        if tableData[indexPath.section] == .sessionSection {
            return isMultiSelectEnabled ? nil : indexPath
        }

        guard !multiSelectGestureInProgress, tableData[indexPath.section] == .upNextSection else {
            return indexPath
        }

        if isShowingFilterEmptyNotice { return nil }

        if let episode = DataManager.sharedManager.playlistEpisodeAt(index: queueIndex(forVisibleRow: indexPath.row) + 1) {
            if selectedEpisodesContains(uuid: episode.episodeUuid) {
                tableView.delegate?.tableView?(tableView, didDeselectRowAt: indexPath)
                return nil
            }
            return indexPath
        }
        return nil
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if isMultiSelectEnabled, tableData[indexPath.section] == .upNextSection {
            // the cell below is optional because cellForRow only returns a cell if it's visible, and we don't need to tick cells that don't exist
            if let episode = DataManager.sharedManager.playlistEpisodeAt(index: queueIndex(forVisibleRow: indexPath.row) + 1) {
                if !multiSelectGestureInProgress {
                    // If the episode is already selected move to the end of the array
                    selectedEpisodesRemove(uuid: episode.episodeUuid)
                }

                if !multiSelectGestureInProgress || multiSelectGestureInProgress, !selectedEpisodesContains(uuid: episode.episodeUuid) {
                    selectedPlayListEpisodes.append(episode)
                    // the cell below is optional because cellForRow only returns a cell if it's visible, and we don't need to tick cells that don't exist
                    if let cell = upNextTable.cellForRow(at: indexPath) as? PlayerCell? {
                        cell?.showTick = true
                    }
                }
            }
        } else {
            tableView.deselectRow(at: indexPath, animated: true)
            let section = tableData[indexPath.section]

            if section == .nowPlayingSection {
                track(.upNextNowPlayingTapped)

                dismiss(animated: true, completion: {
                    if let miniPlayer = UIApplication.shared.appDelegate()?.miniPlayer(), miniPlayer.playerOpenState == .closed {
                        UIApplication.shared.appDelegate()?.miniPlayer()?.openFullScreenPlayer()
                    }
                })

                return
            }

            if isShowingFilterEmptyNotice { return }

            if section == .sessionSection {
                if let episode = sessionEpisodes?[safe: indexPath.row] {
                    AnalyticsPlaybackHelper.shared.currentSource = .upNext
                    PlaybackManager.shared.play(sessionEpisode: episode)
                }
                return
            }

            guard let episode = PlaybackManager.shared.queue.episodeAt(index: queueIndex(forVisibleRow: indexPath.row)) else { return }

            let playOnTap = Settings.playUpNextOnTap()

            track(.upNextQueueEpisodeTapped, properties: ["will_play": playOnTap])

            if playOnTap {
                AnalyticsPlaybackHelper.shared.currentSource = .upNext
                PlaybackManager.shared.load(episode: episode, autoPlay: true, overrideUpNext: false)
            } else {
                showEpisodeDetailViewController(for: episode)
            }
        }
    }

    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        guard tableData[indexPath.section] == .upNextSection else { return }
        if let episode = DataManager.sharedManager.playlistEpisodeAt(index: queueIndex(forVisibleRow: indexPath.row) + 1), let index = selectedPlayListEpisodes.firstIndex(of: episode) {
            selectedPlayListEpisodes.remove(at: index)
            if let cell = upNextTable.cellForRow(at: indexPath) as? PlayerCell? {
                cell?.showTick = false
            }
        }
    }

    // MARK: - Rearrange

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        let section = tableData[indexPath.section]
        if section == .nowPlayingSection {
            return false
        } else if section == .sessionSection {
            // Manual playlist sessions are drag-reorderable (it reorders the playlist itself)
            return Settings.playbackSession()?.type == .playlist
        } else if section == .upNextSection, PlaybackManager.shared.queue.upNextCount() == 0 || isShowingFilterEmptyNotice {
            return false
        }
        return true
    }

    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        if sourceIndexPath == destinationIndexPath { return }

        if tableData[sourceIndexPath.section] == .sessionSection {
            moveSessionEpisode(fromRow: sourceIndexPath.row, toRow: destinationIndexPath.row)
            return
        }

        let playQueue = PlaybackManager.shared.queue

        if visibleQueueIndices != nil {
            moveVisibleEpisode(fromVisibleRow: sourceIndexPath.row, toVisibleRow: destinationIndexPath.row)
        } else {
            playQueue.moveEpisode(from: sourceIndexPath.row, to: destinationIndexPath.row)
        }

        // This logic is reversed because the lower the row number the higher it is in the queue
        let didMoveUp = destinationIndexPath.row < sourceIndexPath.row
        let slots = abs(destinationIndexPath.row - sourceIndexPath.row)
        let isTop = destinationIndexPath.row == 0

        track(.upNextQueueReordered, properties: ["direction": didMoveUp ? "up" : "down", "slots": slots, "is_next": isTop])
    }

    func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath, toProposedIndexPath proposedDestinationIndexPath: IndexPath) -> IndexPath {
        // Rows can only be reordered within their own section — session episodes and queue
        // episodes live in different worlds.
        if tableData[proposedDestinationIndexPath.section] == tableData[sourceIndexPath.section] {
            return proposedDestinationIndexPath
        }

        return IndexPath(row: 0, section: sourceIndexPath.section)
    }

    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        .none
    }

    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        false
    }

    // MARK: - Swipe Actions

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        switch tableData[indexPath.section] {
        case .upNextSection:
            return true
        case .sessionSection:
            // A row must be editable for its reorder control to show; manual playlist
            // sessions are drag-reorderable. Swipe actions are blocked separately in the
            // SwipeCellKit delegate, so no other editing UI appears.
            return Settings.playbackSession()?.type == .playlist
        case .nowPlayingSection:
            return false
        }
    }

    // MARK: - Cell Heights

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let section = tableData[indexPath.section]
        if section == .nowPlayingSection { return UpNextViewController.nowPlayingRowHeight }
        if section == .sessionSection { return UpNextViewController.upNextRowHeight }
        if PlaybackManager.shared.queue.upNextCount() == 0 || isShowingFilterEmptyNotice { return UpNextViewController.emptyStateRowHeight }
        return UpNextViewController.upNextRowHeight
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        let section = tableData[indexPath.section]
        if section == .nowPlayingSection { return UpNextViewController.nowPlayingRowHeight }
        if section == .sessionSection { return UpNextViewController.upNextRowHeight }
        if PlaybackManager.shared.queue.upNextCount() == 0 || isShowingFilterEmptyNotice { return UpNextViewController.emptyStateRowHeight }
        return UpNextViewController.upNextRowHeight
    }

    // MARK: - Multiselect

    func tableView(_ tableView: UITableView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
        tableData[indexPath.section] == .upNextSection && Settings.multiSelectGestureEnabled()
    }

    func tableView(_ tableView: UITableView, didBeginMultipleSelectionInteractionAt indexPath: IndexPath) {
        if isMultiSelectEnabled == false {
            isMultiSelectEnabled = true
        }
        multiSelectGestureInProgress = true
    }

    func tableViewDidEndMultipleSelectionInteraction(_ tableView: UITableView) {
        multiSelectGestureInProgress = false
    }

    // MARK: - Helper Functions

    func refreshSections() {
        var sections: [sections] = [.upNextSection]

        if sessionEpisodes != nil {
            sections.insert(.sessionSection, at: 0)
        }

        if let _ = PlaybackManager.shared.currentEpisode() {
            sections.insert(.nowPlayingSection, at: 0)
            upNextTable.themeStyle = .primaryUi04
        } else {
            upNextTable.backgroundColor = UIColor(Theme.sharedTheme.primaryUi02)
        }
        tableData = sections
    }

    @objc func reloadTable() {
        refreshUpNextFilterMatches()
        refreshSections()
        upNextTable.reloadData()
    }

    @objc func upNextChanged() {
        if changedViaSwipeToRemove { return }

        if isMultiSelectEnabled {
            let upNextUuids = DataManager.sharedManager.allUpNextPlaylistEpisodes().map(\.episodeUuid)
            for (index, selectedEpisode) in selectedPlayListEpisodes.enumerated() {
                if !upNextUuids.contains(selectedEpisode.episodeUuid), index > selectedPlayListEpisodes.count {
                    selectedPlayListEpisodes.remove(at: index)
                }
            }

            if let currentUuid = PlaybackManager.shared.currentEpisode()?.uuid {
                selectedEpisodesRemove(uuid: currentUuid)
            }
            if upNextUuids.isEmpty {
                isMultiSelectEnabled = false
            }
        }
        // this method is sometimes called during a re-arrange animation. For whatever weird reason doing this as part of that operation causes the table to flash.
        // This is only when the Lottie animation in the the now playing cell is running, so before removing this call, test that case
        DispatchQueue.main.async {
            self.updateNavBarButtons()
            self.reloadTable()
        }
    }

    @objc func appDidBecomeActive() {
        // there's a weird issue with the drag handle tints disappearing on the app coming back from being backgrounded, so reload the table in that case
        self.reloadTable()
    }

    @objc func tableLongPressed(_ sender: UILongPressGestureRecognizer) {
        let touchPoint = sender.location(in: upNextTable)
        guard let indexPath = upNextTable.indexPathForRow(at: touchPoint), tableData[indexPath.section] == .upNextSection,
              !isShowingFilterEmptyNotice,
              let episode = PlaybackManager.shared.queue.episodeAt(index: queueIndex(forVisibleRow: indexPath.row)) else { return }

        if sender.state == .began {
            if isMultiSelectEnabled {
                showLongPressSelectOptions(indexPath: indexPath)
            } else if !Settings.playUpNextOnTap() {
                AnalyticsPlaybackHelper.shared.currentSource = .upNext
                PlaybackActionHelper.play(episode: episode)
                track(.upNextQueueEpisodeLongPressed, properties: ["will_play": true])
            } else {
                showEpisodeDetailViewController(for: episode)
                track(.upNextQueueEpisodeLongPressed, properties: ["will_play": false])
            }
        }
    }
}
