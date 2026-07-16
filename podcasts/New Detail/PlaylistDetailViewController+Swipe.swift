import PocketCastsDataModel
import PocketCastsUtils
import SwipeCellKit

extension PlaylistDetailViewController: SwipeTableViewCellDelegate, SwipeHandler {
    // MARK: - SwipeTableViewCellDelegate

    func tableView(_ tableView: UITableView, editActionsForRowAt indexPath: IndexPath, for orientation: SwipeActionsOrientation) -> [SwipeAction]? {
        guard !isMultiSelectEnabled, let episode = viewModel.listEpisode(at: indexPath)?.episode else { return nil }

        let rowSection = viewModel.section(at: indexPath.section)
        switch orientation {
        case .left:
            // Episodes rows use the shared triage vocabulary (the dot lives there, so
            // swiping it away must clear it); Session lineup rows keep the queue actions.
            if rowSection == .browse {
                return TriageSwipes.leftActions(for: episode, inLocalSession: viewModel.thisSessionMemberUuids.contains(episode.uuid), addToSession: { [weak self] in
                    guard let self else { return }
                    self.viewModel.addToSessionsPerSetting(episodeUuids: [episode.uuid], presenting: self)
                })
            }
            let actions = SwipeActionsHelper.createLeftActionsForEpisode(episode, tableView: tableView, indexPath: indexPath, swipeHandler: self)
            return actions.swipeKitActions()
        case .right:
            if rowSection == .browse {
                return TriageSwipes.rightActions(for: episode, inLocalSession: viewModel.thisSessionMemberUuids.contains(episode.uuid), removeFromSession: { [weak self] in
                    guard let self else { return }
                    SessionManager.shared.removeFromSessions(episodeUuids: [episode.uuid], preferred: self.viewModel.session ?? self.viewModel.lensSession, presenting: self) { [weak self] in
                        self?.viewModel.reloadEpisodeList(animated: true)
                    }
                }, reload: { [weak self] in
                    // The unread dot lives in the cell but isn't part of a row's content
                    // identity, so a diff reload won't redraw the swiped row — refresh the
                    // visible dots directly so marking seen clears the dot immediately.
                    self?.refreshVisibleUnseenDots()
                    self?.viewModel.reloadEpisodeList(animated: true)
                })
            }
            // Fork: lens-page Session rows — Remove from the session at the edge,
            // then the archive toggle (same shape as a store's lineup).
            if viewModel.isLensPage {
                return lensLineupRightActions(for: episode)
            }
            let actions = SwipeActionsHelper.createRightActionsForEpisode(episode, tableView: tableView, indexPath: indexPath, swipeHandler: self)
            return actions.swipeKitActions()
        }
    }

    /// Fork: re-paint the unread dot on every visible row from a fresh unseen set. The dot
    /// isn't part of a row's diff identity, so a mark-seen has to nudge the cells itself.
    private func refreshVisibleUnseenDots() {
        let unseen = InboxManager.shared.unseenUuids()
        for case let cell as EpisodeCell in tableView.visibleCells {
            guard let indexPath = tableView.indexPath(for: cell),
                  let episode = viewModel.listEpisode(at: indexPath)?.episode else { continue }
            cell.setUnseenIndicator(visible: unseen.contains(episode.uuid))
        }
    }

    private func lensLineupRightActions(for episode: BaseEpisode) -> [SwipeAction] {
        let remove = SwipeAction(style: .default, title: nil) { [weak self] action, _ in
            defer { action.fulfill(with: .reset) }
            guard let self else { return }
            guard let session = self.viewModel.lensSession ?? self.viewModel.session else {
                FileLog.shared.addMessage("Lens lineup remove: no session resolved for \(self.viewModel.playlist.uuid)")
                return
            }
            SessionManager.shared.removeFromLineup(episodeUuids: [episode.uuid], session: session)
            self.viewModel.reloadEpisodeList(animated: true)
        }
        remove.image = TriageSwipes.sessionRemoveImage()?.withTintColor(.white, renderingMode: .alwaysOriginal)
        remove.backgroundColor = ThemeColor.support05() // red — Remove from Session
        remove.accessibilityLabel = L10n.sessionRemoveFrom
        remove.hidesWhenSelected = true

        var actions = [remove]
        if let episode = episode as? Episode {
            let archived = episode.archived
            let uuid = episode.uuid
            let archive = SwipeAction(style: .default, title: nil) { [weak self] action, _ in
                // Fresh object so the diff sees the change; fulfill closes the swipe.
                if let fresh = DataManager.sharedManager.findEpisode(uuid: uuid) {
                    if archived {
                        EpisodeManager.unarchiveEpisode(episode: fresh, fireNotification: true)
                    } else {
                        EpisodeManager.archiveEpisode(episode: fresh, fireNotification: true)
                    }
                }
                self?.viewModel.reloadEpisodeList(animated: true)
                action.fulfill(with: .reset)
            }
            archive.image = UIImage(named: archived ? "list_unarchive" : "list_archive")
            archive.backgroundColor = ThemeColor.support06()
            archive.accessibilityLabel = archived ? L10n.unarchive : L10n.archive
            archive.hidesWhenSelected = true
            actions.append(archive)
        }
        return actions
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

    func tableView(_ tableView: UITableView, willBeginEditingRowAt indexPath: IndexPath, for orientation: SwipeActionsOrientation) {
        reloader.pause(for: .seconds(8)) // Adding a timeout just in case calling `resume` for whatever reason
    }

    func tableView(_ tableView: UITableView, didEndEditingRowAt indexPath: IndexPath?, for orientation: SwipeActionsOrientation) {
        reloader.resume(after: .seconds(1))
    }

    // MARK: - SwipeActionsHandler

    var swipeSource: String {
        "filters"
    }

    var swipeSourceType: SwipeSourceType {
        viewModel.isManualPlaylist ? .manualPlaylistDetail : .smartPlaylistDetail
    }

    func actionPerformed(willBeRemoved: Bool) {
        reloader.resume(after: .seconds(1))
        if willBeRemoved {
            viewModel.reloadEpisodeList()
        }
    }

    func deleteRequested(uuid: String) {} // we don't support this one

    func archivingRemovesFromList() -> Bool {
        true
    }

    func share(episode: Episode, at indexPath: IndexPath) {
        SharingHelper.shared.shareLinkTo(episode: episode, fromController: self, fromTableView: tableView, at: indexPath)
    }

    func addToManualPlaylist(episode: PocketCastsDataModel.Episode, at: IndexPath) {
        NavigationManager.sharedManager.navigateTo(
            NavigationManager.manualPlaylistsChooserKey,
            data: [
                NavigationManager.manualPlaylistsChooserEpisodeKey: episode
            ]
        )
    }

    func removeFromManualPlaylist(episode: PocketCastsDataModel.Episode, at: IndexPath) {
        track(episode: episode, added: false, to: viewModel.playlist, source: "swipe_remove")

        viewModel.delete(episodes: [episode.uuid])
        viewModel.reloadEpisodeList()
    }
}
