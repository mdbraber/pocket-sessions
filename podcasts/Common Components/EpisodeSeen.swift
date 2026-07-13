import Foundation
import PocketCastsDataModel

/// Fork: seen/unseen per episode. "Seen" is a bounded hybrid — an explicit
/// per-episode override, or playback progress, or a per-inbox "cleared-through"
/// watermark (with the global inbox's line as a floor). Purely attention state:
/// display filters only.
extension BaseEpisode {
    /// Seen within a specific inbox (feeder). Explicit overrides win, then playback,
    /// then the inbox's cleared-through watermark.
    func isSeen(inFeeder feederUuid: String) -> Bool {
        if SessionStore.shared.isUnseenMarked(episodeUuid: uuid) { return false }
        if SessionStore.shared.isSeenMarked(episodeUuid: uuid) { return true }
        if playedUpTo > 0 { return true }
        guard let watermark = SessionStore.shared.effectiveWatermark(feederUuid: feederUuid),
              let published = (self as? Episode)?.publishedDate else { return false }
        return published <= watermark
    }

    /// Account-wide seen, using the global inbox baseline — for surfaces without a
    /// specific inbox context (badges, the Up Next filter).
    var isSeen: Bool { isSeen(inFeeder: SessionStore.globalInboxUuid) }
}

enum EpisodeSeenManager {
    /// Explicit per-episode seen — selective "clear this one".
    static func markSeen(_ episodes: [BaseEpisode]) {
        guard !episodes.isEmpty else { return }
        SessionStore.shared.markSeen(episodeUuids: episodes.map(\.uuid))
    }

    /// Explicit per-episode unseen — "bring this back", fresh again.
    static func markUnseen(_ episodes: [BaseEpisode]) {
        guard !episodes.isEmpty else { return }
        SessionStore.shared.markUnseen(episodeUuids: episodes.map(\.uuid))
        freshenForUnseen(episodes)
    }

    /// Bulk "Mark All as Seen" for one inbox — advances that inbox's watermark (O(1))
    /// instead of writing a marker per episode, so the store never balloons.
    static func clearInbox(_ episodes: [BaseEpisode], feederUuid: String) {
        let watermark = episodes.compactMap { ($0 as? Episode)?.publishedDate }.max() ?? Date()
        SessionStore.shared.clearThrough(feederUuid: feederUuid, date: watermark, episodeUuids: episodes.map(\.uuid))
    }

    static func toggleSeen(episode: BaseEpisode, inFeeder feederUuid: String = SessionStore.globalInboxUuid) {
        if episode.isSeen(inFeeder: feederUuid) { markUnseen([episode]) } else { markSeen([episode]) }
    }

    /// Unseen means "fresh again" — the episode must actually return to inboxes.
    /// Progress would keep it seen (playedUpTo > 0), and archive state or an old
    /// dismissal would keep the feeder from offering it, so clear those too.
    private static func freshenForUnseen(_ episodes: [BaseEpisode]) {
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
}
