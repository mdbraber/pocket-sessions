import Foundation
import PocketCastsDataModel

/// Fork: what a session's feeder speaks for, and the badge numbers derived from it.
///
/// **Unseen is Inbox playlist membership.** There is no seen flag, no watermark, no dismissal
/// set, and no precedence chain — a session's "inbox" is simply its domain intersected with the
/// one global Inbox playlist. Everything that used to make an episode disappear from an inbox
/// (played, archived, added to a session, dismissed) now removes it from that playlist instead,
/// which is a single source of truth that also syncs.
///
/// That also deletes the fork's worst hot path. `inboxEpisodes` used to run a full playlist query
/// *per session* and then filter every unarchived episode of every subscribed podcast in Swift.
/// The per-podcast badge version of it "made the whole app sluggish" (its own comment). Both are
/// now indexed set lookups.
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

    /// Every episode the feeder could ever speak for. Newest first.
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

    /// This feeder's unseen episodes: its domain ∩ the Inbox playlist.
    static func inboxEpisodes(for session: Session) -> [Episode] {
        let unseen = InboxManager.shared.unseenUuids()
        guard !unseen.isEmpty else { return [] }
        return domainEpisodes(for: session, includeArchived: false).filter { unseen.contains($0.uuid) }
    }

    // MARK: - Session membership

    /// The union of every session's lineup — one query, not one per session.
    static func allStoreMemberUuids() -> Set<String> {
        let storeUuids = SessionStore.shared.sessions.compactMap(\.storePlaylistUuid)
        return DataManager.sharedManager.playlistEpisodeUuids(forPlaylistUuids: storeUuids)
    }

    static func storeMemberUuids(for session: Session) -> [String] {
        guard let storeUuid = session.storePlaylistUuid,
              let store = DataManager.sharedManager.findPlaylist(uuid: storeUuid) else { return [] }
        return DataManager.sharedManager.positionedEpisodeUuids(for: store)
    }

    // MARK: - Grid badges

    /// The unseen count for every podcast at once, from ONE grouped query.
    static func inboxBadgeCounts(forPodcasts podcasts: [Podcast]) -> [String: Int] {
        guard !podcasts.isEmpty else { return [:] }
        let counts = DataManager.sharedManager.playlistEpisodeCountsByPodcast(for: DataManager.inboxPlaylistUuid)
        let wanted = Set(podcasts.map(\.uuid))
        return counts.filter { wanted.contains($0.key) }
    }

    /// Bulk session-lineup counts — the podcast page's Session tab number.
    static func sessionBadgeCounts(forPodcasts podcasts: [Podcast]) -> [String: Int] {
        var counts = [String: Int]()
        for podcast in podcasts {
            guard let session = SessionStore.shared.session(forPodcast: podcast.uuid) else { continue }
            counts[podcast.uuid] = storeMemberUuids(for: session).count
        }
        return counts
    }

    /// A smart playlist's unseen count: |Inbox ∩ that playlist's results|.
    static func inboxBadgeCount(forPlaylist playlist: EpisodeFilter) -> Int {
        let unseen = InboxManager.shared.unseenUuids()
        guard !unseen.isEmpty else { return 0 }

        if playlist.manual {
            return DataManager.sharedManager.playlistEpisodeUuids(for: playlist.uuid).intersection(unseen).count
        }
        return EpisodesDataManager().playlistEpisodes(for: playlist, limit: 0)
            .filter { unseen.contains($0.episode.uuid) }
            .count
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
