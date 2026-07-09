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
            return sessionExpanded ? (sessionEpisodes?.count ?? 0) : 0
        case .upNextSection:
            if isQueueCollapsed { return 0 } // folded to its header while a session plays
            if PlaybackManager.shared.queue.upNextCount() == 0 { return 1 } // empty state cell
            if isShowingFilterEmptyNotice { return 1 }
            return visibleUpNextCount
        }
    }

    // MARK: - Section Headers

    /// True while the queue is the playing world (paused session, something playing):
    /// its header then sits above the Now Playing card, mirroring the active session's layout.
    private var queueHeaderAboveCard: Bool {
        sessionEpisodes != nil && Settings.playbackSessionPaused() && PlaybackManager.shared.currentEpisode() != nil
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        // The playing world's header sits above the Now Playing card: the session's while
        // the session plays, the queue's while the queue plays (paused session). The
        // parked world keeps its own (collapsible) header bar on its section.
        if tableData[section] == .nowPlayingSection, sessionEpisodes != nil {
            if Settings.playbackSessionPaused() {
                return preparedQueueHeader()
            }
            updateSessionHeader()
            return sessionHeaderView
        }
        if tableData[section] == .sessionSection {
            if Settings.playbackSessionPaused() || PlaybackManager.shared.currentEpisode() == nil {
                updateSessionHeader()
                return sessionHeaderView
            }
            return nil
        }
        guard tableData[section] == .upNextSection, tableData.count > 1 else { return nil }
        if queueHeaderAboveCard { return nil } // rendered above the Now Playing card instead
        return preparedQueueHeader()
    }

    private func preparedQueueHeader() -> UIView {
        let headerView = self.headerView

        updateTimeRemainingLabel()
        updateQueueChevron()

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

        // A collapsed queue is just its title bar — no controls, no filter indicator.
        if isQueueCollapsed {
            shuffleButton.isHidden = true
            sortButton.isHidden = true
            clearQueueButton.isHidden = true
            filterButton.isHidden = true
            hideSkippedButton.isHidden = true
            hideSessionButton.isHidden = true
            filterIndicatorButton.isHidden = true
            clearFilterButton.isHidden = true
        }
        return headerView
    }

    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        // The playing world's counts line ("N episodes · X left") sits under the card.
        guard tableData[section] == .nowPlayingSection, sessionEpisodes != nil else { return nil }
        updateNowPlayingMetaLabel()
        return nowPlayingMetaFooterView
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        let model = tableData[section]
        if model == .nowPlayingSection, sessionEpisodes != nil {
            return UIFontMetrics(forTextStyle: .footnote).scaledValue(for: 24)
        }
        // Breathing room between the playing world's rows and the parked world's header.
        if sessionEpisodes != nil {
            let paused = Settings.playbackSessionPaused()
            if (model == .sessionSection && !paused) || (model == .upNextSection && paused) {
                return 16
            }
        }
        return .leastNormalMagnitude
    }

    /// Session header: the "Session: <name>" line, its counts line while parked (a
    /// playing session's counts live under the Now Playing card instead), plus the inbox
    /// notice line when the playlist has untriaged episodes.
    private var sessionHeaderHeight: CGFloat {
        var height: CGFloat = 34
        // Parked: counts line plus the same breathing room the parked queue header has
        // under its counts.
        if Settings.playbackSessionPaused() { height += 28 }
        if showsSessionInboxNotice { height += 21 }
        return height
    }

    /// Queue header: the title/counts row plus (unless collapsed) the filter indicator
    /// line. A parked queue (session active) keeps its counts line under the title in
    /// every state, so its header is taller.
    private var queueHeaderHeight: CGFloat {
        let metrics = UIFontMetrics(forTextStyle: .footnote)
        let filterRowVisible = FeatureFlag.upNextFilter.enabled && Settings.upNextFilter() != nil && PlaybackManager.shared.queue.upNextCount() > 0 && !isQueueCollapsed
        let queueParked = FeatureFlag.playbackSessions.enabled && Settings.playbackSession() != nil && !Settings.playbackSessionPaused()
        return metrics.scaledValue(for: queueParked ? 62 : 48) + (filterRowVisible ? 26 : 0)
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        let section = tableData[section]
        let metrics = UIFontMetrics(forTextStyle: .footnote)
        switch section {
        case .nowPlayingSection:
            guard sessionEpisodes != nil else { return 16 }
            // The playing world's header renders here, above the card.
            return Settings.playbackSessionPaused() ? queueHeaderHeight : metrics.scaledValue(for: sessionHeaderHeight)
        case .sessionSection:
            // Active session: the header lives above the Now Playing card, this is a spacer.
            // Paused session (or nothing playing): the header bar renders here.
            let headerHere = Settings.playbackSessionPaused() || PlaybackManager.shared.currentEpisode() == nil
            return headerHere ? metrics.scaledValue(for: sessionHeaderHeight) : 8
        case .upNextSection:
            if queueHeaderAboveCard { return 8 } // header rendered above the Now Playing card
            return queueHeaderHeight
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
            if Settings.upNextFilter() == nil, Settings.upNextHideSessionEpisodes() {
                // Emptied by the session eye alone — every queued episode belongs to
                // the session playing above.
                emptyCell.configure(title: L10n.upNextSessionHiddenEmptyTitle,
                                    message: L10n.upNextSessionHiddenEmptyDescription,
                                    icon: { Image(systemName: "eye.slash") },
                    actions: [
                        .init(title: L10n.upNextSessionHiddenShow) {
                            Settings.setUpNextHideSessionEpisodes(false)
                        }
                    ])
                return emptyCell
            }
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
                    // Don't restart an episode that's already playing.
                    if episode.uuid == PlaybackManager.shared.currentEpisode()?.uuid { return }
                    // Same tap behavior as queue rows: play directly or show the episode
                    // card, per the "Play Up Next On Tap" setting.
                    if Settings.playUpNextOnTap() {
                        AnalyticsPlaybackHelper.shared.currentSource = .upNext
                        PlaybackManager.shared.play(sessionEpisode: episode)
                    } else {
                        showEpisodeDetailViewController(for: episode)
                    }
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
            // Playlist and smart playlist sessions are drag-reorderable (it reorders the
            // source playlist itself — the session is a live mirror).
            guard indexPath.row < (sessionEpisodes?.count ?? 0) else { return false }
            let sessionType = Settings.playbackSession()?.type
            return sessionType == .playlist || sessionType == .smartPlaylist
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
            // Within the session section, drops can't land below the inbox notice row.
            if tableData[sourceIndexPath.section] == .sessionSection,
               let episodeCount = sessionEpisodes?.count,
               proposedDestinationIndexPath.row >= episodeCount {
                return IndexPath(row: max(episodeCount - 1, 0), section: proposedDestinationIndexPath.section)
            }
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
            // A row must be editable for its reorder control to show; playlist and smart
            // playlist sessions are drag-reorderable. The inbox notice row stays inert.
            guard indexPath.row < (sessionEpisodes?.count ?? 0) else { return false }
            let sessionType = Settings.playbackSession()?.type
            return sessionType == .playlist || sessionType == .smartPlaylist
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
        // The playing world leads; the parked world sits below it.
        var sections: [sections] = [.upNextSection]

        if sessionEpisodes != nil {
            if Settings.playbackSessionPaused() {
                sections.append(.sessionSection) // parked session below the queue
            } else {
                sections.insert(.sessionSection, at: 0) // playing session above the queue
            }
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
        // The screen title follows the tab bar item: "Session" while one is active.
        let sessionActive = FeatureFlag.playbackSessions.enabled && Settings.playbackSession() != nil
        title = sessionActive ? L10n.playbackSessionTabSession : L10n.upNext
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

/// Fork: "N new episodes in Inbox" row at the end of the session section — tapping it opens
/// the session's playlist so the episodes can be triaged into the lineup.
class SessionInboxNoticeCell: ThemeableCell {
    static let height: CGFloat = 44

    private let noticeLabel = UILabel()
    private let chevron = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        noticeLabel.font = UIFont.font(ofSize: 14, weight: .medium, scalingWith: .footnote)
        noticeLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(noticeLabel)

        chevron.image = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        chevron.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(chevron)

        NSLayoutConstraint.activate([
            noticeLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            noticeLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            chevron.leadingAnchor.constraint(equalTo: noticeLabel.trailingAnchor, constant: 6),
            chevron.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            chevron.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20)
        ])

        updateNoticeColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(inboxCount: Int) {
        noticeLabel.text = inboxCount == 1
            ? L10n.playbackSessionInboxNoticeSingular
            : L10n.playbackSessionInboxNoticePlural(inboxCount.localized())
        updateNoticeColors()
    }

    override func handleThemeDidChange() {
        updateNoticeColors()
    }

    private func updateNoticeColors() {
        let accent = AppTheme.colorForStyle(.primaryInteractive01, themeOverride: themeOverride)
        noticeLabel.textColor = accent
        chevron.tintColor = accent
    }
}
