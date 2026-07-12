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

    /// Inserts episodes at the session's insert marker. Adding means intent to play,
    /// so archived episodes come back out of the archive on the way in (otherwise the
    /// decisive-action sweep would immediately remove them from the store again).
    func addToLineup(episodeUuids: [String], session: Session) {
        guard let store = store(for: session), !episodeUuids.isEmpty else { return }
        unarchiveIfNeeded(episodeUuids: episodeUuids)
        var order = DataManager.sharedManager.positionedEpisodeUuids(for: store).filter { !episodeUuids.contains($0) }
        let index = insertMarkerIndex(for: session, inLineup: order)
        order.insert(contentsOf: episodeUuids, at: min(index, order.count))

        // Rows may not exist yet for new members — write titles/podcast uuids via the
        // stock add first, then apply the full order.
        let newEpisodes = episodeUuids.compactMap { DataManager.sharedManager.findEpisode(uuid: $0) }
        _ = DataManager.sharedManager.add(episodes: newEpisodes, to: store)
        DataManager.sharedManager.setCustomOrder(episodeUuids: order, for: store)
        markStoreChanged(store)

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
        let episodes = episodeUuids.compactMap { DataManager.sharedManager.findEpisode(uuid: $0) }
        _ = DataManager.sharedManager.add(episodes: episodes, to: store)
        DataManager.sharedManager.setCustomOrder(episodeUuids: episodeUuids, for: store)
        markStoreChanged(store)

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

    /// Removes from the lineup and records the scoped dismissal so the feeder never
    /// re-offers it. Recoverable via the Dismissed list.
    func removeFromLineup(episodeUuids: [String], session: Session) {
        guard let store = store(for: session) else { return }
        DataManager.sharedManager.deleteEpisodes(episodeUuids, from: store)
        SessionStore.shared.setDismissed(episodeUuids: episodeUuids, sessionUuid: session.uuid)
        NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged, object: store)
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
        PlaybackManager.shared.play(sessionEpisode: episode)
    }

    func sessionsCovering(podcastUuid: String) -> [Session] {
        SessionStore.shared.sessions.filter { $0.uuid != SessionStore.globalInboxUuid && feeder($0.feeder, coversPodcast: podcastUuid) }
    }

    private func feeder(_ feeder: SessionFeeder, coversPodcast podcastUuid: String) -> Bool {
        switch feeder {
        case .none, .allPodcasts:
            return false
        case .podcast(let uuid):
            return uuid == podcastUuid
        case .folder(let uuid):
            return DataManager.sharedManager.findPodcast(uuid: podcastUuid)?.folderUuid == uuid
        case .smartPlaylist(let uuid):
            guard let playlist = DataManager.sharedManager.findPlaylist(uuid: uuid), !playlist.filterAllPodcasts else { return false }
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

    /// Play as Session on a podcast: creates the session on first use, and reseeds a
    /// drained store from the page's current order (minus decided/dismissed episodes)
    /// so the button always starts something.
    func playPodcastSession(for podcast: Podcast) {
        let pageOrder = EpisodesDataManager().episodes(for: podcast)
            .flatMap { $0.elements.compactMap { ($0 as? ListEpisode)?.episode } }

        let playableUuids = pageOrder
            .filter { episode in
                guard let episode = episode as? Episode else { return false }
                return !episode.archived && !episode.played()
            }
            .map(\.uuid)

        let session = SessionStore.shared.session(forPodcast: podcast.uuid)
            ?? createSession(name: podcast.title ?? L10n.filtersDefaultNewFilter, feeder: .podcast(uuid: podcast.uuid), seedEpisodeUuids: playableUuids)
        play(session: session, fallbackSeed: playableUuids)
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

    /// Starts a session, refilling a drained store from its feeder's offers (or the
    /// given seed) first — pressing play always starts something when anything exists.
    func play(session: Session, fallbackSeed: [String] = []) {
        if SessionFeederEngine.storeMemberUuids(for: session).isEmpty {
            var refill = SessionFeederEngine.inboxEpisodes(for: session).map(\.uuid)
            if refill.isEmpty {
                let dismissed = Set(SessionStore.shared.dismissedUuids(sessionUuid: session.uuid))
                refill = fallbackSeed.filter { !dismissed.contains($0) }
            }
            if !refill.isEmpty {
                addToLineup(episodeUuids: refill, session: session)
            }
        }
        guard let storeUuid = session.storePlaylistUuid else { return }
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
            guard let self, let uuid = notification.object as? String,
                  let episode = DataManager.sharedManager.findEpisode(uuid: uuid) else { return }
            guard episode.played() || episode.archived else { return }
            for session in SessionStore.shared.sessions {
                guard let store = self.store(for: session) else { continue }
                let members = DataManager.sharedManager.positionedEpisodeUuids(for: store)
                if members.contains(uuid) {
                    DataManager.sharedManager.deleteEpisodes([uuid], from: store)
                    NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged, object: store)
                    self.promptIfSessionFinished(session, store: store, remaining: members.count - 1)
                }
            }
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

    @objc func prune() {
        SessionStore.shared.prune()
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
    }

    /// Smart playlists carrying a folder rule re-materialize the folder's podcasts
    /// into their synced podcast rule whenever folders change.
    @objc func refreshFolderRules() {
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
