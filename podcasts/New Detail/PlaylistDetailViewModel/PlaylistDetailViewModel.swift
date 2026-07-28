import Foundation
import Combine
import PocketCastsDataModel
import PocketCastsUtils
import DifferenceKit

class PlaylistDetailViewModel: ObservableObject {
    let playlistMetadataLoader = PlaylistMetadataLoader.shared

    typealias DataSourceValue = [ArraySection<Section, ListItem>]

    enum Section: String, ContentEquatable, ContentIdentifiable {
        case header
        case archive
        case episodes
        /// Fork: the session page's Episodes tab — the feeder's full domain, browsed
        /// without triage semantics.
        case browse

        func isContentEqual(to source: Section) -> Bool {
            self == source
        }
    }

    /// Fork: which tab of a session page is shown — Session (the hand-ordered plays-next
    /// list) or Episodes (the feeder's full domain). There is no Inbox tab: unseen episodes
    /// are not partitioned off, they carry the unread dot in the Episodes list.
    enum TriageTab {
        case lineup
        case browse

        /// The tab's per-page sort key.
        var sortKey: TriageTabSort.Tab {
            switch self {
            case .lineup: return .session
            case .browse: return .episodes
            }
        }
    }

    /// Pages open on Episodes; only explicit navigation (`pendingInitialTab`) opens the Session tab.
    @Published var selectedTriageTab: TriageTab = .browse
    @Published private(set) var triageLineupCount = 0
    private(set) var triageLineupDuration: TimeInterval = 0
    private(set) var triageBrowseCount = 0
    private(set) var triageBrowseDuration: TimeInterval = 0

    /// The preset scope for this page — always the Episodes scope. The Session lineup is a
    /// hand-made list that presets never narrow (matching the podcast page's Session tab),
    /// so the funnel only ever shows on, and edits, the Episodes/Browse views.
    var filterScope: FilterScope { .episodes }

    /// Fork: the active Filter Preset for the current tab.
    var activePreset: FilterPreset { FilterPresets.active(filterScope) }

    /// True when the current tab's preset genuinely narrows — drives the control's accent.
    var isPresetNarrowing: Bool { FilterPresets.isNarrowing(filterScope) }

    /// The full fetched list, regardless of the selected tab - the header artwork
    /// always reflects the whole playlist.
    private(set) var allOverlayEpisodes: [ListEpisode] = []

    /// Fork: THIS page's own session store members (empty on pages with no session). The in-session
    /// badge is full-brightness for these and half-brightness for episodes in *other* sessions.
    private(set) var thisSessionMemberUuids: Set<String> = []

    /// The badge state for an episode on this page: in-this-session / in-another-session / none.
    func sessionIndicatorState(for episodeUuid: String) -> SessionIndicatorState {
        SessionIndicatorState.resolve(episodeUuid, thisSession: thisSessionMemberUuids)
    }
    /// Inbox membership — the unread dot. Fetched ONCE per section build; the cell reads the Set.
    private(set) var unseenUuidsForDisplay: Set<String> = []

    /// The last fetch's episodes — lets tab switches rebuild sections instantly
    /// instead of waiting for the async fetch (which still follows for freshness).
    private var lastFetchedEpisodes: [ListEpisode] = []

    func selectTriageTab(_ tab: TriageTab) {
        guard selectedTriageTab != tab else { return }
        selectedTriageTab = tab

        // Instant: the new tab renders from data already in hand, so the table never
        // sits on the previous tab's rows.
        let changeSetTuple = buildChangeSet(source: episodes, newData: lastFetchedEpisodes)
        onChange(changeSetTuple.1, false, changeSetTuple.0)

        // Freshness pass (engine sets, counts) in the background.
        reloadEpisodeList(animated: false)
    }

    enum ButtonTag {
        case smartRules
        case addEpisodes
        case playAll
        case queueSession
        case playlistFolder
        case playlistSettings
    }

    /// Fork: "Queue Session" — an outline button beside "Play Session" that floats this session to the
    /// TOP of the session list on the Queue page (without playing). Needs a real session behind the
    /// page: an existing one (manual session store) or a lens that can create one.
    var showsQueueSession: Bool {
        session != nil || isLensPage
    }

