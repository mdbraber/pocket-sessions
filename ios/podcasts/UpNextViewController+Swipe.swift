import Foundation
import PocketCastsDataModel
import PocketCastsUtils
import SwipeCellKit

extension UpNextViewController: SwipeTableViewCellDelegate, SwipeHandler {
    func swipeCurrentlyAllowed() -> Bool {
        // Reorder mode suspends swipes — a horizontal drag there is an attempt to grab the grip.
        return isReorderInProgress == false && !lineupReorderMode
    }

    func tableView(_ tableView: UITableView, editActionsForRowAt indexPath: IndexPath, for orientation: SwipeActionsOrientation) -> [SwipeAction]? {
        // Fork: swipe a session away to remove it from the "recent/planned" list. A podcast/folder
        // session's dedicated store is deleted (and "Play as Session" recreates it); a smart-playlist
        // or manual session keeps its underlying playlist — only the session row goes. The pinned
        // playing session isn't swipeable.
        if showingSessionList {
            guard !sessionListReorderMode,
                  let listIndex = sessionListIndex(forTableRow: indexPath.row),
                  let row = sessionListRows[safe: listIndex], !row.isUpNext else { return nil }
            switch orientation {
            case .right:
                guard !row.isActive else { return nil }
                let remove = SwipeAction(style: .destructive, title: nil) { [weak self] _, _ in
                    guard let self, let session = SessionStore.shared.session(uuid: row.sessionUuid) else { return }
                    self.removeSessionFromList(session)
                    self.refreshSessionState()
                    self.reloadTable()
                }
                remove.image = UIImage(systemName: "trash")
                remove.backgroundColor = ThemeColor.support05(for: themeOverride)
                remove.accessibilityLabel = L10n.remove
                return [remove]
            case .left:
                // Move to Top / Move to Bottom within the POOL — Up Next and the current session are
                // pinned above it, so only pool sessions reorder.
                guard sessionPlacement(at: listIndex) == .pool else { return nil }
                let poolTop = 1 + (sessionListHasCurrent ? 1 : 0)
                let poolBottom = max(sessionListRows.count - 1, poolTop)
                let moveToTop = SwipeAction(style: .default, title: nil) { [weak self] _, _ in
                    self?.reorderSessionList(from: listIndex, to: poolTop)
                    self?.reloadTable()
                }
                moveToTop.image = UIImage(named: "upnext-movetotop")
                moveToTop.backgroundColor = ThemeColor.support04()
                moveToTop.accessibilityLabel = L10n.moveToTop
                moveToTop.hidesWhenSelected = true
                let moveToBottom = SwipeAction(style: .default, title: nil) { [weak self] _, _ in
                    self?.reorderSessionList(from: listIndex, to: poolBottom)
                    self?.reloadTable()
                }
                moveToBottom.image = UIImage(named: "upnext-movetobottom")
                moveToBottom.backgroundColor = ThemeColor.support03()
                moveToBottom.accessibilityLabel = L10n.moveToBottom
                moveToBottom.hidesWhenSelected = true
                return [moveToTop, moveToBottom]
            }
        }
        // The Now Playing card carries the same actions as its world's rows — acting
        // on the playing episode hands playback to whatever comes next.
        if tableData[indexPath.section] == .nowPlayingSection {
            // Fork: the card is the lineup's pinned head — the session's current episode, or the
            // queue's own head in Up Next (which, mid-session, is NOT the player's current episode).
            guard isTopBlockCardRow(indexPath), let episode = lineupHeadEpisode else { return nil }
            if orientation == .left {
                // The card *is* the playing episode, so "move to top/bottom" is a no-op —
                // only the two add actions make sense here.
                let inLocalSession = displayedWorld == .session && browsedSession != nil
                return [addToSessionSwipeAction(for: episode, inLocalSession: inLocalSession),
                        addToSwipeAction(for: episode, at: indexPath)].compactMap { $0 }
            }
            if displayedWorld == .session {
                return episodeSwipeActions(for: episode)
            }

            // Up Next world: identical to the queue rows — remove and mark played.
            let removeAction = SwipeAction(style: .destructive, title: nil) { [weak self] _, _ in
                guard let self else { return }
                Analytics.track(.episodeSwipeActionPerformed, properties: ["action": "delete", "source": "up_next"])
                SessionLinking.removeFromUpNextAskingSession(episode: episode) { [weak self] in
                    guard let self else { return }
                    self.changedViaSwipeToRemove = true
                    self.refreshSessionState()
                    self.reloadTable()
                    self.changedViaSwipeToRemove = false
                }
            }
            removeAction.image = UIImage(named: "episode-removenext")
            removeAction.backgroundColor = ThemeColor.support05(for: themeOverride)
            removeAction.accessibilityLabel = L10n.removeFromUpNext

            return [removeAction, archiveSwipeAction(for: episode), markPlayedSwipeAction(for: episode)].compactMap { $0 }
        }

        // Session rows aren't queue rows — moves reorder the mirrored playlist on the
        // left; archive / mark played on the right.
        if tableData[indexPath.section] == .sessionSection {
            guard let episode = filteredLineupTail[safe: indexPath.row] else { return nil }
            switch orientation {
            case .left:
                // Same left swipe as every other row: Add to Session (only when this
                // lineup isn't already a session's), Add to… (a picker for queue/playlist
                // destinations), then reorder within the session.
                let adds = [addToSessionSwipeAction(for: episode, inLocalSession: browsedSession != nil),
                            addToSwipeAction(for: episode, at: indexPath)].compactMap { $0 }
                return adds + (sessionMoveSwipeActions(at: indexPath) ?? [])
            case .right:
                return episodeSwipeActions(for: episode)
            }
        }

        guard tableData[indexPath.section] == .upNextSection else { return nil }

        switch orientation {
        case .left:
            let moveToTopAction = SwipeAction(style: .default, title: nil) { [weak self] _, indexPath in
                guard let self, let episode = self.filteredLineupTail[safe: indexPath.row] else { return }

                Analytics.track(.episodeSwipeActionPerformed, properties: ["action": "up_next_move_up", "source": "up_next"])

                // The top of the visible tail sits below the pinned head (offset while a session plays).
                PlaybackManager.shared.queue.move(episode: episode, to: self.upNextListOffset, fireNotification: false)
                self.moveRow(at: indexPath, to: IndexPath(row: 0, section: indexPath.section), in: tableView)
            }
            moveToTopAction.image = UIImage(named: "upnext-movetotop")
            moveToTopAction.backgroundColor = ThemeColor.support04()
            moveToTopAction.accessibilityLabel = L10n.moveToTop
            moveToTopAction.hidesWhenSelected = true
            let moveToBottomAction = SwipeAction(style: .default, title: nil) { [weak self] _, indexPath in
                guard let self, let episode = self.filteredLineupTail[safe: indexPath.row] else { return }

                let queueCount = PlaybackManager.shared.queue.upNextCount()
                PlaybackManager.shared.queue.move(episode: episode, to: queueCount - 1, fireNotification: false)
                self.moveRow(at: indexPath, to: IndexPath(row: self.filteredLineupTail.count - 1, section: indexPath.section), in: tableView)
                Analytics.track(.episodeSwipeActionPerformed, properties: ["action": "up_next_move_down", "source": "up_next"])
            }
            moveToBottomAction.image = UIImage(named: "upnext-movetobottom")
            moveToBottomAction.backgroundColor = ThemeColor.support03()
            moveToBottomAction.accessibilityLabel = L10n.moveToBottom
            moveToBottomAction.hidesWhenSelected = true
            guard let episode = filteredLineupTail[safe: indexPath.row] else {
                return [moveToTopAction, moveToBottomAction]
            }
            // Queue rows belong to no session, so Add to Session always shows here.
            return [addToSessionSwipeAction(for: episode, inLocalSession: false),
                    addToSwipeAction(for: episode, at: indexPath)].compactMap { $0 }
                + [moveToTopAction, moveToBottomAction]
        case .right:
            let deleteAction = SwipeAction(style: .destructive, title: nil) { [weak self] _, indexPath in
                guard let self, let episode = self.filteredLineupTail[safe: indexPath.row] else { return }

                Analytics.track(.episodeSwipeActionPerformed, properties: ["action": "delete", "source": "up_next"])
                // The removal may be deferred behind a "keep in Session?" prompt, so the
                // table is refreshed in the completion rather than animating this row.
                SessionLinking.removeFromUpNextAskingSession(episode: episode) { [weak self] in
                    guard let self else { return }
                    self.changedViaSwipeToRemove = true
                    self.refreshSessionState()
                    self.reloadTable()
                    if PlaybackManager.shared.queue.upNextCount() == 0, FeatureFlag.upNextShuffle.enabled {
                        self.isMultiSelectEnabled = false
                        self.updateNavBarButtons()
                    }
                    self.changedViaSwipeToRemove = false
                }
            }

            // customize the action appearance
            deleteAction.image = UIImage(named: "episode-removenext")
            deleteAction.backgroundColor = ThemeColor.support05(for: themeOverride)
            deleteAction.accessibilityLabel = L10n.removeFromUpNext

            guard let episode = filteredLineupTail[safe: indexPath.row] else {
                return [deleteAction]
            }
            return [deleteAction, archiveSwipeAction(for: episode), markPlayedSwipeAction(for: episode)].compactMap { $0 }
        }
    }

