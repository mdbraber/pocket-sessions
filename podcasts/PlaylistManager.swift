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

        if playlist.manual {
            handleManualPlaylistDeleted(playlistUuid: playlist.uuid)
        }

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

    /// Fork rules: when a folder is deleted, drop it from every smart playlist's folder
    /// rule — mirroring what handlePodcastUnsubscribed does for the podcast rule.
    class func handleFolderDeleted(folderUuid: String) {
        for playlist in DataManager.sharedManager.allSmartPlaylists(includeDeleted: false) where !playlist.folderUuids.isEmpty {
            var uuids = playlist.folderUuids.components(separatedBy: ",")
            guard let index = uuids.firstIndex(of: folderUuid) else { continue }

            uuids.remove(at: index)
            playlist.folderUuids = uuids.joined(separator: ",")
            if uuids.isEmpty { playlist.foldersExcluded = false }
            DataManager.sharedManager.save(playlist: playlist)
        }
    }

    /// Fork rules: when a manual playlist is deleted, drop it from every smart playlist's
    /// playlist rule.
    class func handleManualPlaylistDeleted(playlistUuid: String) {
        for playlist in DataManager.sharedManager.allSmartPlaylists(includeDeleted: false) where !playlist.manualPlaylistUuids.isEmpty {
            var uuids = playlist.manualPlaylistUuids.components(separatedBy: ",")
            guard let index = uuids.firstIndex(of: playlistUuid) else { continue }

            uuids.remove(at: index)
            playlist.manualPlaylistUuids = uuids.joined(separator: ",")
            if uuids.isEmpty { playlist.manualPlaylistsExcluded = false }
            DataManager.sharedManager.save(playlist: playlist)
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
