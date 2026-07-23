import Foundation
import UIKit
import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils

/// Fork: where the "Add to Session" verb lands, per Settings → Inbox.
enum AddToSessionMode: String, CaseIterable {
    case allMatching
    case currentOnly
    case ask

    static var current: AddToSessionMode {
        AddToSessionMode(rawValue: UserDefaults.standard.string(forKey: "SJInboxAddToSessionMode") ?? "") ?? .allMatching
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: "SJInboxAddToSessionMode")
    }

    var title: String {
        switch self {
        case .allMatching: return L10n.inboxAddModeAll
        case .currentOnly: return L10n.inboxAddModeCurrent
        case .ask: return L10n.inboxAddModeAsk
        }
    }
}

/// Fork: where the "Remove from Session" verb takes an episode out of — every session holding it,
/// only this page's, or a prompt. The parallel of `AddToSessionMode` for the remove direction.
enum RemoveFromSessionMode: String, CaseIterable {
    case all
    case currentOnly
    case ask

    static var current: RemoveFromSessionMode {
        RemoveFromSessionMode(rawValue: UserDefaults.standard.string(forKey: "SJRemoveFromSessionMode") ?? "") ?? .all
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: "SJRemoveFromSessionMode")
    }

    var title: String {
        switch self {
        case .all: return L10n.sessionRemoveModeAll
        case .currentOnly: return L10n.sessionRemoveModeCurrent
        case .ask: return L10n.sessionRemoveModeAsk
        }
    }
}

/// Fork: session operations — creating sessions, mutating their stores (synced manual
/// playlists), triage verbs, and the decisive-action sweeps that keep stores and the
/// bookkeeping tables aligned with playback.
class SessionManager {
    static let shared = SessionManager()

