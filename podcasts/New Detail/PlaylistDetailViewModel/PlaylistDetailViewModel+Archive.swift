import PocketCastsDataModel

extension PlaylistDetailViewModel {
    var shouldShowArchived: Bool {
        playlist.showArchivedEpisodes
    }

    var shouldShowArchivePlaceholder: Bool {
        archivedEpisodesCount > 0 && !shouldShowArchived
    }

    var shouldShowEmptyPlaceholder: Bool {
        // Fork: sessions keep their full chrome (header, tabs, feeder) — emptiness
        // renders as a row inside the selected tab. Only plain manual playlists get
        // the whole-screen Add Episodes state.
        episodes.isEmpty && !shouldShowArchivePlaceholder && isManualPlaylist && session == nil
    }

    func unarchivedEpisodesCount() -> Int {
        dataManager.playlistEpisodeCount(
            for: playlist,
            episodeUuidToAdd: playlist.episodeUuidToAddToQueries()
        )
    }

    func updateShowArchivedEpisodes(show: Bool) {
        playlist.showArchivedEpisodes = show
        dataManager.save(playlist: playlist)
    }
}
