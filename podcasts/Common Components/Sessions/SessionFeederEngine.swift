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
    static func domainEpisodes(for session: Session, includeArchived: Bool) -> [Episode] {
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
    static func inboxEpisodes(for session: Session) -> [Episode] {
        let members = allStoreMemberUuids()
        let dismissed = Set(SessionStore.shared.dismissedUuids(sessionUuid: session.uuid))
        let queued = Set(PlaybackManager.shared.queue.allEpisodes(includeNowPlaying: true).map(\.uuid))

        return domainEpisodes(for: session, includeArchived: false).filter { episode in
            if episode.played() || episode.archived { return false }
            if members.contains(episode.uuid) || dismissed.contains(episode.uuid) || queued.contains(episode.uuid) { return false }
            return true
        }
    }

    /// The union of every session's lineup — an episode in ANY lineup is decided,
    /// so no inbox offers it (the partition rule: Inbox holds only the undecided).
    static func allStoreMemberUuids() -> Set<String> {
        var members = Set<String>()
        for session in SessionStore.shared.sessions {
            members.formUnion(storeMemberUuids(for: session))
        }
        return members
    }

    static func storeMemberUuids(for session: Session) -> [String] {
        guard let storeUuid = session.storePlaylistUuid,
              let store = DataManager.sharedManager.findPlaylist(uuid: storeUuid) else { return [] }
        return EpisodesDataManager().playlistEpisodes(for: store, limit: 0).map { $0.episode.uuid }
    }

    // MARK: - Grid badges

    /// Bulk inbox counts for the grid badges — the podcast page's Inbox tab number
    /// for every podcast, from ONE episode query. Grid refreshes fire on every
    /// triage/queue event; per-podcast queries here made the whole app sluggish.
    static func inboxBadgeCounts(forPodcasts podcasts: [Podcast]) -> [String: Int] {
        guard !podcasts.isEmpty else { return [:] }

        let queued = Set(PlaybackManager.shared.queue.allEpisodes(includeNowPlaying: true).map(\.uuid))
        let members = allStoreMemberUuids()

        // Dismissals are scoped per podcast session — only podcasts with sessions
        // have any.
        var dismissedByPodcast = [String: Set<String>]()
        for podcast in podcasts {
            guard let session = SessionStore.shared.session(forPodcast: podcast.uuid) else { continue }
            dismissedByPodcast[podcast.uuid] = Set(SessionStore.shared.dismissedUuids(sessionUuid: session.uuid))
        }

        let placeholders = podcasts.map { _ in "?" }.joined(separator: ",")
        let episodes = DataManager.sharedManager.findEpisodesWhere(
            customWhere: "podcastUuid IN (\(placeholders)) AND archived = 0",
            arguments: podcasts.map(\.uuid)
        )

        var counts = [String: Int]()
        for episode in episodes {
            // Mirrors inboxEpisodes plus the callers' seen filter: undecided only.
            if episode.played() || episode.isSeen { continue }
            if queued.contains(episode.uuid) { continue }
            if members.contains(episode.uuid) { continue }
            if dismissedByPodcast[episode.podcastUuid]?.contains(episode.uuid) == true { continue }
            counts[episode.podcastUuid, default: 0] += 1
        }
        return counts
    }

    /// Bulk session-lineup counts — the podcast page's Session tab number. Only
    /// podcasts with sessions cost a query.
    static func sessionBadgeCounts(forPodcasts podcasts: [Podcast]) -> [String: Int] {
        var counts = [String: Int]()
        for podcast in podcasts {
            guard let session = SessionStore.shared.session(forPodcast: podcast.uuid) else { continue }
            counts[podcast.uuid] = storeMemberUuids(for: session).count
        }
        return counts
    }

    /// The playlist page's Inbox count — via its session (store or fed lens), or the
    /// sessionless lens preview.
    static func inboxBadgeCount(forPlaylist playlist: EpisodeFilter) -> Int {
        let session = SessionStore.shared.session(forStore: playlist.uuid)
            ?? SessionStore.shared.session(forSmartPlaylistFeeder: playlist.uuid)
            ?? (playlist.manual ? nil : Session(uuid: "lens-inbox-preview", storePlaylistUuid: nil, feeder: .smartPlaylist(uuid: playlist.uuid)))
        guard let session else { return 0 }
        return inboxEpisodes(for: session).count
    }

    /// The playlist page's Session count — its session's lineup size.
    static func sessionBadgeCount(forPlaylist playlist: EpisodeFilter) -> Int {
        let session = SessionStore.shared.session(forStore: playlist.uuid)
            ?? SessionStore.shared.session(forSmartPlaylistFeeder: playlist.uuid)
        guard let session else { return 0 }
        return storeMemberUuids(for: session).count
    }

    /// One badge number for a playlist row, aligned with the podcast badge types
    /// (dot types return 0/1).
    static func badgeCount(forPlaylist playlist: EpisodeFilter, badgeType: BadgeType) -> Int {
        switch badgeType {
        case .off:
            return 0
        case .latestEpisode:
            let latest = EpisodesDataManager().playlistEpisodes(for: playlist, limit: 0)
                .compactMap { $0.episode as? Episode }
                .max { ($0.publishedDate ?? .distantPast) < ($1.publishedDate ?? .distantPast) }
            guard let latest else { return 0 }
            return latest.unplayed() && !latest.archived ? 1 : 0
        case .allUnplayed:
            return EpisodesDataManager().playlistEpisodes(for: playlist, limit: 0)
                .compactMap { $0.episode as? Episode }
                .filter { !$0.played() && !$0.archived }
                .count
        case .anyInInbox:
            return min(inboxBadgeCount(forPlaylist: playlist), 1)
        case .inboxCount:
            return inboxBadgeCount(forPlaylist: playlist)
        case .sessionCount:
            return sessionBadgeCount(forPlaylist: playlist)
        }
    }
}