    func tableView(_ tableView: UITableView, editActionsOptionsForRowAt indexPath: IndexPath, for orientation: SwipeActionsOrientation) -> SwipeOptions {
        var options = SwipeOptions()

        switch orientation {
        case .left:
            options.expansionStyle = .selection
        case .right:
            options.expansionStyle = .destructive(automaticallyDelete: false)
        }

        return options
    }

    /// Move to top / move to bottom for session rows — same affordance as the queue,
    /// but reordering the session's mirrored playlist.
    private func sessionMoveSwipeActions(at indexPath: IndexPath) -> [SwipeAction]? {
        let sessionType = browsedPlaybackSession?.type
        guard sessionType == .playlist || sessionType == .smartPlaylist else { return nil }

        let moveToTop = SwipeAction(style: .default, title: nil) { [weak self] _, indexPath in
            // Fork (Model B): move to the TOP OF THE TAIL — below the pinned current — rather than
            // making it the now-playing item (that's a play-button gesture, not a reorder swipe).
            self?.moveSessionEpisode(fromRow: indexPath.row, toRow: 0)
        }
        moveToTop.image = UIImage(named: "upnext-movetotop")
        moveToTop.backgroundColor = ThemeColor.support04()
        moveToTop.accessibilityLabel = L10n.moveToTop
        moveToTop.hidesWhenSelected = true

        let moveToBottom = SwipeAction(style: .default, title: nil) { [weak self] _, indexPath in
            guard let self else { return }
            self.moveSessionEpisode(fromRow: indexPath.row, toRow: max((self.sessionEpisodes?.count ?? 1) - 1, 0))
        }
        moveToBottom.image = UIImage(named: "upnext-movetobottom")
        moveToBottom.backgroundColor = ThemeColor.support03()
        moveToBottom.accessibilityLabel = L10n.moveToBottom
        moveToBottom.hidesWhenSelected = true

        return [moveToTop, moveToBottom]
    }