    let onButtonTapped: (ButtonTag) -> Void
    let dataManager: DataManager
    let episodesDataManager: EpisodesDataManager

    /// All visible episodes in display order.
    var episodes: [ListEpisode] {
        dataSource
            .filter { $0.model == .episodes }
            .flatMap { $0.elements.compactMap { $0 as? ListEpisode } }
    }

    /// Fork: the positioned episodes (the "Lineup").
    var lineupEpisodes: [ListEpisode] {
        dataSource.first(where: { $0.model == .episodes })?.elements.compactMap { $0 as? ListEpisode } ?? []
    }

    /// Fork: the session coordinating this playlist as its store, when there is one.
    var session: Session? {
        SessionStore.shared.session(forStore: playlist.uuid)
    }

    /// Fork: kept as the UI's switch for the triage experience — now meaning "this
    /// playlist is a session's store".
    var usesCustomOrderOverlay: Bool {
        session != nil
    }

    var sessionAutoAdd: Bool {
        session?.autoAdd ?? false
    }

    /// Fork: smart playlist (lens) pages carry the same triage tabs — the lens itself
    /// is the feeder; its session's store lives elsewhere and may not exist yet.
    /// A smart playlist that opted out of being a session playlist is NOT a lens page — it
    /// renders as a plain smart playlist: no triage tabs, no Play Session, no session rows in
    /// the ⋯ menu, and nothing here lazily creates a session for it.
    var isLensPage: Bool { !isManualPlaylist && !Settings.playlistOptedOutOfSession(uuid: playlist.uuid) }

    /// Nil once the playlist opts out of being a session playlist, even if a session still
    /// exists from before — the page must show no trace of it. The session itself is untouched.
    var lensSession: Session? {
        guard isLensPage else { return nil }
        return SessionStore.shared.session(forSmartPlaylistFeeder: playlist.uuid)
    }

    /// The feeder used to compute lens-page offers before a session exists.
    var lensFeederSession: Session {
        lensSession ?? Session(uuid: "lens-inbox-preview", storePlaylistUuid: nil, feeder: .smartPlaylist(uuid: playlist.uuid))
    }

    /// Fork: pages showing the Inbox | Session | Episodes strip.
    var usesTriageTabs: Bool { session != nil || isLensPage }

    /// Fork: the header's play button normally plays the SESSION lineup. A smart playlist that
    /// opted out of being a session playlist has no session to play, so it reads (and behaves
    /// as) stock Play All. Manual playlists are unaffected.
    var playAllButtonTitle: String {
        (!isManualPlaylist && !isLensPage) ? L10n.playAll : L10n.playlistPlayAsSession
    }

    /// Every episode that belongs to any session's store — the "in a session" badge set. Memoized
    /// (see `SessionMembership`) so it isn't re-queried on every reload.
    var inAnySessionUuids: Set<String> { SessionMembership.shared.inAnySession }

    /// The episode backing a table row, resilient to placeholder rows (empty states)
    /// sharing a section with episodes.
    func listEpisode(at indexPath: IndexPath) -> ListEpisode? {
        dataSource[safe: indexPath.section]?.elements[safe: indexPath.row] as? ListEpisode
    }

    func section(at index: Int) -> Section? {
        dataSource[safe: index]?.model
    }

    /// Fork: synchronously moves an element within the episodes section, keeping the
    /// table's data source consistent during an inline drag reorder. Persistence
    /// happens separately after the drop.
    func moveLineupElement(from sourceRow: Int, to destinationRow: Int) {
        guard let index = dataSource.firstIndex(where: { $0.model == .episodes }) else { return }
        var elements = dataSource[index].elements
        guard let element = elements[safe: sourceRow] else { return }
        elements.remove(at: sourceRow)
        elements.insert(element, at: min(destinationRow, elements.count))
        dataSource[index] = ArraySection(model: .episodes, elements: elements)
    }