    func setup() {
        NotificationCenter.default.addObserver(self, selector: #selector(refreshFolderRules), name: Constants.Notifications.folderChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshFolderRules), name: ServerNotifications.syncCompleted, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(episodeStateChanged), name: Constants.Notifications.episodeArchiveStatusChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(episodeStateChanged), name: Constants.Notifications.episodePlayStatusChanged, object: nil)
        // Bulk operations announce without a uuid — those trigger a full sweep.
        NotificationCenter.default.addObserver(self, selector: #selector(episodeStateChanged), name: Constants.Notifications.manyEpisodesChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(trackChanged), name: Constants.Notifications.playbackTrackChanged, object: nil)
        // Recency ("Recently Played") is earned by listening, not by navigating: opening a
        // session primes it silently, so the stamp waits for audio to actually start.
        NotificationCenter.default.addObserver(self, selector: #selector(sessionPlaybackStarted), name: Constants.Notifications.playbackStarted, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(prune), name: ServerNotifications.podcastsRefreshed, object: nil)
        // Fork: every podcast in a selected Session-Playlists folder keeps a session; a deleted
        // podcast loses its session.
        NotificationCenter.default.addObserver(self, selector: #selector(syncFolderScopedPodcastSessions), name: Constants.Notifications.folderChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(podcastDeleted(_:)), name: Constants.Notifications.podcastDeleted, object: nil)
        // Fork: a smart playlist that feeds a session defines that session's contents. When its
        // rules change, bring the store back in line with the new filter (see reconcile below).
        NotificationCenter.default.addObserver(self, selector: #selector(feederSmartPlaylistChanged(_:)), name: Constants.Notifications.playlistChanged, object: nil)
        // Every eager signal (star, and any future eager axis) mirrors live on its notification;
        // lazy signals (play-status) mirror on session view/play instead — see `reconcileOnView`.
        for signal in SessionFeederEngine.FeederSignal.allCases where signal.cadence == .eager {
            if let name = signal.eagerNotification {
                NotificationCenter.default.addObserver(self, selector: #selector(eagerSignalFired), name: name, object: nil)
            }
        }
        // The feeder-signal cache is only valid while the sessions and their feeders' rules hold.
        NotificationCenter.default.addObserver(self, selector: #selector(invalidateFeederVolatilityCache), name: SessionStore.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(invalidateFeederVolatilityCache), name: ServerNotifications.syncCompleted, object: nil)
        // A feeder's rules can also change via server sync (edited on another device) — the local
        // playlistChanged-with-object path never sees those, so mirror every smart-fed session
        // after each sync. Also once at startup, to heal edits missed while the app was gone.
        NotificationCenter.default.addObserver(self, selector: #selector(smartFeederRulesMayHaveChanged), name: ServerNotifications.syncCompleted, object: nil)
        smartFeederRulesMayHaveChanged()
        syncFolderScopedPodcastSessions()
    }

    private let eagerReconcileDebounce = Debounce(delay: 1.5)

    /// The signals every smart-playlist-fed session's feeder is sensitive to, keyed by session uuid
    /// — cached so each reconcile trigger can decide in O(1) whether any feeder even cares, instead
    /// of re-querying feeders. Dropped when the set of sessions or a feeder's rules change (see the
    /// observers in `setup` and the invalidate at the head of `feederSmartPlaylistChanged`).
    private var cachedFeederSignals: [String: Set<SessionFeederEngine.FeederSignal>]?

    @objc private func invalidateFeederVolatilityCache() {
        cachedFeederSignals = nil
    }

    private func feederSignalsBySession() -> [String: Set<SessionFeederEngine.FeederSignal>] {
        if let cached = cachedFeederSignals { return cached }
        var map = [String: Set<SessionFeederEngine.FeederSignal>]()
        for session in SessionStore.shared.sessions {
            guard case .smartPlaylist(let uuid) = session.feeder,
                  let feeder = DataManager.sharedManager.findPlaylist(uuid: uuid) else { continue }
            map[session.uuid] = SessionFeederEngine.signals(of: feeder)
        }
        cachedFeederSignals = map
        return map
    }

    /// Fired by any eager signal's notification (star, and any future eager axis). Mirrors every
    /// feeder sensitive to an eager signal — but only if one exists, so an event no feeder cares
    /// about is O(1) with no DB work and no debounce scheduled.
    @objc private func eagerSignalFired() {
        let signals = feederSignalsBySession()
        guard signals.values.contains(where: { $0.contains { $0.cadence == .eager } }) else { return }
        eagerReconcileDebounce.call { [weak self] in
            DispatchQueue.main.async { self?.reconcileEagerFeeders() }
        }
    }

    private func reconcileEagerFeeders() {
        guard !isReconcilingFeeder else { return }
        let signals = feederSignalsBySession()
        let targets = SessionStore.shared.sessions.filter { (signals[$0.uuid] ?? []).contains { $0.cadence == .eager } }
        guard !targets.isEmpty else { return }
        isReconcilingFeeder = true
        defer { isReconcilingFeeder = false }
        targets.forEach { reconcileStoreToFeeder(session: $0) }
    }

    private let syncReconcileDebounce = Debounce(delay: 2)

    /// Debounced full mirror of every smart-fed session — the sync-driven counterpart of
    /// `feederSmartPlaylistChanged`, which only covers local edits (they post `playlistChanged`
    /// with the playlist object; synced-in edits don't).
    @objc private func smartFeederRulesMayHaveChanged() {
        syncReconcileDebounce.call { [weak self] in
            DispatchQueue.main.async { self?.reconcileAllSmartFeeders() }
        }
    }

    private func reconcileAllSmartFeeders() {
        guard !isReconcilingFeeder else { return }
        let targets = SessionStore.shared.sessions.filter {
            if case .smartPlaylist = $0.feeder { return true }
            return false
        }
        guard !targets.isEmpty else { return }
        isReconcilingFeeder = true
        defer { isReconcilingFeeder = false }
        targets.forEach { reconcileStoreToFeeder(session: $0) }
    }

    /// Lazy mirror: called when a session is opened or played, so lazy-cadence feeders (play-status)
    /// reshape at a natural moment instead of churning live. O(1) short-circuit (cached) unless this
    /// session's feeder actually has a lazy signal.
    func reconcileOnView(session: Session) {
        let signals = feederSignalsBySession()[session.uuid] ?? []
        guard signals.contains(where: { $0.cadence == .lazy }), !isReconcilingFeeder else { return }
        isReconcilingFeeder = true
        defer { isReconcilingFeeder = false }
        reconcileStoreToFeeder(session: session)
    }

    /// Guards `reconcileStoreToFeeder` from re-entering when its own store edits post
    /// `playlistChanged`.
    private var isReconcilingFeeder = false

    @objc private func feederSmartPlaylistChanged(_ notification: Notification) {
        guard !isReconcilingFeeder,
              let playlist = notification.object as? EpisodeFilter,
              let session = SessionStore.shared.session(forSmartPlaylistFeeder: playlist.uuid) else { return }
        // The feeder's rules just changed — its signal set may have too.
        invalidateFeederVolatilityCache()
        isReconcilingFeeder = true
        defer { isReconcilingFeeder = false }
        reconcileStoreToFeeder(session: session)
    }

    /// Fork: keep the session's store honest against its smart-playlist feeder — drop members
    /// the filter no longer matches, and pull in covered episodes that are already SHELVED in
    /// some session. Never the whole filter result: lineups are curated, so a smart-fed session
    /// gathers the curated episodes its rules cover, it does not mirror the query. (The full-
    /// domain add turned "create/edit a smart playlist" into "dump every matching episode into
    /// the lineup".)
    ///
    /// Manual fill mode (`autoFill == false`) goes one step further: the shelved-gather half is
    /// skipped entirely, so the session is hand-curated — the feeder still prunes members its
    /// filter no longer matches, but episodes join ONLY via explicit user adds.
    ///
    /// The prune only prunes what it gathered — never what the user added: pinned members
    /// (explicit user adds, `Session.pinnedEpisodeUuids`) survive even when the filter no
    /// longer matches them.
    func reconcileStoreToFeeder(session: Session) {
        // Only smart-playlist feeders mirror their filter. A podcast/folder feeder's "domain" is
        // the whole podcast/folder, which must never be dumped wholesale into a curated lineup.
        guard case .smartPlaylist = session.feeder, store(for: session) != nil else { return }
        // A playlist that has opted out of being a session playlist is left exactly as it was —
        // no prune, no gather. Its lineup is preserved so opting back in restores it intact.
        // Guarding here covers every reconcile entry point (eager, lazy, sync-driven, folder rules).
        guard !SessionManager.isOptedOut(feeder: session.feeder) else { return }
        let domain = SessionFeederEngine.domainEpisodes(for: session).map(\.uuid)
        let domainSet = Set(domain)
        let current = SessionFeederEngine.storeMemberUuids(for: session)
        let currentSet = Set(current)
        let shelved = SessionFeederEngine.allStoreMemberUuids()

        // Hygiene: pins must never outlive membership — drop stale pin entries for episodes
        // no longer in the lineup (e.g. removed via a surface that bypasses the primitives).
        let stalePins = session.pinnedEpisodeUuids.filter { !currentSet.contains($0) }
        if !stalePins.isEmpty {
            SessionStore.shared.unpin(episodeUuids: stalePins, for: session.uuid)
        }
        let pinned = Set(session.pinnedEpisodeUuids).intersection(currentSet)

        let toRemove = current.filter { !domainSet.contains($0) && !pinned.contains($0) }
        let toAdd = domain.filter { !currentSet.contains($0) && shelved.contains($0) }

        if !toRemove.isEmpty {
            removeFromLineup(episodeUuids: toRemove, session: session)
        }
        // Manual fill: prune-only. Gathering shelved episodes here would grow a
        // hand-curated lineup behind the user's back.
        if session.autoFill, !toAdd.isEmpty {
            addToLineup(episodeUuids: toAdd, session: session)
        }
    }

    /// Fork: for each podcast folder ticked in Session Playlists, ensure every podcast in it has an
    /// (empty, auto-add-off) session, filed into a playlist folder with the same name. Idempotent.
    @objc func syncFolderScopedPodcastSessions() {
        let selectedFolders = Settings.showPodcastSessionFolders()
        let selectedPodcasts = Settings.showPodcastSessionPodcasts()
        guard !selectedFolders.isEmpty || !selectedPodcasts.isEmpty else { return }
        let podcasts = DataManager.sharedManager.allPodcasts(includeUnsubscribed: false)
        var filed = false

        for podcast in podcasts {
            let inSelectedFolder = podcast.folderUuid.map(selectedFolders.contains) ?? false
            guard inSelectedFolder || selectedPodcasts.contains(podcast.uuid) else { continue }
            // empty, auto-add off by default; folder-covered ones are filed into the mirroring
            // Playlists folder (individually-selected podcasts with no selected folder stay ungrouped).
            let session = SessionStore.shared.session(forPodcast: podcast.uuid)
                ?? createSession(name: podcast.title ?? L10n.filtersDefaultNewFilter, feeder: .podcast(uuid: podcast.uuid))
            if let storeUuid = session.storePlaylistUuid, fileFolderScopedPodcastSession(podcast: podcast, storeUuid: storeUuid) {
                filed = true
            }
        }

        if filed {
            NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged)
        }
    }

    /// Files a per-podcast session's store into the Playlists folder that mirrors the podcast's own
    /// library folder, when that folder is a selected Session-Playlists folder — so the session lives
    /// inside e.g. "Series" (where the podcast lives in the Podcasts tab) instead of sitting at the
    /// Playlists top level looking like a stray. No-op (false) when the podcast has no selected folder
    /// or the store is already filed there; returns true when it actually moved the store.
    @discardableResult
    func fileFolderScopedPodcastSession(podcast: Podcast, storeUuid: String) -> Bool {
        guard let podcastFolderUuid = podcast.folderUuid,
              Settings.showPodcastSessionFolders().contains(podcastFolderUuid),
              let podcastFolder = DataManager.sharedManager.findFolder(uuid: podcastFolderUuid) else { return false }
        let playlistFolder = PlaylistFolderManager.shared.allFolders().first { $0.name == podcastFolder.name }
            ?? PlaylistFolderManager.shared.createFolder(name: podcastFolder.name, color: podcastFolder.color, playlistUuids: [])
        guard PlaylistFolderManager.shared.folderUuid(forPlaylist: storeUuid) != playlistFolder.uuid else { return false }
        PlaylistFolderManager.shared.setFolder(playlistFolder.uuid, forPlaylist: storeUuid)
        return true
    }

    @objc private func podcastDeleted(_ notification: Notification) {
        guard let podcastUuid = notification.object as? String,
              let session = SessionStore.shared.session(forPodcast: podcastUuid) else { return }
        if let storeUuid = session.storePlaylistUuid {
            PlaylistFolderManager.shared.setFolder(nil, forPlaylist: storeUuid)
        }
        deleteSession(session)
    }

    // MARK: - Creation

    /// A new session wrapping a fresh manual store. The store is a real synced playlist.
    @discardableResult
    func createSession(name: String, feeder: SessionFeeder, seedEpisodeUuids: [String] = []) -> Session {
        let store = PlaylistManager.createNewPlaylist()
        store.playlistName = name
        store.manual = true
        store.sortType = PlaylistSort.dragAndDrop.rawValue
        store.isNew = false
        store.syncStatus = SyncStatus.notSynced.rawValue
        DataManager.sharedManager.save(playlist: store)

        if !seedEpisodeUuids.isEmpty {
            unarchiveIfNeeded(episodeUuids: seedEpisodeUuids)
            unplayIfNeeded(episodeUuids: seedEpisodeUuids)
            let episodes = seedEpisodeUuids.compactMap { DataManager.sharedManager.findEpisode(uuid: $0) }
            _ = DataManager.sharedManager.add(episodes: episodes, to: store)
        }

        var session = Session(uuid: UUID().uuidString, storePlaylistUuid: store.uuid, feeder: feeder)
        // New sessions start from the model default; each session's Position is edited on
        // its own surfaces (the playlist's ⋯ menu, or podcast settings for podcast sessions).
        session.insertMode = PlaylistInsertMode.top.rawValue
        SessionStore.shared.upsert(session)
        NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged)
        return session
    }

    /// The session for a podcast, created on first use (feeder = the podcast itself).
    func findOrCreateSession(forPodcast podcast: Podcast, seedEpisodeUuids: [String] = []) -> Session {
        let session = SessionStore.shared.session(forPodcast: podcast.uuid)
            ?? createSession(name: podcast.title ?? L10n.filtersDefaultNewFilter, feeder: .podcast(uuid: podcast.uuid), seedEpisodeUuids: seedEpisodeUuids)
        // Mirror the podcast's folder immediately (even for sessions first created by playback or an
        // "Add to Session"), so a folder-covered session never surfaces stray at the Playlists top level.
        if let storeUuid = session.storePlaylistUuid, fileFolderScopedPodcastSession(podcast: podcast, storeUuid: storeUuid) {
            NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged)
        }
        return session
    }

    /// Deletes the session, its store playlist, and (for rule sessions) its feeder playlist.
    func deleteSession(_ session: Session) {
        if let storeUuid = session.storePlaylistUuid, let store = DataManager.sharedManager.findPlaylist(uuid: storeUuid) {
            PlaylistManager.delete(playlist: store, fireEvent: false)
        }
        // Only hidden "— feed" machinery dies with its session — a real lens acting
        // as feeder is the user's own smart playlist and must survive.
        if case .smartPlaylist(let feederUuid) = session.feeder,
           SessionStore.shared.feederPlaylistUuids.contains(feederUuid),
           let feederPlaylist = DataManager.sharedManager.findPlaylist(uuid: feederUuid) {
            PlaylistManager.delete(playlist: feederPlaylist, fireEvent: false)
        }
        SessionStore.shared.delete(sessionUuid: session.uuid)
        NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged)
    }

    /// Converts a lens (pure smart playlist) into a Session: the lens flips into the
    /// store — keeping its name, uuid and spot — seeded with the current query order,
    /// while a fresh hidden feeder playlist carries the rules onward.
    @discardableResult
    func convertLens(_ lens: EpisodeFilter, seedEpisodeUuids: [String]) -> Session {
        let feeder = EpisodeFilter.makeDefault()
        feeder.copySessionRules(from: lens)
        feeder.playlistName = "\(lens.playlistName) — feed"
        feeder.sortType = PlaylistSort.newestToOldest.rawValue
        feeder.sortPosition = 32000
        feeder.syncStatus = SyncStatus.notSynced.rawValue
        DataManager.sharedManager.save(playlist: feeder)

        lens.manual = true
        lens.sortType = PlaylistSort.dragAndDrop.rawValue
        lens.syncStatus = SyncStatus.notSynced.rawValue
        DataManager.sharedManager.save(playlist: lens)

        let episodes = seedEpisodeUuids.compactMap { DataManager.sharedManager.findEpisode(uuid: $0) }
        _ = DataManager.sharedManager.add(episodes: episodes, to: lens)

        let session = Session(uuid: UUID().uuidString, storePlaylistUuid: lens.uuid, feeder: .smartPlaylist(uuid: feeder.uuid))
        SessionStore.shared.upsert(session)
        NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged)
        return session
    }

    /// The playlist whose rules the sparkle edits: the session's feeder, or the
    /// playlist itself for lenses.
    func rulesPlaylist(for playlist: EpisodeFilter) -> EpisodeFilter? {
        guard let session = SessionStore.shared.session(forStore: playlist.uuid) else {
            return playlist.manual ? nil : playlist
        }
        if case .smartPlaylist(let feederUuid) = session.feeder {
            return DataManager.sharedManager.findPlaylist(uuid: feederUuid)
        }
        return nil
    }

    // MARK: - Store access

    func store(for session: Session) -> EpisodeFilter? {
        guard let uuid = session.storePlaylistUuid else { return nil }
        return DataManager.sharedManager.findPlaylist(uuid: uuid)
    }

    // MARK: - Lineup mutations (all mark the store for sync)

    /// Unarchives any archived episodes among the given uuids, posting one archive
    /// notification at the end instead of one per episode.
    private func unarchiveIfNeeded(episodeUuids: [String]) {
        let archived = episodeUuids
            .compactMap { DataManager.sharedManager.findEpisode(uuid: $0) }
            .filter { $0.archived }
        guard !archived.isEmpty else { return }
        for episode in archived {
            EpisodeManager.unarchiveEpisode(episode: episode, fireNotification: false)
        }
        NotificationCenter.postOnMainThread(notification: Constants.Notifications.episodeArchiveStatusChanged)
    }

    /// Marks any already-played episodes among the given uuids as unplayed, posting one play-status
    /// notification at the end. Adding to a session is intent to play it again — same as Up Next,
    /// which already unplays on add — so a finished episode shouldn't land in the lineup done.
    private func unplayIfNeeded(episodeUuids: [String]) {
        let played = episodeUuids
            .compactMap { DataManager.sharedManager.findEpisode(uuid: $0) }
            .filter { $0.played() }
        guard !played.isEmpty else { return }
        for episode in played {
            EpisodeManager.markAsUnplayed(episode: episode, fireNotification: false, userInitiated: false)
        }
        NotificationCenter.postOnMainThread(notification: Constants.Notifications.episodePlayStatusChanged)
    }

    /// Inserts episodes at the session's insert marker. Adding means intent to play,
    /// so archived episodes come back out of the archive on the way in (otherwise the
    /// decisive-action sweep would immediately remove them from the store again).
    ///
    /// `pinning` marks this as an explicit USER add: the episodes are pinned in this
    /// session, so the feeder's prune (`reconcileStoreToFeeder`) never removes them.
    /// Automatic paths (feeder gathers, backfills, auto-add ingest, queue mirrors,
    /// seeding) leave it false — what was gathered stays prunable.
    func addToLineup(episodeUuids: [String], session: Session, pinning: Bool = false) {
        guard let store = store(for: session), !episodeUuids.isEmpty else { return }
        unarchiveIfNeeded(episodeUuids: episodeUuids)
        unplayIfNeeded(episodeUuids: episodeUuids)

        // One atomic transaction (read current order → insert at the session's marker → rewrite →
        // denormalize title/podcast → mark for sync), replacing the former read + add() + setCustomOrder
        // trio whose separate statements left a lost-update window for a concurrent reconcile/add.
        let insertMode = PlaylistInsertMode(rawValue: session.insertMode) ?? .top
        DataManager.sharedManager.insertSessionMembers(episodeUuids: episodeUuids, insertMode: insertMode, anchorUuid: session.lastInsertedUuid, for: store)
        markStoreChanged(store)

        // Deciding to play something is deciding about it: it leaves the Inbox.
        //
        // This is a PRIMITIVE call, not a verb — nothing mirrors from an Inbox removal, so
        // the Up Next <-> Session mirroring stays a two-party relationship with the Inbox as
        // a leaf. Calling a verb here is what would make recursion possible.
        InboxManager.shared.markSeen(episodeUuids: episodeUuids)

        // One transaction, re-reading the live row: sets lastInserted and (optionally) the pins
        // together — no stale-copy clobber, and one save + cloud diff instead of upsert-then-pin.
        SessionStore.shared.mutateSession(session) { updated in
            if let last = episodeUuids.last { updated.lastInsertedUuid = last }
            if pinning {
                updated.pinnedEpisodeUuids.append(contentsOf: episodeUuids.filter { !updated.pinnedEpisodeUuids.contains($0) })
            }
        }
    }

    /// Replaces the lineup wholesale: the store becomes exactly these episodes, in
    /// this order. Former members return to triage (no dismissals are recorded —
    /// replacement isn't a per-episode "no"). Former members are unpinned; `pinning`
    /// pins the new lineup (an explicit USER choice, e.g. "Make This the Session").
    func replaceLineup(episodeUuids: [String], session: Session, pinning: Bool = false) {
        guard let store = store(for: session), !episodeUuids.isEmpty else { return }
        let current = DataManager.sharedManager.positionedEpisodeUuids(for: store).filter { !episodeUuids.contains($0) }
        if !current.isEmpty {
            DataManager.sharedManager.deleteEpisodes(current, from: store)
        }
        unarchiveIfNeeded(episodeUuids: episodeUuids)
        unplayIfNeeded(episodeUuids: episodeUuids)
        let episodes = episodeUuids.compactMap { DataManager.sharedManager.findEpisode(uuid: $0) }
        _ = DataManager.sharedManager.add(episodes: episodes, to: store)
        DataManager.sharedManager.setCustomOrder(episodeUuids: episodeUuids, for: store)
        markStoreChanged(store)
        InboxManager.shared.markSeen(episodeUuids: episodeUuids)

        // One transaction, re-reading the live row: set lastInserted, drop pins on replaced-away
        // members (membership is now exactly `episodeUuids`), and pin the new lineup if asked.
        SessionStore.shared.mutateSession(session) { updated in
            updated.lastInsertedUuid = episodeUuids.last ?? ""
            if !current.isEmpty {
                updated.pinnedEpisodeUuids.removeAll { current.contains($0) }
            }
            if pinning {
                updated.pinnedEpisodeUuids.append(contentsOf: episodeUuids.filter { !updated.pinnedEpisodeUuids.contains($0) })
            }
        }
    }

    /// Persists a full lineup order (after drag reorder).
    func setLineupOrder(episodeUuids: [String], session: Session) {
        guard let store = store(for: session) else { return }
        DataManager.sharedManager.setCustomOrder(episodeUuids: episodeUuids, for: store)
        markStoreChanged(store)
    }

    /// Removes from the lineup.
    ///
    /// This deliberately does NOT make the episode unseen again. You saw it and you decided
    /// about it; taking it back out of a lineup is not un-deciding. (Dismissals are gone — with
    /// membership as the only state, a removal leaves no record to recover from.)
    ///
    /// If the episode being removed is the one currently playing, playback advances off it —
    /// otherwise deleting the store row does nothing visible and the episode keeps playing, which
    /// reads as "remove didn't work". Every remove path funnels through here, so fixing it once
    /// covers the Up Next card, the Session tabs, and multi-select alike.
    func removeFromLineup(episodeUuids: [String], session: Session) {
        guard let store = store(for: session) else { return }
        DataManager.sharedManager.deleteEpisodes(episodeUuids, from: store) // already marks the playlist dirty
        // Pins never outlive membership: leaving the lineup unpins, so a later
        // re-gather behaves normally.
        SessionStore.shared.unpin(episodeUuids: episodeUuids, for: session.uuid)
        NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged, object: store)

        if let playing = PlaybackManager.shared.currentEpisode(), episodeUuids.contains(playing.uuid) {
            PlaybackManager.shared.removeIfPlayingOrQueued(episode: playing, fireNotification: true, userInitiated: true)
        }
    }

    // MARK: - Fork: direct-add pin bookkeeping

    /// Pin bookkeeping for the upstream "Add to Playlist" flows (the playlist chooser and
    /// the playlist detail "Add Episodes" search), which write to manual playlists directly
    /// through DataManager — deliberately keeping the stock add's positioning semantics
    /// rather than routing through `addToLineup`. When the target playlist backs a session,
    /// though, that hand-add is still an explicit USER add: without a pin, a smart feeder's
    /// prune (`reconcileStoreToFeeder`) would sweep the episode back out as soon as it falls
    /// outside (or later leaves) the feeder's rules.
    ///
    /// Call ONLY from user-driven add UI. Automatic paths (sync applying remote playlist
    /// changes, Inbox ingest, feeder gathers/backfills) never call this, so what they add
    /// stays prunable. The global Inbox can never pin: its playlist uuid is guarded outright,
    /// and the Inbox session's `storePlaylistUuid` is nil so the store lookup can't match it.
    func pinDirectAdd(episodeUuids: [String], storePlaylistUuid: String) {
        guard !episodeUuids.isEmpty,
              storePlaylistUuid != DataManager.inboxPlaylistUuid,
              let session = SessionStore.shared.session(forStore: storePlaylistUuid),
              session.uuid != SessionStore.globalInboxUuid else { return }
        SessionStore.shared.pin(episodeUuids: episodeUuids, for: session.uuid)
        // The direct-add sites mark the playlist dirty and save it themselves, but they
        // don't post playlistChanged the way `markStoreChanged` does — post it here so
        // session UI refreshes. No double-post: those sites post nothing on this path.
        if let store = DataManager.sharedManager.findPlaylist(uuid: storePlaylistUuid) {
            NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged, object: store)
        }
    }

    /// The symmetric half: unchecking a playlist in the chooser removes membership directly
    /// (bypassing `removeFromLineup`), and pins must never outlive membership.
    func unpinDirectRemove(episodeUuids: [String], storePlaylistUuid: String) {
        guard !episodeUuids.isEmpty,
              storePlaylistUuid != DataManager.inboxPlaylistUuid,
              let session = SessionStore.shared.session(forStore: storePlaylistUuid),
              session.uuid != SessionStore.globalInboxUuid else { return }
        SessionStore.shared.unpin(episodeUuids: episodeUuids, for: session.uuid)
        if let store = DataManager.sharedManager.findPlaylist(uuid: storePlaylistUuid) {
            NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged, object: store)
        }
    }

