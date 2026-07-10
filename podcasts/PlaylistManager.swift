import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils
import UIKit

class PlaylistManager {
    enum DefaultUUIDs {
        static let newReleases = "2797DCF8-1C93-4999-B52A-D1849736FA2C"
        static let inProgress = "D89A925C-5CE1-41A4-A879-2751838CE5CE"
    }

    // MARK: - Default Playlists

    class func createDefaultPlaylists() {
        // new releases
        var existingUuid = DefaultUUIDs.newReleases
        var existingFilter = DataManager.sharedManager.findPlaylist(uuid: existingUuid)
        if existingFilter == nil {
            let newReleases = EpisodeFilter()
            newReleases.filterUnplayed = true
            newReleases.filterPartiallyPlayed = true
            newReleases.filterAudioVideoType = AudioVideoFilter.all.rawValue
            newReleases.filterAllPodcasts = true
            newReleases.sortPosition = 0
            newReleases.playlistName = L10n.filtersDefaultNewReleases
            newReleases.filterDownloaded = true
            newReleases.filterNotDownloaded = true
            newReleases.filterHours = (24 * 14) // two weeks
            newReleases.uuid = existingUuid
            newReleases.customIcon = PlaylistIcon.redRecent.rawValue
            newReleases.syncStatus = SyncStatus.synced.rawValue
            DataManager.sharedManager.save(playlist: newReleases)
        }

        // don't create the rest of these if the user already has playlists
        let playlistsCount = DataManager.sharedManager.playlistsCount(includeDeleted: false)
        if playlistsCount > 1 {
            NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged)

            return
        }

        // in progress
        existingUuid = DefaultUUIDs.inProgress
        existingFilter = DataManager.sharedManager.findPlaylist(uuid: existingUuid)
        if existingFilter == nil {
            let inProgress = EpisodeFilter()
            inProgress.filterAllPodcasts = true
            inProgress.filterAudioVideoType = AudioVideoFilter.all.rawValue
            inProgress.sortPosition = 2
            inProgress.playlistName = L10n.inProgress
            inProgress.filterDownloaded = true
            inProgress.filterNotDownloaded = true
            inProgress.filterUnplayed = false
            inProgress.filterPartiallyPlayed = true
            inProgress.filterFinished = false
            inProgress.filterHours = (24 * 31) // one month
            inProgress.uuid = existingUuid
            inProgress.customIcon = PlaylistIcon.purpleUnplayed.rawValue
            inProgress.syncStatus = SyncStatus.synced.rawValue
            DataManager.sharedManager.save(playlist: inProgress)
        }

        NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged)
    }

    class func delete(playlist: EpisodeFilter?, fireEvent: Bool) {
        guard let playlist else { return }

        if SyncManager.isUserLoggedIn() {
            playlist.wasDeleted = true
            playlist.syncStatus = SyncStatus.notSynced.rawValue
            DataManager.sharedManager.save(playlist: playlist)
        } else {
            DataManager.sharedManager.delete(playlist: playlist)
        }

        if fireEvent {
            NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged)
        }
    }

    class func createNewPlaylist() -> EpisodeFilter {
        let playlist = EpisodeFilter.makeDefault()
        playlist.playlistName = L10n.filtersDefaultNewFilter
        playlist.sortPosition = nextSortPosition()
        playlist.isNew = true
        return playlist
    }

    /// Fork: the smart playlist that mirrors just this podcast, created on first use.
    /// Podcast sessions run through it so they get custom order, the New inbox, and
    /// session reorder/sort like any other smart playlist.
    class func findOrCreateSmartPlaylist(for podcast: Podcast) -> EpisodeFilter {
        let playlists = DataManager.sharedManager.allPlaylists(includeDeleted: false)
        if let existing = playlists.first(where: { !$0.manual && !$0.filterAllPodcasts && $0.podcastUuids == podcast.uuid }) {
            return existing
        }

        let playlist = createNewPlaylist()
        playlist.playlistName = podcast.title ?? L10n.filtersDefaultNewFilter
        playlist.filterAllPodcasts = false
        playlist.podcastUuids = podcast.uuid
        playlist.isNew = false
        DataManager.sharedManager.save(playlist: playlist)
        NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged)
        return playlist
    }

    class func checkForAutoDownloads() {
        let playlists = DataManager.sharedManager.allPlaylists(includeDeleted: false)

        if playlists.isEmpty { return }

        let onWifi = NetworkUtils.shared.isConnectedToUnexpensiveConnection()
        let mobileDataAllowed = Settings.autoDownloadMobileDataAllowed()
        for playlist in playlists {
            guard playlist.autoDownloadEpisodes else { continue }

            let query = PlaylistQueryBuilder.query(clause: .episode, for: playlist, episodeUuidToAdd: playlist.episodeUuidToAddToQueries(), limit: Int(playlist.maxAutoDownloadEpisodes()))
            let episodes = DataManager.sharedManager.findPlaylistEpisodesWhere(query: query, arguments: nil)

            for episode in episodes {
                if episode.downloaded(pathFinder: DownloadManager.shared) || episode.queued() { continue }

                if !onWifi, !mobileDataAllowed {
                    DownloadManager.shared.queueForLaterDownload(episodeUuid: episode.uuid, fireNotification: false, autoDownloadStatus: .autoDownloaded)
                } else {
                    DownloadManager.shared.addToQueue(episodeUuid: episode.uuid, fireNotification: false, autoDownloadStatus: .autoDownloaded)
                }
            }
        }
    }

    class func handlePodcastUnsubscribed(podcastUuid: String) {
        let playlists = DataManager.sharedManager.allPlaylists(includeDeleted: false)
        if playlists.isEmpty { return }

        for playlist in playlists {
            guard !playlist.filterAllPodcasts, !playlist.podcastUuids.isEmpty else { continue }

            var podcastUuids = playlist.podcastUuids.components(separatedBy: ",")
            guard let indexOfUuid = podcastUuids.firstIndex(of: podcastUuid) else { continue }

            podcastUuids.remove(at: indexOfUuid)
            playlist.podcastUuids = podcastUuids.joined(separator: ",")
            if SyncManager.isUserLoggedIn() { playlist.syncStatus = SyncStatus.notSynced.rawValue }
            DataManager.sharedManager.save(playlist: playlist)
        }
    }

    /// Fork: when a folder is deleted, drop the link from every playlist tracking it.
    /// The materialized podcastUuids stay as they were — the playlist freezes as an
    /// ordinary podcast-filtered playlist.
    class func handleFolderDeleted(folderUuid: String) {
        for playlist in DataManager.sharedManager.allSmartPlaylists(includeDeleted: false) where !playlist.folderUuids.isEmpty {
            var uuids = playlist.folderUuids.components(separatedBy: ",")
            guard let index = uuids.firstIndex(of: folderUuid) else { continue }

            uuids.remove(at: index)
            playlist.folderUuids = uuids.joined(separator: ",")
            DataManager.sharedManager.save(playlist: playlist)
        }
        refreshFolderLinkedPlaylists()
    }

    /// Fork folder links: re-materializes every folder-linked smart playlist's podcast
    /// rule from its folders' current membership. The podcast list lands in the stock,
    /// synced podcastUuids field, so other devices see an ordinary podcast-filtered
    /// playlist; only this device maintains the link. Cheap enough to run after every
    /// sync and folder change.
    class func refreshFolderLinkedPlaylists() {
        let linked = DataManager.sharedManager.allSmartPlaylists(includeDeleted: false).filter { !$0.folderUuids.isEmpty }
        guard !linked.isEmpty else { return }

        let podcasts = DataManager.sharedManager.allPodcasts(includeUnsubscribed: false)
        var changed = false
        for playlist in linked {
            let folderUuids = Set(playlist.folderUuids.components(separatedBy: ",").filter { !$0.isEmpty })
            let podcastUuids = podcasts
                .filter { $0.folderUuid.map(folderUuids.contains) ?? false }
                .map(\.uuid)
                .sorted()
            // An empty folder should match nothing; an empty podcastUuids would mean
            // "all podcasts" to the stock query, so a placeholder keeps it empty.
            let materialized = podcastUuids.isEmpty ? "none" : podcastUuids.joined(separator: ",")
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

    class func autoDownloadPlaylistsCount() -> Int {
        let playlists = DataManager.sharedManager.allPlaylists(includeDeleted: false)

        return playlists.filter { playlist -> Bool in
            playlist.autoDownloadEpisodes
        }.count
    }

    private class func nextSortPosition() -> Int32 {
        Int32(DataManager.sharedManager.nextSortPositionForPlaylist())
    }
}

/// Fork: keeps folder-linked smart playlists in step with folder membership. Folder
/// edits on this device and changes arriving via sync both re-materialize the linked
/// playlists' podcast rules (a no-op when nothing moved).
class FolderLinkRefresher: NSObject {
    static let shared = FolderLinkRefresher()

    func setup() {
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: Constants.Notifications.folderChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: ServerNotifications.syncCompleted, object: nil)
        refresh()
    }

    @objc private func refresh() {
        DispatchQueue.global(qos: .utility).async {
            PlaylistManager.refreshFolderLinkedPlaylists()
        }
    }
}