    /// Fork: persists the lineup exactly as currently displayed (after a cross-section
    /// drag), then reloads so sections rebuild (e.g. an emptied inbox disappears).
    func commitLineupOrder() {
        let order = lineupEpisodes.map { $0.episode.uuid }
        if let session = session ?? lensSession {
            // Store pages write their own session; lens pages write the fed one.
            SessionManager.shared.setLineupOrder(episodeUuids: order, session: session)
        } else {
            dataManager.setCustomOrder(episodeUuids: order, for: playlist)
        }
        reloadEpisodeList()
    }

    var isManualPlaylist: Bool {
        playlist.manual
    }

    // Fork: Group By — a per-playlist display preference for the Episodes tab. It is no longer
    // session-backed: the Session tab renders its lineup in play order and never groups, so the
    // Session model dropped groupBy/groupLimit entirely.
    var groupBy: EpisodeGroupBy {
        get {
            EpisodeGroupBy(rawValue: UserDefaults.standard.integer(forKey: "SJPlaylistGroupBy-\(playlist.uuid)")) ?? .none
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "SJPlaylistGroupBy-\(playlist.uuid)")
            reloadEpisodeList(animated: false)
        }
    }

    /// Episodes per group; 0 means no limit.
    var groupLimit: Int {
        get {
            UserDefaults.standard.integer(forKey: "SJPlaylistGroupLimit-\(playlist.uuid)")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "SJPlaylistGroupLimit-\(playlist.uuid)")
            reloadEpisodeList(animated: false)
        }
    }

    /// Reverses the order the groups appear in (items inside each group keep their sort).
    var reverseGroup: Bool {
        get {
            UserDefaults.standard.bool(forKey: "SJPlaylistReverseGroup-\(playlist.uuid)")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "SJPlaylistReverseGroup-\(playlist.uuid)")
            reloadEpisodeList(animated: false)
        }
    }

    /// Interleaves Group By heading rows (and applies the group limit) in display order.
    private func groupedElements(_ episodes: [ListEpisode]) -> [ListItem] {
        guard groupBy != .none || groupLimit > 0 else { return episodes }
        return EpisodeGrouper.group(episodes, by: groupBy, limit: groupLimit, reversed: reverseGroup) { $0.episode }
            .flatMap { group -> [ListItem] in
                guard let title = group.title else { return group.items }
                let header = PlaylistGroupHeaderPlaceholder(title: title, target: Self.groupNavTarget(groupBy: groupBy, in: group.items))
                return [header] + group.items
            }
    }

    /// Fork: the destination behind a Group By header's chevron — resolved from the group's own
    /// episodes. Only Podcast and Folder groupings have a single place to go; a "No Folder" group
    /// (no folder on its podcasts) and every other grouping have none.
    private static func groupNavTarget(groupBy: EpisodeGroupBy, in items: [ListEpisode]) -> PlaylistGroupHeaderPlaceholder.GroupNavTarget? {
        guard let podcast = items.first?.episode.parentPodcast() else { return nil }
        switch groupBy {
        case .podcast:
            return .podcast(uuid: podcast.uuid)
        case .folder:
            guard let folderUuid = podcast.folderUuid, !folderUuid.isEmpty else { return nil }
            return .folder(uuid: folderUuid)
        default:
            return nil
        }
    }

    var hasSubscribedPodcasts: Bool {
        dataManager.podcastCount() > 0
    }

    var isPlaylistFull: Bool {
#if DEBUG
        playlistEpisodesCount >= Settings.debugPlaylistsLimit
#else
        playlistEpisodesCount >= Constants.Limits.maxFilterItems
#endif
    }

    @Published private(set) var dataSource: DataSourceValue = []
    @Published var images: [PlaylistArtworkView.ImageItem] = []
    @Published var playlistEpisodesCount: Int = 0
    @Published var playlistName: String = ""

    private(set) var playlist: EpisodeFilter
    @Published private(set) var isSearching = false
    private(set) var firstTimeLoading = true
    private(set) var archivedEpisodesCount: Int = 0

    private var searchTerm: String = ""
    private var artworkLoadingTask: Task<Void, Never>?
    private let imageManager: ImageManager
    private let onChange: (StagedChangeset<DataSourceValue>, Bool, Bool) -> Void
    private var tempEpisodes: [ListEpisode] = []
    private let artworkImagesLimit = 4

    private lazy var operationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    init(
        playlist: EpisodeFilter,
        dataManager: DataManager = .sharedManager,
        imageManager: ImageManager = .sharedManager,
        episodesDataManager: EpisodesDataManager = .init(),
        onChange: @escaping (StagedChangeset<DataSourceValue>, Bool, Bool) -> Void,
        onButtonTapped: @escaping (ButtonTag) -> Void
    ) {
        self.playlist = playlist
        self.dataManager = dataManager
        self.imageManager = imageManager
        self.episodesDataManager = episodesDataManager
        self.onChange = onChange
        self.onButtonTapped = onButtonTapped
        // Fork: a one-shot initial tab set by navigation (e.g. Go to Session → Session tab).
        if let tab = Self.pendingInitialTab.removeValue(forKey: playlist.uuid) {
            selectedTriageTab = tab
        }
        self.dataSource = makeSections(episodes: [])
    }

    /// Fork: navigation can request the tab a playlist opens on (keyed by uuid, consumed once).
    static var pendingInitialTab: [String: TriageTab] = [:]

    func update(data: DataSourceValue, then block: (() -> Void)? = nil) {
        self.dataSource = data

        artworkLoadingTask?.cancel()

        // Capture the newly updated episodes on the main thread before entering the async task.
        // Artwork comes from the unarchived subset so the Show Archived toggle (which only
        // interleaves archived rows into the same ordering) can't reshuffle it.
        let currentEpisodes = (allOverlayEpisodes.isEmpty ? self.episodes : allOverlayEpisodes)
            .filter { !(($0.episode as? Episode)?.archived ?? false) }
        // Fork: session artwork comes from the feeder (stable); lenses naming podcasts
        // use their rule. Neither shifts with episode order, tabs, or arrivals.
        let rulePodcastUuids: [String] = {
            if let session { return session.artworkPodcastUuids }
            if !isManualPlaylist, !playlist.filterAllPodcasts {
                return playlist.podcastUuids.components(separatedBy: ",").filter { !$0.isEmpty && $0 != "none" }
            }
            return []
        }()

        artworkLoadingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let count = await self.playlistMetadataLoader.loadCount(for: self.playlist)
                if self.isSearching {
                    await MainActor.run {
                        self.playlistEpisodesCount = count
                    }
                } else {
                    let images: [PlaylistArtworkView.ImageItem]
                    if !rulePodcastUuids.isEmpty {
                        images = self.imageItems(forPodcastUuids: rulePodcastUuids)
                    } else {
                        let firstFourDistinct = self.firstDistinctPodcasts(from: currentEpisodes, limit: self.artworkImagesLimit)
                        images = try await self.loadImagesURLs(episodes: firstFourDistinct)
                    }

                    guard !Task.isCancelled else { return }

                    await MainActor.run {
                        // Re-publishing identical images makes the blurred header
                        // backdrop reload and flash (e.g. on triage tab switches).
                        if images != self.images {
                            self.images = images
                        }
                        if count != self.playlistEpisodesCount {
                            self.playlistEpisodesCount = count
                        }
                        block?()
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    block?()
                }
            }
        }
    }

    func update(playlist: EpisodeFilter) {
        self.playlist = playlist
    }

    func reloadPlaylistAndEpisodes() {
        if isSearching, !searchTerm.isEmpty {
            searchEpisodes(for: searchTerm)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if let reloadedPlaylist = DataManager.sharedManager.findPlaylist(uuid: playlist.uuid) {
                playlist = reloadedPlaylist

                DispatchQueue.main.async { [weak self] in
                    self?.playlistName = reloadedPlaylist.playlistName
                }
            }
            reloadEpisodeList(animated: true)
        }
    }

    func reloadEpisodeList(animated: Bool = true) {
        if isSearching, !searchTerm.isEmpty {
            searchEpisodes(for: searchTerm)
            return
        }
        operationQueue.cancelAllOperations()

        let refreshOperation = PlaylistDetailFetchOperation(
            dataManager: dataManager,
            episodesDataManager: episodesDataManager,
            playlist: playlist
        ) { [weak self] newData, archivedEpisodeCount in
            self?.handleFetchCompletion(newData: newData, archivedEpisodeCount: archivedEpisodeCount, animated: animated)
        }
        operationQueue.addOperation(refreshOperation)
    }

    private func handleFetchCompletion(newData: [ListEpisode], archivedEpisodeCount: Int, animated: Bool) {
        archivedEpisodesCount = archivedEpisodeCount
        let isFirstReload = firstTimeLoading
        firstTimeLoading = false
        // Fork: keep the last fetched set so a live session/store change can rebuild the changeset.
        lastFetchedEpisodes = newData
        let changeSetTuple = buildChangeSet(source: episodes, newData: newData)
        let contentHasChanged = changeSetTuple.0
        if contentHasChanged {
            dataManager.updatePlaylistUpdateDate(for: playlist)
        }
        onChange(changeSetTuple.1, animated && !isFirstReload, contentHasChanged)
    }

    func totalDuration() -> String? {
        let totalDuration = episodes.map { $0.episode.duration - $0.episode.playedUpTo }.reduce(0, +)
        if totalDuration <= 0 {
            return nil
        }
        let formattedDuration = TimeFormatter.shared.multipleUnitFormattedShortTime(time: totalDuration)
        return formattedDuration.isEmpty ? nil : formattedDuration
    }

    func delete(episodes uuids: [String]) {
        if let session = session ?? lensSession {
            // Store pages remove from their own session; lens pages from the fed one
            // (removing from the lens playlist itself would be a lineup no-op).
            SessionManager.shared.removeFromLineup(episodeUuids: uuids, session: session)
        } else {
            dataManager.deleteEpisodes(uuids, from: playlist)
        }
    }

    func remove(episode uuid: String, at index: Int) {
        var newData = episodes
        newData.remove(at: index)
        let changeSetTuple = buildChangeSet(source: episodes, newData: newData)
        onChange(changeSetTuple.1, true, changeSetTuple.0)

        delete(episodes: [uuid])
    }

    func updatePlaylist(sortType type: PlaylistSort) {
        if playlist.sortType == type.rawValue { return }
        // Fork: seed the lineup from the currently displayed order when a smart playlist
        // first switches to custom order, so the switch is a visual no-op. Existing rows
        // are kept when switching away, so switching back restores the hand-made order.
        if !isManualPlaylist, type == .dragAndDrop, dataManager.positionedEpisodeUuids(for: playlist).isEmpty {
            playlist.customOrderLastInsertedUuid = ""
            dataManager.setCustomOrder(episodeUuids: episodes.map { $0.episode.uuid }, for: playlist)
        }
        playlist.syncStatus = SyncStatus.notSynced.rawValue
        playlist.sortType = type.rawValue
        dataManager.save(playlist: playlist)
    }

    // MARK: - Fork: custom-order overlay actions

    /// Places episodes into the lineup at the insert marker ("Add to lineup").
    /// Fork: the user-facing Add to Session verb — routes per Settings → Inbox
    /// (all matching sessions / this one / ask), with this page's session preferred.
    func addToSessionsPerSetting(episodeUuids: [String], presenting: UIViewController?) {
        guard !episodeUuids.isEmpty else { return }
        let preferred: Session
        if let session {
            preferred = session
        } else if isLensPage, let lens = SessionManager.shared.findOrCreateSession(forSmartPlaylist: playlist) {
            preferred = lens
        } else {
            addToLineup(episodeUuids: episodeUuids)
            return
        }
        SessionManager.shared.addToSessions(episodeUuids: episodeUuids, preferred: preferred, presenting: presenting) { [weak self] _ in
            self?.reloadEpisodeList(animated: true)
        }
    }

    func addToLineup(episodeUuids: [String]) {
        guard !episodeUuids.isEmpty else { return }
        if let session {
            // Explicit USER add — pinned, so the feeder's prune never removes it.
            SessionManager.shared.addToLineup(episodeUuids: episodeUuids, session: session, pinning: true)
        } else if isLensPage, let session = SessionManager.shared.findOrCreateSession(forSmartPlaylist: playlist) {
            SessionManager.shared.addToLineup(episodeUuids: episodeUuids, session: session, pinning: true)
        } else {
            dataManager.insertIntoCustomOrder(episodeUuids: episodeUuids, for: playlist)
            // Linked adds: one mirrored hop into the queue when enabled.
        SessionLinking.mirrorSessionAdd(episodeUuids: episodeUuids)
    }
        reloadEpisodeList()
    }

    /// The session whose insert mode this page controls — the store's own on a
    /// session page, or the lens's fed session on a smart-playlist page.
    var insertModeSession: Session? {
        session ?? lensSession
    }

    func updatePlaylist(insertMode: PlaylistInsertMode) {
        if var session = insertModeSession {
            guard session.insertMode != insertMode.rawValue else { return }
            session.insertMode = insertMode.rawValue
            SessionStore.shared.upsert(session)
        } else if isLensPage, var session = SessionManager.shared.findOrCreateSession(forSmartPlaylist: playlist) {
            // No fed session yet — create it so the choice sticks (same lazy
            // creation the Session tab does).
            session.insertMode = insertMode.rawValue
            SessionStore.shared.upsert(session)
        } else {
            guard playlist.insertMode != insertMode else { return }
            playlist.insertMode = insertMode
            dataManager.save(playlist: playlist)
        }
        reloadEpisodeList()
    }

    func updatePlaylist(newEpisodesAutoAdd: Bool) {
        guard var session, session.autoAdd != newEpisodesAutoAdd else { return }
        session.autoAdd = newEpisodesAutoAdd
        SessionStore.shared.upsert(session)
        reloadEpisodeList()
    }

    private func buildChangeSet(
        source: [ListEpisode],
        newData: [ListEpisode]
    ) -> (Bool, StagedChangeset<DataSourceValue>) {
        let oldSections = dataSource
        let contentChanged = !source.isContentEqual(to: newData)
        let effectiveEpisodes = contentChanged ? newData : episodes
        let newSections = makeSections(episodes: effectiveEpisodes)

        let changeset = StagedChangeset(
            source: oldSections,
            target: newSections
        )

        let contentHasChanged = !newSections.isContentEqual(to: oldSections) || contentChanged
        return (contentHasChanged, changeset)
    }

    private func makeSections(episodes: [ListEpisode]) -> DataSourceValue {
        var sections: DataSourceValue = [
            ArraySection(model: .header, elements: [PlaylistHeaderViewCellPlaceholder()])
        ]

        if isManualPlaylist, session == nil {
            // The .archive section survives only to anchor the search bar (rendered as its header
            // view). The Show Archived toggle is gone — archived visibility is a Filter Preset rule
            // now, and "All Episodes" includes archived by default.
            sections.append(ArraySection(model: .archive, elements: []))
        }

        // Fork: a session's store splits by tab — Session (the store itself) and Episodes
        // (the feeder's full domain). The fetched episodes ARE the session lineup. Unseen
        // episodes are NOT partitioned out of Episodes: they carry the unread dot instead.
        if let session, !isSearching {
            let tint = AppTheme.appTintColor()
            let lineup = episodes
            allOverlayEpisodes = episodes
            // This page IS a session store; its members are "in this session" (full brightness).
            thisSessionMemberUuids = Set(lineup.map { $0.episode.uuid })
            unseenUuidsForDisplay = InboxManager.shared.unseenUuids()

            triageLineupCount = lineup.count
            triageLineupDuration = lineup.reduce(0.0) { $0 + max(0, $1.episode.duration - $1.episode.playedUpTo) }

            var shown: [ListEpisode]
            let model: Section
            switch selectedTriageTab {
            case .lineup:
                // The lineup is a hand-made list — presets never narrow it (matching the
                // podcast page's Session tab); they shape the Browse view only.
                shown = lineup
                model = .episodes
            case .browse:
                shown = SessionFeederEngine.domainEpisodes(for: session, preset: activePreset)
                    .map { ListEpisode(episode: $0, tintColor: tint) }
                model = .browse
            }
            // Fork: the tab's per-page sort.
            shown = TriageTabSort.arrange(shown, tab: selectedTriageTab.sortKey, pageUuid: playlist.uuid)
            if selectedTriageTab == .browse {
                triageBrowseCount = shown.count
                triageBrowseDuration = shown.reduce(0.0) { $0 + max(0, $1.episode.duration - $1.episode.playedUpTo) }
            }
            // Group By shapes the Inbox and Episodes views; the Session lineup is
            // hand-ordered and never grouped.
            let elements: [ListItem]
            if shown.isEmpty {
                elements = [PlaylistTabEmptyPlaceholder()]
            } else if selectedTriageTab == .lineup {
                elements = shown
            } else {
                elements = groupedElements(shown)
            }
            sections.append(ArraySection(model: model, elements: elements))
            return sections
        }

        // Fork: smart playlist (lens) pages carry the same two tabs — the lens is the
        // feeder, its session's store (if any) is the Session lineup, and Episodes is the
        // query itself. Unseen episodes carry the dot; they are not partitioned off.
        if isLensPage, !isSearching {
            let tint = AppTheme.appTintColor()
            var lineup = [ListEpisode]()
            if let real = lensSession, let storeUuid = real.storePlaylistUuid,
               let store = DataManager.sharedManager.findPlaylist(uuid: storeUuid) {
                // Finished episodes have left the session as far as playback and the session
                // chooser are concerned ("N episodes · time left" counts what's still to
                // play), so the tab must not count or list them either — a store that
                // accumulated members historically would otherwise read in the thousands.
                lineup = DataManager.sharedManager.positionedEpisodeUuids(for: store)
                    .compactMap { DataManager.sharedManager.findEpisode(uuid: $0) }
                    .filter { !$0.played() }
                    .map { ListEpisode(episode: $0, tintColor: tint) }
            }
            let browse = episodes
            allOverlayEpisodes = episodes
            // This lens's own session (if any) is "this session"; everything else in a session shows
            // dimmed. A lens with no/empty session (e.g. All) simply has no "this session" members,
            // so its in-session episodes all render as "other session".
            thisSessionMemberUuids = (lensSession != nil) ? Set(lineup.map { $0.episode.uuid }) : []
            unseenUuidsForDisplay = InboxManager.shared.unseenUuids()

            triageLineupCount = lineup.count
            triageLineupDuration = lineup.reduce(0.0) { $0 + max(0, $1.episode.duration - $1.episode.playedUpTo) }
            triageBrowseCount = browse.count
            triageBrowseDuration = browse.reduce(0.0) { $0 + max(0, $1.episode.duration - $1.episode.playedUpTo) }

            var shown: [ListEpisode]
            let model: Section
            switch selectedTriageTab {
            case .lineup:
                // Same rule as the session-store page: the lineup is never preset-filtered.
                shown = lineup
                model = .episodes
            case .browse:
                shown = browse
                model = .browse
            }
            // Fork: the tab's per-page sort.
            shown = TriageTabSort.arrange(shown, tab: selectedTriageTab.sortKey, pageUuid: playlist.uuid)
            let elements: [ListItem]
            if shown.isEmpty {
                elements = [PlaylistTabEmptyPlaceholder()]
            } else if selectedTriageTab == .lineup {
                elements = shown
            } else {
                elements = groupedElements(shown)
            }
            sections.append(ArraySection(model: model, elements: elements))
            return sections
        }

        // Plain playlists have no session of their own — in-session episodes all render dimmed.
        thisSessionMemberUuids = []

        let episodeElements: [ListItem]
        if episodes.isEmpty {
            // One placeholder, context-aware in the cell: "no episodes match this filter" when a
            // preset or search is narrowing, plain "no episodes" when the list is genuinely empty.
            episodeElements = [PlaylistTabEmptyPlaceholder()]
        } else {
            episodeElements = groupedElements(episodes)
        }

        sections.append(ArraySection(model: .episodes, elements: episodeElements))
        return sections
    }

    private func loadImagesURLs(episodes: [ListEpisode], includingEpisodeArtwork: Bool = false) async throws -> [PlaylistArtworkView.ImageItem] {
        try await withThrowingTaskGroup(of: PlaylistArtworkView.ImageItem.self) { group in
            for episode in episodes {
                group.addTask {
                    if includingEpisodeArtwork,
                       let url = try await ShowInfoCoordinator.shared.loadEpisodeArtworkUrl(podcastUuid: episode.episode.podcastUuid, episodeUuid: episode.episode.uuid) {
                        return PlaylistArtworkView.ImageItem(id: episode.episode.uuid, url: url)
                    }
                    let url = self.imageManager.podcastUrl(imageSize: .detail, uuid: episode.episode.podcastUuid)
                    return PlaylistArtworkView.ImageItem(id: episode.episode.podcastUuid, url: url)
                }
            }
            var results: [PlaylistArtworkView.ImageItem] = []
            for try await item in group {
                results.append(item)
            }

            let mapEpisodes = Dictionary(uniqueKeysWithValues: episodes.enumerated().map { ($1.episode.uuid, $0) })
            let mapPodcasts = Dictionary(uniqueKeysWithValues: episodes.enumerated().map { ($1.episode.podcastUuid, $0) })

            return results.sorted { lhs, rhs in
                let lhsIndex = (mapEpisodes[lhs.id] ?? mapPodcasts[lhs.id]) ?? Int.max
                let rhsIndex = (mapEpisodes[rhs.id] ?? mapPodcasts[rhs.id]) ?? Int.max
                return lhsIndex < rhsIndex
            }
        }
    }

    /// Artwork tiles straight from the podcast rule, in its stored order. Matches the
    /// episode-derived grid's shape: four tiles, or a single one when fewer exist.
    private func imageItems(forPodcastUuids uuids: [String]) -> [PlaylistArtworkView.ImageItem] {
        var tiles = Array(uuids.prefix(artworkImagesLimit))
        if tiles.count < artworkImagesLimit {
            tiles = Array(tiles.prefix(1))
        }
        return tiles.map { PlaylistArtworkView.ImageItem(id: $0, url: imageManager.podcastUrl(imageSize: .detail, uuid: $0)) }
    }

    private func firstDistinctPodcasts(from episodes: [ListEpisode], limit: Int) -> [ListEpisode] {
        var seen = Set<String>()
        var list: [ListEpisode] = []

        for episode in episodes {
            if seen.insert(episode.episode.podcastUuid).inserted {
                list.append(episode)
                if list.count == limit {
                    break
                }
            }
        }

        if !list.isEmpty, list.count < limit {
            return Array(list.prefix(1))
        }
        return list
    }
}