    /// Removes each episode from every session whose store currently holds it — the inverse of the
    /// "Add to Session" swipe when the episode is already in a session.
    func removeFromAllSessions(episodeUuids: [String]) {
        for uuid in episodeUuids {
            let holding = Set(DataManager.sharedManager.manualPlaylistUUIDs(for: uuid))
            guard !holding.isEmpty else { continue }
            for session in SessionStore.shared.sessions where session.storePlaylistUuid.map(holding.contains) == true {
                removeFromLineup(episodeUuids: [uuid], session: session)
            }
        }
    }

    /// Whether any session's store currently holds this episode.
    func isInAnySession(episodeUuid: String) -> Bool {
        let holding = Set(DataManager.sharedManager.manualPlaylistUUIDs(for: episodeUuid))
        guard !holding.isEmpty else { return false }
        return SessionStore.shared.sessions.contains { $0.storePlaylistUuid.map(holding.contains) == true }
    }

    /// Fork: one-time reconcile — every session gains the in-session episodes its feeder covers that
    /// it doesn't already hold. Propagates existing membership across overlapping feeders (a podcast
    /// in Comedy + Favorites lands in both sessions) and fills all-podcasts sessions when the setting
    /// allows. Loosely maintained: forward "add to all matching" keeps it current going forward, this
    /// catches up the episodes added before the invariant held.
    @discardableResult
    func backfillSessions() -> Int {
        let inSessionUuids = SessionMembership.shared.inAnySession
        let episodes = inSessionUuids.compactMap { DataManager.sharedManager.findEpisode(uuid: $0) }
        FileLog.shared.addMessage("Backfill: \(SessionStore.shared.sessions.count) sessions, \(episodes.count)/\(inSessionUuids.count) in-session episodes resolved")
        guard !episodes.isEmpty else { return 0 }

        // Ensure a session exists for any feeder source that would actually receive episodes —
        // created here, on the explicit Backfill (empty-overlap sources get nothing).
        // Smart playlists:
        for playlist in DataManager.sharedManager.allSmartPlaylists(includeDeleted: false)
        where SessionStore.shared.session(forSmartPlaylistFeeder: playlist.uuid) == nil {
            if episodes.contains(where: { feeder(.smartPlaylist(uuid: playlist.uuid), coversEpisode: $0) }) {
                _ = findOrCreateSession(forSmartPlaylist: playlist)
            }
        }
        // Folders no longer get their own session — folder sessions are retired.
        // Per podcast: every podcast that has an in-session episode gets its own session.
        for podcastUuid in Set(episodes.map(\.podcastUuid))
        where SessionStore.shared.session(forPodcast: podcastUuid) == nil {
            if let podcast = DataManager.sharedManager.findPodcast(uuid: podcastUuid) {
                _ = findOrCreateSession(forPodcast: podcast)
            }
        }

        var added = 0
        for session in SessionStore.shared.sessions where session.uuid != SessionStore.globalInboxUuid {
            // Manual-fill sessions are hand-curated: the global sweep must not pour covered
            // episodes into them. (The per-playlist Backfill row remains the explicit way in.)
            guard session.autoFill else { continue }
            // Opted-out playlists are left alone by the sweep — their lineup is frozen, not filled.
            guard !SessionManager.isOptedOut(feeder: session.feeder) else { continue }
            guard let store = store(for: session) else {
                FileLog.shared.addMessage("Backfill: session \(session.uuid) has no store — skipped")
                continue
            }
            let existing = Set(SessionFeederEngine.storeMemberUuids(for: session))
            let missing = episodes.filter { !existing.contains($0.uuid) && feeder(session.feeder, coversEpisode: $0) }
            FileLog.shared.addMessage("Backfill: '\(store.playlistName)' feeder=\(session.feeder) existing=\(existing.count) missing=\(missing.count)")
            guard !missing.isEmpty else { continue }
            // Bulk catch-up counts as gathered, NOT pinned — the feeder may prune these later.
            _ = DataManager.sharedManager.add(episodes: missing, to: store)
            markStoreChanged(store)
            added += missing.count
        }
        return added
    }

