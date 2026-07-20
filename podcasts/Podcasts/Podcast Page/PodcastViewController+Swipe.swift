import Foundation
import PocketCastsDataModel
import PocketCastsUtils
import SwipeCellKit

extension PodcastViewController: SwipeTableViewCellDelegate, SwipeHandler {
    // MARK: - SwipeTableViewCellDelegate

    func tableView(_ tableView: UITableView, editActionsForRowAt indexPath: IndexPath, for orientation: SwipeActionsOrientation) -> [SwipeAction]? {
        guard !isMultiSelectEnabled, indexPath.section == PodcastViewController.allEpisodesSection, let episode = episodeAtIndexPath(indexPath) else { return nil }

        switch orientation {
        case .left:
            // Session (lineup) rows keep the queue actions; Episodes rows speak the
            // shared triage vocabulary (Add to Session · Play Next · Play Last).
            if showingSession {
                let actions = SwipeActionsHelper.createLeftActionsForEpisode(episode, tableView: tableView, indexPath: indexPath, swipeHandler: self)
                return actions.swipeKitActions()
            }
            return TriageSwipes.leftActions(for: episode, inLocalSession: cachedSessionMemberUuids.contains(episode.uuid), presenting: self, source: swipeSource, addToSession: { [weak self] in
                guard let self, let podcast = self.podcast else { return }

                let session = SessionManager.shared.findOrCreateSession(forPodcast: podcast)
                SessionManager.shared.addToSessions(episodeUuids: [episode.uuid], preferred: session, presenting: self) { [weak self] _ in
                    guard let self, let podcast = self.podcast else { return }
                    self.loadLocalEpisodes(podcast: podcast, animated: true)
                }
            })
        case .right:
            // Session rows: remove-at-edge like any lineup. Episodes rows: triage
            // (Remove from Session if local · Archive/Unarchive · Mark as (Un)Seen).
            if showingSession {
                let actions = SwipeActionsHelper.createRightActionsForEpisode(episode, tableView: tableView, indexPath: indexPath, swipeHandler: self)
                return actions.swipeKitActions()
            }
            return TriageSwipes.rightActions(for: episode, inLocalSession: cachedSessionMemberUuids.contains(episode.uuid), removeFromSession: { [weak self] in
                guard let self, let podcast = self.podcast else { return }
                SessionManager.shared.removeFromSessions(episodeUuids: [episode.uuid], preferred: SessionStore.shared.session(forPodcast: podcast.uuid), presenting: self) { [weak self] in
                    guard let self, let podcast = self.podcast else { return }
                    self.loadLocalEpisodes(podcast: podcast, animated: true)
                }
            }, reload: { [weak self] in
                guard let self, let podcast = self.podcast else { return }
                // The unread dot isn't part of a row's diff identity, so a diff reload
                // won't redraw the swiped row — refresh visible dots directly first.
                self.refreshVisibleUnseenDots()
                self.loadLocalEpisodes(podcast: podcast, animated: true)
            })
        }
    }

    /// Fork: re-paint the unread dot on every visible row from a fresh unseen set, so a
    /// mark-seen swipe clears the dot immediately (the dot isn't in a row's diff identity).
    private func refreshVisibleUnseenDots() {
        let unseen = InboxManager.shared.unseenUuids()
        for case let cell as EpisodeCell in episodesTable.visibleCells {
            guard let indexPath = episodesTable.indexPath(for: cell),
                  let episode = episodeAtIndexPath(indexPath) else { continue }
            cell.setUnseenIndicator(visible: unseen.contains(episode.uuid))
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

    // MARK: - SwipeActionsHandler

    var swipeSource: String {
        "podcast_details"
    }

    var swipeSourceType: SwipeSourceType {
        // Fork: the inline Session tab shows lineup rows, which swipe like a manual
        // playlist (remove-from-session on the edge, no add-to-playlist).
        showingSession ? .manualPlaylistDetail : .podcast
    }

    func archivingRemovesFromList() -> Bool {
        if showingSession { return true }

        return !(podcast?.showArchived ?? false)
    }

    func actionPerformed(willBeRemoved: Bool) {
        guard let podcast else { return }

        loadLocalEpisodes(podcast: podcast, animated: true)
    }

    func deleteRequested(uuid: String) {} // we don't support this one

    func share(episode: Episode, at indexPath: IndexPath) {
        SharingHelper.shared.shareLinkTo(episode: episode, fromController: self, fromTableView: tableView(), at: indexPath)
    }

    func addToManualPlaylist(episode: Episode, at: IndexPath) {
        NavigationManager.sharedManager.navigateTo(
            NavigationManager.manualPlaylistsChooserKey,
            data: [
                NavigationManager.manualPlaylistsChooserEpisodeKey: episode
            ]
        )
    }

    func removeFromManualPlaylist(episode: PocketCastsDataModel.Episode, at: IndexPath) {
        guard showingSession, let podcast, let session = SessionStore.shared.session(forPodcast: podcast.uuid) else { return }

        SessionManager.shared.removeFromLineup(episodeUuids: [episode.uuid], session: session)
        loadLocalEpisodes(podcast: podcast, animated: true)
    }
}
