import PocketCastsDataModel
import PocketCastsUtils
import PocketCastsServer
import SwiftUI
import UIKit

extension UpNextViewController: UITableViewDelegate, UITableViewDataSource {
    // MARK: - TableView DataSource

    func numberOfSections(in tableView: UITableView) -> Int {
        tableData.count
    }

    /// The Now Playing card shows in whichever world owns the *playing episode*: the session
    /// while the player is holding one of ITS episodes, the queue otherwise. Peeking at the other
    /// world via the pill shows that world's list without the card.
    /// "Holding one of its episodes" — sounding or not — so it is NOT narrowed to `playing()`; but
    /// it IS narrowed to the source, so playing a queue episode (even mid-session) hands the card to
    /// the Up Next world and the session drops back to regular rows.
    var sessionOwnsCard: Bool {
        !Settings.playbackSessionPaused()
            && PlaybackManager.shared.currentEpisodeIsSessionSourced
            && PlaybackManager.shared.currentEpisode() != nil
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

    /// Fork: the "Paused — playing from Up Next" banner was removed (the user didn't want it), so it
    /// never shows. Kept as a single flag so the row-count / cell-for-row / height paths that check it
    /// all simply skip it.
    var showsSessionPausedBanner: Bool { false }

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
        // Fork (Model B): the Session world PINS the current episode as a top-block card — the
        // sort/reorder below it never moves it. Its next-up (browsed session) or now-playing
        // (active session) episode is the head.
        if displayedWorld == .session { return sessionCurrentEpisode != nil }
        // Up Next world: the head is the queue's own Now Playing card, OR — when a session owns
        // playback — that session's episode surfaced as the queue head (a plain player row, below).
        return queueOwnsCard || upNextShowsSessionHeadRow
    }

    /// Fork: the lineup episode search — a row between the pinned card and the info line, on both
    /// the Session details and Up Next details screens. Present only when there's a tail worth
    /// filtering (more than the pinned card) or a query is already active.
    var topBlockHasLineupSearch: Bool {
        if showingSessionList { return false }
        if displayedWorld == .session {
            guard browsedPlaybackSession != nil else { return false }
            return (sessionEpisodes?.isEmpty == false) || lineupSearchActive
        }
        // Up Next details.
        return PlaybackManager.shared.queue.upNextCount() > 0 || lineupSearchActive
    }

    /// Fork: sessions are now kept fully separate from Up Next — a session's now-playing episode
    /// lives ONLY in its own lineup, never surfaced as the queue world's head row. (Previously it
    /// showed as an equalizer head here; that made a paused session's episode look like the queue's
    /// now-playing and, on remove, advance the session and "refill". Up Next shows only the queue.)
    var upNextShowsSessionHeadRow: Bool {
        false
    }

    var topBlockHasControls: Bool {
        // Fork: the session list carries no counts/controls line — the rows speak for themselves.
        if showingSessionList { return false }
        // A world with a single episode (just the one on the card) has nothing to count,
        // sort or shuffle — the info row is noise, so drop it.
        guard topBlockEpisodeCount > 1 else { return false }
        if displayedWorld == .session { return browsedPlaybackSession != nil }
        return PlaybackManager.shared.queue.upNextCount() > 0 || PlaybackManager.shared.currentEpisode() != nil
    }

    /// Episodes in the current world, counting the now-playing/pinned card.
    var topBlockEpisodeCount: Int {
        if displayedWorld == .session {
            // Pinned current (card) + the reorderable tail.
            return (sessionCurrentEpisode != nil ? 1 : 0) + (sessionEpisodes?.count ?? 0)
        }
        return (topBlockHasCard ? 1 : 0) + PlaybackManager.shared.queue.upNextCount()
    }

    /// Fork: the top block is laid out as [pinned card] → [lineup search] → [info line], in that
    /// order, for both the Session details and Up Next details screens.
    var topBlockCardRow: Int? {
        topBlockHasCard ? 0 : nil
    }

    var topBlockLineupSearchRow: Int? {
        guard topBlockHasLineupSearch else { return nil }
        return topBlockHasCard ? 1 : 0
    }

    var topBlockControlsRow: Int? {
        guard topBlockHasControls else { return nil }
        return (topBlockHasCard ? 1 : 0) + (topBlockHasLineupSearch ? 1 : 0)
    }

    func isTopBlockCardRow(_ indexPath: IndexPath) -> Bool {
        tableData[indexPath.section] == .nowPlayingSection && indexPath.row == topBlockCardRow
    }

