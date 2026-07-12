import Foundation
import PocketCastsDataModel

/// Fork: seen/unseen per episode. Seen = any playback progress, or a manual mark in
/// the local SessionStore. Purely attention state — display filters only.
extension BaseEpisode {
    var isSeen: Bool {
        playedUpTo > 0 || SessionStore.shared.isManuallySeen(episodeUuid: uuid)
    }
}

enum EpisodeSeenManager {
    static func setSeen(_ seen: Bool, episode: BaseEpisode) {
        setSeen(seen, episodes: [episode])
    }

    /// Batched: one store write, one dismissal sweep, and at most one notification
    /// pair for the whole set — bulk selections stay fast.
    static func setSeen(_ seen: Bool, episodes: [BaseEpisode]) {
        guard !episodes.isEmpty else { return }
        SessionStore.shared.setSeen(seen, episodeUuids: episodes.map(\.uuid))
        guard !seen else { return }

        // Unseen means "fresh again" — the episode must actually return to inboxes.
        // Progress would keep isSeen true (seen = playedUpTo > 0 || manual mark), and
        // archive state or an old dismissal would keep the feeder from offering it.
        var changedState = false
        for episode in episodes {
            if episode.playedUpTo > 0 || episode.played() || episode.inProgress() {
                EpisodeManager.markAsUnplayed(episode: episode, fireNotification: false, userInitiated: false)
                changedState = true
            } else if let episode = episode as? Episode, episode.archived {
                EpisodeManager.unarchiveEpisode(episode: episode, fireNotification: false)
                changedState = true
            }
        }
        SessionStore.shared.clearDismissals(episodeUuids: episodes.map(\.uuid))
        if changedState {
            NotificationCenter.postOnMainThread(notification: Constants.Notifications.episodePlayStatusChanged)
            NotificationCenter.postOnMainThread(notification: Constants.Notifications.episodeArchiveStatusChanged)
        }
    }

    static func toggleSeen(episode: BaseEpisode) {
        setSeen(!episode.isSeen, episode: episode)
    }
}