    /// "Add to…" — the shared destination picker, with this screen's own route to the
    /// manual-playlist chooser (it has to dismiss itself when shown over the player).
    private func addToSwipeAction(for episode: BaseEpisode, at indexPath: IndexPath) -> SwipeAction {
        let uuid = episode.uuid
        return TriageSwipes.addToAction(for: episode,
                                        presenting: self,
                                        source: swipeSource,
                                        themeOverride: themeOverride) { [weak self] in
            guard let self, let fresh = DataManager.sharedManager.findEpisode(uuid: uuid) else { return }
            self.addToManualPlaylist(episode: fresh, at: indexPath)
        }
    }

    /// "Add to Session" — the same green verb the triage lists carry, routed the same
    /// way (per the Inbox setting). Skipped when the row already belongs to the session
    /// on screen.
    private func addToSessionSwipeAction(for episode: BaseEpisode, inLocalSession: Bool) -> SwipeAction? {
        guard !inLocalSession else { return nil }
        // Sessions exist only for subscribed podcasts: hide the verb when nothing could
        // receive the episode — its podcast unsubscribed and no existing session covers it.
        if let episode = episode as? Episode,
           DataManager.sharedManager.findPodcast(uuid: episode.podcastUuid) == nil,
           SessionManager.shared.sessionsCovering(podcastUuid: episode.podcastUuid).isEmpty {
            return nil
        }
        let uuid = episode.uuid
        // Only a session you are LOOKING AT is a preferred target. `browsedSession` falls
        // back to the active one, so passing it from the queue world would hand the episode
        // to whatever happens to be playing — and `preferred` is added whether or not its
        // feeder covers the episode. From the queue, routing is coverage-based only.
        let preferred = (displayedWorld == .session && !showingSessionList) ? browsedSession : nil
        let action = SwipeAction(style: .default, title: nil) { [weak self] action, _ in
            action.fulfill(with: .reset)
            guard let self else { return }
            SessionManager.shared.addToSessions(episodeUuids: [uuid], preferred: preferred, presenting: self) { [weak self] _ in
                self?.refreshSessionState()
                self?.reloadTable()
            }
        }
        action.image = TriageSwipes.sessionAddImage
        action.backgroundColor = TriageSwipes.addToSessionGreen // deeper session green
        action.accessibilityLabel = L10n.playlistAddToLineup
        action.hidesWhenSelected = true
        return action
    }

