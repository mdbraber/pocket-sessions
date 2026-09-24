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

    /// Fork: "Queue Session" — makes this the TOP session on the Queue page (the next one up) WITHOUT
    /// starting playback. It resolves/creates the session, then floats it to the front of the session
    /// order so it lands at the top of the session list; whatever is currently playing keeps playing.
    func queueSession() {
        let resolved: Session?
        if let existing = viewModel.session {
            resolved = existing
        } else if viewModel.isLensPage {
            resolved = SessionManager.shared.findOrCreateSession(forSmartPlaylist: viewModel.playlist)
        } else {
            resolved = nil
        }
        guard let session = resolved else { return }

        // Float it to the front of the session order (its sortIndex becomes 0), so the Queue page
        // shows it at the top of the session list. Keep every other session's relative order.
        let order = [session.uuid] + SessionStore.shared.sessions.map(\.uuid).filter { $0 != session.uuid }
        SessionStore.shared.reorderSessions(order)

        Toast.show(L10n.playlistQueueSessionToast)
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
