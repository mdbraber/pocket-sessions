import CarPlay
import Foundation
import PocketCastsDataModel
import PocketCastsUtils

// MARK: - Queue tab (fork)
//
// The Queue tab is the world switcher — CarPlay has no separate Sessions tab. Playback lives
// in one of two "worlds": the Up Next queue, or a Session that plays off to the side (see
// PlaybackManager's startPlaybackSession / endPlaybackSession). The tab shows Up Next first,
// the most recent session under it as a tile row, and every remaining session below that —
// every row hands playback over on tap, and the active world carries the playing indicator
// and a "Now Playing" subtitle.
extension CarPlaySceneDelegate {

    /// A session paired with its store playlist, in the phone chooser's order and honouring
    /// its "Show" toggles — `SessionListRows` is the single source of truth for which
    /// sessions exist and how they're ordered (it already drops the global Inbox, the hidden
    /// feeder stores, and sessions whose store playlist is gone).
    private var sessionRows: [(session: Session, store: EpisodeFilter)] {
        SessionListRows.current(sort: .recentlyPlayed, filters: .current)
            .compactMap { row in
                guard let session = SessionStore.shared.session(uuid: row.sessionUuid),
                      let storeUuid = row.storeUuid,
                      let store = DataManager.sharedManager.findPlaylist(uuid: storeUuid) else { return nil }
                return (session, store)
            }
    }

    /// True while a session (not the queue) owns playback.
    private var sessionWorldActive: Bool {
        Settings.playbackSession() != nil && !Settings.playbackSessionPaused()
    }

    /// The one tab that carries every world: two tile rows — Up Next and the most recent
    /// session, in whichever order `worldSections` puts them — then every other session as a
    /// plain switch row. The two tile rows are ONE image-row item each — the title line carries CarPlay's standard chevron
    /// and drills into that world's full episode list, with its episodes as artwork tiles
    /// beneath (tap a tile to play it in that world).
    var queueTabSections: [CPListSection] {
        let rows = sessionRows
        // "Most recent" is the chooser's first row, not the playback pointer: the session you
        // last listened to still leads the tab when nothing is playing at all.
        let current = rows.first

        // The playing episode belongs to whichever world owns playback — while a session
        // plays, it must NOT appear under Up Next.
        let queueEpisodes = PlaybackManager.shared.allEpisodesInQueue(includeNowPlaying: !sessionWorldActive)
        let upNextItem = worldTilesItem(title: L10n.upNext,
                                        episodes: Array(queueEpisodes.prefix(8)),
                                        onTileTap: { [weak self] episode in self?.episodeTapped(episode) },
                                        onRowTap: { [weak self] in self?.upNextTapped(showNowPlaying: true) })
        let upNextSection = CPListSection(items: [upNextItem])

        var sessionSection: CPListSection?
        if let current {
            let lineup: [BaseEpisode] = DataManager.sharedManager.playlistEpisodes(for: current.store, limit: 8)
            let item = worldTilesItem(title: current.store.playlistName,
                                      episodes: lineup,
                                      onTileTap: { [weak self] episode in self?.playEpisodeInSession(episode, session: current.session) },
                                      onRowTap: { [weak self] in self?.sessionEpisodesTapped(session: current.session, store: current.store) })
            sessionSection = CPListSection(items: [item])
        }

        var sections = worldSections(upNext: upNextSection, session: sessionSection, leaderStoreUuid: current?.store.uuid)

        let others = rows.dropFirst().prefix(Constants.Limits.maxCarplayItems)
        if !others.isEmpty {
            let items: [CPListTemplateItem] = others.map(switchRow)
            sections.append(CPListSection(items: items))
        }
        return sections
    }

    /// Whichever world you're in leads: while a session owns playback its tile row sits on
    /// top, otherwise Up Next does and the most recent session follows. Nothing else about
    /// the two rows changes — only which of them you reach first.
    private func worldSections(upNext: CPListSection, session: CPListSection?, leaderStoreUuid: String?) -> [CPListSection] {
        guard let session else { return [upNext] }
        // The swap needs the leading row to BE the session that owns playback. A parked
        // pointer still counts as the session world, but the most-recent row can be a
        // different session — promoting that one would put a session you aren't in on top.
        let leads = sessionWorldActive && leaderStoreUuid == Settings.playbackSession()?.uuid
        return leads ? [session, upNext] : [upNext, session]
    }