    func isTopBlockLineupSearchRow(_ indexPath: IndexPath) -> Bool {
        tableData[indexPath.section] == .nowPlayingSection && topBlockLineupSearchRow != nil && indexPath.row == topBlockLineupSearchRow
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let section = tableData[section]
        switch section {
        case .nowPlayingSection:
            return (topBlockHasCard ? 1 : 0) + (topBlockHasLineupSearch ? 1 : 0) + (topBlockHasControls ? 1 : 0)
        case .sessionSection:
            if showingSessionList { return max(sessionListRows.count, 1) + (showSessionSearchRow ? 1 : 0) } // 1 = empty state cell
            if browsedPlaybackSession == nil { return 1 } // empty state cell
            // The pinned current is the top-block card; this section is the reorderable tail
            // (filtered by the lineup search when a query is active).
            return filteredSessionTail.count
        case .upNextSection:
            if lineupSearchActive { return max(filteredUpNextEpisodes.count, 1) } // 1 = empty state cell
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

        shuffleButton.isHidden = !FeatureFlag.upNextShuffle.enabled || PlaybackManager.shared.queue.upNextCount() == 0
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
            // Fork: the lineup episode search — a row between the pinned card and the info line.
            if isTopBlockLineupSearchRow(indexPath) {
                return lineupSearchCell
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
                    // Leave a gap below the info line before the first episode row.
                    controls.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -14),
                    controls.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
                    controls.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor)
                ])
                return cell
            }
            // Fork (Model B): the pinned card. Session details pins the current session episode;
            // Up Next details pins the queue's now-playing episode. Both use the SAME styled
            // EpisodeCell as the lineup rows so the screens read identically.
            if displayedWorld == .session, let episode = sessionCurrentEpisode {
                return sessionEpisodeCell(for: episode, active: browsingActiveSession && !activeBoxSuppressed, at: indexPath)
            }
            if let episode = PlaybackManager.shared.currentEpisode() {
                return queueEpisodeCell(for: episode, active: true, at: indexPath)
            }
            let blank = tableView.dequeueReusableCell(withIdentifier: UpNextViewController.episodeCell, for: indexPath) as! EpisodeCell
            blank.themeOverride = themeOverride
            blank.showsReorderControl = false
            blank.showTick = false
            return blank
        }

        if section == .sessionSection {
            if showingSessionList {
                // The search + ⋯ header rides at table row 1, between Up Next and the current session.
                if isSessionSearchRow(indexPath) { return sessionSearchCell }
                guard let listIndex = sessionListIndex(forTableRow: indexPath.row),
                      let row = sessionListRows[safe: listIndex] else {
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
                // Tapping the row opens the lane's page (see didSelect); the play button plays it.
                sessionCell.onPlayTapped = { [weak self] in self?.playSessionLane(row) }
                sessionCell.upNextInSessionList = Settings.upNextInSessionList()
                // The first session (list index 1, below the Up Next row) is the "top session".
                sessionCell.isTopSession = listIndex == 1 && !row.isUpNext
                sessionCell.populate(from: row, placement: sessionPlacement(at: listIndex), reordering: sessionListReorderMode)
                sessionCell.setActiveBoxSuppressed(activeBoxSuppressed)
                // In Reorder Items mode the pool rows show a drag handle; Up Next and the current
                // session are pinned. (All indices map through `sessionListIndex` for the search row.)
                sessionCell.showsReorderControl = sessionListReorderMode && sessionPlacement(at: listIndex) == .pool
                return sessionCell
            }
            if browsedPlaybackSession == nil {
                let emptyCell = tableView.dequeueReusableCell(withIdentifier: UpNextViewController.emptyStateCell, for: indexPath) as! EmptyStateCell
                emptyCell.configure(title: L10n.playbackSessionEmptyTitle,
                                    icon: { Image(systemName: "rectangle.stack") })
                return emptyCell
            }
            // Fork: the session lineup tail — the reorderable episodes below the pinned current.
            // The pinned current is the top-block card (see nowPlayingSection), so no tail row is
            // ever "active"; the accent box lives on the card.
            guard let episode = filteredSessionTail[safe: indexPath.row] else {
                let cell = tableView.dequeueReusableCell(withIdentifier: UpNextViewController.episodeCell, for: indexPath) as! EpisodeCell
                cell.themeOverride = themeOverride
                cell.showsReorderControl = false
                cell.showTick = false
                return cell
            }
            return sessionEpisodeCell(for: episode, active: false, at: indexPath)
        }

        // Fork: while a lineup query is active, Up Next details render the filtered up-next episodes.
        if lineupSearchActive {
            guard let episode = filteredUpNextEpisodes[safe: indexPath.row] else {
                let emptyCell = tableView.dequeueReusableCell(withIdentifier: UpNextViewController.emptyStateCell, for: indexPath) as! EmptyStateCell
                emptyCell.configure(title: L10n.upNextEmptyTitle, icon: { Image("upnext") })
                return emptyCell
            }
            return queueEpisodeCell(for: episode, active: false, at: indexPath)
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

        guard let episode = PlaybackManager.shared.queue.episodeAt(index: indexPath.row) else {
            let blank = tableView.dequeueReusableCell(withIdentifier: UpNextViewController.episodeCell, for: indexPath) as! EpisodeCell
            blank.themeOverride = themeOverride
            blank.showsReorderControl = false
            blank.showTick = false
            return blank
        }
        return queueEpisodeCell(for: episode, active: false, at: indexPath)
    }

    /// Fork: one row type for the whole session lineup — the active/current episode included. The
    /// active row just gets the accent surface (green session / blue up-next); `populateFrom` already
    /// lights the equalizer and sets the action button to pause for the playing episode.
    private func sessionEpisodeCell(for episode: BaseEpisode, active: Bool, at indexPath: IndexPath) -> EpisodeCell {
        let cell = upNextTable.dequeueReusableCell(withIdentifier: UpNextViewController.episodeCell, for: indexPath) as! EpisodeCell
        cell.themeOverride = themeOverride
        cell.hidesArtwork = false
        cell.episodeImageLeadConstraint.constant = 16.0
        cell.delegate = self
        // No system reorder grip — episodes reorder via long-press (drag-and-drop).
        cell.showsReorderControl = false
        // Every row carries the play/pause action button now (the active row's shows pause).
        cell.hidesActionButton = false
        // The host drives the select control (this table is always editing — see the flag docs),
        // so UIKit's reorder setEditing(true) can't flash the select circle mid-drag.
        cell.managesOwnSelectControl = true
        cell.shouldShowSelect = isMultiSelectEnabled
        cell.playlist = browsedPlaybackSession.map { .filter(uuid: $0.uuid) }
        cell.playButtonTintOverride = AppTheme.colorForStyle(.primaryText01, themeOverride: themeOverride)
        // The play button moves the episode to the top of the lineup and makes it the active item
        // (see `playSessionEpisodeMovingToTop`) — matching how the queue pins its now-playing.
        cell.onSessionLineupPlay = { [weak self] ep in self?.playSessionEpisodeMovingToTop(ep) }
        cell.populateFrom(episode: episode, tintColor: nil)
        // Every row here is a session member, so the in-session badge is redundant.
        cell.setSessionIndicator(.none)
        cell.setUnseenIndicator(visible: false)
        cell.setActiveSurface(accent: active ? nowPlayingWorldAccent : nil, progress: active ? episodeProgressFraction(episode) : 0)
        cell.showTick = selectedEpisodesContains(uuid: episode.uuid)
        cell.contentView.alpha = 1
        return cell
    }

    /// Fork: a queue (Up Next) row — the SAME EpisodeCell as the session lineup, so the rows read
    /// identically (proper 44pt action button, artwork, info line). The queue plays standalone, so it
    /// sets neither `playInSession` nor `onSessionLineupPlay`. The now-playing episode is `active`.
    private func queueEpisodeCell(for episode: BaseEpisode, active: Bool, at indexPath: IndexPath) -> EpisodeCell {
        let cell = upNextTable.dequeueReusableCell(withIdentifier: UpNextViewController.episodeCell, for: indexPath) as! EpisodeCell
        cell.themeOverride = themeOverride
        cell.hidesArtwork = false
        cell.episodeImageLeadConstraint.constant = 16.0
        cell.delegate = self
        cell.showsReorderControl = false
        cell.hidesActionButton = false
        cell.managesOwnSelectControl = true
        cell.shouldShowSelect = isMultiSelectEnabled
        cell.playlist = nil
        cell.playButtonTintOverride = AppTheme.colorForStyle(.primaryText01, themeOverride: themeOverride)
        cell.populateFrom(episode: episode, tintColor: nil)
        cell.setSessionIndicator(SessionIndicatorState.resolve(episode.uuid, thisSession: sessionMemberUuidsForDisplay))
        cell.setUnseenIndicator(visible: false)
        let showsAccent = active && !isMultiSelectEnabled && !activeBoxSuppressed
        cell.setActiveSurface(accent: showsAccent ? nowPlayingWorldAccent : nil, progress: active ? episodeProgressFraction(episode) : 0)
        cell.showTick = selectedEpisodesContains(uuid: episode.uuid)
        cell.contentView.alpha = 1
        return cell
    }

    /// The played fraction of an episode (live time for the now-playing one, else its saved position).
    func episodeProgressFraction(_ episode: BaseEpisode) -> CGFloat {
        guard episode.duration > 0 else { return 0 }
        let time = PlaybackManager.shared.isNowPlayingEpisode(episodeUuid: episode.uuid)
            ? PlaybackManager.shared.currentTime()
            : episode.playedUpTo
        return CGFloat(min(1, max(0, time / episode.duration)))
    }

    /// Fork: the session lineup's play button plays the episode AND makes it the top / now-playing row
    /// — mirroring how the queue keeps its now-playing at position 0. Playing must happen before the
    /// top-write (see `makeSessionEpisodeCurrentAtTop`) so the episode isn't shoved under the one it
    /// interrupts.
    func playSessionEpisodeMovingToTop(_ episode: BaseEpisode) {
        if browsingActiveSession {
            // The play button always plays (autoPlay true).
            makeSessionEpisodeCurrentAtTop(episode, autoPlay: true)
            return
        }
        // Browsed (non-active) session: activate + play it, then write it to the top of that lineup.
        playFromBrowsedSession(episode: episode)
        if let (_, playlist) = sessionPlaylistPreparedForReorder() {
            Self.writeSessionLineupTop(episodeUuid: episode.uuid, in: playlist)
        }
        reloadTable()
    }

    // MARK: - Selection

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        if tableData[indexPath.section] == .nowPlayingSection {
            // The paused banner is one big Resume button (not part of multi-select).
            if isSessionPausedBannerRow(indexPath) { return isMultiSelectEnabled ? nil : indexPath }
            if !isTopBlockCardRow(indexPath) { return nil }
            // Multi-select: ticking the now-playing card toggles like any queue row.
            if isMultiSelectEnabled, displayedWorld == .upNext,
               let episode = DataManager.sharedManager.playlistEpisodeAt(index: 0),
               selectedEpisodesContains(uuid: episode.episodeUuid) {
                tableView.delegate?.tableView?(tableView, didDeselectRowAt: indexPath)
                return nil
            }
            return indexPath
        }
        if tableData[indexPath.section] == .sessionSection {
            // Chooser rows are tappable (they open a session); its empty state and the search row
            // aren't. Map through `sessionListIndex` so the search-row offset is respected — using the
            // raw row made the last pool row (index == count) unselectable when the search bar showed.
            if showingSessionList {
                guard let listIndex = sessionListIndex(forTableRow: indexPath.row) else { return nil } // search row
                return sessionListRows[safe: listIndex] == nil ? nil : indexPath
            }
            // The empty state is inert when there's no session to show a lineup for.
            if browsedPlaybackSession == nil { return nil }
            if isMultiSelectEnabled, !multiSelectGestureInProgress,
               let episode = filteredSessionTail[safe: indexPath.row], selectedEpisodesContains(uuid: episode.uuid) {
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
        // Chooser rows: the pinned Up Next row opens the queue world; a session row drops into its
        // lineup. No multi-select here.
        if showingSessionList, tableData[indexPath.section] == .sessionSection {
            // Deselect SYNCHRONOUSLY (not animated) before opening the lane — otherwise, in this
            // always-editing table, the selection carries into the reloaded lineup and its row shows a
            // stray multi-select control.
            tableView.deselectRow(at: indexPath, animated: false)
            // Single tap OPENS the lane's page; the play button plays it. The search row and Reorder
            // Items mode are not drill-ins.
            guard !sessionListReorderMode, !isSessionSearchRow(indexPath),
                  let listIndex = sessionListIndex(forTableRow: indexPath.row),
                  let row = sessionListRows[safe: listIndex] else { return }
            openSessionLanePage(row)
            return
        }

        if isMultiSelectEnabled, tableData[indexPath.section] == .sessionSection {
            guard let episode = filteredSessionTail[safe: indexPath.row] else { return }
            if !multiSelectGestureInProgress {
                selectedEpisodesRemove(uuid: episode.uuid)
            }
            if !multiSelectGestureInProgress || !selectedEpisodesContains(uuid: episode.uuid) {
                selectedSessionEpisodes.append(episode)
                if let cell = upNextTable.cellForRow(at: indexPath) as? EpisodeCell {
                    cell.showTick = true
                }
            }
            return
        }

        // Fork: the now-playing card in the queue world is a selectable player row during
        // multi-select — it maps to position 0 of the Up Next playlist.
        if isMultiSelectEnabled, tableData[indexPath.section] == .nowPlayingSection,
           isTopBlockCardRow(indexPath), displayedWorld == .upNext {
            if let episode = DataManager.sharedManager.playlistEpisodeAt(index: 0) {
                if !multiSelectGestureInProgress { selectedEpisodesRemove(uuid: episode.episodeUuid) }
                if !multiSelectGestureInProgress || !selectedEpisodesContains(uuid: episode.episodeUuid) {
                    selectedPlayListEpisodes.append(episode)
                    if let cell = upNextTable.cellForRow(at: indexPath) as? EpisodeCell {
                        cell.showTick = true
                    }
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
                    if let cell = upNextTable.cellForRow(at: indexPath) as? EpisodeCell {
                        cell.showTick = true
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
                // Clear the selection immediately — in this always-editing table a left-behind
                // selection draws the leading multi-select control beside the artwork.
                upNextTable.deselectRow(at: indexPath, animated: false)
                if let episode = filteredSessionTail[safe: indexPath.row] {
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
                    // The current episode: with tap-to-play ON it resumes only if idle (already
                    // playing → no restart); with the setting OFF, tapping shows the actions page,
                    // exactly like any other episode.
                    if episode.uuid == PlaybackManager.shared.currentEpisode()?.uuid {
                        if Settings.playUpNextOnTap() {
                            if !PlaybackManager.shared.playing() {
                                AnalyticsPlaybackHelper.shared.currentSource = .upNext
                                PlaybackManager.shared.play(sessionEpisode: episode)
                            }
                        } else {
                            showEpisodeDetailViewController(for: episode, fromSession: true)
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

            let episodeForTap = lineupSearchActive ? filteredUpNextEpisodes[safe: indexPath.row] : PlaybackManager.shared.queue.episodeAt(index: indexPath.row)
            guard let episode = episodeForTap else { return }

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
            guard let episode = filteredSessionTail[safe: indexPath.row] else { return }
            selectedEpisodesRemove(uuid: episode.uuid)
            if let cell = upNextTable.cellForRow(at: indexPath) as? EpisodeCell {
                cell.showTick = false
            }
            return
        }
        // Fork: the now-playing card (queue world, multi-select) maps to playlist position 0.
        if tableData[indexPath.section] == .nowPlayingSection, isTopBlockCardRow(indexPath), displayedWorld == .upNext {
            if let episode = DataManager.sharedManager.playlistEpisodeAt(index: 0), let index = selectedPlayListEpisodes.firstIndex(of: episode) {
                selectedPlayListEpisodes.remove(at: index)
                if let cell = upNextTable.cellForRow(at: indexPath) as? EpisodeCell {
                    cell.showTick = false
                }
            }
            return
        }
        guard tableData[indexPath.section] == .upNextSection else { return }
        if let episode = DataManager.sharedManager.playlistEpisodeAt(index: indexPath.row + 1), let index = selectedPlayListEpisodes.firstIndex(of: episode) {
            selectedPlayListEpisodes.remove(at: index)
            if let cell = upNextTable.cellForRow(at: indexPath) as? EpisodeCell {
                cell.showTick = false
            }
        }
    }

    // MARK: - Rearrange

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        // Fork: reorder is via drag-and-drop (the drag/drop delegate), not the editing-mode handle —
        // except the chooser's "Reorder Items" mode, which keeps a real grip on pool rows.
        guard tableData[indexPath.section] == .sessionSection, showingSessionList,
              sessionListReorderMode, let listIndex = sessionListIndex(forTableRow: indexPath.row) else { return false }
        return sessionPlacement(at: listIndex) == .pool
    }

    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        if sourceIndexPath == destinationIndexPath { return }

        // Fork: reordering the session list — persist the new pool order. Up Next and the current
        // session are pinned, so this only moves pool rows amongst themselves. The search row rides
        // in the table during reorder, so map table rows to list indices first.
        if showingSessionList, tableData[sourceIndexPath.section] == .sessionSection {
            if let from = sessionListIndex(forTableRow: sourceIndexPath.row),
               let to = sessionListIndex(forTableRow: destinationIndexPath.row) {
                reorderSessionList(from: from, to: to)
            }
            return
        }

        // Fork (Model B): the session lineup's current is pinned as the card, so a tail drag only
        // reorders the tail among itself — it never lands on / above the pinned current. Making an
        // episode current is a play/long-press action, not a drag.
        if tableData[sourceIndexPath.section] == .sessionSection, displayedWorld == .session {
            moveSessionEpisode(fromRow: sourceIndexPath.row, toRow: destinationIndexPath.row)
            return
        }

        let playQueue = PlaybackManager.shared.queue

        // Fork: the idle top row (position 0) and the up-next rows are one draggable list when
        // nothing is sounding. moveEpisode uses up-next indices (position 0 = index -1), so a drag
        // out of / into the top block maps through -1.
        if tableData[sourceIndexPath.section] == .nowPlayingSection {
            let dest = tableData[destinationIndexPath.section] == .upNextSection ? destinationIndexPath.row : 0
            playQueue.moveEpisode(from: -1, to: dest)
            return
        }
        if tableData[destinationIndexPath.section] == .nowPlayingSection {
            playQueue.moveEpisode(from: sourceIndexPath.row, to: -1)
            return
        }

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
                if showingSessionList {
                    // Reorder: pool rows only — pinned below Up Next, the current session (when there
                    // is one), and the search row (which rides in the table during reorder). Table
                    // rows = list rows + 1 for the search row, so offset the clamp by it.
                    let searchOffset = showSessionSearchRow ? 1 : 0
                    let pinnedListRows = 1 + (sessionListHasCurrent ? 1 : 0) // Up Next [+ current]
                    let pinned = min(pinnedListRows + searchOffset, sessionListRows.count + searchOffset)
                    let maxRow = max(sessionListRows.count - 1 + searchOffset, 0)
                    let row = min(max(proposedDestinationIndexPath.row, pinned), maxRow)
                    return IndexPath(row: row, section: proposedDestinationIndexPath.section)
                }
                let maxRow = max((sessionEpisodes?.count ?? 1) - 1, 0)
                return IndexPath(row: min(proposedDestinationIndexPath.row, maxRow), section: proposedDestinationIndexPath.section)
            }
            return proposedDestinationIndexPath
        }

        // Fork: the QUEUE (Up Next details) keeps its established card behaviour — drag a list episode
        // UP onto the now-playing card to make it current, or the card DOWN into the list. The SESSION
        // lineup's current is pinned (Model B), so neither cross-move is offered there.
        if displayedWorld == .upNext, tableData[proposedDestinationIndexPath.section] == .nowPlayingSection, let cardRow = topBlockCardRow {
            if tableData[sourceIndexPath.section] == .upNextSection, queueOwnsCard {
                return IndexPath(row: cardRow, section: proposedDestinationIndexPath.section)
            }
        }

        if displayedWorld == .upNext, tableData[sourceIndexPath.section] == .nowPlayingSection,
           tableData[proposedDestinationIndexPath.section] == .upNextSection {
            let count = PlaybackManager.shared.queue.upNextCount()
            return IndexPath(row: min(proposedDestinationIndexPath.row, max(count - 1, 0)), section: proposedDestinationIndexPath.section)
        }

        // No other cross-section move is allowed — pin the row to where it started.
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
            // Fork: a row must be editable for its reorder handle (and swipe) to show. Only pool
            // rows move; Up Next (row 0) and the current session (row 1) are pinned.
            // (Swipe-to-remove is separately gated in +Swipe.)
            if showingSessionList {
                guard let listIndex = sessionListIndex(forTableRow: indexPath.row) else { return false } // search row
                return sessionPlacement(at: listIndex) == .pool
            }
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
            // The lineup episode search row (between the pinned card and the info line).
            if isTopBlockLineupSearchRow(indexPath) {
                return UpNextViewController.sessionSearchRowHeight
            }
            if !isTopBlockCardRow(indexPath) {
                let metrics = UIFontMetrics(forTextStyle: .footnote)
                // The info/counts line: a compact row under the nav bar, plus a 14pt gap below it
                // (see the controls' bottom constraint) before the first episode row.
                return metrics.scaledValue(for: 34 + 14)
            }
            // Fork: no big card anymore — the now-playing row is a self-sizing EpisodeCell in BOTH
            // worlds now, so it uses automatic height like the rest of the list.
            return UITableView.automaticDimension
        }
        if section == .sessionSection {
            if showingSessionList {
                if isSessionSearchRow(indexPath) { return UpNextViewController.sessionSearchRowHeight }
                return sessionListIndex(forTableRow: indexPath.row).flatMap { sessionListRows[safe: $0] } == nil ? UpNextViewController.emptyStateRowHeight : UITableView.automaticDimension
            }
            if browsedPlaybackSession == nil { return UpNextViewController.emptyStateRowHeight }
            // EpisodeCell rows self-size (two-line title + info line).
            return UITableView.automaticDimension
        }
        if PlaybackManager.shared.queue.upNextCount() == 0 { return UpNextViewController.emptyStateRowHeight }
        // The queue rows are self-sizing EpisodeCells now (same as the session lineup).
        return UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        // The Up Next table is permanently in editing mode (for drag-reorder), which makes an
        // EpisodeCell show its multi-select circle even at rest. Reflect the real multi-select
        // state instead (PlayerCell already ignores editing and toggles select explicitly).
        if let episodeCell = cell as? EpisodeCell {
            episodeCell.setEditing(isMultiSelectEnabled, animated: false)
        }
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
        // One grouped query for the union of every session's lineup — not one `positionedEpisodeUuids`
        // DB query per session on every reload.
        Self.cachedSessionMemberUuids = SessionFeederEngine.allStoreMemberUuids()
    }

    var sessionMemberUuidsForDisplay: Set<String> { Self.cachedSessionMemberUuids }

    @objc func reloadTable() {
        reloadScheduled = false // any pending coalesced reload is subsumed by this immediate one
        // Fork: reorder uses UIKit drag-and-drop (long-press to lift), enabled everywhere. (UITableView
        // has no programmatic interactive-move API — that's collection-view only — so a custom-gesture
        // live-swap isn't available here; drag-and-drop lifts the row and shows an insertion point.)
        upNextTable.dragInteractionEnabled = true
        refreshSessionMembership()
        refreshSessionState()
        refreshSections()
        // Fork: the tab is always "Queue" (set on the tab bar item itself). The session list is
        // the home; the queue and each session are lineups pushed from it.
        updateStickyChrome()
        // Nav buttons are level-dependent (back chevron vs Select/Clear) — keep them in step.
        updateNavBarButtons()
        upNextTable.reloadData()
    }

    /// Coalesces reload requests: several notifications (queue advance, episode add/remove, foreground)
    /// can fire for one user action; this collapses them into a single `reloadTable()` per runloop
    /// turn instead of the O(sessions) rebuild running two or three times back-to-back.
    func setNeedsReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.reloadScheduled else { return }
            self.reloadScheduled = false
            self.reloadTable()
        }
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
        // Coalesced: a burst of queue notifications collapses into one reload. In the session list a
        // queue change only touches the Up Next row, so repaint in place instead of flashing every row.
        DispatchQueue.main.async {
            self.updateNavBarButtons()
            if self.displayedWorld == .session {
                self.sessionPlayStateChanged()
            } else {
                self.setNeedsReload()
            }
        }
    }

    @objc func appDidBecomeActive() {
        // there's a weird issue with the drag handle tints disappearing on the app coming back from being backgrounded, so reload the table in that case
        setNeedsReload()
    }

    @objc func tableLongPressed(_ sender: UILongPressGestureRecognizer) {
        guard sender.state == .began else { return }
        let point = sender.location(in: upNextTable)
        guard let indexPath = upNextTable.indexPathForRow(at: point) else { return }
        // A reorderable row lets the drag interaction own the long-press (it lifts for a drag-reorder),
        // so the custom gesture stays out of the way. Everything else gets the play/options action.
        if dragReorderAllowed(at: indexPath) { return }
        handleLongPressAction(at: indexPath)
    }

    /// The long-press action for a NON-reorderable row: the inverse of the "Play Up Next On Tap"
    /// setting (play / episode options), mirroring the tap behaviour the setting describes.
    private func handleLongPressAction(at indexPath: IndexPath) {
        let section = tableData[safe: indexPath.section]

        // Session LINEUP episode (the chooser's session rows aren't episodes, so they're excluded).
        if section == .sessionSection, !showingSessionList, let episode = filteredSessionTail[safe: indexPath.row] {
            guard !isMultiSelectEnabled else { return }
            if Settings.playUpNextOnTap() {
                showEpisodeDetailViewController(for: episode, fromSession: true)
            } else if browsingActiveSession {
                AnalyticsPlaybackHelper.shared.currentSource = .upNext
                PlaybackManager.shared.play(sessionEpisode: episode)
            } else {
                playFromBrowsedSession(episode: episode)
            }
            return
        }

        // Up Next queue episode.
        guard section == .upNextSection, let episode = PlaybackManager.shared.queue.episodeAt(index: indexPath.row) else { return }
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

// MARK: - Fork: long-press drag-reorder (chooser pool, now-playing card, lineup + queue episodes)

extension UpNextViewController: UITableViewDragDelegate, UITableViewDropDelegate {
    /// Which rows can be reorder-moved at all — drives `canMoveRowAt` (interactive movement) and,
    /// via `dragReorderAllowed`, which long-press starts a live-swap drag. The now-playing card
    /// (dragged via a long-press on it / its play/pause icon), the drag-and-drop-sorted session
    /// lineup, the queue, and the chooser pool all qualify. The pinned Up Next / current chooser
    /// rows, sorted lineups, empty states and the search row do not.
    func rowIsReorderable(at indexPath: IndexPath) -> Bool {
        guard let section = tableData[safe: indexPath.section] else { return false }
        switch section {
        case .nowPlayingSection:
            // Fork (Model B): the SESSION lineup's current is PINNED — never draggable. The queue's
            // now-playing card stays draggable (established Up Next behaviour). Never the search/info row.
            return isTopBlockCardRow(indexPath) && topBlockHasCard && displayedWorld != .session
        case .sessionSection:
            if showingSessionList {
                guard !isSessionSearchRow(indexPath), let listIndex = sessionListIndex(forTableRow: indexPath.row) else { return false }
                return sessionPlacement(at: listIndex) == .pool
            }
            // The lineup mirrors its playlist, so it's only reorderable in Drag & Drop sort (a sorted
            // lineup shows the accent sort icon and can't be dragged — see `browsedSessionSortIsDragAndDrop`).
            // A live title filter can't be reordered (the tail is a subset), so drag is off then.
            guard browsedPlaybackSession != nil, !lineupSearchActive, indexPath.row < (sessionEpisodes?.count ?? 0) else { return false }
            let type = browsedPlaybackSession?.type
            return (type == .playlist || type == .smartPlaylist) && browsedSessionSortIsDragAndDrop
        case .upNextSection:
            return PlaybackManager.shared.queue.upNextCount() > 0
        }
    }

    /// A long-press starts a live-swap reorder only on a reorderable row and only outside
    /// multi-select (there the pan-to-select gesture owns the touch).
    func dragReorderAllowed(at indexPath: IndexPath) -> Bool {
        !isMultiSelectEnabled && rowIsReorderable(at: indexPath)
    }

    func tableView(_ tableView: UITableView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        guard dragReorderAllowed(at: indexPath) else { return [] }
        // Clear the DRAGGED cell's accent styling synchronously here — the lift preview is snapshotted
        // now, before `dragSessionWillBegin` runs, so this is what strips its bg/border/progress from
        // the floating copy too (not just the source row).
        if let cell = tableView.cellForRow(at: indexPath) {
            (cell as? EpisodeCell)?.setActiveSurface(accent: nil)
            (cell as? PlayerCell)?.setActiveSurface(accent: nil)
            (cell as? SessionListCell)?.setActiveBoxSuppressed(true)
        }
        // The chooser drag carries the session uuid (used by external drops); lineup drags are
        // in-app reorders keyed purely by the source indexPath stashed in `localObject`.
        let provider: NSItemProvider
        if showingSessionList, let listIndex = sessionListIndex(forTableRow: indexPath.row), let row = sessionListRows[safe: listIndex] {
            provider = NSItemProvider(object: row.sessionUuid as NSString)
        } else {
            provider = NSItemProvider()
        }
        let item = UIDragItem(itemProvider: provider)
        item.localObject = indexPath
        return [item]
    }

    /// While ANY row is being dragged, the active (currently-playing) row sheds its accent box so the
    /// whole list reads uniform mid-reorder. (Up Next keeps its own box — it's not the active row.)
    func tableView(_ tableView: UITableView, dragSessionWillBegin session: UIDragSession) {
        activeBoxSuppressed = true
        for cell in tableView.visibleCells {
            (cell as? EpisodeCell)?.setActiveSurface(accent: nil)   // no-op unless it's the active row
            (cell as? PlayerCell)?.setActiveSurface(accent: nil)
            (cell as? SessionListCell)?.setActiveBoxSuppressed(true)
        }
    }

    /// Restores the active row's accent box once the drag ends — whether it dropped, cancelled, or the
    /// row didn't move.
    func tableView(_ tableView: UITableView, dragSessionDidEnd session: UIDragSession) {
        activeBoxSuppressed = false
        setNeedsReload()
    }

    func tableView(_ tableView: UITableView, dropSessionDidUpdate session: UIDropSession, withDestinationIndexPath destinationIndexPath: IndexPath?) -> UITableViewDropProposal {
        let cancel = UITableViewDropProposal(operation: .cancel)
        guard session.localDragSession != nil,
              let source = session.localDragSession?.items.first?.localObject as? IndexPath,
              let dest = destinationIndexPath else { return cancel }

        if showingSessionList {
            // Chooser: a move onto a pool row only (never above the pinned Up Next / current rows
            // or onto the search row).
            guard !isSessionSearchRow(dest), let listIndex = sessionListIndex(forTableRow: dest.row),
                  sessionPlacement(at: listIndex) == .pool else { return cancel }
            return UITableViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
        }
        return lineupDropProposal(source: source, dest: dest)
    }

    /// Validates a lineup/queue drag: dropping an episode ONTO the card makes it current; the card
    /// or an episode dropped into the list reorders within the same world.
    private func lineupDropProposal(source: IndexPath, dest: IndexPath) -> UITableViewDropProposal {
        let cancel = UITableViewDropProposal(operation: .cancel)
        let sourceSection = tableData[safe: source.section]
        let destSection = tableData[safe: dest.section]

        // Onto the card → make current. Fork (Model B): only the QUEUE card accepts this; the session
        // lineup's current is pinned, so a tail episode can never drop onto it.
        if destSection == .nowPlayingSection {
            guard isTopBlockCardRow(dest), topBlockHasCard, displayedWorld == .upNext else { return cancel }
            return sourceSection == .upNextSection ? UITableViewDropProposal(operation: .move, intent: .insertIntoDestinationIndexPath) : cancel
        }
        // The queue card dragged down into its own list (session card is pinned).
        if sourceSection == .nowPlayingSection {
            let intoOwnWorld = displayedWorld == .upNext && destSection == .upNextSection
            return intoOwnWorld ? UITableViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath) : cancel
        }
        // Episode-to-episode within the same section.
        guard sourceSection == destSection else { return cancel }
        return UITableViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func tableView(_ tableView: UITableView, performDropWith coordinator: UITableViewDropCoordinator) {
        guard let item = coordinator.items.first,
              let source = item.dragItem.localObject as? IndexPath,
              let dest = coordinator.destinationIndexPath else { return }

        if showingSessionList {
            guard let from = sessionListIndex(forTableRow: source.row),
                  let to = sessionListIndex(forTableRow: dest.row) else { return }
            if from == to {
                // Fork: a long-press that lifts a session but drops it in place (no move) is the
                // "make this session current" gesture — inheriting the current play state.
                if let row = sessionListRows[safe: from] {
                    makeSessionCurrentInheritingPlayState(row)
                }
                coordinator.drop(item.dragItem, toRowAt: dest)
                return
            }
            // Otherwise it's a reorder — the POOL only (Up Next and the Current Session are pinned).
            reorderSessionList(from: from, to: to)
            tableView.reloadData()
            coordinator.drop(item.dragItem, toRowAt: dest)
            return
        }

        performLineupDrop(source: source, dest: dest)
        coordinator.drop(item.dragItem, toRowAt: dest)
    }

    /// Applies a validated lineup/queue drop by routing to the existing reorder entry points, then
    /// reloads so the rows reflect the new order (drag-and-drop doesn't auto-move rows the way the
    /// editing-mode handle did).
    private func performLineupDrop(source: IndexPath, dest: IndexPath) {
        let sourceSection = tableData[safe: source.section]
        let destSection = tableData[safe: dest.section]

        // Onto the queue card → make the dragged episode current (session card is pinned, never a target).
        if destSection == .nowPlayingSection {
            if sourceSection == .upNextSection {
                PlaybackManager.shared.queue.moveEpisode(from: source.row, to: -1)
            }
            reloadTable()
            return
        }
        // The queue card dragged down into its list (session card is pinned).
        if sourceSection == .nowPlayingSection {
            if displayedWorld == .upNext {
                PlaybackManager.shared.queue.moveEpisode(from: -1, to: dest.row)
                reloadTable()
            }
            return
        }
        // Episode-to-episode. Fork (Model B): a session tail reorders among itself below the pinned
        // current — never "to top / make current" (that's a play/long-press action).
        if sourceSection == .sessionSection {
            moveSessionEpisode(fromRow: source.row, toRow: dest.row)
            reloadTable()
            return
        }
        if sourceSection == .upNextSection {
            PlaybackManager.shared.queue.moveEpisode(from: source.row, to: dest.row)
            reloadTable()
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
