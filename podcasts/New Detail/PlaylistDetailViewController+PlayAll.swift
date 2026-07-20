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
        // playback returns to the untouched queue when it runs out.
        let playlist = viewModel.playlist

        // Fork: Play as Session is about the session's lineup, nothing else —
        // the Inbox and Episodes views never leak in. Sessions are created
        // empty on first use; an empty lineup hints instead of playing.
        if let session = viewModel.session {
            SessionManager.shared.play(session: session)
            return
        }
        // Opted-out smart playlists have no session — they fall through to stock Play All.
        if viewModel.isLensPage, let session = SessionManager.shared.findOrCreateSession(forSmartPlaylist: playlist) {
            SessionManager.shared.play(session: session)
            return
        }

        startSession()
    }

    private func startSession() {
        let playlist = viewModel.playlist
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