    /// One world as one item: title line (standard chevron, opens the details list) with the
    /// episode tiles directly beneath it.
    private func worldTilesItem(title: String, episodes: [BaseEpisode], onTileTap: @escaping (BaseEpisode) -> Void, onRowTap: @escaping () -> Void) -> CPListImageRowItem {
        let images = episodes.map { CarPlayImageHelper.imageForEpisode($0, maxSize: CPListImageRowItem.maximumImageSize) }
        let item = CPListImageRowItem(text: title, images: images)
        item.listImageRowHandler = { _, index, completion in
            if let episode = episodes[safe: index] { onTileTap(episode) }
            completion()
        }
        item.handler = { _, completion in
            onRowTap()
            completion()
        }
        return item
    }


    /// The session's full episode list: a "Play Session" row that hands playback to this
    /// session's world, then its episodes (tapping one plays it within the session).
    private func sessionEpisodesTapped(session: Session, store: EpisodeFilter) {
        let listTemplate = CarPlayListData.template(title: store.playlistName, emptyTitle: L10n.sessionEmptyToast) { [weak self] in
            guard let self else { return nil }

            let episodes: [BaseEpisode] = DataManager.sharedManager.playlistEpisodes(for: store, limit: Constants.Limits.maxCarplayItems)
            let episodeItems = self.convertToListItems(episodes: episodes, showArtwork: true, playlist: .filter(uuid: store.uuid), session: session)

            // "Play Session" only offers a switch — once this session already owns playback
            // there is nothing to switch to, so the row hides.
            let isPlaying = self.sessionWorldActive && Settings.playbackSession()?.uuid == store.uuid
            guard !isPlaying else { return [CPListSection(items: episodeItems)] }

            let playItem = CPListItem(text: L10n.playlistPlayAsSession, detailText: nil, image: UIImage(named: "car_filter_play"))
            playItem.handler = { [weak self] _, completion in
                self?.switchToSession(session, store: store)
                completion()
            }

            return [CPListSection(items: [playItem]), CPListSection(items: episodeItems)]
        }
        interfaceController?.push(listTemplate)
    }

    /// One session as a plain row: tap hands playback over.
    private func switchRow(for row: (session: Session, store: EpisodeFilter)) -> CPListItem {
        let isActive = sessionWorldActive && row.store.uuid == Settings.playbackSession()?.uuid
        let remaining = SessionFeederEngine.storeMemberUuids(for: row.session).count
        let detail = isActive ? L10n.nowPlaying : L10n.episodeCountPluralFormat(remaining.localized())
        let item = CPListItem(text: row.store.playlistName, detailText: detail, image: row.store.grid())
        item.isPlaying = isActive
        item.playingIndicatorLocation = .trailing
        item.handler = { [weak self] _, completion in
            self?.switchToSession(row.session, store: row.store)
            completion()
        }
        return item
    }

    func createQueueTab() -> CPListTemplate {
        CarPlayListData.template(title: L10n.upNext, emptyTitle: L10n.carplayNoSessions, image: UIImage(systemName: "rectangle.stack")) { [weak self] in
            self?.queueTabSections
        }
    }

    // MARK: - World switching

    /// Hands playback to a session's world, mirroring the app's Switch Session sheet: start it if
    /// it isn't the active session, resume it if it's parked, otherwise just play.
    func switchToSession(_ session: Session, store: EpisodeFilter) {
        AnalyticsPlaybackHelper.shared.currentSource = .carPlay
        let target = PlaybackSession(type: .playlist, uuid: store.uuid)
        // Recency is stamped when audio starts (SessionManager.sessionPlaybackStarted) —
        // CarPlay's switch always plays, so it needs no stamp of its own.

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

    // MARK: - Now Playing world switcher

    /// A Now Playing button that opens the same switcher the Queue tab shows — Up Next, the
    /// current session, then the recent sessions; tap to hand playback over. Nil when no
    /// session exists, because a one-row "Up Next" picker would switch nothing.
    func worldSwitchButton() -> CPNowPlayingButton? {
        guard !sessionRows.isEmpty, let image = UIImage(systemName: "rectangle.stack") else { return nil }
        return CPNowPlayingImageButton(image: image) { [weak self] _ in
            DispatchQueue.main.async { self?.presentWorldSwitcher() }
        }
    }

    /// Switching pops straight back to Now Playing (showNowPlaying pops-to, since it's in the
    /// stack beneath this list).
    private func presentWorldSwitcher() {
        let template = CarPlayListData.template(title: L10n.playbackSessionSwitchShort, emptyTitle: L10n.carplayNoSessions) { [weak self] in
            self?.queueTabSections
        }
        interfaceController?.push(template)
    }
}
