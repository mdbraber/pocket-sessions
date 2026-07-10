import Foundation
import PocketCastsDataModel
import PocketCastsUtils
import SwipeCellKit

extension UpNextViewController: SwipeTableViewCellDelegate, SwipeHandler {
    func swipeCurrentlyAllowed() -> Bool {
        return isReorderInProgress == false
    }

    func tableView(_ tableView: UITableView, editActionsForRowAt indexPath: IndexPath, for orientation: SwipeActionsOrientation) -> [SwipeAction]? {
        // The Now Playing card: archive / add to playlist / mark played — acting on
        // the playing episode hands playback to whatever comes next.
        if tableData[indexPath.section] == .nowPlayingSection {
            guard topBlockHasCard, indexPath.row == 0, orientation == .right,
                  let episode = PlaybackManager.shared.currentEpisode() else { return nil }
            return episodeSwipeActions(for: episode)
        }

        // Session rows aren't queue rows — moves reorder the mirrored playlist on the
        // left; archive / mark played on the right.
        if tableData[indexPath.section] == .sessionSection {
            guard let episode = sessionEpisodes?[safe: indexPath.row] else { return nil }
            switch orientation {
            case .left:
                return sessionMoveSwipeActions(at: indexPath)
            case .right:
                return episodeSwipeActions(for: episode, includeQueueAdds: true)
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

                self.changedViaSwipeToRemove = true
                PlaybackManager.shared.removeIfPlayingOrQueued(episode: episode, fireNotification: true, userInitiated: true)
                Analytics.track(.episodeSwipeActionPerformed, properties: ["action": "delete", "source": "up_next"])
                self.refreshUpNextFilterMatches()
                let remainingEpisodes = PlaybackManager.shared.queue.upNextCount()
                if remainingEpisodes > 0 {
                    do {
                        try SJCommonUtils.catchException {
                            tableView.deleteRows(at: [indexPath], with: .automatic)
                        }
                    } catch {
                        FileLog.shared.addMessage("Caught Objective-C exception while trying to remove an Up Next row by swiping, reloading table instead")
                        tableView.reloadData()
                    }
                } else {
                    tableView.reloadData() // if they delete the very last episode, reload the table to get the empty up next cell
                    if FeatureFlag.upNextShuffle.enabled {
                        isMultiSelectEnabled = false
                        updateNavBarButtons()
                    }
                }
                self.changedViaSwipeToRemove = false
            }

            // customize the action appearance
            deleteAction.image = UIImage(named: "episode-removenext")
            deleteAction.backgroundColor = ThemeColor.support05(for: themeOverride)
            deleteAction.accessibilityLabel = L10n.removeFromUpNext

            let markPlayedAction = SwipeAction(style: .default, title: nil) { [weak self] _, indexPath in
                guard let self, let episode = PlaybackManager.shared.queue.episodeAt(index: self.queueIndex(forVisibleRow: indexPath.row)) else { return }
                EpisodeManager.markAsPlayed(episode: episode, fireNotification: true)
            }
            markPlayedAction.hidesWhenSelected = true
            markPlayedAction.backgroundColor = ThemeColor.support02()
            markPlayedAction.image = UIImage(named: "episode-markasplayed")
            markPlayedAction.accessibilityLabel = L10n.markPlayedShort

            return [deleteAction, markPlayedAction]
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

    /// Right-swipe actions for the Now Playing card and session rows: archive and
    /// mark played — session rows also offer adding to the top/bottom of Up Next.
    private func episodeSwipeActions(for episode: BaseEpisode, includeQueueAdds: Bool = false) -> [SwipeAction] {
        var actions = [SwipeAction]()

        if let episode = episode as? Episode {
            let archive = SwipeAction(style: .default, title: nil) { [weak self] _, _ in
                EpisodeManager.archiveEpisode(episode: episode, fireNotification: true)
                self?.reloadTable()
            }
            archive.image = UIImage(named: "list_archive")
            archive.backgroundColor = ThemeColor.support06()
            archive.accessibilityLabel = L10n.archive
            archive.hidesWhenSelected = true
            actions.append(archive)
        }

        if includeQueueAdds {
            let addTop = SwipeAction(style: .default, title: nil) { _, _ in
                PlaybackManager.shared.addToUpNext(episode: episode, ignoringQueueLimit: true, toTop: true, userInitiated: true)
            }
            addTop.image = UIImage(named: "list_playnext")
            addTop.backgroundColor = ThemeColor.support02()
            addTop.accessibilityLabel = L10n.playNext
            addTop.hidesWhenSelected = true
            actions.append(addTop)

            let addBottom = SwipeAction(style: .default, title: nil) { _, _ in
                PlaybackManager.shared.addToUpNext(episode: episode, ignoringQueueLimit: true, toTop: false, userInitiated: true)
            }
            addBottom.image = UIImage(named: "list_playlast")
            addBottom.backgroundColor = ThemeColor.support02()
            addBottom.accessibilityLabel = L10n.playLast
            addBottom.hidesWhenSelected = true
            actions.append(addBottom)
        }

        let markPlayed = SwipeAction(style: .default, title: nil) { [weak self] _, _ in
            EpisodeManager.markAsPlayed(episode: episode, fireNotification: true)
            self?.reloadTable()
        }
        markPlayed.image = UIImage(named: "episode-markasplayed")
        markPlayed.backgroundColor = ThemeColor.support02()
        markPlayed.accessibilityLabel = L10n.markPlayedShort
        markPlayed.hidesWhenSelected = true
        actions.append(markPlayed)

        return actions
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
