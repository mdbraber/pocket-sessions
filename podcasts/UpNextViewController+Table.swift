import PocketCastsDataModel
import PocketCastsUtils
import PocketCastsServer
import SwiftUI

extension UpNextViewController: UITableViewDelegate, UITableViewDataSource {
    // MARK: - TableView DataSource

    func numberOfSections(in tableView: UITableView) -> Int {
        tableData.count
    }

    /// The Now Playing card shows in whichever world owns the playing episode: the
    /// session while it plays, the queue otherwise. Peeking at the other world via the
    /// pill shows that world's list without the card.
    var sessionOwnsCard: Bool {
        FeatureFlag.playbackSessions.enabled && Settings.playbackSession() != nil
            && !Settings.playbackSessionPaused() && PlaybackManager.shared.currentEpisode() != nil
    }

    var queueOwnsCard: Bool {
        FeatureFlag.playbackSessions.enabled && PlaybackManager.shared.currentEpisode() != nil && !sessionOwnsCard
    }

    /// Flag-on: the top section holds the optional Now Playing card plus the world's
    /// counts/controls line as rows, so the whole block scrolls with the list.
    var topBlockHasCard: Bool {
        displayedWorld == .session ? sessionOwnsCard : queueOwnsCard
    }

    var topBlockHasControls: Bool {
        if displayedWorld == .session { return Settings.playbackSession() != nil }
        return PlaybackManager.shared.queue.upNextCount() > 0 || PlaybackManager.shared.currentEpisode() != nil
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let section = tableData[section]
        switch section {
        case .nowPlayingSection:
            if !FeatureFlag.playbackSessions.enabled { return 1 }
            return (topBlockHasCard ? 1 : 0) + (topBlockHasControls ? 1 : 0)
        case .sessionSection:
            if Settings.playbackSession() == nil { return 1 } // empty state cell
            return sessionEpisodes?.count ?? 0
        case .upNextSection:
            if PlaybackManager.shared.queue.upNextCount() == 0 { return 1 } // empty state cell
            if isShowingFilterEmptyNotice { return 1 }
            return visibleUpNextCount
        }
    }