    /// Fork: per-playlist Backfill (the playlist options row) — the smart playlist's session
    /// (created on demand) gains every in-session episode its feeder covers that it doesn't
    /// already hold. The single-session counterpart of `backfillSessions()`.
    /// Deliberately ignores `autoFill`: this row IS an explicit user add — the escape hatch
    /// into a Manual session.
    @discardableResult
    func backfillSession(forSmartPlaylist playlist: EpisodeFilter) -> Int {
        let inSessionUuids = SessionMembership.shared.inAnySession
        let episodes = inSessionUuids.compactMap { DataManager.sharedManager.findEpisode(uuid: $0) }
        guard !episodes.isEmpty else { return 0 }

        guard let session = findOrCreateSession(forSmartPlaylist: playlist), let store = store(for: session) else {
            FileLog.shared.addMessage("Backfill: session for playlist \(playlist.uuid) has no store — skipped")
            return 0
        }
        let existing = Set(SessionFeederEngine.storeMemberUuids(for: session))
        let missing = episodes.filter { !existing.contains($0.uuid) && feeder(session.feeder, coversEpisode: $0) }
        FileLog.shared.addMessage("Backfill: '\(store.playlistName)' existing=\(existing.count) missing=\(missing.count)")
        guard !missing.isEmpty else { return 0 }
        // Bulk catch-up counts as gathered, NOT pinned — the feeder may prune these later.
        _ = DataManager.sharedManager.add(episodes: missing, to: store)
        markStoreChanged(store)
        return missing.count
    }