    /// Right-swipe actions for the Now Playing card and session rows: Remove (from
    /// the session's lineup, dismissal and all) at the edge, then archive.
    private func episodeSwipeActions(for episode: BaseEpisode) -> [SwipeAction] {
        let remove = SwipeAction(style: .default, title: nil) { [weak self] action, _ in
            defer { action.fulfill(with: .reset) }
            guard let self else { return }
            // The lineup on screen is the browsed one — remove from THAT session.
            if let storeSession = self.browsedSession {
                SessionManager.shared.removeFromLineup(episodeUuids: [episode.uuid], session: storeSession)
            } else if let playbackSession = self.browsedPlaybackSession, playbackSession.type == .playlist,
                      let playlist = DataManager.sharedManager.findPlaylist(uuid: playbackSession.uuid) {
                DataManager.sharedManager.deleteEpisodes([episode.uuid], from: playlist)
                NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged, object: playlist)
            } else {
                PlaybackManager.shared.removeIfPlayingOrQueued(episode: episode, fireNotification: true, userInitiated: true)
            }
            self.refreshSessionState()
            self.reloadTable()
        }
        remove.image = TriageSwipes.sessionRemoveImage()?.withTintColor(.white, renderingMode: .alwaysOriginal)
        remove.backgroundColor = ThemeColor.support05(for: themeOverride)
        remove.accessibilityLabel = L10n.sessionRemoveFrom
        remove.hidesWhenSelected = true

