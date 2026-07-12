import Foundation
import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils

/// Fork: one-time migration from the overlay era (smart playlists carrying local
/// position rows, decline sentinels, reserved-uuid global inbox, the 1s seen hack)
/// into the session architecture. The key insight making this safe: the overlay's
/// position rows ARE stock manual-playlist membership rows (same table, same keys) —
/// converting a custom-order smart playlist to a manual store is a flag flip.
enum SessionMigration {
    private static let legacyGlobalInboxUuid = "fork-global-inbox"
    private static let legacyDeclinedPrefix = "fork-inbox-declined-"
    private static let legacyFolderPlaylistsMapKey = "SJFolderAutoPlaylists"

    private static let migration2Key = "SJSessionMigration2Done"
    private static let migration3Key = "SJSessionMigration3Done"
    private static let migration4Key = "SJSessionMigration4Done"

    /// Fourth pass: any surviving "seen = 1s of progress" sentinels (server
    /// round-trips re-imported some after the first migration) become seen rows and
    /// the progress goes back to unplayed. Nothing writes the sentinel anymore.
    static func runSeenSentinelCleanupIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migration4Key) else { return }
        UserDefaults.standard.set(true, forKey: migration4Key)

        let marked = DataManager.sharedManager.findEpisodesWhere(customWhere: "playedUpTo > 0 AND playedUpTo <= 1", arguments: [])
        guard !marked.isEmpty else { return }
        for episode in marked {
            SessionStore.shared.setSeen(true, episodeUuid: episode.uuid)
            DataManager.sharedManager.saveEpisode(playedUpTo: 0, episode: episode, updateSyncFlag: SyncManager.isUserLoggedIn())
            if episode.inProgress() {
                DataManager.sharedManager.saveEpisode(playingStatus: .notPlayed, episode: episode, updateSyncFlag: SyncManager.isUserLoggedIn())
            }
        }
        NotificationCenter.postOnMainThread(notification: Constants.Notifications.manyEpisodesChanged)
        FileLog.shared.addMessage("SessionMigration: reset \(marked.count) 1s seen-sentinel episodes to unplayed")
    }

    /// Third pass (three-tab redesign): sessions fed by hidden "X — feed" playlists
    /// dissolve back into plain visible smart playlists — the feed playlist takes
    /// back the original name (rules intact) and the store goes away, lineup and
    /// all. Sessions are created lazily from the smart playlist's page from here on.
    static func runFeedRestoreMigrationIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migration3Key) else { return }
        UserDefaults.standard.set(true, forKey: migration3Key)

        let suffix = " — feed"
        var restored = 0
        for session in SessionStore.shared.sessions where session.uuid != SessionStore.globalInboxUuid {
            guard case .smartPlaylist(let feederUuid) = session.feeder,
                  let feeder = DataManager.sharedManager.findPlaylist(uuid: feederUuid),
                  feeder.playlistName.hasSuffix(suffix) else { continue }

            feeder.playlistName = String(feeder.playlistName.dropLast(suffix.count))
            if let storeUuid = session.storePlaylistUuid,
               let store = DataManager.sharedManager.findPlaylist(uuid: storeUuid) {
                // The restored lens takes the store's spot in the list.
                feeder.sortPosition = store.sortPosition
                PlaylistManager.delete(playlist: store, fireEvent: false)
            }
            feeder.isNew = false
            feeder.syncStatus = SyncStatus.notSynced.rawValue
            DataManager.sharedManager.save(playlist: feeder)
            SessionStore.shared.delete(sessionUuid: session.uuid)
            restored += 1
        }
        if restored > 0 {
            NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged)
        }
        FileLog.shared.addMessage("SessionMigration: restored \(restored) hidden feed playlists to visible smart playlists")
    }

    /// Second pass (feeder-page redesign): folders stop being direct feeders — each
    /// folder-fed session gains a hidden smart playlist carrying a live folder rule.
    static func runFolderFeederMigrationIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migration2Key) else { return }
        UserDefaults.standard.set(true, forKey: migration2Key)

        let podcasts = DataManager.sharedManager.allPodcasts(includeUnsubscribed: false)
        for session in SessionStore.shared.sessions {
            guard case .folder(let folderUuid) = session.feeder else { continue }
            var updated = session
            guard let folder = DataManager.sharedManager.findFolder(uuid: folderUuid) else {
                updated.feeder = .none
                SessionStore.shared.upsert(updated)
                continue
            }
            let feeder = EpisodeFilter.makeDefault()
            feeder.playlistName = "\(folder.name) — feed"
            feeder.folderUuids = folderUuid
            let covered = podcasts.filter { $0.folderUuid == folderUuid }.map(\.uuid).sorted()
            feeder.podcastUuids = covered.isEmpty ? "none" : covered.joined(separator: ",")
            feeder.filterAllPodcasts = false
            feeder.sortType = PlaylistSort.newestToOldest.rawValue
            feeder.sortPosition = 32000
            feeder.syncStatus = SyncStatus.notSynced.rawValue
            DataManager.sharedManager.save(playlist: feeder)
            updated.feeder = .smartPlaylist(uuid: feeder.uuid)
            SessionStore.shared.upsert(updated)
        }
        FileLog.shared.addMessage("SessionMigration: folder feeders re-pointed through folder-rule smart playlists")
    }

    static func runIfNeeded() {
        guard !SessionStore.shared.hasMigrated else { return }
        FileLog.shared.addMessage("SessionMigration: starting")

        migrateCustomOrderPlaylists()
        migrateGlobalInbox()
        migrateSeenMarks()

        // The playing session's playlist may have flipped smart→manual under it.
        if let playing = Settings.playbackSession(), playing.type == .smartPlaylist,
           SessionStore.shared.session(forStore: playing.uuid) != nil {
            Settings.setPlaybackSession(PlaybackSession(type: .playlist, uuid: playing.uuid))
        }

        SessionStore.shared.markMigrated()
        NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged)
        FileLog.shared.addMessage("SessionMigration: done")
    }

    // MARK: - Custom-order smart playlists → sessions

    private static func migrateCustomOrderPlaylists() {
        let folderMap = UserDefaults.standard.dictionary(forKey: legacyFolderPlaylistsMapKey) as? [String: String] ?? [:]
        let folderPlaylistUuids = Dictionary(uniqueKeysWithValues: folderMap.map { ($0.value, $0.key) }) // playlistUuid -> folderUuid

        for playlist in DataManager.sharedManager.allSmartPlaylists(includeDeleted: false) {
            guard playlist.sortType == PlaylistSort.dragAndDrop.rawValue else { continue } // date-sorted = lens, untouched

            let feeder = feederFor(playlist: playlist, folderPlaylistUuids: folderPlaylistUuids)

            // The store IS the old playlist: its position rows are already manual
            // membership rows. Flip it, and it syncs up complete with its lineup.
            playlist.manual = true
            playlist.syncStatus = SyncStatus.notSynced.rawValue
            DataManager.sharedManager.save(playlist: playlist)

            var session = ForkSession(uuid: UUID().uuidString, storePlaylistUuid: playlist.uuid, feeder: feeder)
            session.autoAdd = playlist.newEpisodesAutoAdd
            session.insertMode = playlist.customOrderInsertMode
            session.lastInsertedUuid = playlist.customOrderLastInsertedUuid
            session.groupBy = UserDefaults.standard.integer(forKey: "SJPlaylistGroupBy-\(playlist.uuid)")
            session.groupLimit = UserDefaults.standard.integer(forKey: "SJPlaylistGroupLimit-\(playlist.uuid)")
            session.showPlayed = UserDefaults.standard.bool(forKey: "SJPlaylistShowPlayed-\(playlist.uuid)")
            SessionStore.shared.upsert(session)

            // Per-shelf declines → scoped dismissals; the sentinel rows go away.
            let declineHandle = EpisodeFilter()
            declineHandle.uuid = legacyDeclinedPrefix + playlist.uuid
            let declined = DataManager.sharedManager.positionedEpisodeUuids(for: declineHandle)
            SessionStore.shared.setDismissed(episodeUuids: declined, sessionUuid: session.uuid)
            DataManager.sharedManager.setCustomOrder(episodeUuids: [], for: declineHandle)
        }
    }

    /// Folder-linked playlists become folder feeders; single-podcast bridges become
    /// podcast feeders; genuinely rule-based playlists keep their rules alive in a new
    /// hidden feeder playlist (the store took over their identity).
    private static func feederFor(playlist: EpisodeFilter, folderPlaylistUuids: [String: String]) -> SessionFeeder {
        let linkedFolder = folderPlaylistUuids[playlist.uuid]
            ?? playlist.folderUuids.components(separatedBy: ",").first { !$0.isEmpty }
        if let linkedFolder, DataManager.sharedManager.findFolder(uuid: linkedFolder) != nil {
            return .folder(uuid: linkedFolder)
        }

        let podcastUuids = playlist.podcastUuids.components(separatedBy: ",").filter { !$0.isEmpty && $0 != "none" }
        if !playlist.filterAllPodcasts, podcastUuids.count == 1, let only = podcastUuids.first,
           DataManager.sharedManager.findPodcast(uuid: only) != nil {
            return .podcast(uuid: only)
        }

        // Rule-based: spawn the feeder playlist carrying the rules, marked as machinery.
        let feeder = EpisodeFilter.makeDefault()
        feeder.copySessionRules(from: playlist)
        feeder.playlistName = "\(playlist.playlistName) — feed"
        feeder.sortType = PlaylistSort.newestToOldest.rawValue
        feeder.sortPosition = 32000
        feeder.syncStatus = SyncStatus.notSynced.rawValue
        DataManager.sharedManager.save(playlist: feeder)
        return .smartPlaylist(uuid: feeder.uuid)
    }

    // MARK: - Global inbox

    private static func migrateGlobalInbox() {
        let handle = EpisodeFilter()
        handle.uuid = legacyGlobalInboxUuid
        let currentInbox = Set(DataManager.sharedManager.positionedEpisodeUuids(for: handle))

        let global = SessionStore.shared.globalInbox

        // Anything the computed inbox would offer that ISN'T in the old positioned list
        // was already handled (kept, cleared, swept) — record those as dismissals so
        // nothing resurfaces.
        let handled = SessionFeederEngine.inboxEpisodes(for: global)
            .map(\.uuid)
            .filter { !currentInbox.contains($0) }
        SessionStore.shared.setDismissed(episodeUuids: handled, sessionUuid: global.uuid)

        // The reserved-uuid rows are done.
        DataManager.sharedManager.setCustomOrder(episodeUuids: [], for: handle)
        UserDefaults.standard.removeObject(forKey: "SJGlobalInboxLastScan")
        UserDefaults.standard.removeObject(forKey: "SJGlobalInboxBackfilled")
    }

    // MARK: - Seen marks (the 1s hack → SeenEpisode rows)

    private static func migrateSeenMarks() {
        let marked = DataManager.sharedManager.findEpisodesWhere(customWhere: "playedUpTo > 0 AND playedUpTo <= 1", arguments: [])
        for episode in marked {
            SessionStore.shared.setSeen(true, episodeUuid: episode.uuid)
            DataManager.sharedManager.saveEpisode(playedUpTo: 0, episode: episode, updateSyncFlag: SyncManager.isUserLoggedIn())
        }
    }
}

extension EpisodeFilter {
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