    /// Every non-inbox session whose store currently holds any of these episodes.
    func sessionsHolding(episodeUuids: [String]) -> [Session] {
        let holders = Set(episodeUuids.flatMap { DataManager.sharedManager.manualPlaylistUUIDs(for: $0) })
        guard !holders.isEmpty else { return [] }
        return SessionStore.shared.sessions.filter {
            $0.uuid != SessionStore.globalInboxUuid
                && !Self.isOptedOut(feeder: $0.feeder) // a frozen "not a session playlist" never lists
                && ($0.storePlaylistUuid.map(holders.contains) ?? false)
        }
    }

    /// Fork: the "Remove from Session" verb, honoring `RemoveFromSessionMode`. `preferred` is the
    /// page's own session (nil on generic lists). Only removes the episodes a given session holds.
    func removeFromSessions(episodeUuids: [String], preferred: Session?, presenting: UIViewController?, onRemoved: (() -> Void)? = nil) {
        guard !episodeUuids.isEmpty else { return }
        let holding = sessionsHolding(episodeUuids: episodeUuids)
        guard !holding.isEmpty else { onRemoved?(); return }

        // Batched: delete from every target store, THEN one membership invalidation + one
        // notification. Removing from K sessions used to post K playlistChanged (K full reloads);
        // now it's one — the slow swipe.
        let doRemove: ([Session]) -> Void = { [weak self] sessions in
            guard let self else { return }
            var removedPlaying = false
            for session in sessions {
                guard let store = self.store(for: session) else { continue }
                let members = Set(SessionFeederEngine.storeMemberUuids(for: session))
                let toRemove = episodeUuids.filter { members.contains($0) }
                guard !toRemove.isEmpty else { continue }
                DataManager.sharedManager.deleteEpisodes(toRemove, from: store) // marks the store dirty
                SessionStore.shared.unpin(episodeUuids: toRemove, for: session.uuid) // pins never outlive membership
                if let playing = PlaybackManager.shared.currentEpisode(), toRemove.contains(playing.uuid) { removedPlaying = true }
            }
            SessionMembership.shared.invalidate()
            if removedPlaying, let playing = PlaybackManager.shared.currentEpisode() {
                PlaybackManager.shared.removeIfPlayingOrQueued(episode: playing, fireNotification: true, userInitiated: true)
            }
            NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged)
            onRemoved?()
        }

