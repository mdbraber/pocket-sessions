import PocketCastsDataModel
import PocketCastsUtils

extension PlaylistDetailViewController: UISheetPresentationControllerDelegate, PlaylistPlayAllSheetHostDelegate {
    func playAll() {
        if viewModel.episodes.isEmpty, viewModel.session == nil {
            Toast.show(L10n.playlistManualPlayAllEmptyList)
            return
        }

        track(.filterPlayAllTapped)

        // Play All starts a playback session: the playlist plays instead of the queue, and
        // playback returns to the untouched queue when it runs out. The stock replace-the-
        // queue flow below stays intact but unused while the flag is on.
        if FeatureFlag.playbackSessions.enabled {
            let playlist = viewModel.playlist

            // Fork: Play as Session is about the session's lineup, nothing else —
            // the Inbox and Episodes views never leak in. Sessions are created
            // empty on first use; an empty lineup hints instead of playing.
            if let session = viewModel.session {
                SessionManager.shared.play(session: session)
                return
            }
            if !playlist.manual {
                SessionManager.shared.play(session: SessionManager.shared.findOrCreateSession(forSmartPlaylist: playlist))
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
        // Recency for the Switch Session sheet.
        SessionStore.shared.markUsed(playbackUuid: playlist.uuid)
        PlaybackManager.shared.startPlaybackSession(PlaybackSession(type: playlist.manual ? .playlist : .smartPlaylist, uuid: playlist.uuid))
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
