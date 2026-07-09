import Foundation
import PocketCastsDataModel
import PocketCastsUtils
import SwipeCellKit

extension UpNextViewController: SwipeTableViewCellDelegate, SwipeHandler {
    func swipeCurrentlyAllowed() -> Bool {
        return isReorderInProgress == false
    }

    func tableView(_ tableView: UITableView, editActionsForRowAt indexPath: IndexPath, for orientation: SwipeActionsOrientation) -> [SwipeAction]? {
        // Session rows aren't queue rows — the queue's move/remove actions don't apply.
        // They get the app-wide episode swipes instead: Play Next / Play Last on the left,
        // archive / share / add-to-playlist on the right (the inbox notice row gets none).
        if tableData[indexPath.section] == .sessionSection {
            guard let episode = sessionEpisodes?[safe: indexPath.row] else { return nil }
            switch orientation {
            case .left:
                return SwipeActionsHelper.createLeftActionsForEpisode(episode, tableView: tableView, indexPath: indexPath, swipeHandler: self).swipeKitActions()
            case .right:
                return SwipeActionsHelper.createRightActionsForEpisode(episode, tableView: tableView, indexPath: indexPath, swipeHandler: self).swipeKitActions()
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

            if let episode = DataManager.sharedManager.episodeInUpNextAt(index: queueIndex(forVisibleRow: indexPath.row) + 1) as? Episode {
                let shareAction = SwipeAction(style: .default, title: nil) { [weak self] _, _ in
                    guard let self else { return }
                    Analytics.track(
                        .episodeSwipeActionPerformed,
                        properties: [
                            "action": "add_to_playlist",
                            "source": "up_next"
                        ]
                    )
                    let presentModal: () -> Void = { [weak self] in
                        NavigationManager.sharedManager.navigateTo(
                            NavigationManager.manualPlaylistsChooserKey,
                            data: [
                                NavigationManager.manualPlaylistsChooserEpisodeKey: episode,
                                NavigationManager.manualPlaylistsChooserRootKey: self as Any
                            ]
                        )
                    }
                    if self.presentingViewController is PlayerContainerViewController {
                        self.dismiss(animated: true, completion: presentModal)
                    } else {
                        presentModal()
                    }
                }
                shareAction.hidesWhenSelected = true
                shareAction.backgroundColor = SwipeActionsHelper.addToPlaylistSwipeBackground
                shareAction.image = UIImage(named: "playlist-add-episode")
                shareAction.accessibilityLabel = L10n.playlistManualAddEpisodes
                return [deleteAction, shareAction]
            }

            return [deleteAction]
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