/// Fork: the insert-marker row rendered inside the Lineup section — the visible line where
/// "Add to lineup" places episodes. Its position in the section expresses the marker state.
extension PlaylistDetailViewModel {
    func clearSearch() {
        searchTerm = ""
        replaceEpisodesSection(with: tempEpisodes)
        reloadEpisodeList()
    }

    func endSearch() {
        isSearching = false
        searchTerm = ""
        replaceEpisodesSection(with: tempEpisodes)
        tempEpisodes.removeAll()

        reloadPlaylistAndEpisodes()
    }

    private func replaceEpisodesSection(with episodes: [ListEpisode]) {
        guard let index = dataSource.firstIndex(where: { $0.model == .episodes }) else { return }
        dataSource[index] = ArraySection(model: .episodes, elements: episodes)
    }

    func startSearch() {
        if isSearching {
            return
        }
        isSearching = true
        tempEpisodes = episodes

        let changeSetTuple = buildChangeSet(source: episodes, newData: episodes)
        DispatchQueue.main.async { [weak self] in
            self?.onChange(changeSetTuple.1, false, changeSetTuple.0)
        }
    }

    func searchEpisodes(for searchTerm: String) {
        if searchTerm.isEmpty {
            return
        }
        self.searchTerm = searchTerm
        let escapedSearch = searchTerm.escapeLike(escapeChar: "\\")
        // Session store pages: no Episodes-scope preset on the store query (see
        // PlaylistDetailFetchOperation — same cross-scope reasoning).
        let newData = episodesDataManager.playlistEpisodes(for: playlist, limit: 0, search: escapedSearch, preset: session == nil ? FilterPresets.active() : nil)
        let changeSetTuple = buildChangeSet(source: episodes, newData: newData)
        DispatchQueue.main.async { [weak self] in
            // Avoid animation as long we use the current diffable framework
            self?.onChange(changeSetTuple.1, false, changeSetTuple.0)
        }
    }
}