        switch RemoveFromSessionMode.current {
        case .all:
            doRemove(holding)
        case .currentOnly:
            if let preferred, holding.contains(where: { $0.uuid == preferred.uuid }) {
                doRemove([preferred])
            } else if holding.count == 1 {
                doRemove(holding)
            } else {
                // No clear "current" session and it's in several — ask rather than guess.
                presentRemovePicker(holding: holding, presenting: presenting, doRemove: doRemove)
            }
        case .ask:
            if holding.count == 1 {
                doRemove(holding)
            } else {
                presentRemovePicker(holding: holding, presenting: presenting, doRemove: doRemove)
            }
        }
    }

    private func presentRemovePicker(holding: [Session], presenting: UIViewController?, doRemove: @escaping ([Session]) -> Void) {
        guard let presenting else { doRemove(holding); return }
        DispatchQueue.main.async {
            let picker = OptionsPicker(title: L10n.sessionRemoveFrom.localizedUppercase)
            picker.addAction(action: OptionAction(label: L10n.inboxAddAllSessions, icon: nil) {
                doRemove(holding)
            })
            for session in holding {
                let name = self.store(for: session)?.playlistName ?? ""
                picker.addAction(action: OptionAction(label: name, icon: nil) {
                    doRemove([session])
                })
            }
            picker.present(from: presenting)
        }
    }

    /// Fork: the "Add to Session" verb. Where episodes land is governed by the
    /// Settings → Inbox mode: every session whose feeder covers them (plus the
    /// current page's session), only the current one, or a picker. The chosen or
    /// current session receives everything; other matching sessions receive only
    /// the episodes their feeder actually covers.
    func addToSessions(episodeUuids: [String], preferred: Session?, presenting: UIViewController?, onAdded: (([Session]) -> Void)? = nil) {
        guard !episodeUuids.isEmpty else { return }
        let episodes = episodeUuids.compactMap { DataManager.sharedManager.findEpisode(uuid: $0) }

        // Existing sessions whose feeder covers any of the episodes, current page first.
        var covering = SessionStore.shared.sessions.filter { session in
            session.uuid != SessionStore.globalInboxUuid && session.storePlaylistUuid != nil
                && episodes.contains { self.feeder(session.feeder, coversEpisode: $0) }
        }
        if let preferred {
            covering.removeAll { $0.uuid == preferred.uuid }
            covering.insert(preferred, at: 0)
        }

        // Manual-fill sessions never receive from broad fan-outs ("all matching" and its
        // fallbacks) — being covered by the feeder is not consent to be filled. The page's
        // own session is an explicit target, so a Manual `preferred` still receives; the Ask
        // picker below keeps enumerating the full `covering` list, so a Manual session can
        // always be chosen by name.
        let fanOutTargets = covering.filter { $0.autoFill || $0.uuid == preferred?.uuid }

        // The episodes' own podcasts always match — their sessions spring into being
        // on demand, so adding works even for a podcast that never had one.
        let podcastsWithoutSessions: [Podcast] = {
            var seen = Set<String>()
            return episodes.compactMap { episode in
                guard !seen.contains(episode.podcastUuid) else { return nil }
                seen.insert(episode.podcastUuid)
                guard SessionStore.shared.session(forPodcast: episode.podcastUuid) == nil else { return nil }
                return DataManager.sharedManager.findPodcast(uuid: episode.podcastUuid, includeUnsubscribed: true)
            }
        }()

        func withPodcastSessions(_ sessions: [Session]) -> [Session] {
            sessions + podcastsWithoutSessions.map { findOrCreateSession(forPodcast: $0) }
        }

        func add(to targets: [Session]) {
            // Store mutations are DB-heavy for long selections — off the main thread,
            // with the completion back on it.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                var landed = [Session]()
                for session in targets {
                    let uuids = (session.uuid == preferred?.uuid || targets.count == 1)
                        ? episodeUuids
                        : episodes.filter { self.feeder(session.feeder, coversEpisode: $0) }.map(\.uuid)
                    guard !uuids.isEmpty else { continue }
                    // Every route through addToSessions is a USER verb (swipes, multi-select,
                    // episode card, Ask picker) — pin-everywhere: the episode is pinned in
                    // every session the verb lands it in.
                    self.addToLineup(episodeUuids: uuids, session: session, pinning: true)
                    landed.append(session)
                }
                // Linked adds: one mirrored hop into the queue when enabled.
                if !landed.isEmpty {
                    SessionLinking.mirrorSessionAdd(episodeUuids: episodeUuids)
                }
                DispatchQueue.main.async {
                    onAdded?(landed)
                }
            }
        }

        switch AddToSessionMode.current {
        case .currentOnly:
            // The `fanOutTargets.first` fallback (no page session) is a guess, not a choice —
            // it must not guess a Manual session. A Manual `preferred` is in `fanOutTargets`.
            add(to: [preferred ?? fanOutTargets.first ?? withPodcastSessions([]).first].compactMap { $0 })
        case .allMatching:
            add(to: withPodcastSessions(fanOutTargets))
        case .ask:
            let rowCount = covering.count + podcastsWithoutSessions.count
            guard rowCount > 1, let presenting else {
                add(to: withPodcastSessions(fanOutTargets))
                return
            }
            let picker = OptionsPicker(title: L10n.playlistAddToLineup.localizedUppercase)
            picker.addAction(action: OptionAction(label: L10n.inboxAddAllSessions, icon: nil) { [weak self] in
                guard self != nil else { return }
                add(to: withPodcastSessions(fanOutTargets))
            })
            for session in covering {
                let name = store(for: session)?.playlistName ?? L10n.playbackSessionTabSession
                picker.addAction(action: OptionAction(label: name, icon: nil) {
                    add(to: [session])
                })
            }
            // Podcasts without sessions appear by name; picking one creates it.
            for podcast in podcastsWithoutSessions {
                picker.addAction(action: OptionAction(label: podcast.title ?? L10n.playbackSessionTabSession, icon: nil) { [weak self] in
                    guard let self else { return }
                    add(to: [self.findOrCreateSession(forPodcast: podcast)])
                })
            }
            picker.present(from: presenting)
        }
    }

    /// Fork: tap-to-play from a Session tab, Up Next style — switches the active
    /// playback session to this one when needed, then plays the tapped episode.
    func play(episode: BaseEpisode, in session: Session) {
        guard let storeUuid = session.storePlaylistUuid else { return }
        let target = PlaybackSession(type: .playlist, uuid: storeUuid)
        if Settings.playbackSession() != target {
            Settings.setPlaybackSession(target)
            Settings.setPlaybackSessionPaused(false)
        }
        PlaybackManager.shared.play(sessionEpisode: episode)
    }

    /// Stamps the active session as recently played once audio starts, whatever started it
    /// — the chooser, the Switch sheet, a Play Session button, CarPlay, or a resume.
    @objc private func sessionPlaybackStarted() {
        guard let playing = Settings.playbackSession(), !Settings.playbackSessionPaused() else { return }
        SessionStore.shared.markUsed(playbackUuid: playing.uuid)
    }

    func sessionsCovering(podcastUuid: String) -> [Session] {
        SessionStore.shared.sessions.filter { $0.uuid != SessionStore.globalInboxUuid && feeder($0.feeder, coversPodcast: podcastUuid) }
    }

    /// Fork: whether a SMART-PLAYLIST session covers this podcast via an EXPLICIT podcast scope —
    /// backs the session list's "Hide Podcasts in Smart Playlists" toggle (a podcast already gathered
    /// by a smart playlist doesn't need its own session row). An "all podcasts" smart playlist is
    /// deliberately excluded: it would otherwise hide every per-podcast session.
    func smartPlaylistSessionCovers(podcastUuid: String) -> Bool {
        SessionStore.shared.sessions.contains { session in
            guard case .smartPlaylist(let uuid) = session.feeder,
                  !Settings.playlistOptedOutOfSession(uuid: uuid),
                  let playlist = DataManager.sharedManager.findPlaylist(uuid: uuid),
                  !playlist.filterAllPodcasts else { return false }
            return playlist.podcastUuids.components(separatedBy: ",").contains(podcastUuid)
        }
    }

    /// The union of every podcast covered by a smart-playlist session — computed ONCE so the session
    /// list builder can test coverage with an O(1) `Set.contains` per podcast session, instead of
    /// calling `smartPlaylistSessionCovers` (a full sessions scan + DB hit) inside its per-session
    /// loop (which was O(sessions²)).
    func smartPlaylistCoveredPodcastUuids() -> Set<String> {
        var covered = Set<String>()
        for session in SessionStore.shared.sessions {
            guard case .smartPlaylist(let uuid) = session.feeder,
                  !Settings.playlistOptedOutOfSession(uuid: uuid),
                  let playlist = DataManager.sharedManager.findPlaylist(uuid: uuid),
                  !playlist.filterAllPodcasts else { continue }
            covered.formUnion(playlist.podcastUuids.components(separatedBy: ","))
        }
        return covered
    }

    private func feeder(_ feeder: SessionFeeder, coversPodcast podcastUuid: String) -> Bool {
        switch feeder {
        case .none:
            return false
        case .allPodcasts:
            // An all-podcasts feeder covers every episode — uniform with any other feeder. Whether a
            // given add reaches it is governed by the general Add mode (all matching / this / ask).
            return true
        case .podcast(let uuid):
            return uuid == podcastUuid
        case .folder(let uuid):
            return DataManager.sharedManager.findPodcast(uuid: podcastUuid)?.folderUuid == uuid
        case .smartPlaylist(let uuid):
            // A playlist that opted out of being a session playlist covers nothing: it must never
            // be offered as an add target, nor gathered into by any sweep. Its existing lineup is
            // untouched — this only stops new traffic reaching it.
            guard !Settings.playlistOptedOutOfSession(uuid: uuid) else { return false }
            guard let playlist = DataManager.sharedManager.findPlaylist(uuid: uuid) else { return false }
            if playlist.filterAllPodcasts { return true }
            return playlist.podcastUuids.components(separatedBy: ",").contains(podcastUuid)
        }
    }

    /// Fork: whether a feeder covers a specific EPISODE. For a smart-playlist feeder this honours the
    /// playlist's EPISODE-LEVEL rules (duration, release date, unplayed, …) — not just whether the
    /// podcast is in scope. Without this, an "all podcasts, max 10 min" playlist would swallow a 40-min
    /// episode on "Add to Session" or a backfill (the reported bug), because podcast coverage was true.
    /// Non-smart feeders (podcast, folder, all-podcasts) have no episode rules, so they defer to
    /// podcast coverage.
    func feeder(_ feeder: SessionFeeder, coversEpisode episode: BaseEpisode) -> Bool {
        guard case .smartPlaylist(let uuid) = feeder else {
            return self.feeder(feeder, coversPodcast: episode.parentIdentifier())
        }
        guard !Settings.playlistOptedOutOfSession(uuid: uuid),
              let playlist = DataManager.sharedManager.findPlaylist(uuid: uuid) else { return false }
        // Run the playlist's own query constrained to this one episode: a hit means it matches the rules.
        let query = PlaylistQueryBuilder.query(clause: .episode,
                                               for: playlist,
                                               limit: 1,
                                               shouldShowArchived: true,
                                               extraWhere: "episode.uuid = '\(episode.uuid)'")
        return !DataManager.sharedManager.findPlaylistEpisodesWhere(query: query, arguments: nil).isEmpty
    }

    /// Whether a session's lineup has nothing left to play (every episode finished, or none
    /// present). Backs the "Hide empty sessions" toggle. A non-session playlist is never "empty"
    /// by this rule, so the filter leaves plain playlists alone.
    func sessionIsEmpty(storePlaylistUuid: String) -> Bool {
        guard SessionStore.shared.session(forStore: storePlaylistUuid) != nil else { return false }
        return PlaybackSession(type: .playlist, uuid: storePlaylistUuid).orderedEpisodes().allSatisfy { $0.played() }
    }

    /// Whether this playlist is the STORE of a smart-playlist session whose feeder is the user's
    /// own VISIBLE smart playlist. That smart playlist is already the Playlists-tab entry and opens
    /// the session, so its store is a redundant second row to hide *there* — the chooser still lists
    /// the session via the store. A converted lens (feeder is a hidden "— feed" copy) returns false:
    /// its store is the only entry and must stay.
    func storeHasVisibleSmartFeeder(playlistUuid: String) -> Bool {
        guard let session = SessionStore.shared.session(forStore: playlistUuid),
              case .smartPlaylist(let feederUuid) = session.feeder,
              let feeder = DataManager.sharedManager.findPlaylist(uuid: feederUuid) else { return false }
        return !feeder.playlistName.hasSuffix(" — feed")
    }

    // MARK: - Insert marker

    /// Whether a playlist should appear in the Playlists tab given the "Session Playlists" settings.
    /// A plain (non-session) playlist always shows; a session store shows per its feeder type:
    /// manual/smart toggles, and per-podcast sessions only when the podcast's folder is selected.
    func sessionStoreVisible(playlistUuid: String) -> Bool {
        guard let session = SessionStore.shared.session(forStore: playlistUuid) else { return true }
        switch session.feeder {
        case .none:
            return Settings.showManualSessions()
        case .smartPlaylist, .folder, .allPodcasts:
            return Settings.showSmartPlaylistSessions()
        case .podcast(let podcastUuid):
            if Settings.showPodcastSessionPodcasts().contains(podcastUuid) { return true }
            guard let folderUuid = DataManager.sharedManager.findPodcast(uuid: podcastUuid, includeUnsubscribed: true)?.folderUuid else { return false }
            return Settings.showPodcastSessionFolders().contains(folderUuid)
        }
    }

    /// How many podcasts a feeder covers — used to order sessions from most specific (a single
    /// podcast) to broadest (all podcasts).
    func feederPodcastCount(_ feeder: SessionFeeder) -> Int {
        switch feeder {
        case .none:
            return 0
        case .podcast:
            return 1
        case .folder(let uuid):
            return DataManager.sharedManager.allPodcasts(includeUnsubscribed: false).filter { $0.folderUuid == uuid }.count
        case .smartPlaylist(let uuid):
            guard let playlist = DataManager.sharedManager.findPlaylist(uuid: uuid) else { return 0 }
            if playlist.filterAllPodcasts { return Int.max }
            return playlist.podcastUuids.components(separatedBy: ",").filter { !$0.isEmpty && $0 != "none" }.count
        case .allPodcasts:
            return Int.max
        }
    }


    /// Play as Session on a podcast: plays the podcast's session lineup, nothing
    /// else — the Inbox and Episodes tabs never leak in. Created empty on first use.
    func playPodcastSession(for podcast: Podcast) {
        play(session: findOrCreateSession(forPodcast: podcast))
    }

    /// Fork: this session is fed by a smart playlist the user has declared "not a session
    /// playlist" (`Settings.playlistOptedOutOfSession`). Such a session is frozen — never
    /// listed, never created, never reconciled, never filled — but its store and lineup are
    /// preserved, so turning the toggle back on restores it exactly as it was.
    static func isOptedOut(feeder: SessionFeeder) -> Bool {
        if case .smartPlaylist(let uuid) = feeder { return Settings.playlistOptedOutOfSession(uuid: uuid) }
        return false
    }

    /// The smart playlist's session — the playlist itself is the feeder; the store
    /// carries its name. Created lazily, seeded with the current query order.
    ///
    /// Nil when the playlist has opted out of being a session playlist
    /// (`Settings.playlistOptedOutOfSession`): no session is created, and an existing one
    /// (from before the opt-out) is deliberately NOT returned, so no surface can revive it.
    /// Optional rather than a separate guard so every call site is compiler-checked.
    func findOrCreateSession(forSmartPlaylist lens: EpisodeFilter, seedEpisodeUuids: [String] = []) -> Session? {
        guard !Settings.playlistOptedOutOfSession(uuid: lens.uuid) else { return nil }
        if let existing = SessionStore.shared.session(forSmartPlaylistFeeder: lens.uuid) { return existing }
        return createSession(name: lens.playlistName, feeder: .smartPlaylist(uuid: lens.uuid), seedEpisodeUuids: seedEpisodeUuids)
    }

    /// Fork: a just-created smart playlist inherits the episodes already shelved in sessions.
    /// When its filter matches anything currently in a session lineup, its own session springs
    /// into being and the reconciler mirrors the filter in — so podcasts you've already triaged
    /// carry their lineup into the new playlist's session instead of starting empty.
    func adoptNewSmartPlaylist(_ playlist: EpisodeFilter) {
        guard !playlist.manual,
              // "Not a session playlist" means never adopt one either.
              !Settings.playlistOptedOutOfSession(uuid: playlist.uuid),
              SessionStore.shared.session(forSmartPlaylistFeeder: playlist.uuid) == nil else { return }
        let shelved = SessionFeederEngine.allStoreMemberUuids()
        guard !shelved.isEmpty else { return }
        let overlaps = EpisodesDataManager().playlistEpisodes(for: playlist, limit: 0)
            .contains { shelved.contains($0.episode.uuid) }
        guard overlaps else { return }

        guard let session = findOrCreateSession(forSmartPlaylist: playlist) else { return }
        guard !isReconcilingFeeder else { return }
        isReconcilingFeeder = true
        defer { isReconcilingFeeder = false }
        reconcileStoreToFeeder(session: session)
    }

    /// The folder's session, created lazily on first use.
    /// Starts a session — the lineup only, never the Inbox or Episodes list. An
    /// empty lineup is a no-op with a hint; filling it is triage's job.
    func play(session: Session) {
        // A play-status feeder mirrors lazily — sync it to the filter right before playing.
        reconcileOnView(session: session)
        guard let storeUuid = session.storePlaylistUuid else { return }
        guard !SessionFeederEngine.storeMemberUuids(for: session).isEmpty else {
            Toast.show(L10n.sessionEmptyToast)
            return
        }
        PlaybackManager.shared.startPlaybackSession(PlaybackSession(type: .playlist, uuid: storeUuid))
    }

    /// The podcast page's session mirrors the page order — sort/group changes reseed.
    func reseedPodcastSession(for podcast: Podcast) {
        guard let session = SessionStore.shared.session(forPodcast: podcast.uuid) else { return }
        let pageOrder = EpisodesDataManager().episodes(for: podcast)
            .flatMap { $0.elements.compactMap { ($0 as? ListEpisode)?.episode.uuid } }
        guard !pageOrder.isEmpty else { return }
        // Only reorder what's in the store; the page fetch includes episodes the
        // session may have dismissed or finished.
        let members = Set(SessionFeederEngine.storeMemberUuids(for: session))
        setLineupOrder(episodeUuids: pageOrder.filter { members.contains($0) }, session: session)
    }

    // MARK: - Sweeps

    /// Played or archived episodes leave every store (a synced removal) — the lineup is
    /// always "what's left".
    @objc private func episodeStateChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let uuid = notification.object as? String {
                // Fast path: an episode in no session can't be in any lineup, so marking it
                // played/archived needn't touch a single store. (This is the hot path behind a
                // slow "Mark as Played" — without it, every mark queried every session's store.)
                guard SessionMembership.shared.inAnySession.contains(uuid) else { return }
                guard let episode = DataManager.sharedManager.findEpisode(uuid: uuid),
                      episode.played() || episode.archived else { return }
                self.sweepLineups(decidedFilter: { $0 == uuid })
            } else {
                // No uuid (bulk archive / mark played) — sweep everything. A session
                // NEVER holds archived or played episodes.
                self.sweepLineups(decidedFilter: nil)
            }
        }
    }

    /// Removes decided (played/archived) episodes from every lineup. A nil filter
    /// checks every member; otherwise only matching uuids are considered.
    private func sweepLineups(decidedFilter: ((String) -> Bool)?) {
        // Nothing is in any lineup — skip the per-session store queries entirely (matters when
        // many empty sessions exist, e.g. a folder-scoped session per podcast).
        guard !SessionMembership.shared.inAnySession.isEmpty else { return }
        for session in SessionStore.shared.sessions {
            guard let store = store(for: session) else { continue }
            let members = DataManager.sharedManager.positionedEpisodeUuids(for: store)
            let decided = members.filter { uuid in
                if let decidedFilter, !decidedFilter(uuid) { return false }
                guard let episode = DataManager.sharedManager.findEpisode(uuid: uuid) else { return false }
                return episode.played() || episode.archived
            }
            guard !decided.isEmpty else { continue }
            DataManager.sharedManager.deleteEpisodes(decided, from: store)
            SessionStore.shared.unpin(episodeUuids: decided, for: session.uuid) // pins never outlive membership
            NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged, object: store)
            promptIfSessionFinished(session, store: store, remaining: members.count - decided.count)
        }
    }

    /// The playing session just drained: ephemeral stores offer to clean themselves up
    /// via a toast — dismissing it keeps the playlist. This can't stack with
    /// PlaybackManager's plain "session finished" toast: that path clears the
    /// playback-session pointer synchronously before this (main-async) sweep runs,
    /// so the `Settings.playbackSession()` guard below fails whenever it fired.
    private func promptIfSessionFinished(_ session: Session, store: EpisodeFilter, remaining: Int) {
        guard remaining <= 0,
              session.feeder == SessionFeeder.none,
              let playing = Settings.playbackSession(), playing.uuid == store.uuid else { return }
        let name = store.playlistName
        DispatchQueue.main.async { [weak self] in
            Toast.show(L10n.sessionFinishedTitle(name), actions: [
                Toast.Action(title: L10n.sessionFinishedDelete, action: {
                    PlaybackManager.shared.endPlaybackSession()
                    self?.deleteSession(session)
                })
            ])
        }
    }

    /// Playing an episode counts as seen naturally (progress) — nothing to write; this
    /// hook exists for the inbox badge to refresh.
    @objc private func trackChanged() {
        NotificationCenter.postOnMainThread(notification: SessionStore.changed)
    }

    /// Nothing to prune anymore: seen marks, dismissals and watermarks are all gone —
    /// membership of the Inbox playlist is the only state, and it is bounded by definition.
    /// The hook survives because auto-add sessions still want to absorb new offers on refresh.
    @objc func prune() {
        autoAddSweep()
    }

    /// Auto-add sessions absorb their feeder's offers straight into the store.
    func autoAddSweep() {
        for session in SessionStore.shared.sessions where session.autoAdd {
            ingestAutoAdd(session: session)
        }
    }

    func ingestAutoAdd(session: Session) {
        // Manual fill wins over the auto-add toggle: a hand-curated lineup absorbs nothing
        // automatically — offers stay in the inbox until the user adds them explicitly.
        guard session.autoFill, !SessionManager.isOptedOut(feeder: session.feeder) else { return }
        var offers = SessionFeederEngine.inboxEpisodes(for: session).map(\.uuid)
        guard !offers.isEmpty else { return }
        // The global limit caps auto-adds only: once the lineup is full, new arrivals
        // stay in the inbox. Manual adds are never capped.
        if let store = store(for: session) {
            let capacity = Settings.sessionAutoAddLimit() - DataManager.sharedManager.positionedEpisodeUuids(for: store).count
            guard capacity > 0 else { return }
            offers = Array(offers.prefix(capacity))
        }
        addToLineup(episodeUuids: offers, session: session)
        // Fork: auto-add to a Session honors the Session -> Up Next link, so an auto-added episode
        // also lands in Up Next when linking is on. mirrorSessionAdd honors the per-podcast setting,
        // skips episodes already queued, and calls the queue primitive directly (no cascade).
        SessionLinking.mirrorSessionAdd(episodeUuids: offers)
    }

    /// Smart playlists carrying a folder rule re-materialize the folder's podcasts
    /// into their synced podcast rule whenever folders change.
    @objc func refreshFolderRules() {
        guard FeatureFlag.smartPlaylistFolderRules.enabled else { return }
        DispatchQueue.global(qos: .utility).async {
            let linked = DataManager.sharedManager.allSmartPlaylists(includeDeleted: false).filter { !$0.folderUuids.isEmpty }
            guard !linked.isEmpty else { return }
            let podcasts = DataManager.sharedManager.allPodcasts(includeUnsubscribed: false)
            var changed = false
            var changedFeederSessions: [Session] = []
            for playlist in linked {
                let folderUuids = Set(playlist.folderUuids.components(separatedBy: ",").filter { !$0.isEmpty })
                let covered = podcasts.filter { $0.folderUuid.map(folderUuids.contains) ?? false }.map(\.uuid).sorted()
                let materialized = covered.isEmpty ? "none" : covered.joined(separator: ",")
                guard materialized != playlist.podcastUuids || playlist.filterAllPodcasts else { continue }
                playlist.podcastUuids = materialized
                playlist.filterAllPodcasts = false
                if SyncManager.isUserLoggedIn() { playlist.syncStatus = SyncStatus.notSynced.rawValue }
                DataManager.sharedManager.save(playlist: playlist)
                changed = true
                if let session = SessionStore.shared.session(forSmartPlaylistFeeder: playlist.uuid) {
                    changedFeederSessions.append(session)
                }
            }
            // A folder-linked feeder that changed shape must reshape its session's store too.
            for session in changedFeederSessions {
                self.reconcileStoreToFeeder(session: session)
            }
            if changed {
                NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged)
            }
        }
    }

    // MARK: - Healing

    /// A stock client can delete half a pair: a session whose store is gone degrades to
    /// removable; a rule session whose feeder is gone degrades to a static store.
    func healSessions() {
        for session in SessionStore.shared.sessions where session.uuid != SessionStore.globalInboxUuid {
            if let storeUuid = session.storePlaylistUuid,
               DataManager.sharedManager.findPlaylist(uuid: storeUuid) == nil {
                SessionStore.shared.delete(sessionUuid: session.uuid)
                continue
            }
            if case .smartPlaylist(let feederUuid) = session.feeder,
               DataManager.sharedManager.findPlaylist(uuid: feederUuid) == nil {
                var updated = session
                updated.feeder = .none
                SessionStore.shared.upsert(updated)
            }
            if case .folder(let folderUuid) = session.feeder,
               DataManager.sharedManager.findFolder(uuid: folderUuid) == nil {
                var updated = session
                updated.feeder = .none
                SessionStore.shared.upsert(updated)
            }
        }
    }

    private func markStoreChanged(_ store: EpisodeFilter) {
        store.syncStatus = SyncStatus.notSynced.rawValue
        DataManager.sharedManager.save(playlist: store)
        NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged, object: store)
    }
}

