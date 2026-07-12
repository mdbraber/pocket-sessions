import Foundation
import PocketCastsDataModel

/// Fork: computes what a session's feeder offers. Inbox membership is derived, never
/// stored: candidates − store members − dismissed − archived/played, with seen as a
/// display filter on top.
enum SessionFeederEngine {
    private static let optOutKey = "SJGlobalInboxOptOutPodcasts"

    // MARK: - Per-podcast opt-out (global Inbox)

    static func optOutPodcastUuids() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: optOutKey) ?? [])
    }

    static func setOptedOut(_ optedOut: Bool, podcastUuid: String) {
        var uuids = optOutPodcastUuids()
        if optedOut { uuids.insert(podcastUuid) } else { uuids.remove(podcastUuid) }
        UserDefaults.standard.set(Array(uuids), forKey: optOutKey)
        NotificationCenter.postOnMainThread(notification: SessionStore.changed)
    }

    // MARK: - Domains

    /// Every episode the feeder could ever speak for (no recency window) — the basis
    /// for the Archived tab. Newest first.
    static func domainEpisodes(for session: ForkSession, includeArchived: Bool) -> [Episode] {
        let archivedClause = includeArchived ? "" : " AND archived = 0"
        switch session.feeder {
        case .none:
            return []
        case .podcast(let uuid):
            return DataManager.sharedManager.findEpisodesWhere(
                customWhere: "podcastUuid = ?\(archivedClause) ORDER BY publishedDate DESC",
                arguments: [uuid]
            )
        case .folder(let uuid):
            let podcastUuids = DataManager.sharedManager.allPodcasts(includeUnsubscribed: false)
                .filter { $0.folderUuid == uuid }
                .map(\.uuid)
            guard !podcastUuids.isEmpty else { return [] }
            let placeholders = podcastUuids.map { _ in "?" }.joined(separator: ",")
            return DataManager.sharedManager.findEpisodesWhere(
                customWhere: "podcastUuid IN (\(placeholders))\(archivedClause) ORDER BY publishedDate DESC",
                arguments: podcastUuids
            )
        case .smartPlaylist(let uuid):
            guard let playlist = DataManager.sharedManager.findPlaylist(uuid: uuid) else { return [] }
            return EpisodesDataManager().playlistEpisodes(for: playlist, limit: 0, shouldShowArchived: includeArchived)
                .compactMap { $0.episode as? Episode }
        case .allPodcasts:
            let optedOut = optOutPodcastUuids()
            return DataManager.sharedManager.findEpisodesWhere(
                customWhere: "podcastUuid IN (SELECT uuid FROM \(DataManager.podcastTableName) WHERE subscribed = 1)\(archivedClause) ORDER BY publishedDate DESC",
                arguments: []
            )
            .filter { !optedOut.contains($0.podcastUuid) }
        }
    }

    /// The feeder's current offers: undecided and not already in the store, any age.
    /// Seen filtering happens at the caller per settings.
    static func inboxEpisodes(for session: ForkSession) -> [Episode] {
        let members = Set(storeMemberUuids(for: session))
        let dismissed = Set(SessionStore.shared.dismissedUuids(sessionUuid: session.uuid))
        let queued = Set(PlaybackManager.shared.queue.allEpisodes(includeNowPlaying: true).map(\.uuid))

        return domainEpisodes(for: session, includeArchived: false).filter { episode in
            if episode.played() || episode.archived { return false }
            if members.contains(episode.uuid) || dismissed.contains(episode.uuid) || queued.contains(episode.uuid) { return false }
            return true
        }
    }

    /// The Inbox of a session page: the feeder's offers, widened by the given
    /// filters. Unwindowed everywhere — every undecided episode is an offer.
    static func displayEpisodes(for session: ForkSession, showArchived: Bool, showPlayed: Bool, showSeen: Bool) -> [Episode] {
        let members = Set(storeMemberUuids(for: session))
        let dismissed = Set(SessionStore.shared.dismissedUuids(sessionUuid: session.uuid))
        let queued = Set(PlaybackManager.shared.queue.allEpisodes(includeNowPlaying: true).map(\.uuid))

        return domainEpisodes(for: session, includeArchived: showArchived).filter { episode in
            if episode.archived, !showArchived { return false }
            if episode.played(), !showPlayed { return false }
            if !showSeen, !episode.archived, !episode.played(), episode.isSeen { return false }
            if members.contains(episode.uuid) || dismissed.contains(episode.uuid) || queued.contains(episode.uuid) { return false }
            return true
        }
    }

    static func storeMemberUuids(for session: ForkSession) -> [String] {
        guard let storeUuid = session.storePlaylistUuid,
              let store = DataManager.sharedManager.findPlaylist(uuid: storeUuid) else { return [] }
        return EpisodesDataManager().playlistEpisodes(for: store, limit: 0).map { $0.episode.uuid }
    }

}
