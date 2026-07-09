import PocketCastsDataModel
import PocketCastsUtils

extension PlaylistDetailViewController: UISheetPresentationControllerDelegate, PlaylistPlayAllSheetHostDelegate {
    func playAll() {
        if viewModel.episodes.isEmpty {
            Toast.show(L10n.playlistManualPlayAllEmptyList)
            return
        }

        track(.filterPlayAllTapped)

        // Play All starts a playback session: the playlist plays instead of the queue, and
        // playback returns to the untouched queue when it runs out. The stock replace-the-
        // queue flow below stays intact but unused while the flag is on.
        if FeatureFlag.playbackSessions.enabled {
            let playlist = viewModel.playlist

            // Sessions play the Lineup; with an empty Lineup and everything still in New,
            // silently playing untriaged episodes would contradict the inbox model — ask.
            if playlist.usesCustomOrderOverlay, viewModel.lineupEpisodes.isEmpty, !viewModel.inboxEpisodes.isEmpty {
                presentEmptyLineupPlayPicker()
                return
            }

            startSession()
            return
        }

        let playlistEpisodeIDs = viewModel.episodes.map { $0.episode.uuid }
        if !PlaybackManager.shared.playIfSafe(playlist: viewModel.playlist, episodeIDs: playlistEpisodeIDs) {
            let sheet = PlaylistPlayAllSheetHost(delegate: self)
            present(sheet, animated: true)
        }
    }

    private func startSession() {
        let playlist = viewModel.playlist
        PlaybackManager.shared.startPlaybackSession(PlaybackSession(type: playlist.manual ? .playlist : .smartPlaylist, uuid: playlist.uuid))
    }

    /// The Lineup is empty and every episode sits in New: offer to triage the lot into the
    /// Lineup before playing, or play the on-screen order as-is (the session's fallback).
    private func presentEmptyLineupPlayPicker() {
        let optionsPicker = OptionsPicker(title: L10n.playlistEmptyLineupTitle(viewModel.inboxEpisodes.count.localized()).localizedUppercase)

        optionsPicker.addAction(action: OptionAction(label: L10n.playlistEmptyLineupAddAllAndPlay, icon: "filter_play") { [weak self] in
            guard let self else { return }
            self.viewModel.addToLineup(episodeUuids: self.viewModel.inboxEpisodes.map { $0.episode.uuid })
            self.startSession()
        })

        optionsPicker.addAction(action: OptionAction(label: L10n.playlistEmptyLineupPlayAsIs, icon: "filter_play") { [weak self] in
            self?.startSession()
        })

        optionsPicker.present(from: self)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        track(.filterPlayAllDismissed)
    }

    func onTapSaveAndReplace() {
        presentedViewController?.dismiss(animated: true)

        track(
            .filterPlayAllReplaceAndPlayTapped,
            properties: [
                "save_up_next": Settings.saveCurrentUpNextQueueIntoPlaylist
            ]
        )

        if Settings.saveCurrentUpNextQueueIntoPlaylist {
            viewModel.saveUpNextAndPlay()
            return
        }

        viewModel.playAllEpisodes()
    }
}
