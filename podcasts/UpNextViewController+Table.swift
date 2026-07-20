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
    /// The session owns the card whenever the player is holding one of its episodes —
    /// sounding or not. This must NOT be narrowed to "actually playing": `queueOwnsCard`
    /// is its complement, so a session that disowns its own episode hands that episode to
    /// the Up Next world as *its* Now Playing card, and the episode stops being tappable
    /// (it is already the player's current episode, so a row tap has nothing to do).
    var sessionOwnsCard: Bool {
        Settings.playbackSession() != nil
            && !Settings.playbackSessionPaused() && PlaybackManager.shared.currentEpisode() != nil
    }

    var queueOwnsCard: Bool {
        PlaybackManager.shared.currentEpisode() != nil && !sessionOwnsCard
    }

    /// Fork: the session is actually making noise — as opposed to merely holding an
    /// episode on the card (primed by opening the session, or paused mid-episode).
    /// When it isn't sounding the card is just "what's next", which changes what "top of
    /// the list" means (see `moveSessionEpisodeToTop`) and where the info line sits.
    var sessionIsSounding: Bool {
        PlaybackManager.shared.playing() && sessionOwnsCard
    }

    /// Fork: "Paused — playing from Up Next" banner shown at the top of the session
    /// world while the session sits parked behind queue playback. It lives as row 0 of
    /// the top block (never alongside the Now Playing card — the banner needs a paused
    /// session, the card an active one) so session-section episode indices stay stable.
    /// Only the ACTIVE session's own lineup can be "paused behind the queue" — browsing
    /// another session says nothing about playback, so it gets no banner.
    var showsSessionPausedBanner: Bool {
        displayedWorld == .session && sessionLevel == .lineup
            && browsingActiveSession && Settings.playbackSessionPaused()
    }

    func isSessionPausedBannerRow(_ indexPath: IndexPath) -> Bool {
        tableData[indexPath.section] == .nowPlayingSection && showsSessionPausedBanner && indexPath.row == 0
    }

    /// Fork: the paused banner's tap — resumes the session at its last-played episode,
    /// falling back to the first remaining one. Same call as the session row-tap resume.
    func resumePausedSession() {
        guard let session = Settings.playbackSession(), Settings.playbackSessionPaused() else { return }
        let remaining = session.remainingEpisodes(excluding: nil)
        guard let episode = remaining.first(where: { $0.uuid == Settings.playbackSessionLastEpisodeUuid() }) ?? remaining.first else { return }
        AnalyticsPlaybackHelper.shared.currentSource = .upNext
        PlaybackManager.shared.play(sessionEpisode: episode)
    }

    /// Flag-on: the top section holds the optional Now Playing card plus the world's
    /// counts/controls line as rows, so the whole block scrolls with the list.
    var topBlockHasCard: Bool {
        // The chooser is a list of sessions — no episode is "playing" at that level.
        if showingSessionList { return false }
        // The card belongs to the lineup only when the browsed session IS the active one:
        // browsing another session must show no card at all.
        return displayedWorld == .session ? browsedSessionOwnsCard : queueOwnsCard
    }

    var topBlockHasControls: Bool {
        // The chooser's only header is its counts line, and an empty chooser doesn't
        // need one either.
        if showingSessionList { return !sessionListRows.isEmpty }
        // A world with a single episode (just the one on the card) has nothing to count,
        // sort or shuffle — the info row is noise, so drop it.
        guard topBlockEpisodeCount > 1 else { return false }
        if displayedWorld == .session { return browsedPlaybackSession != nil }
        return PlaybackManager.shared.queue.upNextCount() > 0 || PlaybackManager.shared.currentEpisode() != nil
    }

    /// Episodes in the current world, counting the now-playing card.
    var topBlockEpisodeCount: Int {
        if displayedWorld == .session {
            return (browsedSessionOwnsCard ? 1 : 0) + (sessionEpisodes?.count ?? 0)
        }
        return (queueOwnsCard ? 1 : 0) + PlaybackManager.shared.queue.upNextCount()
    }

    /// Fork: while the session isn't sounding its card is just "what's next" — the head of
    /// the list rather than something being listened to — so the counts/controls line
    /// reads as the list's header and belongs above it. Sounding: card first, as before.
    var topBlockControlsAboveCard: Bool {
        topBlockHasCard && displayedWorld == .session && !sessionIsSounding
    }

    /// Row index of the Now Playing card inside the top block, or nil when there's no card.
    /// The paused banner never coexists with the card (the banner needs a paused session,
    /// the card an active one), so only the controls line can sit above it.
    var topBlockCardRow: Int? {
        guard topBlockHasCard else { return nil }
        return (topBlockControlsAboveCard && topBlockHasControls) ? 1 : 0
    }

    func isTopBlockCardRow(_ indexPath: IndexPath) -> Bool {
        tableData[indexPath.section] == .nowPlayingSection && indexPath.row == topBlockCardRow
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let section = tableData[section]
        switch section {
        case .nowPlayingSection:
            return (showsSessionPausedBanner ? 1 : 0) + (topBlockHasCard ? 1 : 0) + (topBlockHasControls ? 1 : 0)
        case .sessionSection:
            if showingSessionList { return max(sessionListRows.count, 1) } // 1 = empty state cell
            if browsedPlaybackSession == nil { return 1 } // empty state cell
            return sessionEpisodes?.count ?? 0
        case .upNextSection:
            if PlaybackManager.shared.queue.upNextCount() == 0 { return 1 } // empty state cell
            return PlaybackManager.shared.queue.upNextCount()
        }
    }

    // MARK: - Section Headers

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        // Nothing pins — the title is the table's header view and the top block is
        // made of rows.
        nil
    }

    func preparedQueueHeader() -> UIView {
        let headerView = self.headerView

        updateTimeRemainingLabel()

        // The clear text button always shows alongside the shuffle icon.
        shuffleButton.isHidden = !FeatureFlag.upNextShuffle.enabled || PlaybackManager.shared.queue.upNextCount() == 0
        clearQueueButton.isHidden = false
        clearQueueButton.isEnabled = PlaybackManager.shared.queue.upNextCount() > 0
        if FeatureFlag.upNextSort.enabled {
            sortButton.isHidden = PlaybackManager.shared.queue.upNextCount() == 0
        }

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
    /// 8 above the title + 28 for the title itself + 8 below it.
    static let titleBlockHeight: CGFloat = 44

    var sessionHeaderHeight: CGFloat {
        // One title block everywhere: 8 above the title + 28 title (title2 bold) + 8 below.
        // "Up Next", "Sessions" and a session's own name all sit identically, so nothing
        // shifts as you switch worlds or move between the chooser and a lineup.
        if displayedWorld == .upNext { return Self.titleBlockHeight }
        // The chooser always has a title ("Sessions"); only the lineup needs a session.
        if showingSessionList { return Self.titleBlockHeight }
        guard browsedPlaybackSession != nil else { return .leastNormalMagnitude }
        var height: CGFloat = Self.titleBlockHeight
        if showsSessionInboxNotice { height += 21 }
        return height
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        tableData[section] == .nowPlayingSection ? .leastNormalMagnitude : .leastNormalMagnitude
    }

    // MARK: - Cell Population

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let section = tableData[indexPath.section]
        if section == .nowPlayingSection {
            if isSessionPausedBannerRow(indexPath) {
                let bannerCell = tableView.dequeueReusableCell(withIdentifier: UpNextViewController.sessionPausedBannerCell, for: indexPath) as! SessionPausedBannerCell
                bannerCell.themeOverride = themeOverride
                return bannerCell
            }
            if !isTopBlockCardRow(indexPath) {
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
            if showingSessionList {
                guard let row = sessionListRows[safe: indexPath.row] else {
                    let emptyCell = tableView.dequeueReusableCell(withIdentifier: UpNextViewController.emptyStateCell, for: indexPath) as! EmptyStateCell
                    emptyCell.configure(title: L10n.sessionListNoneTitle,
                                        message: L10n.sessionListNoneMessage,
                                        icon: { Image(systemName: "rectangle.stack") },
                        actions: [
                            .init(title: L10n.sessionListNoneAction) {
                                NavigationManager.sharedManager.navigateTo(NavigationManager.podcastListPageKey, data: nil)
                            }
                        ])
                    return emptyCell
                }
                let sessionCell = tableView.dequeueReusableCell(withIdentifier: SessionListCell.reuseIdentifier, for: indexPath) as! SessionListCell
                sessionCell.themeOverride = themeOverride
                sessionCell.populate(from: row)
                return sessionCell
            }
            if browsedPlaybackSession == nil {
                let emptyCell = tableView.dequeueReusableCell(withIdentifier: UpNextViewController.emptyStateCell, for: indexPath) as! EmptyStateCell
                emptyCell.configure(title: L10n.playbackSessionEmptyTitle,
                                    icon: { Image(systemName: "rectangle.stack") })
                return emptyCell
            }
            let playerCell = tableView.dequeueReusableCell(withIdentifier: UpNextViewController.playerCell, for: indexPath) as! PlayerCell
            playerCell.themeOverride = themeOverride
            playerCell.shouldShowSelect(show: isMultiSelectEnabled, animate: false)
            playerCell.delegate = self
            if let episode = sessionEpisodes?[safe: indexPath.row] {
                playerCell.populateFrom(episode: episode)
                // This IS the session tab — every row is a member, so the session badge is redundant.
                playerCell.setSessionIndicator(.none)
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

        let playerCell = tableView.dequeueReusableCell(withIdentifier: UpNextViewController.playerCell, for: indexPath) as! PlayerCell
        playerCell.themeOverride = themeOverride
        playerCell.shouldShowSelect(show: isMultiSelectEnabled, animate: false)
        playerCell.delegate = self

        if let episode = PlaybackManager.shared.queue.episodeAt(index: indexPath.row) {
            playerCell.populateFrom(episode: episode)
            playerCell.setSessionIndicator(SessionIndicatorState.resolve(episode.uuid, thisSession: sessionMemberUuidsForDisplay))
            playerCell.setUpNextIndicator(visible: false)
            // Fork: session playback can leave the sounding episode sitting in the
            // queue — the equalizer bars + accent title mark it.
            playerCell.setNowPlaying(PlaybackManager.shared.isNowPlayingEpisode(episodeUuid: episode.uuid))
            playerCell.showTick = selectedEpisodesContains(uuid: episode.uuid)
            playerCell.contentView.alpha = 1
        }
        return playerCell
    }

    // MARK: - Selection

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        if tableData[indexPath.section] == .nowPlayingSection {
            // The paused banner is one big Resume button (not part of multi-select).
            if isSessionPausedBannerRow(indexPath) { return isMultiSelectEnabled ? nil : indexPath }
            if !isTopBlockCardRow(indexPath) { return nil }
            return indexPath
        }
        if tableData[indexPath.section] == .sessionSection {
            // Chooser rows are tappable (they open a session); its empty state isn't.
            if showingSessionList { return sessionListRows[safe: indexPath.row] == nil ? nil : indexPath }
            // The empty state is inert when there's no session to show a lineup for.
            if browsedPlaybackSession == nil { return nil }
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

        if let episode = DataManager.sharedManager.playlistEpisodeAt(index: indexPath.row + 1) {
            if selectedEpisodesContains(uuid: episode.episodeUuid) {
                tableView.delegate?.tableView?(tableView, didDeselectRowAt: indexPath)
                return nil
            }
            return indexPath
        }
        return nil
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        // Chooser rows: pick a session and drop into its lineup. No multi-select here.
        if showingSessionList, tableData[indexPath.section] == .sessionSection {
            tableView.deselectRow(at: indexPath, animated: true)
            guard let row = sessionListRows[safe: indexPath.row] else { return }
            openSessionFromList(row)
            return
        }

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
            if let episode = DataManager.sharedManager.playlistEpisodeAt(index: indexPath.row + 1) {
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
                if isSessionPausedBannerRow(indexPath) {
                    resumePausedSession()
                    return
                }
                guard isTopBlockCardRow(indexPath) else { return }
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
                    // Browsing another session is pure navigation — playing from it is
                    // what makes it the active one.
                    if !browsingActiveSession {
                        if Settings.playUpNextOnTap() {
                            playFromBrowsedSession(episode: episode)
                        } else {
                            showEpisodeDetailViewController(for: episode, fromSession: true)
                        }
                        return
                    }
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
                        showEpisodeDetailViewController(for: episode, fromSession: true)
                    }
                }
                return
            }

            guard let episode = PlaybackManager.shared.queue.episodeAt(index: indexPath.row) else { return }

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
        if showingSessionList { return }
        if tableData[indexPath.section] == .sessionSection {
            guard let episode = sessionEpisodes?[safe: indexPath.row] else { return }
            selectedEpisodesRemove(uuid: episode.uuid)
            if let cell = upNextTable.cellForRow(at: indexPath) as? PlayerCell {
                cell.showTick = false
            }
            return
        }
        guard tableData[indexPath.section] == .upNextSection else { return }
        if let episode = DataManager.sharedManager.playlistEpisodeAt(index: indexPath.row + 1), let index = selectedPlayListEpisodes.firstIndex(of: episode) {
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
            // Chooser rows never reorder.
            if showingSessionList { return false }
            // Playlist and smart playlist sessions are drag-reorderable (it reorders the
            // source playlist itself — the session is a live mirror).
            guard indexPath.row < (sessionEpisodes?.count ?? 0) else { return false }
            let sessionType = browsedPlaybackSession?.type
            return sessionType == .playlist || sessionType == .smartPlaylist
        } else if section == .upNextSection {
            if PlaybackManager.shared.queue.upNextCount() == 0 { return false }
        }
        return true
    }

    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        if sourceIndexPath == destinationIndexPath { return }

        // Dropped onto the card: the dragged episode becomes the session's next one.
        if tableData[sourceIndexPath.section] == .sessionSection,
           tableData[destinationIndexPath.section] == .nowPlayingSection {
            moveSessionEpisodeToTop(fromRow: sourceIndexPath.row)
            return
        }

        if tableData[sourceIndexPath.section] == .sessionSection {
            // A drop on row 0 means "make this the top of the lineup" — the same intent as
            // the move-to-top swipe, so it goes through the same entry point (which is what
            // makes row 0 reach above a non-sounding card).
            if destinationIndexPath.row == 0 {
                moveSessionEpisodeToTop(fromRow: sourceIndexPath.row)
            } else {
                moveSessionEpisode(fromRow: sourceIndexPath.row, toRow: destinationIndexPath.row)
            }
            return
        }

        let playQueue = PlaybackManager.shared.queue
        let fromRow = sourceIndexPath.row
        let toRow = destinationIndexPath.row

        playQueue.moveEpisode(from: fromRow, to: toRow)

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

        // Dragging UP into the top block. When the card is merely "what's next" (nothing
        // sounding), the CARD ITSELF is a valid destination: returning its index path gives
        // the drag something to land on, and — unlike clamping to row 0 of the list — it
        // still reports a move when the dragged row is already row 0. That is what lets the
        // first list row be lifted above the card at all.
        if tableData[proposedDestinationIndexPath.section] == .nowPlayingSection,
           tableData[sourceIndexPath.section] == .sessionSection,
           browsedSessionOwnsCard, !sessionIsSounding, let cardRow = topBlockCardRow {
            return IndexPath(row: cardRow, section: proposedDestinationIndexPath.section)
        }

        if tableData[proposedDestinationIndexPath.section] == .nowPlayingSection {
            return IndexPath(row: 0, section: sourceIndexPath.section)
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
            // Chooser rows have no swipe/reorder editing.
            if showingSessionList { return false }
            // A row must be editable for its reorder control to show; playlist and smart
            // playlist sessions are drag-reorderable.
            guard indexPath.row < (sessionEpisodes?.count ?? 0) else { return false }
            let sessionType = browsedPlaybackSession?.type
            return sessionType == .playlist || sessionType == .smartPlaylist
        case .nowPlayingSection:
            return false
        }
    }

    // MARK: - Cell Heights

    private func rowHeight(at indexPath: IndexPath) -> CGFloat {
        let section = tableData[indexPath.section]
        if section == .nowPlayingSection {
            if isSessionPausedBannerRow(indexPath) {
                return UIFontMetrics(forTextStyle: .footnote).scaledValue(for: SessionPausedBannerCell.height)
            }
            if !isTopBlockCardRow(indexPath) {
                let metrics = UIFontMetrics(forTextStyle: .footnote)
                // A touch of air below the card: the label sits low in the row
                // (top-heavy padding), keeping the tight gap to the episode below.
                // One height for both worlds: the info line sits the same distance above
                // the first row wherever it appears.
                return metrics.scaledValue(for: 50)
            }
            return UpNextViewController.nowPlayingRowHeight
        }
        if section == .sessionSection {
            if showingSessionList {
                return sessionListRows[safe: indexPath.row] == nil ? UpNextViewController.emptyStateRowHeight : UITableView.automaticDimension
            }
            if browsedPlaybackSession == nil { return UpNextViewController.emptyStateRowHeight }
            return UpNextViewController.upNextRowHeight
        }
        if PlaybackManager.shared.queue.upNextCount() == 0 { return UpNextViewController.emptyStateRowHeight }
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
        !showingSessionList
            && (tableData[indexPath.section] == .upNextSection || tableData[indexPath.section] == .sessionSection)
            && Settings.multiSelectGestureEnabled()
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

        // One world at a time, chosen by the pill switcher. Each world gets the stock
        // layout: the Now Playing card floats on top only when that world owns it.
        // Top block (card + controls line) scrolls with the list.
        sections = [.nowPlayingSection, displayedWorld == .session ? .sessionSection : .upNextSection]

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
        refreshSessionState()
        refreshSections()
        // The title (and tab bar item) follows who owns playback: "Session" while the
        // session is playing, "Up Next" while the queue is (or nothing is).
        let sessionIsActiveWorld = Settings.playbackSession() != nil && !Settings.playbackSessionPaused()
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
        if isMultiSelectEnabled {
            let upNextUuids = Set(DataManager.sharedManager.allUpNextPlaylistEpisodes().map(\.episodeUuid))
            selectedPlayListEpisodes.removeAll { !upNextUuids.contains($0.episodeUuid) }

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
              let episode = PlaybackManager.shared.queue.episodeAt(index: indexPath.row) else { return }

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

/// Fork: "Paused — playing from Up Next" banner at the top of the session world while
/// the session is parked behind queue playback — the whole row is a Resume button.
class SessionPausedBannerCell: ThemeableCell {
    static let height: CGFloat = 44

    private let bannerLabel = UILabel()
    private let resumeLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        bannerLabel.font = UIFont.font(ofSize: 14, weight: .medium, scalingWith: .footnote)
        bannerLabel.text = L10n.sessionPausedBanner
        bannerLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bannerLabel)

        resumeLabel.font = UIFont.font(ofSize: 14, weight: .semibold, scalingWith: .footnote)
        resumeLabel.text = L10n.sessionResume
        resumeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        resumeLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(resumeLabel)

        NSLayoutConstraint.activate([
            bannerLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            bannerLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            bannerLabel.trailingAnchor.constraint(lessThanOrEqualTo: resumeLabel.leadingAnchor, constant: -10),
            resumeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            resumeLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])

        // The row acts as a single Resume button.
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "\(L10n.sessionPausedBanner), \(L10n.sessionResume)"

        updateBannerColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func handleThemeDidChange() {
        // updateColor repaints the backgrounds with the style color — this row sits
        // directly on the table's background, so put the clear back.
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        updateBannerColors()
    }

    private func updateBannerColors() {
        bannerLabel.textColor = AppTheme.colorForStyle(.primaryText02, themeOverride: themeOverride)
        resumeLabel.textColor = AppTheme.colorForStyle(.primaryInteractive01, themeOverride: themeOverride)
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
