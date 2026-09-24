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
/// and the podcast being unsubscribed. One exception: an episode explicitly marked unseen is
/// exempt from the progress rule until it leaves the Inbox again (see `markUnseen`).
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

    /// The Inbox itself — every unseen episode, newest first.
    ///
    /// The stored playlist order is meaningless: the Inbox is a *set*, and its order is whatever
    /// episodes happened to arrive in. Newest-first is the default *view*; sort and grouping are
    /// display lenses and never rewrite the playlist.
    func unseenEpisodes() -> [Episode] {
        DataManager.sharedManager.playlistEpisodes(for: inboxPlaylist(), limit: 0, sortType: .newestToOldest)
    }

    /// The badge number. A count query — it never materialises the episodes.
    func unseenCount() -> Int {
        DataManager.sharedManager.playlistEpisodeCount(for: inboxPlaylist(), episodeUuidToAdd: nil)
    }

    /// Opting a podcast out of the Inbox also clears what it already put there — otherwise the
    /// switch reads as "stop offering" but leaves a pile behind that nothing will ever refill.
    func setOptedOut(_ optedOut: Bool, podcastUuid: String) {
        SessionFeederEngine.setOptedOut(optedOut, podcastUuid: podcastUuid)
        guard optedOut else { return }

        let members = DataManager.sharedManager.findEpisodesWhere(
            customWhere: "uuid IN (SELECT episodeUuid FROM \(DataManager.playlistEpisodeTableName) WHERE playlist_uuid = ?) AND podcastUuid = ?",
            arguments: [DataManager.inboxPlaylistUuid, podcastUuid]
        )
        markSeen(episodeUuids: members.map(\.uuid))
    }

    /// Tri-state Add-to-Inbox. Tightening the policy also clears what the podcast already put in
    /// the Inbox that the new policy would no longer offer: `never` clears all of it;
    /// `whenNotInSessionOrUpNext` clears the ones already shelved in a session or queued.
    func setInboxAddPolicy(_ policy: SessionFeederEngine.InboxAddPolicy, podcastUuid: String) {
        SessionFeederEngine.setInboxAddPolicy(policy, forPodcast: podcastUuid)

        let members = DataManager.sharedManager.findEpisodesWhere(
            customWhere: "uuid IN (SELECT episodeUuid FROM \(DataManager.playlistEpisodeTableName) WHERE playlist_uuid = ?) AND podcastUuid = ?",
            arguments: [DataManager.inboxPlaylistUuid, podcastUuid]
        )
        guard !members.isEmpty else { return }

        switch policy {
        case .always:
            break
        case .never:
            markSeen(episodeUuids: members.map(\.uuid))
        case .whenNotInSessionOrUpNext:
            let shelved = SessionMembership.shared.inAnySession
                .union(PlaybackManager.shared.queue.allEpisodes(includeNowPlaying: true).map(\.uuid))
            markSeen(episodeUuids: members.map(\.uuid).filter { shelved.contains($0) })
        }
    }

    // MARK: - Setup

    func setup() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(episodeStateChanged), name: Constants.Notifications.episodePlayStatusChanged, object: nil)
        center.addObserver(self, selector: #selector(episodeStateChanged), name: Constants.Notifications.episodeArchiveStatusChanged, object: nil)
        center.addObserver(self, selector: #selector(episodeStateChanged), name: Constants.Notifications.manyEpisodesChanged, object: nil)
        center.addObserver(self, selector: #selector(episodeQueued(_:)), name: Constants.Notifications.upNextEpisodeAdded, object: nil)
        center.addObserver(self, selector: #selector(podcastDeleted(_:)), name: Constants.Notifications.podcastDeleted, object: nil)
        // A remote seen-ledger arriving over CloudKit mutates the store; sweeping on that lets
        // this device drop members the other device already triaged away without waiting for
        // the playlist sync to happen to agree. (The sweep is a no-op when nothing applies, and
        // the store skips no-op mutations, so this cannot ping-pong.)
        center.addObserver(self, selector: #selector(episodeStateChanged), name: InboxStore.changed, object: nil)
    }

    // MARK: - Sync import filter

    /// The subset of `candidates` the seen-ledger says were deliberately removed from the
    /// Inbox. Injected into `ServerConfig.shared.inboxSeenFilter` at launch (AppDelegate), so
    /// the playlist sync import — which lives in PocketCastsServer and cannot see app types —
    /// can refuse to resurrect them. See `SyncTask+ServerChanges.importPlaylist`.
    func inboxSeenFilter(_ candidates: Set<String>) -> Set<String> {
        candidates.intersection(store.seenUuids())
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
        // Prune the seen-ledger here rather than on every store save: the drain already runs
        // exactly once per refresh/sync cycle, so this is the cheapest existing hook — O(n)
        // over the ledger a few times a day instead of on every mutation.
        store.pruneSeen(olderThan: Date(timeIntervalSinceNow: -InboxStore.seenRetention))

        let podcasts = DataManager.sharedManager.allPodcasts(includeUnsubscribed: false)
        guard !podcasts.isEmpty else { return }

        let optedOut = SessionFeederEngine.optOutPodcastUuids()
        let conditionalPodcasts = SessionFeederEngine.conditionalInboxPodcastUuids()
        let lines = store.offeredThrough

        var newLines = [String: Date]()
        var needEpisodes = [(podcast: Podcast, line: Date)]()

        // `.never` podcasts (optedOut) are skipped; `.whenNotInSessionOrUpNext` (conditional) are
        // considered here and filtered per-episode below; everything else is `.always`.
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
            var episodes = newEpisodes(for: needEpisodes)
            if !conditionalPodcasts.isEmpty {
                // "When not in Session or Up Next": a conditional podcast's arrival skips the Inbox
                // if it's already shelved in a session or sitting in the queue.
                let shelved = SessionMembership.shared.inAnySession
                    .union(PlaybackManager.shared.queue.allEpisodes(includeNowPlaying: true).map(\.uuid))
                episodes = episodes.filter { !(conditionalPodcasts.contains($0.podcastUuid) && shelved.contains($0.uuid)) }
            }
            add(episodes: episodes)
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
        //
        // Being QUEUED is deliberately not disqualifying. A podcast set to auto-add-to-Up-Next
        // delivers episodes already in the queue, and those must still come through the Inbox:
        // the Inbox is the record of everything that arrived, and Mark All as Seen is how you
        // clear it once you've watched it go past.
        let query = """
        (\(clauses.joined(separator: " OR "))) \
        AND archived = 0 AND wasDeleted = 0 AND playedUpTo = 0 AND playingStatus = \(PlayingStatus.notPlayed.rawValue) \
        ORDER BY publishedDate ASC
        """
        return DataManager.sharedManager.findEpisodesWhere(customWhere: query, arguments: arguments)
    }

    // MARK: - Manual-unseen exemptions

    /// Episodes explicitly marked unseen keep their playback state untouched, so the sweep's
    /// progress rule would otherwise remove them again immediately. This set records the
    /// exemption. It is cleared whenever the episode leaves the Inbox deliberately — every such
    /// path (explicit triage, queuing, session shelving, unsubscribe, policy clears, and the
    /// sweep's archive/delete removals) funnels through `markSeen` — so it can't bounce back.
    static let manualUnseenKey = "SJInboxManualUnseen"

    func manualUnseenUuids() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.manualUnseenKey) ?? [])
    }

    private func addManualUnseen(_ episodeUuids: [String]) {
        UserDefaults.standard.set(Array(manualUnseenUuids().union(episodeUuids)), forKey: Self.manualUnseenKey)
    }

    private func clearManualUnseen(_ episodeUuids: [String]) {
        let current = manualUnseenUuids()
        let remaining = current.subtracting(episodeUuids)
        guard remaining.count != current.count else { return }
        UserDefaults.standard.set(Array(remaining), forKey: Self.manualUnseenKey)
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
        // The seen-ledger records the decision itself, because playlist sync cannot: it is
        // last-writer-wins over the whole membership set, so a lagging device would otherwise
        // re-upload stale membership and resurrect these. Every deliberate removal funnels
        // through here — explicit triage, queuing, session shelving, unsubscribe, the policy
        // clears, and the sweep — so this one line is the ledger's single producer.
        store.recordSeen(episodeUuids: episodeUuids)
        // Leaving the Inbox deliberately also ends any manual-unseen exemption — otherwise the
        // episode would dodge the sweep's progress rule forever if it ever came back.
        clearManualUnseen(episodeUuids)
        NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged, object: playlist)
    }

    /// Mark as unseen — back into the Inbox.
    ///
    /// Playback state and the archive flag are left untouched — "unseen" is an attention mark,
    /// not a rewind. Because any playback progress normally removes an episode from the Inbox,
    /// the uuid also goes into the manual-unseen exemption set so the next sweep doesn't take it
    /// straight back out. Archiving remains decisive: it still removes the episode (and clears
    /// the exemption with it).
    func markUnseen(episodeUuids: [String]) {
        guard !episodeUuids.isEmpty else { return }
        let episodes = episodeUuids.compactMap { DataManager.sharedManager.findEpisode(uuid: $0) }
        guard !episodes.isEmpty else { return }

        // Returning to the Inbox is a decision too: the uuid leaves the seen-ledger (with a
        // synced unseen override, so another device's older seen entry can't resurrect the
        // tombstone) — otherwise the sync-import filter would fight mark-unseen forever.
        store.recordUnseen(episodeUuids: episodes.map(\.uuid))
        addManualUnseen(episodes.map(\.uuid))
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

    /// Removes anything in the Inbox that has since been decided: any playback progress (a few
    /// seconds in is still a decision), archived, or deleted.
    ///
    /// Episodes in the manual-unseen exemption set are skipped for the *progress* rule — they
    /// were put back deliberately, still carrying their progress. Archiving and deleting are
    /// explicit decisions and still remove them (which also clears the exemption, via `markSeen`).
    ///
    /// Note what is NOT here: **being queued**. Queuing clears the dot as an *event*
    /// (`episodeQueued` below), not as a *state*. The difference matters — a podcast set to
    /// auto-add-to-Up-Next delivers episodes that are already queued, and those must still come
    /// through the Inbox. If the sweep treated "is in Up Next" as decided, it would strip their
    /// dots the next time anything at all changed.
    func sweep() {
        let members = unseenUuids()

        // Exemption hygiene: incoming server deletes (`rawDeleteEpisodes` in the sync import)
        // bypass `markSeen`, so an exemption whose episode has already left the Inbox would
        // otherwise linger forever — and silently shield the episode from the progress rule
        // if it ever came back. An exemption only means anything while its episode is a
        // member, so drop the rest. (An episode markUnseen just re-added IS a member here,
        // so its fresh exemption survives.)
        let staleExemptions = manualUnseenUuids().subtracting(members)
        if !staleExemptions.isEmpty {
            clearManualUnseen(Array(staleExemptions))
        }

        let decided = DataManager.sharedManager.findEpisodesWhere(
            customWhere: """
            uuid IN (SELECT episodeUuid FROM \(DataManager.playlistEpisodeTableName) WHERE playlist_uuid = ?) \
            AND (archived = 1 OR wasDeleted = 1 OR playedUpTo > 0 OR playingStatus != \(PlayingStatus.notPlayed.rawValue))
            """,
            arguments: [DataManager.inboxPlaylistUuid]
        )

        let exempt = manualUnseenUuids()
        var removable = Set(decided.filter { $0.archived || $0.wasDeleted || !exempt.contains($0.uuid) }.map(\.uuid))

        // Members the seen-ledger says were triaged away on another device (the remote ledger
        // merged in before the playlist sync corrected membership). markUnseen episodes are
        // safe: their unseen override makes the ledger's answer "not seen".
        removable.formUnion(members.intersection(store.seenUuids()))

        guard !removable.isEmpty else { return }
        markSeen(episodeUuids: Array(removable))
    }

    /// Queuing an episode is deciding to listen to it, so the dot goes.
    ///
    /// This is an event, not a state (see `sweep`). Auto-add-to-Up-Next fires this during the
    /// refresh — *before* the drain runs — so an auto-added episode isn't in the Inbox yet, this
    /// is a no-op for it, and it still gets its dot when the drain offers it moments later.
    /// Exactly the intent: everything comes through the Inbox, however it got queued.
    ///
    /// One-directional, like every other decision here: taking an episode back out of Up Next
    /// does not make it unseen again.
    @objc private func episodeQueued(_ notification: Notification) {
        guard let episodeUuid = notification.object as? String else { return }
        guard isUnseen(episodeUuid: episodeUuid) else { return }
        markSeen(episodeUuids: [episodeUuid])
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
