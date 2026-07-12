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

            // Fork: a smart playlist plays through its session — the query stays the
            // visible feeder; the store is created lazily and seeded with the current
            // matches in the current order.
            if !playlist.manual, viewModel.session == nil {
                let seed = viewModel.episodes.map { $0.episode.uuid }
                let session = SessionManager.shared.findOrCreateSession(forSmartPlaylist: playlist, seedEpisodeUuids: seed)
                SessionManager.shared.play(session: session, fallbackSeed: seed)
                return
            }

            // Sessions play the Lineup. An empty lineup would make the session start
            // silently no-op — offer the inbox, or say there's nothing to play.
            if let session = viewModel.session, SessionFeederEngine.storeMemberUuids(for: session).isEmpty {
                let offers = SessionFeederEngine.inboxEpisodes(for: session)
                if offers.isEmpty {
                    Toast.show(L10n.playlistManualPlayAllEmptyList)
                } else {
                    presentEmptyLineupPlayPicker(offerUuids: offers.map(\.uuid))
                }
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

    /// The Lineup is empty and everything sits in the Inbox: offer to triage the lot
    /// into the Lineup and play.
    private func presentEmptyLineupPlayPicker(offerUuids: [String]) {
        let optionsPicker = OptionsPicker(title: L10n.playlistEmptyLineupTitle(offerUuids.count.localized()).localizedUppercase)

        optionsPicker.addAction(action: OptionAction(label: L10n.playlistEmptyLineupAddAllAndPlay, icon: "filter_play") { [weak self] in
            guard let self else { return }
            self.viewModel.addToLineup(episodeUuids: offerUuids)
            self.startSession()
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