// MARK: - Fork: session subtitles

extension Session {
    /// The row subtitle: sessions announce themselves plainly.
    var displaySubtitle: String {
        L10n.sessionPlaylistSubtitle
    }
}

extension Session {
    /// The stable artwork tiles for this session — derived from the feeder, so the
    /// artwork never shifts as the lineup drains. Empty means "fall back to episodes".
    var artworkPodcastUuids: [String] {
        switch feeder {
        case .podcast(let uuid):
            return [uuid]
        case .folder(let uuid):
            return DataManager.sharedManager.allPodcasts(includeUnsubscribed: false)
                .filter { $0.folderUuid == uuid }
                .map(\.uuid)
                .sorted()
        case .smartPlaylist(let feederUuid):
            guard let feeder = DataManager.sharedManager.findPlaylist(uuid: feederUuid), !feeder.filterAllPodcasts else { return [] }
            return feeder.podcastUuids.components(separatedBy: ",").filter { !$0.isEmpty && $0 != "none" }
        case .none, .allPodcasts:
            return []
        }
    }
}

extension EpisodeFilter {
    /// Copies the smart-rule fields onto another playlist — used when a lens converts
    /// to a session and a hidden feeder playlist takes over its rules.
    func copySessionRules(from other: EpisodeFilter) {
        filterAllPodcasts = other.filterAllPodcasts
        podcastUuids = other.podcastUuids
        filterUnplayed = other.filterUnplayed
        filterPartiallyPlayed = other.filterPartiallyPlayed
        filterFinished = other.filterFinished
        filterDownloaded = other.filterDownloaded
        filterNotDownloaded = other.filterNotDownloaded
        filterAudioVideoType = other.filterAudioVideoType
        filterStarred = other.filterStarred
        filterHours = other.filterHours
        filterDuration = other.filterDuration
        longerThan = other.longerThan
        shorterThan = other.shorterThan
        customIcon = other.customIcon
    }
}
