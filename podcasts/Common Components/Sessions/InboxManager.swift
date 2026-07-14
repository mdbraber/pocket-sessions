import Foundation
import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils

/// Fork: the Inbox — one global manual playlist whose membership means "unseen".
///
/// There is no `seen` column anywhere. Seen is simply "not a member". The unread dot on an
/// episode row *is* Inbox membership, and because the Inbox is an ordinary manual playlist it
/// syncs across devices through Pocket Casts' own playlist sync, for free.
///
/// This class owns the two verbs that move episodes in and out of it.
///
/// **What adds:** the drain, after every sync. Nothing else. In particular there is no hook on
/// "episode inserted" — a full sync and `cache/mobile/podcast/full` both return the *entire*
/// catalogue, and hooking insertion would dump all of it into the Inbox. `offeredThrough` makes
/// that structurally impossible instead: every one of those episodes is already below the line.
///
/// **What removes:** any playback progress, archiving, being added to a Session, explicit triage,
/// and the podcast being unsubscribed.
final class InboxManager {
    static let shared = InboxManager()

    /// The Inbox is a set, not a queue, and it is triaged to zero — but a manual playlist is
    /// hard-capped at 1,000 members by the data model, and `add` there fails **silently and
    /// all-or-nothing** when it would overflow. Stopping short of the ceiling ourselves means
    /// the failure is ours to report rather than an invisible "new episodes stopped appearing".
    static let capacity = 900

    private let sweepDebounce = Debounce(delay: 0.3)

    /// Injectable so tests can point the bookkeeping at a temp file instead of `inbox.json`.
    let store: InboxStore

    init(store: InboxStore = .shared) {
        self.store = store
    }

    // MARK: - The playlist

    /// The Inbox playlist, created on first use.
    ///
    /// Its uuid is a compile-time constant (`DataManager.inboxPlaylistUuid`), which makes this
    /// idempotent across devices: two devices that both create the Inbox before syncing land on
    /// the same uuid and converge. A random uuid would leave two rival Inboxes.
    @discardableResult
    func inboxPlaylist() -> EpisodeFilter {
        if let existing = DataManager.sharedManager.findPlaylist(uuid: DataManager.inboxPlaylistUuid) {
            return existing
        }

        let playlist = EpisodeFilter.makeDefault()
        playlist.uuid = DataManager.inboxPlaylistUuid
        playlist.playlistName = L10n.inboxTitle
        playlist.manual = true
        playlist.sortType = PlaylistSort.dragAndDrop.rawValue
        playlist.isNew = false
        playlist.syncStatus = SyncStatus.notSynced.rawValue
        DataManager.sharedManager.save(playlist: playlist)
        return playlist
    }

    /// Membership, as a Set. Fetch this ONCE per list load and check it per row — never run a
    /// membership query per row.
    func unseenUuids() -> Set<String> {
        DataManager.sharedManager.playlistEpisodeUuids(for: DataManager.inboxPlaylistUuid)
    }

    func isUnseen(episodeUuid: String) -> Bool {
        unseenUuids().contains(episodeUuid)
    }

    // MARK: - Setup