        return [remove, archiveSwipeAction(for: episode), markPlayedSwipeAction(for: episode)].compactMap { $0 }
    }

    /// Archive/unarchive, fresh-fetched and state-aware — shared by every Up Next row.
    private func archiveSwipeAction(for episode: BaseEpisode) -> SwipeAction? {
        guard let episode = episode as? Episode else { return nil }
        let uuid = episode.uuid
        let archived = episode.archived
        let action = SwipeAction(style: .default, title: nil) { [weak self] action, _ in
            if let fresh = DataManager.sharedManager.findEpisode(uuid: uuid) {
                if archived {
                    EpisodeManager.unarchiveEpisode(episode: fresh, fireNotification: true)
                } else {
                    EpisodeManager.archiveEpisode(episode: fresh, fireNotification: true)
                }
            }
            self?.reloadTable()
            action.fulfill(with: .reset)
        }
        action.image = UIImage(named: archived ? "list_unarchive" : "list_archive")
        action.backgroundColor = ThemeColor.support06()
        action.accessibilityLabel = archived ? L10n.unarchive : L10n.archive
        action.hidesWhenSelected = true
        return action
    }

    /// Mark as played — shared by every Up Next row.
    private func markPlayedSwipeAction(for episode: BaseEpisode) -> SwipeAction {
        let uuid = episode.uuid
        let action = SwipeAction(style: .default, title: nil) { [weak self] action, _ in
            if let fresh = DataManager.sharedManager.findBaseEpisode(uuid: uuid) {
                EpisodeManager.markAsPlayed(episode: fresh, fireNotification: true)
            }
            self?.reloadTable()
            action.fulfill(with: .reset)
        }
        action.image = UIImage(named: "episode-markasplayed")
        action.backgroundColor = ThemeColor.support02()
        action.accessibilityLabel = L10n.markPlayedShort
        action.hidesWhenSelected = true
        return action
    }

    // MARK: - SwipeHandler (session rows)

    var swipeSource: String {
        "up_next"
    }

    /// Session rows carry the playlist they play from, so the shared swipe actions behave
    /// like that playlist's detail screen (e.g. manual playlist sessions offer remove).
    var swipeSourceType: SwipeSourceType {
        switch browsedPlaybackSession?.type {
        case .playlist:
            return .manualPlaylistDetail
        case .podcast:
            return .podcast
        case .smartPlaylist, nil:
            return .smartPlaylistDetail
        }
    }

    func archivingRemovesFromList() -> Bool {
        true
    }

    func actionPerformed(willBeRemoved: Bool) {
        refreshSessionState()
        reloadTable()
    }

    func deleteRequested(uuid: String) {} // user episodes can't appear in session lists

    func share(episode: Episode, at indexPath: IndexPath) {
        SharingHelper.shared.shareLinkTo(episode: episode, fromController: self, fromTableView: upNextTable, at: indexPath)
    }

    func addToManualPlaylist(episode: Episode, at: IndexPath) {
        let presentModal: () -> Void = { [weak self] in
            NavigationManager.sharedManager.navigateTo(
                NavigationManager.manualPlaylistsChooserKey,
                data: [
                    NavigationManager.manualPlaylistsChooserEpisodeKey: episode,
                    NavigationManager.manualPlaylistsChooserRootKey: self as Any
                ]
            )
        }
        if presentingViewController is PlayerContainerViewController {
            dismiss(animated: true, completion: presentModal)
        } else {
            presentModal()
        }
    }

    func removeFromManualPlaylist(episode: Episode, at: IndexPath) {
        guard let session = browsedPlaybackSession, session.type == .playlist,
              let playlist = DataManager.sharedManager.findPlaylist(uuid: session.uuid) else { return }
        DataManager.sharedManager.deleteEpisodes([episode.uuid], from: playlist)
        NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged, object: playlist)
        refreshSessionState()
        reloadTable()
    }

    private func moveRow(at: IndexPath, to: IndexPath, in tableView: UITableView) {
        do {
            try SJCommonUtils.catchException {
                tableView.moveRow(at: at, to: to)
            }
        } catch {
            FileLog.shared.addMessage("Caught Objective-C exception while trying to move an Up Next row, reloading table instead")
            tableView.reloadData()
        }
    }
}
