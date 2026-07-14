import CarPlay
import Foundation
import PocketCastsDataModel
import PocketCastsUtils

// MARK: - Sessions tab (fork)
//
// The Sessions tab is a world switcher as much as a browser. Playback lives in one of two
// "worlds": the Up Next queue, or a Session that plays off to the side (see PlaybackManager's
// startPlaybackSession / endPlaybackSession). This tab lets you pick which world owns playback
// and makes it obvious which one currently does — the active row carries the playing indicator
// and a "Now Playing" subtitle.
extension CarPlaySceneDelegate {

    /// A session paired with its store playlist, most-recently-used first (the Inbox is not a
    /// session and never appears here).
    private var sessionRows: [(session: Session, store: EpisodeFilter)] {
        SessionStore.shared.sessions
            .filter { $0.uuid != SessionStore.globalInboxUuid }
            .sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
            .compactMap { session in
                guard let storeUuid = session.storePlaylistUuid,
                      let store = DataManager.sharedManager.findPlaylist(uuid: storeUuid) else { return nil }
                return (session, store)
            }
    }

    /// True while a session (not the queue) owns playback.
    private var sessionWorldActive: Bool {
        Settings.playbackSession() != nil && !Settings.playbackSessionPaused()
    }

    var sessionTabSections: [CPListSection] {
        let activeStoreUuid = sessionWorldActive ? Settings.playbackSession()?.uuid : nil

        // The queue as a world you can return to. Marked as playing when nothing has pulled
        // playback into a session.
        let upNextItem = CPListItem(text: L10n.upNext,
                                    detailText: activeStoreUuid == nil ? L10n.nowPlaying : nil,
                                    image: UIImage(named: "car_upnext"))
        upNextItem.isPlaying = activeStoreUuid == nil && PlaybackManager.shared.currentEpisode() != nil
        upNextItem.playingIndicatorLocation = .trailing
        upNextItem.handler = { [weak self] _, completion in
            self?.switchToUpNextWorld()
            completion()
        }

        var sessionItems = [CPListItem]()
        for row in sessionRows {
            let isActive = row.store.uuid == activeStoreUuid
            let remaining = SessionFeederEngine.storeMemberUuids(for: row.session).count
            let detail = isActive ? L10n.nowPlaying : L10n.episodeCountPluralFormat(remaining.localized())
            let item = CPListItem(text: row.store.playlistName, detailText: detail, image: row.store.grid())
            item.isPlaying = isActive
            item.playingIndicatorLocation = .trailing
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                self?.sessionTapped(session: row.session, store: row.store)
                completion()
            }
            sessionItems.append(item)
        }

        return [
            CPListSection(items: [upNextItem], header: L10n.upNext, sectionIndexTitle: nil),
            CPListSection(items: sessionItems, header: L10n.carplaySessionsTab, sectionIndexTitle: nil)
        ]
    }

    func createSessionsTab() -> CPListTemplate {
        CarPlayListData.template(title: L10n.carplaySessionsTab, emptyTitle: L10n.carplayNoSessions, image: UIImage(systemName: "play.square.stack")) { [weak self] in
            self?.sessionTabSections
        }
    }

    // MARK: - Drill-in + world switching

    /// Opens a session's lineup: a "Play Session" row that hands playback to this session's world,
    /// followed by its episodes (tapping one plays it within the session, not Up Next).
    private func sessionTapped(session: Session, store: EpisodeFilter) {
        let listTemplate = CarPlayListData.template(title: store.playlistName, emptyTitle: L10n.sessionEmptyToast) { [weak self] in
            guard let self else { return nil }

            let playItem = CPListItem(text: L10n.playlistPlayAsSession, detailText: nil, image: UIImage(named: "car_filter_play"))
            playItem.handler = { [weak self] _, completion in
                self?.switchToSession(session, store: store)
                completion()
            }

            let episodes: [BaseEpisode] = DataManager.sharedManager.playlistEpisodes(for: store, limit: Constants.Limits.maxCarplayItems)
            let episodeItems = self.convertToListItems(episodes: episodes, showArtwork: true, playlist: .filter(uuid: store.uuid), session: session)

            return [CPListSection(items: [playItem]), CPListSection(items: episodeItems)]
        }
        interfaceController?.push(listTemplate)
    }

    /// Hands playback to a session's world, mirroring the app's Switch Session sheet: start it if
    /// it isn't the active session, resume it if it's parked, otherwise just play.
    func switchToSession(_ session: Session, store: EpisodeFilter) {
        AnalyticsPlaybackHelper.shared.currentSource = .carPlay
        let target = PlaybackSession(type: .playlist, uuid: store.uuid)
        SessionStore.shared.markUsed(playbackUuid: store.uuid)

        if target != Settings.playbackSession() {
            SessionManager.shared.play(session: session) // guards empty, then startPlaybackSession
        } else if Settings.playbackSessionPaused() {
            if let episode = target.nextEpisode(after: nil) {
                PlaybackManager.shared.play(sessionEpisode: episode)
            }
        } else if !PlaybackManager.shared.playing() {
            PlaybackManager.shared.play()
        }
        interfaceController?.showNowPlaying()
    }

    /// Returns playback to the Up Next queue, mirroring the app's Switch Session sheet.
    func switchToUpNextWorld() {
        AnalyticsPlaybackHelper.shared.currentSource = .carPlay
        if Settings.playbackSession() != nil {
            PlaybackManager.shared.endPlaybackSession()
        }
        if !PlaybackManager.shared.playing() {
            if PlaybackManager.shared.currentEpisode() != nil {
                PlaybackManager.shared.play()
            } else if let first = PlaybackManager.shared.queue.allEpisodes(includeNowPlaying: false).first {
                PlaybackManager.shared.load(episode: first, autoPlay: true, overrideUpNext: false)
            }
        }
        interfaceController?.showNowPlaying()
    }

    /// Plays an episode inside a session's world (keeps the session as the playback source).
    func playEpisodeInSession(_ episode: BaseEpisode, session: Session) {
        AnalyticsPlaybackHelper.shared.currentSource = .carPlay
        SessionManager.shared.play(episode: episode, in: session)
        interfaceController?.showNowPlaying()
    }
}