    func setup() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(episodeStateChanged), name: Constants.Notifications.episodePlayStatusChanged, object: nil)
        center.addObserver(self, selector: #selector(episodeStateChanged), name: Constants.Notifications.episodeArchiveStatusChanged, object: nil)
        center.addObserver(self, selector: #selector(episodeStateChanged), name: Constants.Notifications.manyEpisodesChanged, object: nil)
        center.addObserver(self, selector: #selector(podcastDeleted(_:)), name: Constants.Notifications.podcastDeleted, object: nil)
    }

    // MARK: - Adding: the drain

    /// Adds genuinely new episodes to the Inbox. Called **after the sync completes**, never
    /// during the refresh — otherwise we would be editing a stale playlist, and the
    /// last-writer-wins push would clobber another device's triage.
    ///
    /// The rule is uniform, and it is the same rule for a brand-new install, a brand-new
    /// subscription, and an ordinary refresh:
    ///
    ///   - A subscribed podcast with **no** `offeredThrough` entry is new to us. Its line moves
    ///     to its newest episode and **nothing is added**. We never fill a backlog into the
    ///     Inbox: the Inbox is for what's new, not for what's there. (This is also what keeps a
    ///     fresh install, a full sync, and an OPML import from flooding it.)
    ///   - Otherwise, everything published after the line — and not already archived or played —
    ///     is offered, and the line moves up.
    func drain() {
        let podcasts = DataManager.sharedManager.allPodcasts(includeUnsubscribed: false)
        guard !podcasts.isEmpty else { return }

        let optedOut = SessionFeederEngine.optOutPodcastUuids()
        let lines = store.offeredThrough

        var newLines = [String: Date]()
        var needEpisodes = [(podcast: Podcast, line: Date)]()

        for podcast in podcasts where !optedOut.contains(podcast.uuid) {
            // `latestEpisodeDate` is maintained by the refresh (updateLatestEpisodeInfo), so by
            // the time we run it already reflects anything new that just arrived.
            guard let latest = podcast.latestEpisodeDate else { continue }

            guard let line = lines[podcast.uuid] else {
                newLines[podcast.uuid] = latest // new to us: offer nothing, just draw the line
                continue
            }
            guard latest > line else { continue } // nothing new

            needEpisodes.append((podcast, line))
            newLines[podcast.uuid] = latest
        }

        if !needEpisodes.isEmpty {
            add(episodes: newEpisodes(for: needEpisodes))
        }

        // Advance the line even for podcasts whose new episodes we skipped (auto-archived on
        // arrival, say) — otherwise every drain reconsiders them forever.
        store.advanceOfferedThrough(newLines)
    }

    /// One query for every podcast that has something new — not one query per podcast.
    private func newEpisodes(for candidates: [(podcast: Podcast, line: Date)]) -> [Episode] {
        var clauses = [String]()
        var arguments = [Any]()
        for candidate in candidates {
            clauses.append("(podcast_id = ? AND publishedDate > ?)")
            arguments.append(candidate.podcast.id)
            arguments.append(candidate.line)
        }

        // Anything already archived or already touched is not "new" to triage — the sync ran
        // before us, so a decision made on another device is already reflected here.
        let query = """
        (\(clauses.joined(separator: " OR "))) \
        AND archived = 0 AND wasDeleted = 0 AND playedUpTo = 0 AND playingStatus = \(PlayingStatus.notPlayed.rawValue) \
        ORDER BY publishedDate ASC
        """
        return DataManager.sharedManager.findEpisodesWhere(customWhere: query, arguments: arguments)
    }

    // MARK: - Verbs

    /// Adds episodes to the Inbox, respecting the cap. One write, one notification.
    private func add(episodes: [Episode]) {
        guard !episodes.isEmpty else { return }
        let playlist = inboxPlaylist()

        let existing = unseenUuids()
        var incoming = episodes.filter { !existing.contains($0.uuid) }
        guard !incoming.isEmpty else { return }

        let room = Self.capacity - existing.count
        guard room > 0 else {
            FileLog.shared.addMessage("InboxManager: Inbox is full (\(existing.count)); \(incoming.count) new episodes not offered")
            return
        }
        if incoming.count > room {
            FileLog.shared.addMessage("InboxManager: Inbox near capacity; offering \(room) of \(incoming.count) new episodes")
            incoming = Array(incoming.prefix(room))
        }

        guard DataManager.sharedManager.add(episodes: incoming, to: playlist) else {
            FileLog.shared.addMessage("InboxManager: failed to add \(incoming.count) episodes to the Inbox")
            return
        }
        NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged, object: playlist)
    }

    /// Mark as seen — i.e. leave the Inbox. This is the bulk verb: ONE delete, ONE notification,
    /// however many episodes. Per-episode mutation here would be N writes and N observer reloads,
    /// which is this fork's recurring bug class.
    func markSeen(episodeUuids: [String]) {
        guard !episodeUuids.isEmpty else { return }
        let playlist = inboxPlaylist()
        DataManager.sharedManager.deleteEpisodes(episodeUuids, from: playlist)
        NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged, object: playlist)
    }

    /// Mark as unseen — back into the Inbox.
    ///
    /// This also **unplays and unarchives**, and that is load-bearing rather than a nicety: any
    /// playback progress removes an episode from the Inbox, so re-adding one that still carries
    /// progress would see it swept straight back out on the next state change. "Unseen" means
    /// "fresh again", and it is the only recovery path in the model — removals leave no record.
    func markUnseen(episodeUuids: [String]) {
        guard !episodeUuids.isEmpty else { return }
        let episodes = episodeUuids.compactMap { DataManager.sharedManager.findEpisode(uuid: $0) }
        guard !episodes.isEmpty else { return }

        for episode in episodes where episode.played() || episode.playedUpTo > 0 {
            EpisodeManager.markAsUnplayed(episode: episode, fireNotification: false)
        }
        for episode in episodes where episode.archived {
            EpisodeManager.unarchiveEpisode(episode: episode, fireNotification: false)
        }
        NotificationCenter.postOnMainThread(notification: Constants.Notifications.manyEpisodesChanged)

        add(episodes: episodes)
    }

    // MARK: - Removing: the sweeps

    /// Bulk events (`manyEpisodesChanged`) carry no uuid, so the only honest response is to
    /// re-check the whole Inbox. Debounced, and done as one query plus one delete.
    @objc private func episodeStateChanged() {
        sweepDebounce.call { [weak self] in
            self?.sweep()
        }
    }

    /// Removes anything in the Inbox that has since been decided: archived, or touched at all.
    /// "Any playback progress" is deliberate — a few seconds in is still a decision.
    func sweep() {
        let decided = DataManager.sharedManager.findEpisodesWhere(
            customWhere: """
            uuid IN (SELECT episodeUuid FROM \(DataManager.playlistEpisodeTableName) WHERE playlist_uuid = ?) \
            AND (archived = 1 OR wasDeleted = 1 OR playedUpTo > 0 OR playingStatus != \(PlayingStatus.notPlayed.rawValue))
            """,
            arguments: [DataManager.inboxPlaylistUuid]
        )
        guard !decided.isEmpty else { return }
        markSeen(episodeUuids: decided.map(\.uuid))
    }

    @objc private func podcastDeleted(_ notification: Notification) {
        guard let podcastUuid = notification.object as? String else { return }

        // A re-subscribe should behave like a fresh subscribe (draw the line, offer nothing)
        // rather than replay the podcast's history.
        store.forget(podcastUuid: podcastUuid)

        // Membership would otherwise pin the podcast alive: `deletePodcastIfUnused` bails when
        // `playlistContainsPodcast` is true, so an unsubscribed podcast with Inbox members would
        // never be cleaned up.
        let orphaned = DataManager.sharedManager.findEpisodesWhere(
            customWhere: "uuid IN (SELECT episodeUuid FROM \(DataManager.playlistEpisodeTableName) WHERE playlist_uuid = ?) AND podcastUuid = ?",
            arguments: [DataManager.inboxPlaylistUuid, podcastUuid]
        )
        guard !orphaned.isEmpty else { return }
        markSeen(episodeUuids: orphaned.map(\.uuid))
    }
}
