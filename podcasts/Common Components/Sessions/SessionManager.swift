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

    /// Fork: a podcast uuid whose page should open on its Session tab the next time it
    /// appears — set right before navigating there (e.g. from the switch sheet).
    static var pendingSessionLanding: String?

    func setup() {
        NotificationCenter.default.addObserver(self, selector: #selector(refreshFolderRules), name: Constants.Notifications.folderChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshFolderRules), name: ServerNotifications.syncCompleted, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(episodeStateChanged), name: Constants.Notifications.episodeArchiveStatusChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(episodeStateChanged), name: Constants.Notifications.episodePlayStatusChanged, object: nil)
        // Bulk operations announce without a uuid — those trigger a full sweep.
        NotificationCenter.default.addObserver(self, selector: #selector(episodeStateChanged), name: Constants.Notifications.manyEpisodesChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(trackChanged), name: Constants.Notifications.playbackTrackChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(prune), name: ServerNotifications.podcastsRefreshed, object: nil)
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

        let session = Session(uuid: UUID().uuidString, storePlaylistUuid: store.uuid, feeder: feeder)
        SessionStore.shared.upsert(session)
        NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged)
        return session
    }

    /// The session for a podcast, created on first use (feeder = the podcast itself).
    func findOrCreateSession(forPodcast podcast: Podcast, seedEpisodeUuids: [String] = []) -> Session {
        if let existing = SessionStore.shared.session(forPodcast: podcast.uuid) { return existing }
        return createSession(name: podcast.title ?? L10n.filtersDefaultNewFilter, feeder: .podcast(uuid: podcast.uuid), seedEpisodeUuids: seedEpisodeUuids)
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
    func addToLineup(episodeUuids: [String], session: Session) {
        guard let store = store(for: session), !episodeUuids.isEmpty else { return }
        unarchiveIfNeeded(episodeUuids: episodeUuids)
        unplayIfNeeded(episodeUuids: episodeUuids)
        var order = DataManager.sharedManager.positionedEpisodeUuids(for: store).filter { !episodeUuids.contains($0) }
        let index = insertMarkerIndex(for: session, inLineup: order)
        order.insert(contentsOf: episodeUuids, at: min(index, order.count))

        // Rows may not exist yet for new members — write titles/podcast uuids via the
        // stock add first, then apply the full order.
        let newEpisodes = episodeUuids.compactMap { DataManager.sharedManager.findEpisode(uuid: $0) }
        _ = DataManager.sharedManager.add(episodes: newEpisodes, to: store)
        DataManager.sharedManager.setCustomOrder(episodeUuids: order, for: store)
        markStoreChanged(store)

        // Deciding to play something is deciding about it: it leaves the Inbox.
        //
        // This is a PRIMITIVE call, not a verb — nothing mirrors from an Inbox removal, so
        // the Up Next <-> Session mirroring stays a two-party relationship with the Inbox as
        // a leaf. Calling a verb here is what would make recursion possible.
        InboxManager.shared.markSeen(episodeUuids: episodeUuids)

        var updated = session
        updated.lastInsertedUuid = episodeUuids.last ?? updated.lastInsertedUuid
        SessionStore.shared.upsert(updated)
    }

    /// Replaces the lineup wholesale: the store becomes exactly these episodes, in
    /// this order. Former members return to triage (no dismissals are recorded —
    /// replacement isn't a per-episode "no").
    func replaceLineup(episodeUuids: [String], session: Session) {
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

        var updated = session
        updated.lastInsertedUuid = episodeUuids.last ?? ""
        SessionStore.shared.upsert(updated)
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
        NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged, object: store)

        if let playing = PlaybackManager.shared.currentEpisode(), episodeUuids.contains(playing.uuid) {
            PlaybackManager.shared.removeIfPlayingOrQueued(episode: playing, fireNotification: true, userInitiated: true)
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
            if episodes.contains(where: { feeder(.smartPlaylist(uuid: playlist.uuid), coversPodcast: $0.podcastUuid) }) {
                _ = findOrCreateSession(forSmartPlaylist: playlist)
            }
        }
        // Folders:
        for folder in DataManager.sharedManager.allFolders(includeDeleted: false)
        where SessionStore.shared.session(forFolder: folder.uuid) == nil {
            if episodes.contains(where: { feeder(.folder(uuid: folder.uuid), coversPodcast: $0.podcastUuid) }) {
                _ = findOrCreateSession(forFolder: folder)
            }
        }
        // Per podcast: every podcast that has an in-session episode gets its own session.
        for podcastUuid in Set(episodes.map(\.podcastUuid))
        where SessionStore.shared.session(forPodcast: podcastUuid) == nil {
            if let podcast = DataManager.sharedManager.findPodcast(uuid: podcastUuid) {
                _ = findOrCreateSession(forPodcast: podcast)
            }
        }

        var added = 0
        for session in SessionStore.shared.sessions where session.uuid != SessionStore.globalInboxUuid {
            guard let store = store(for: session) else {
                FileLog.shared.addMessage("Backfill: session \(session.uuid) has no store — skipped")
                continue
            }
            let existing = Set(SessionFeederEngine.storeMemberUuids(for: session))
            let missing = episodes.filter { !existing.contains($0.uuid) && feeder(session.feeder, coversPodcast: $0.podcastUuid) }
            FileLog.shared.addMessage("Backfill: '\(store.playlistName)' feeder=\(session.feeder) existing=\(existing.count) missing=\(missing.count)")
            guard !missing.isEmpty else { continue }
            _ = DataManager.sharedManager.add(episodes: missing, to: store)
            markStoreChanged(store)
            added += missing.count
        }
        return added
    }

    /// Every non-inbox session whose store currently holds any of these episodes.
    func sessionsHolding(episodeUuids: [String]) -> [Session] {
        let holders = Set(episodeUuids.flatMap { DataManager.sharedManager.manualPlaylistUUIDs(for: $0) })
        guard !holders.isEmpty else { return [] }
        return SessionStore.shared.sessions.filter {
            $0.uuid != SessionStore.globalInboxUuid && ($0.storePlaylistUuid.map(holders.contains) ?? false)
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
                && episodes.contains { self.feeder(session.feeder, coversPodcast: $0.podcastUuid) }
        }
        if let preferred {
            covering.removeAll { $0.uuid == preferred.uuid }
            covering.insert(preferred, at: 0)
        }

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
                        : episodes.filter { self.feeder(session.feeder, coversPodcast: $0.podcastUuid) }.map(\.uuid)
                    guard !uuids.isEmpty else { continue }
                    self.addToLineup(episodeUuids: uuids, session: session)
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
            add(to: [preferred ?? covering.first ?? withPodcastSessions([]).first].compactMap { $0 })
        case .allMatching:
            add(to: withPodcastSessions(covering))
        case .ask:
            let rowCount = covering.count + podcastsWithoutSessions.count
            guard rowCount > 1, let presenting else {
                add(to: withPodcastSessions(covering))
                return
            }
            let picker = OptionsPicker(title: L10n.playlistAddToLineup.localizedUppercase)
            picker.addAction(action: OptionAction(label: L10n.inboxAddAllSessions, icon: nil) { [weak self] in
                guard self != nil else { return }
                add(to: withPodcastSessions(covering))
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
        // Recency for the Switch Session sheet.
        SessionStore.shared.markUsed(playbackUuid: storeUuid)
        PlaybackManager.shared.play(sessionEpisode: episode)
    }

    func sessionsCovering(podcastUuid: String) -> [Session] {
        SessionStore.shared.sessions.filter { $0.uuid != SessionStore.globalInboxUuid && feeder($0.feeder, coversPodcast: podcastUuid) }
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
            guard let playlist = DataManager.sharedManager.findPlaylist(uuid: uuid) else { return false }
            if playlist.filterAllPodcasts { return true }
            return playlist.podcastUuids.components(separatedBy: ",").contains(podcastUuid)
        }
    }

    // MARK: - Insert marker

    func insertMarkerIndex(for session: Session, inLineup lineup: [String]) -> Int {
        switch PlaylistInsertMode(rawValue: session.insertMode) ?? .afterLastInserted {
        case .top:
            return 0
        case .bottom:
            return lineup.count
        case .afterLastInserted:
            if let index = lineup.firstIndex(of: session.lastInsertedUuid) { return index + 1 }
            return 0
        case .beforeLastInserted:
            if let index = lineup.firstIndex(of: session.lastInsertedUuid) { return index }
            return lineup.count
        }
    }

    /// Play as Session on a podcast: plays the podcast's session lineup, nothing
    /// else — the Inbox and Episodes tabs never leak in. Created empty on first use.
    func playPodcastSession(for podcast: Podcast) {
        play(session: findOrCreateSession(forPodcast: podcast))
    }

    /// The smart playlist's session — the playlist itself is the feeder; the store
    /// carries its name. Created lazily, seeded with the current query order.
    func findOrCreateSession(forSmartPlaylist lens: EpisodeFilter, seedEpisodeUuids: [String] = []) -> Session {
        if let existing = SessionStore.shared.session(forSmartPlaylistFeeder: lens.uuid) { return existing }
        return createSession(name: lens.playlistName, feeder: .smartPlaylist(uuid: lens.uuid), seedEpisodeUuids: seedEpisodeUuids)
    }

    /// The folder's session, created lazily on first use.
    func findOrCreateSession(forFolder folder: Folder) -> Session {
        if let existing = SessionStore.shared.session(forFolder: folder.uuid) { return existing }
        return createSession(name: folder.name, feeder: .folder(uuid: folder.uuid))
    }

    /// Starts a session — the lineup only, never the Inbox or Episodes list. An
    /// empty lineup is a no-op with a hint; filling it is triage's job.
    func play(session: Session) {
        guard let storeUuid = session.storePlaylistUuid else { return }
        guard !SessionFeederEngine.storeMemberUuids(for: session).isEmpty else {
            Toast.show(L10n.sessionEmptyToast)
            return
        }
        // Recency for the Switch Session sheet.
        SessionStore.shared.markUsed(playbackUuid: storeUuid)
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
            NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged, object: store)
            promptIfSessionFinished(session, store: store, remaining: members.count - decided.count)
        }
    }

    /// The playing session just drained: ephemeral stores offer to clean themselves up.
    private func promptIfSessionFinished(_ session: Session, store: EpisodeFilter, remaining: Int) {
        guard remaining <= 0,
              session.feeder == SessionFeeder.none,
              let playing = Settings.playbackSession(), playing.uuid == store.uuid,
              let host = SceneHelper.rootViewController() else { return }
        let alert = UIAlertController(
            title: L10n.sessionFinishedTitle(store.playlistName),
            message: L10n.sessionFinishedMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.sessionFinishedKeep, style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.sessionFinishedDelete, style: .destructive) { [weak self] _ in
            PlaybackManager.shared.endPlaybackSession()
            self?.deleteSession(session)
        })
        host.present(alert, animated: true)
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
