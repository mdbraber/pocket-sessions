import PocketCastsDataModel

extension PlaylistDetailViewModel {
    /// Fork: archived visibility is a Filter Preset rule now, not a column on the playlist.
    /// nil ("don't care") and true ("archived only") both show archived; only false hides them.
    var shouldShowArchived: Bool {
        FilterPresets.active().archived != false
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

    /// Fork: the Show/Hide Archived toggle edits the active preset's `archived` rule — one place
    /// where archived visibility lives, for every list.
    func updateShowArchivedEpisodes(show: Bool) {
        var preset = FilterPresets.active()
        preset.archived = show ? nil : false
        FilterPresetStore.shared.upsert(preset)
        reloadEpisodeList(animated: false)
    }
}