    // MARK: - Section Headers

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        // Flag-on: nothing pins — the title is the table's header view and the top
        // block is made of rows.
        if FeatureFlag.playbackSessions.enabled { return nil }
        if tableData[section] == .upNextSection {
            guard tableData.count > 1 else { return nil }
            return preparedQueueHeader()
        }
        return nil
    }

    func preparedQueueHeader() -> UIView {
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

    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        return nil
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        .leastNormalMagnitude
    }


    /// Session header: the "Session: <name>" line with its counts line, plus the inbox
    /// notice line when the playlist has untriaged episodes. No session → no header.
    var sessionHeaderHeight: CGFloat {
        // Title-only block: 8 + 28 title (title2 bold) + 6 — the counts/controls line
        // lives below the card as the list's section header. The queue world shows the
        // same block titled "Up Next".
        if displayedWorld == .upNext { return 42 }
        guard Settings.playbackSession() != nil else { return .leastNormalMagnitude }
        var height: CGFloat = 42
        if showsSessionInboxNotice { height += 21 }
        return height
    }

    /// Queue header: the counts/controls row, plus the filter indicator line when a
    /// filter is active.
    var queueHeaderHeight: CGFloat {
        let metrics = UIFontMetrics(forTextStyle: .footnote)
        let filterRowVisible = FeatureFlag.upNextFilter.enabled && Settings.upNextFilter() != nil && PlaybackManager.shared.queue.upNextCount() > 0
        return metrics.scaledValue(for: 48) + (filterRowVisible ? 26 : 0)
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        if FeatureFlag.playbackSessions.enabled {
            return tableData[section] == .nowPlayingSection ? 8 : .leastNormalMagnitude
        }
        let section = tableData[section]
        switch section {
        case .nowPlayingSection:
            return 16
        case .sessionSection:
            return .leastNormalMagnitude
        case .upNextSection:
            return queueHeaderHeight
        }
    }

    // MARK: - Cell Population

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let section = tableData[indexPath.section]
        if section == .nowPlayingSection {
            if FeatureFlag.playbackSessions.enabled, !(topBlockHasCard && indexPath.row == 0) {
                // The counts/controls line as a scrolling row.
                let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
                cell.selectionStyle = .none
                cell.backgroundColor = .clear
                cell.contentView.backgroundColor = .clear
                let controls = displayedWorld == .session ? sessionControlsView : preparedQueueHeader()
                controls.removeFromSuperview()
                controls.translatesAutoresizingMaskIntoConstraints = false
                cell.contentView.addSubview(controls)
                NSLayoutConstraint.activate([
                    controls.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
                    controls.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor),
                    controls.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
                    controls.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor)
                ])
                return cell
            }
            let nowPlayingCell = tableView.dequeueReusableCell(withIdentifier: UpNextViewController.nowPlayingCell, for: indexPath) as! UpNextNowPlayingCell
            nowPlayingCell.themeOverride = themeOverride
            nowPlayingCell.delegate = self
            if let episode = PlaybackManager.shared.currentEpisode() {
                nowPlayingCell.populateFrom(episode: episode)
            }
            return nowPlayingCell
        }

        if section == .sessionSection {
            if Settings.playbackSession() == nil {
                let emptyCell = tableView.dequeueReusableCell(withIdentifier: UpNextViewController.emptyStateCell, for: indexPath) as! EmptyStateCell
                emptyCell.configure(title: L10n.playbackSessionEmptyTitle,
                                    icon: { Image(systemName: "play.square.stack") },
                    actions: [
                        .init(title: L10n.playbackSessionChoose) { [weak self] in
                            self?.presentSessionPicker(includeUpNext: false)
                        }
                    ])
                return emptyCell
            }
            let playerCell = tableView.dequeueReusableCell(withIdentifier: UpNextViewController.playerCell, for: indexPath) as! PlayerCell
            playerCell.themeOverride = themeOverride
            playerCell.shouldShowSelect(show: isMultiSelectEnabled, animate: false)
            playerCell.delegate = self
            if let episode = sessionEpisodes?[safe: indexPath.row] {
                playerCell.populateFrom(episode: episode)
                // Session rows ARE the session — but show when one is also queued.
                playerCell.setSessionIndicator(visible: false)
                playerCell.setUpNextIndicator(visible: PlaybackManager.shared.inUpNext(episode: episode))
                playerCell.setNowPlaying(PlaybackManager.shared.isNowPlayingEpisode(episodeUuid: episode.uuid))
                playerCell.showTick = selectedEpisodesContains(uuid: episode.uuid)
            } else {
                playerCell.showTick = false
            }
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
            playerCell.setSessionIndicator(visible: sessionMemberUuidsForDisplay.contains(episode.uuid))
            playerCell.setUpNextIndicator(visible: false)
            // Fork: session playback can leave the sounding episode sitting in the
            // queue — the equalizer bars + accent title mark it.
            playerCell.setNowPlaying(PlaybackManager.shared.isNowPlayingEpisode(episodeUuid: episode.uuid))
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
        if tableData[indexPath.section] == .nowPlayingSection {
            if FeatureFlag.playbackSessions.enabled, !(topBlockHasCard && indexPath.row == 0) { return nil }
            return indexPath
        }
        if tableData[indexPath.section] == .sessionSection {
            // The empty state's button is the only action when no session is active.
            if Settings.playbackSession() == nil { return nil }
            if isMultiSelectEnabled, !multiSelectGestureInProgress,
               let episode = sessionEpisodes?[safe: indexPath.row], selectedEpisodesContains(uuid: episode.uuid) {
                tableView.delegate?.tableView?(tableView, didDeselectRowAt: indexPath)
                return nil
            }
            return indexPath
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
        if isMultiSelectEnabled, tableData[indexPath.section] == .sessionSection {
            guard let episode = sessionEpisodes?[safe: indexPath.row] else { return }
            if !multiSelectGestureInProgress {
                selectedEpisodesRemove(uuid: episode.uuid)
            }
            if !multiSelectGestureInProgress || !selectedEpisodesContains(uuid: episode.uuid) {
                selectedSessionEpisodes.append(episode)
                if let cell = upNextTable.cellForRow(at: indexPath) as? PlayerCell {
                    cell.showTick = true
                }
            }
            return
        }

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

            // Tapping the Now Playing card opens the full-screen player — unless it's
            // sitting paused and tap-to-play is on, in which case it resumes.
            if section == .nowPlayingSection {
                guard !FeatureFlag.playbackSessions.enabled || (topBlockHasCard && indexPath.row == 0) else { return }
                if Settings.playUpNextOnTap(), !PlaybackManager.shared.playing() {
                    PlaybackManager.shared.play()
                    return
                }
                track(.upNextNowPlayingTapped)

                dismiss(animated: true, completion: {
                    if let miniPlayer = UIApplication.shared.appDelegate()?.miniPlayer(), miniPlayer.playerOpenState == .closed {
                        UIApplication.shared.appDelegate()?.miniPlayer()?.openFullScreenPlayer()
                    }
                })

                return
            }

            if section == .sessionSection {
                if let episode = sessionEpisodes?[safe: indexPath.row] {
                    // The current episode shouldn't restart from scratch — but if it's
                    // sitting idle (loaded, not playing), tapping it starts playback.
                    if episode.uuid == PlaybackManager.shared.currentEpisode()?.uuid {
                        if Settings.playUpNextOnTap(), !PlaybackManager.shared.playing() {
                            AnalyticsPlaybackHelper.shared.currentSource = .upNext
                            PlaybackManager.shared.play(sessionEpisode: episode)
                        }
                        return
                    }
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

            if isShowingFilterEmptyNotice { return }

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
        if tableData[indexPath.section] == .sessionSection {
            guard let episode = sessionEpisodes?[safe: indexPath.row] else { return }
            selectedEpisodesRemove(uuid: episode.uuid)
            if let cell = upNextTable.cellForRow(at: indexPath) as? PlayerCell {
                cell.showTick = false
            }
            return
        }
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
        } else if section == .upNextSection {
            if PlaybackManager.shared.queue.upNextCount() == 0 || isShowingFilterEmptyNotice { return false }
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
        let fromRow = sourceIndexPath.row
        let toRow = destinationIndexPath.row

        if visibleQueueIndices != nil {
            moveVisibleEpisode(fromVisibleRow: fromRow, toVisibleRow: toRow)
        } else {
            playQueue.moveEpisode(from: fromRow, to: toRow)
        }

        // This logic is reversed because the lower the row number the higher it is in the queue
        let didMoveUp = toRow < fromRow
        let slots = abs(toRow - fromRow)
        let isTop = toRow == 0

        track(.upNextQueueReordered, properties: ["direction": didMoveUp ? "up" : "down", "slots": slots, "is_next": isTop])
    }

    func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath, toProposedIndexPath proposedDestinationIndexPath: IndexPath) -> IndexPath {
        // Rows can only be reordered within their own section — session episodes and queue
        // episodes live in different worlds.
        if tableData[proposedDestinationIndexPath.section] == tableData[sourceIndexPath.section] {
            if tableData[sourceIndexPath.section] == .sessionSection {
                let maxRow = max((sessionEpisodes?.count ?? 1) - 1, 0)
                return IndexPath(row: min(proposedDestinationIndexPath.row, maxRow), section: proposedDestinationIndexPath.section)
            }
            return proposedDestinationIndexPath
        }

        return IndexPath(row: sourceIndexPath.row, section: sourceIndexPath.section)
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
            // playlist sessions are drag-reorderable.
            guard indexPath.row < (sessionEpisodes?.count ?? 0) else { return false }
            let sessionType = Settings.playbackSession()?.type
            return sessionType == .playlist || sessionType == .smartPlaylist
        case .nowPlayingSection:
            return false
        }
    }

    // MARK: - Cell Heights

    private func rowHeight(at indexPath: IndexPath) -> CGFloat {
        let section = tableData[indexPath.section]
        if section == .nowPlayingSection {
            if FeatureFlag.playbackSessions.enabled, !(topBlockHasCard && indexPath.row == 0) {
                let metrics = UIFontMetrics(forTextStyle: .footnote)
                // A touch of air below the card: the label sits low in the row
                // (top-heavy padding), keeping the tight gap to the episode below.
                if displayedWorld == .session { return metrics.scaledValue(for: 48) }
                let filterRowVisible = FeatureFlag.upNextFilter.enabled && Settings.upNextFilter() != nil && PlaybackManager.shared.queue.upNextCount() > 0
                return metrics.scaledValue(for: 50) + (filterRowVisible ? 26 : 0)
            }
            return UpNextViewController.nowPlayingRowHeight
        }
        if section == .sessionSection {
            if Settings.playbackSession() == nil { return UpNextViewController.emptyStateRowHeight }
            return UpNextViewController.upNextRowHeight
        }
        if PlaybackManager.shared.queue.upNextCount() == 0 || isShowingFilterEmptyNotice { return UpNextViewController.emptyStateRowHeight }
        return UpNextViewController.upNextRowHeight
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        rowHeight(at: indexPath)
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        rowHeight(at: indexPath)
    }

    // MARK: - Multiselect

    func tableView(_ tableView: UITableView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
        (tableData[indexPath.section] == .upNextSection || tableData[indexPath.section] == .sessionSection) && Settings.multiSelectGestureEnabled()
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
        var sections: [sections]

        if FeatureFlag.playbackSessions.enabled {
            // One world at a time, chosen by the pill switcher. Each world gets the stock
            // layout: the Now Playing card floats on top only when that world owns it.
            // Top block (card + controls line) scrolls with the list.
            sections = [.nowPlayingSection, displayedWorld == .session ? .sessionSection : .upNextSection]
        } else {
            sections = [.upNextSection]
            if PlaybackManager.shared.currentEpisode() != nil {
                sections.insert(.nowPlayingSection, at: 0)
            }
        }

        if PlaybackManager.shared.currentEpisode() != nil {
            upNextTable.themeStyle = .primaryUi04
        } else {
            upNextTable.backgroundColor = UIColor(Theme.sharedTheme.primaryUi02)
        }

        tableData = sections
    }

    /// Fork: uuids across every session store — drives the green in-a-session
    /// indicator on queue rows. Refreshed per table reload, not per row.
    private static var cachedSessionMemberUuids: Set<String> = []

    func refreshSessionMembership() {
        Self.cachedSessionMemberUuids = Set(SessionStore.shared.sessions.flatMap { SessionFeederEngine.storeMemberUuids(for: $0) })
    }

    var sessionMemberUuidsForDisplay: Set<String> { Self.cachedSessionMemberUuids }

    @objc func reloadTable() {
        refreshSessionMembership()
        refreshUpNextFilterMatches()
        refreshSections()
        // The title (and tab bar item) follows who owns playback: "Session" while the
        // session is playing, "Up Next" while the queue is (or nothing is).
        let sessionIsActiveWorld = FeatureFlag.playbackSessions.enabled && Settings.playbackSession() != nil && !Settings.playbackSessionPaused()
        title = sessionIsActiveWorld ? L10n.playbackSessionTabSession : L10n.upNext
        // The bottom tab bar button names the playing world too.
        navigationController?.tabBarItem.title = title
        updateWorldSwitcher()
        updateStickyChrome()
        // Nav buttons are world-dependent (Switch vs Clear) — keep them in step.
        updateNavBarButtons()
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
