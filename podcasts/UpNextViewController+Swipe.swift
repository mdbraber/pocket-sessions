import Foundation
import PocketCastsDataModel
import PocketCastsUtils
import SwipeCellKit

extension UpNextViewController: SwipeTableViewCellDelegate, SwipeHandler {
    func swipeCurrentlyAllowed() -> Bool {
        return isReorderInProgress == false
    }

    func tableView(_ tableView: UITableView, editActionsForRowAt indexPath: IndexPath, for orientation: SwipeActionsOrientation) -> [SwipeAction]? {
        // The Now Playing card carries the same actions as its world's rows — acting
        // on the playing episode hands playback to whatever comes next.
        if tableData[indexPath.section] == .nowPlayingSection {
            guard topBlockHasCard, indexPath.row == 0, orientation == .right,
                  let episode = PlaybackManager.shared.currentEpisode() else { return nil }
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
                    self.refreshUpNextFilterMatches()
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
            guard let episode = sessionEpisodes?[safe: indexPath.row] else { return nil }
            switch orientation {
            case .left:
                // Session-world rows: reorder within the session (move to top/bottom),
                // then push the episode into the actual Up Next queue (Play Next / Play Last),
                // like every other list. Four actions — the moves plus the queue adds.
                return (sessionMoveSwipeActions(at: indexPath) ?? []) + upNextAddSwipeActions(for: episode)
            case .right:
                return episodeSwipeActions(for: episode)
            }
        }

        guard tableData[indexPath.section] == .upNextSection else { return nil }

        switch orientation {
        case .left:
            let moveToTopAction = SwipeAction(style: .default, title: nil) { [weak self] _, indexPath in
                guard let self, let episode = PlaybackManager.shared.queue.episodeAt(index: self.queueIndex(forVisibleRow: indexPath.row)) else { return }

                Analytics.track(.episodeSwipeActionPerformed, properties: ["action": "up_next_move_up", "source": "up_next"])

                if self.visibleQueueIndices != nil {
                    // Compact view: "top" means the first matching slot — as high as the
                    // episode can go without displacing any hidden (skipped) episode.
                    self.moveVisibleEpisode(fromVisibleRow: indexPath.row, toVisibleRow: 0)
                } else {
                    PlaybackManager.shared.queue.move(episode: episode, to: 0, fireNotification: false)
                }
                self.moveRow(at: indexPath, to: IndexPath(row: 0, section: indexPath.section), in: tableView)
            }
            moveToTopAction.image = UIImage(named: "upnext-movetotop")
            moveToTopAction.backgroundColor = ThemeColor.support04()
            moveToTopAction.accessibilityLabel = L10n.moveToTop
            moveToTopAction.hidesWhenSelected = true
            let moveToBottomAction = SwipeAction(style: .default, title: nil) { [weak self] _, indexPath in
                guard let self, let episode = PlaybackManager.shared.queue.episodeAt(index: self.queueIndex(forVisibleRow: indexPath.row)) else { return }

                if let visibleIndices = self.visibleQueueIndices {
                    // Compact view: "bottom" means the last matching slot; hidden episodes stay put.
                    self.moveVisibleEpisode(fromVisibleRow: indexPath.row, toVisibleRow: visibleIndices.count - 1)
                    self.moveRow(at: indexPath, to: IndexPath(row: visibleIndices.count - 1, section: indexPath.section), in: tableView)
                } else {
                    let queueCount = PlaybackManager.shared.queue.upNextCount()
                    PlaybackManager.shared.queue.move(episode: episode, to: queueCount - 1, fireNotification: false)
                    self.moveRow(at: indexPath, to: IndexPath(row: queueCount - 1, section: indexPath.section), in: tableView)
                }
                Analytics.track(.episodeSwipeActionPerformed, properties: ["action": "up_next_move_down", "source": "up_next"])
            }
            moveToBottomAction.image = UIImage(named: "upnext-movetobottom")
            moveToBottomAction.backgroundColor = ThemeColor.support03()
            moveToBottomAction.accessibilityLabel = L10n.moveToBottom
            moveToBottomAction.hidesWhenSelected = true
            return [moveToTopAction, moveToBottomAction]
        case .right:
            let deleteAction = SwipeAction(style: .destructive, title: nil) { [weak self] _, indexPath in
                guard let self, let episode = PlaybackManager.shared.queue.episodeAt(index: self.queueIndex(forVisibleRow: indexPath.row)) else { return }

                Analytics.track(.episodeSwipeActionPerformed, properties: ["action": "delete", "source": "up_next"])
                // The removal may be deferred behind a "keep in Session?" prompt, so the
                // table is refreshed in the completion rather than animating this row.
                SessionLinking.removeFromUpNextAskingSession(episode: episode) { [weak self] in
                    guard let self else { return }
                    self.changedViaSwipeToRemove = true
                    self.refreshUpNextFilterMatches()
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

            guard let episode = PlaybackManager.shared.queue.episodeAt(index: queueIndex(forVisibleRow: indexPath.row)) else {
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
        let sessionType = Settings.playbackSession()?.type
        guard sessionType == .playlist || sessionType == .smartPlaylist else { return nil }

        let moveToTop = SwipeAction(style: .default, title: nil) { [weak self] _, indexPath in
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

    /// Add-to-queue swipes for session-world rows — Play Next / Play Last, exactly like
    /// every other list. Honours the primary-swipe preference for their order.
    private func upNextAddSwipeActions(for episode: BaseEpisode) -> [SwipeAction] {
        let uuid = episode.uuid

        let addTop = SwipeAction(style: .default, title: nil) { action, _ in
            if let fresh = DataManager.sharedManager.findBaseEpisode(uuid: uuid) {
                PlaybackManager.shared.addToUpNext(episode: fresh, ignoringQueueLimit: true, toTop: true, userInitiated: true)
                SessionLinking.mirrorQueueAdd(episodes: [fresh])
            }
            Analytics.track(.episodeSwipeActionPerformed, properties: ["action": "up_next_add_top", "source": "up_next"])
            action.fulfill(with: .reset)
        }
        addTop.image = UIImage(named: "list_playnext")
        addTop.backgroundColor = ThemeColor.support04()
        addTop.accessibilityLabel = L10n.playNext
        addTop.hidesWhenSelected = true

        let addBottom = SwipeAction(style: .default, title: nil) { action, _ in
            if let fresh = DataManager.sharedManager.findBaseEpisode(uuid: uuid) {
                PlaybackManager.shared.addToUpNext(episode: fresh, ignoringQueueLimit: true, toTop: false, userInitiated: true)
                SessionLinking.mirrorQueueAdd(episodes: [fresh])
            }
            Analytics.track(.episodeSwipeActionPerformed, properties: ["action": "up_next_add_bottom", "source": "up_next"])
            action.fulfill(with: .reset)
        }
        addBottom.image = UIImage(named: "list_playlast")
        addBottom.backgroundColor = ThemeColor.support03()
        addBottom.accessibilityLabel = L10n.playLast
        addBottom.hidesWhenSelected = true

        return Settings.primaryUpNextSwipeAction() == .playNext ? [addTop, addBottom] : [addBottom, addTop]
    }

    /// Right-swipe actions for the Now Playing card and session rows: Remove (from
    /// the session's lineup, dismissal and all) at the edge, then archive.
    private func episodeSwipeActions(for episode: BaseEpisode) -> [SwipeAction] {
        let remove = SwipeAction(style: .default, title: nil) { [weak self] action, _ in
            defer { action.fulfill(with: .reset) }
            guard let self else { return }
            if let playbackSession = Settings.playbackSession(),
               let storeSession = SessionStore.shared.session(forStore: playbackSession.uuid) {
                SessionManager.shared.removeFromLineup(episodeUuids: [episode.uuid], session: storeSession)
            } else if let playbackSession = Settings.playbackSession(), playbackSession.type == .playlist,
                      let playlist = DataManager.sharedManager.findPlaylist(uuid: playbackSession.uuid) {
                DataManager.sharedManager.deleteEpisodes([episode.uuid], from: playlist)
                NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged, object: playlist)
            } else {
                PlaybackManager.shared.removeIfPlayingOrQueued(episode: episode, fireNotification: true, userInitiated: true)
            }
            self.refreshUpNextFilterMatches()
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
        switch Settings.playbackSession()?.type {
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
        refreshUpNextFilterMatches()
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
        guard let session = Settings.playbackSession(), session.type == .playlist,
              let playlist = DataManager.sharedManager.findPlaylist(uuid: session.uuid) else { return }
        DataManager.sharedManager.deleteEpisodes([episode.uuid], from: playlist)
        NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged, object: playlist)
        refreshUpNextFilterMatches()
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
