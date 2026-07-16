import PocketCastsDataModel
import PocketCastsUtils
import PocketCastsServer
import UIKit

class UpNextViewController: UIViewController, UIGestureRecognizerDelegate, FilterCreatedDelegate {
    static let playerCell = "PlayerCell"
    static let nowPlayingCell = "UpNextNowPlayingCell"
    static let emptyStateCell = "EmptyStateCell"
    static let sessionInboxNoticeCell = "SessionInboxNoticeCell"
    static let upNextSection = 1
    static var upNextRowHeight: CGFloat = UITableView.automaticDimension

    static let nowPlayingRowHeight: CGFloat = UITableView.automaticDimension

    static var emptyStateRowHeight: CGFloat = UITableView.automaticDimension

    static let rearrangeWidth: CGFloat = 60
    static let bottomMargin: CGFloat = 8

    enum sections: Int { case nowPlayingSection = 0, sessionSection, upNextSection }

    var tableData = [sections]()

    var themeOverride: Theme.ThemeType? = nil

    lazy var contentInseter = {
        InsetAdjuster(ignoreMiniPlayer: !self.showingInTab)
    }()

    @MainActor
    var isMultiSelectEnabled = false {
        didSet {
            guard oldValue != isMultiSelectEnabled else { return }

            updateNavBarButtons()
            setEnclosingTabBarHidden(isMultiSelectEnabled, animated: false)
            contentInseter.isMultiSelectEnabled = isMultiSelectEnabled
            if !isMultiSelectEnabled {
                multiSelectActionBar.isHidden = true
                selectedPlayListEpisodes.removeAll()
                selectedSessionEpisodes.removeAll()
                track(.upNextMultiSelectExited)
            } else {
                // The action bar offers the active world's actions: session rows aren't
                // queue rows, so they get the episode actions the session swipes offer.
                if displayedWorld == .session {
                    multiSelectActionBar.getActionsFunc = Settings.sessionMultiSelectActions
                    multiSelectActionBar.setActionsFunc = Settings.updateSessionMultiSelectActions
                } else {
                    multiSelectActionBar.getActionsFunc = Settings.upNextMultiSelectActions
                    multiSelectActionBar.setActionsFunc = Settings.updateUpNextMultiSelectActions
                }
                track(.upNextMultiSelectEntered)
            }
            updateNavBarButtons(animated: true)
            if showingInTab {
                multiSelectActionBarBottomConstraint.constant = Constants.effectiveMiniPlayerOffset + Self.bottomMargin
            }
            animateMultiSelectChange()
        }
    }

    var changedViaSwipeToRemove = false

    /// Fork: multi-select on the Session world tracks episodes directly (session rows
    /// aren't queue join rows).
    var selectedSessionEpisodes = [BaseEpisode]() {
        didSet {
            multiSelectActionBar.setSelectedCount(count: selectedSessionEpisodes.count)
            contentInseter.isMultiSelectEnabled = !selectedSessionEpisodes.isEmpty
            if isMultiSelectEnabled {
                updateNavBarButtons()
            }
        }
    }

    let remainingLabel = ThemeableLabel()
    // Use HitTargetButton so these small header controls meet Apple's recommended 44x44pt minimum tap target without changing their visible size.
    let shuffleButton = HitTargetButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
    let sortButton = HitTargetButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
    let filterButton = HitTargetButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
    let hideSkippedButton = HitTargetButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
    let filterIndicatorButton = UIButton(type: .custom)
    let clearFilterButton = HitTargetButton(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
    let clearQueueButton = HitTargetButton(frame: CGRect(x: 0, y: 0, width: 93, height: 16))
    let sessionHeaderLabel = ThemeableLabel()
    let sessionSortButton = HitTargetButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
    /// Which world the screen is showing. The pill switcher changes only the view —
    /// never what plays — and auto-follows playback ownership on transitions (session
    /// starts → session view; session pauses → queue view; ending a session stays on
    /// the Session view's empty state). A manual pick holds until the next transition.
    enum DisplayedWorld: Int {
        case upNext = 0
        case session = 1
    }

    var displayedWorld: DisplayedWorld = .upNext

    /// Tracks session-playing transitions for the view's auto-follow.
    private var lastKnownSessionActive: Bool?

    let worldSwitcher = UISegmentedControl(items: [L10n.upNext, L10n.playbackSessionTabSession])

    // Sticky chrome above the table: the pill switcher plus the active world's header
    // (session title block or queue controls line). The list scrolls underneath it.
    private let stickyChrome = UIStackView()
    private let stickyChromeBackground = UIView()

    private static let worldSwitcherFont = UIFont.systemFont(ofSize: 13, weight: .medium)

    @objc private func worldSwitcherChanged() {
        displayedWorld = DisplayedWorld(rawValue: worldSwitcher.selectedSegmentIndex) ?? .upNext
        reloadTable()
        upNextTable.setContentOffset(CGPoint(x: 0, y: -upNextTable.adjustedContentInset.top), animated: false)
    }

    /// Activating the tab lands on whichever world owns playback — the tab bar item's
    /// title promised as much.
    @objc private func upNextTabActivated() {
        displayedWorld = sessionOwnsCard ? .session : .upNext
        reloadTable()
    }

    /// Only the pill switcher is sticky; everything below it — session title, card,
    /// counts line, and rows — scrolls as one. The title rides along as the table's
    /// header view (which, unlike section headers, never pins).
    func updateStickyChrome() {
        stickyChrome.backgroundColor = AppTheme.colorForStyle(.primaryUi04, themeOverride: themeOverride)
        stickyChromeBackground.backgroundColor = stickyChrome.backgroundColor

        let metrics = UIFontMetrics(forTextStyle: .footnote)
        let inSession = displayedWorld == .session
        if inSession, Settings.playbackSession() != nil {
            updateSessionHeader()
            sessionHeaderView.frame = CGRect(x: 0, y: 0, width: upNextTable.bounds.width, height: metrics.scaledValue(for: sessionHeaderHeight))
            upNextTable.tableHeaderView = sessionHeaderView
        } else if !inSession {
            // The queue gets the same title block as the session — "Up Next".
            sessionHeaderLabel.text = L10n.upNext
            sessionHeaderLabel.style = .primaryText01
            sessionInboxLabel.isHidden = true
            sessionHeaderView.frame = CGRect(x: 0, y: 0, width: upNextTable.bounds.width, height: metrics.scaledValue(for: sessionHeaderHeight))
            upNextTable.tableHeaderView = sessionHeaderView
        } else {
            upNextTable.tableHeaderView = nil
        }

        let chromeHeight: CGFloat = 52
        guard upNextTable.contentInset.top != chromeHeight else { return }
        // The system adds the safe-area (nav bar) inset on top of contentInset, so all
        // offset math uses adjustedContentInset.
        let wasAtTop = upNextTable.contentOffset.y <= -upNextTable.adjustedContentInset.top + 1
        upNextTable.contentInset.top = chromeHeight
        upNextTable.verticalScrollIndicatorInsets.top = chromeHeight
        if wasAtTop {
            upNextTable.contentOffset.y = -upNextTable.adjustedContentInset.top
        }
    }

    @objc private func pillLongPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        // Only the Session segment (right half) offers the switcher.
        guard recognizer.location(in: worldSwitcher).x > worldSwitcher.bounds.width / 2 else { return }
        switchSessionTapped()
    }

    /// Pill titles carry each world's episode count (including the playing episode)
    /// so the parked world stays visible in the periphery while peeking.
    func updateWorldSwitcher() {
        let textColor = AppTheme.colorForStyle(.primaryText01, themeOverride: themeOverride)
        worldSwitcher.setTitleTextAttributes([.font: Self.worldSwitcherFont, .foregroundColor: textColor], for: .normal)
        worldSwitcher.setTitleTextAttributes([.font: Self.worldSwitcherFont, .foregroundColor: textColor], for: .selected)

        let queueCount = PlaybackManager.shared.queue.upNextCount() + (queueOwnsCard ? 1 : 0)
        setWorldSegment(title: "\(L10n.upNext) · \(queueCount)", playing: queueOwnsCard, at: DisplayedWorld.upNext.rawValue)

        let sessionCount = (sessionEpisodes?.count ?? 0) + (sessionOwnsCard ? 1 : 0)
        let sessionTitle = Settings.playbackSession() != nil
            ? "\(L10n.playbackSessionTabSession) · \(sessionCount)"
            : L10n.playbackSessionTabSession
        setWorldSegment(title: sessionTitle, playing: sessionOwnsCard, at: DisplayedWorld.session.rawValue)

        worldSwitcher.selectedSegmentIndex = displayedWorld.rawValue
    }

    /// The world that owns playback carries the now-playing speaker glyph in its pill —
    /// the same visual language Music/Podcasts use to mark the playing item.
    private func setWorldSegment(title: String, playing: Bool, at index: Int) {
        guard playing else {
            worldSwitcher.setTitle(title, forSegmentAt: index)
            return
        }
        worldSwitcher.setImage(nowPlayingSegmentImage(title: title), forSegmentAt: index)
    }

    /// A segment can hold a title or an image, not both, so the glyph+title combination
    /// is rendered into an image matching the plain segments' font and color.
    private func nowPlayingSegmentImage(title: String) -> UIImage {
        let font = Self.worldSwitcherFont
        let textColor = AppTheme.colorForStyle(.primaryText01, themeOverride: themeOverride)
        let accent = AppTheme.colorForStyle(.primaryInteractive01, themeOverride: themeOverride)

        let attachment = NSTextAttachment()
        if let symbol = UIImage(systemName: "speaker.wave.2.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))?
            .withTintColor(accent, renderingMode: .alwaysOriginal) {
            attachment.image = symbol
            attachment.bounds = CGRect(x: 0, y: (font.capHeight - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height)
        }

        let content = NSMutableAttributedString(attachment: attachment)
        content.append(NSAttributedString(string: " " + title, attributes: [.font: font, .foregroundColor: textColor]))

        let size = CGSize(width: ceil(content.size().width), height: ceil(content.size().height))
        return UIGraphicsImageRenderer(size: size).image { _ in
            content.draw(at: .zero)
        }.withRenderingMode(.alwaysOriginal)
    }
    private var filterTrailingToHideSkipped: NSLayoutConstraint?
    private var filterTrailingToShuffle: NSLayoutConstraint?

    /// Header of the session section: one "Session: <name> ›" line (tap navigates — the
    /// session is a live mirror of that playlist/podcast) with sort and end-session buttons,
    /// a metadata line, and — when the playlist has untriaged episodes — the tappable inbox
    /// notice, sitting above the Now Playing card. Sessions always show their full list.
    lazy var sessionHeaderView: UIView = {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 52))

        sessionHeaderLabel.style = .primaryText01
        sessionHeaderLabel.font = UIFont.font(ofSize: 22, weight: .bold, scalingWith: .title2)
        sessionHeaderLabel.textAlignment = .center
        view.addSubview(sessionHeaderLabel)
        sessionHeaderLabel.translatesAutoresizingMaskIntoConstraints = false

        sessionInboxLabel.font = UIFont.font(ofSize: 13, weight: .medium, scalingWith: .footnote)
        view.addSubview(sessionInboxLabel)
        sessionInboxLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            // Centered like the playlist page's title block.
            sessionHeaderLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            sessionHeaderLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            sessionHeaderLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            sessionHeaderLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),

            sessionInboxLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            sessionInboxLabel.topAnchor.constraint(equalTo: sessionHeaderLabel.bottomAnchor, constant: 3)
        ])

        // The title opens the session's source (the session is a live mirror of it);
        // the inbox line opens the same place to triage.
        sessionHeaderLabel.isUserInteractionEnabled = true
        sessionHeaderLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openSessionSource)))
        sessionInboxLabel.isUserInteractionEnabled = true
        sessionInboxLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(sessionInboxNoticeTapped)))
        return view
    }()

    /// The session's counts/controls line — the session list's section header, sitting
    /// below the Now Playing card exactly like the stock Up Next header, and pinning
    /// under the chrome while scrolling.
    lazy var sessionControlsView: UIView = {
        let view = UIView()

        sessionMetaLabel.style = .primaryText02
        sessionMetaLabel.font = UIFont.font(ofSize: 14, weight: .medium, scalingWith: .footnote)
        view.addSubview(sessionMetaLabel)
        sessionMetaLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(sessionSortButton)
        sessionSortButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            // Bottom-anchored: extra row height becomes breathing room below the card,
            // keeping the tight gap to the first episode.
            sessionMetaLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            sessionMetaLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -11),
            sessionMetaLabel.trailingAnchor.constraint(lessThanOrEqualTo: sessionSortButton.leadingAnchor, constant: -10),

            sessionSortButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            sessionSortButton.centerYAnchor.constraint(equalTo: sessionMetaLabel.centerYAnchor),
            sessionSortButton.widthAnchor.constraint(equalToConstant: 24),
            sessionSortButton.heightAnchor.constraint(equalToConstant: 24)
        ])
        return view
    }()

    let sessionInboxLabel = UILabel()
    let sessionMetaLabel = ThemeableLabel()

    /// The Switch Session sheet: looks like the Playlists screen (artwork, name, count),
    /// with "Up Next" as the first row to hand playback back to the queue.
    @objc func switchSessionTapped() {
        presentSessionPicker(includeUpNext: true)
    }

    /// The empty state's "Choose session" variant omits the Up Next row — with no
    /// session active there is no queue mode to switch back to.
    func presentSessionPicker(includeUpNext: Bool) {
        let controller = SwitchSessionViewController(themeOverride: themeOverride, includeUpNext: includeUpNext) { [weak self] pickedUpNext in
            if pickedUpNext {
                self?.displayedWorld = .upNext
                self?.reloadTable()
            }
        }
        let nav = UINavigationController(rootViewController: controller)
        nav.modalPresentationStyle = .pageSheet
        nav.sheetPresentationController?.detents = [.medium(), .large()]
        present(nav, animated: true)
    }

    /// "N episodes · X left" for what's still to come in the session — the playing
    /// episode isn't counted, so the line stays put during playback.
    func sessionMetaText() -> String? {
        guard let session = Settings.playbackSession() else { return nil }
        let excludedUuid = Settings.playbackSessionPaused() ? nil : PlaybackManager.shared.currentEpisode()?.uuid
        let remainingEpisodes = session.remainingEpisodes(excluding: excludedUuid)
        let totalDuration = remainingEpisodes.reduce(0.0) { $0 + max(0, $1.duration - $1.playedUpTo) }
        // Same strings as the stock Up Next counts line, so the two worlds read alike.
        let time = TimeFormatter.shared.multipleUnitFormattedShortTime(time: totalDuration)
        let count = remainingEpisodes.count
        if count == 0 {
            return L10n.queueUpNextHeaderTimeLeft(time)
        } else if count == 1 {
            return L10n.queueUpNextHeaderOneEpisode(time)
        }
        return L10n.queueUpNextHeaderPlural(count.localized(), time)
    }

    func updateSessionHeader() {
        let session = Settings.playbackSession()



        // With no session the view shows a dimmed "Session" bar with the switcher
        // (and the Switch Session row) as the way back in.
        guard let session else {
            sessionHeaderLabel.text = L10n.playbackSessionTabSession
            sessionHeaderLabel.style = .primaryText02
            sessionMetaLabel.text = nil
            sessionInboxLabel.isHidden = true
            sessionSortButton.isHidden = true
            return
        }

        // The source's name (tapping opens it); the counts line always sits beneath it
        // and covers the full session including the playing episode.
        let sourceName: String
        switch session.type {
        case .podcast:
            sourceName = DataManager.sharedManager.findPodcast(uuid: session.uuid, includeUnsubscribed: true)?.title ?? L10n.playbackSessionTabSession
        case .playlist, .smartPlaylist:
            sourceName = DataManager.sharedManager.findPlaylist(uuid: session.uuid)?.playlistName ?? L10n.playbackSessionTabSession
        }
        // The chevron signals the title links to its session page.
        sessionHeaderLabel.text = sourceName + " ›"
        sessionHeaderLabel.style = .primaryText01
        sessionMetaLabel.text = sessionMetaText()

        // Inbox line: tap to go triage the playlist's inbox.
        if sessionInboxCount > 0 {
            let noticeText = sessionInboxCount == 1
                ? L10n.playbackSessionInboxNoticeSingular
                : L10n.playbackSessionInboxNoticePlural(sessionInboxCount.localized())
            sessionInboxLabel.text = noticeText + " ›"
            sessionInboxLabel.isHidden = false
        } else {
            sessionInboxLabel.isHidden = true
        }
        sessionInboxLabel.textColor = AppTheme.colorForStyle(.primaryInteractive01, themeOverride: themeOverride)
        sessionSortButton.isHidden = !(session.type == .smartPlaylist || session.type == .playlist)
        let sortImage = UIImage(named: "podcast-sort")?
            .withTintColor(AppTheme.colorForStyle(.primaryIcon02, themeOverride: themeOverride), renderingMode: .alwaysOriginal)
        sessionSortButton.setImage(sortImage, for: .normal)
        sessionSortButton.accessibilityLabel = L10n.playbackSessionSortTitle
    }

    /// Ticks the under-card "… left" line while a session episode plays.
    @objc func sessionPlaybackProgressed() {
        guard Settings.playbackSession() != nil, !Settings.playbackSessionPaused() else { return }
        sessionMetaLabel.text = sessionMetaText()
    }

    /// Uuids of queued episodes matching the active Up Next filter, or nil when no filter is set.
    /// Refreshed by `refreshUpNextFilterMatches()`; used for row dimming and the header count.
    var upNextFilterMatchingUuids: Set<String>?

    /// The active session's remaining episodes, shown in place of the queue while a
    /// playback session runs. nil when no session is active.
    var sessionEpisodes: [BaseEpisode]?

    /// Fork: untriaged (inbox) episode count of the session's custom-ordered smart playlist.
    /// Refreshed alongside `sessionEpisodes`; drives the "· N new" header suffix and the
    /// tappable inbox notice row at the end of the session section.
    var sessionInboxCount = 0

    /// The inbox notice row shows in every session state — it's the only place the
    /// untriaged count surfaces on this screen.
    var showsSessionInboxNotice: Bool {
        sessionEpisodes != nil && sessionInboxCount > 0
    }

    /// Fork: opens the session's playlist so its New (inbox) episodes can be triaged.
    @objc func sessionInboxNoticeTapped() {
        openSessionSource()
    }

    // Fork: FilterCreatedDelegate — required to push PlaylistDetailViewController from
    // the session title; nothing creates filters from here.
    var presentingPlaylistDetail: Bool {
        get { false }
        set {}
    }

    func filterCreated(newFilter: EpisodeFilter) {}

    /// Fork: navigates to the session's source — the playlist (manual or smart) or podcast
    /// it plays from. Reached from the session title and the inbox notice row. With no
    /// session, the title tap opens the switcher instead.
    @objc func openSessionSource() {
        guard displayedWorld == .session else { return }
        guard let session = Settings.playbackSession() else {
            switchSessionTapped()
            return
        }

        // From the tab, push locally so Back returns to the Session; from the player
        // sheet there is no local stack — route through NavigationManager instead.
        let pushPodcast: (Podcast) -> () -> Void = { podcast in
            return { [weak self] in
                if let nav = self?.navigationController {
                    nav.pushViewController(PodcastViewController(podcast: podcast), animated: true)
                } else {
                    NavigationManager.sharedManager.navigateTo(
                        NavigationManager.podcastPageKey,
                        data: [NavigationManager.podcastKey: podcast]
                    )
                }
            }
        }
        let pushPlaylist: (String) -> () -> Void = { uuid in
            return { [weak self] in
                if let self, let nav = self.navigationController,
                   let filter = DataManager.sharedManager.findPlaylist(uuid: uuid) {
                    nav.pushViewController(PlaylistDetailViewController(playlist: filter, delegate: self), animated: true)
                } else {
                    NavigationManager.sharedManager.navigateTo(
                        NavigationManager.filterPageKey,
                        data: [NavigationManager.filterUuidKey: uuid]
                    )
                }
            }
        }
        let openFolder: (Folder) -> () -> Void = { folder in
            return {
                NavigationManager.sharedManager.navigateTo(
                    NavigationManager.folderPageKey,
                    data: [NavigationManager.folderKey: folder]
                )
            }
        }

        // Prefer the feeder (the Smart Playlist / podcast / folder that fills this session)
        // over the session's own store playlist, when one is available.
        let feeder = SessionStore.shared.session(forStore: session.uuid)?.feeder
        let navigate: () -> Void
        switch (session.type, feeder) {
        case (.podcast, _):
            guard let podcast = DataManager.sharedManager.findPodcast(uuid: session.uuid, includeUnsubscribed: true) else { return }
            navigate = pushPodcast(podcast)
        case (_, .smartPlaylist(let uuid)):
            navigate = pushPlaylist(uuid)
        case (_, .podcast(let uuid)):
            guard let podcast = DataManager.sharedManager.findPodcast(uuid: uuid, includeUnsubscribed: true) else {
                navigate = pushPlaylist(session.uuid); break
            }
            navigate = pushPodcast(podcast)
        case (_, .folder(let uuid)):
            guard let folder = DataManager.sharedManager.findFolder(uuid: uuid) else {
                navigate = pushPlaylist(session.uuid); break
            }
            navigate = openFolder(folder)
        default:
            // .none / .allPodcasts / no feeder → the session's own store playlist.
            navigate = pushPlaylist(session.uuid)
        }

        if presentingViewController is PlayerContainerViewController {
            dismiss(animated: true, completion: navigate)
        } else {
            navigate()
        }
    }

    /// Fork: how many episodes of the playing session's feeder are waiting in its inbox.
    static func inboxCount(for session: PlaybackSession) -> Int {
        guard session.type == .playlist || session.type == .smartPlaylist,
              let storeSession = SessionStore.shared.session(forStore: session.uuid),
              storeSession.feeder != .none, !storeSession.autoAdd else { return 0 }
        return SessionFeederEngine.inboxEpisodes(for: storeSession).count
    }


    /// Queue indices of the rows shown in the Up Next section, in display order.
    /// nil when every queued episode is shown (no filter, or "show skipped" mode).
    var visibleQueueIndices: [Int]?

    /// Maps a visible table row to its index in the full queue.
    func queueIndex(forVisibleRow row: Int) -> Int {
        guard let visibleQueueIndices, row < visibleQueueIndices.count else { return row }
        return visibleQueueIndices[row]
    }

    var visibleUpNextCount: Int {
        visibleQueueIndices?.count ?? PlaybackManager.shared.queue.upNextCount()
    }

    /// True when the compact filtered view has nothing to show even though the queue isn't
    /// empty — the Up Next section then shows a single explanatory notice cell instead.
    var isShowingFilterEmptyNotice: Bool {
        visibleQueueIndices?.isEmpty == true && PlaybackManager.shared.queue.upNextCount() > 0
    }
    var selectedPlayListEpisodes = [PlaylistEpisode]() {
        didSet {
            multiSelectActionBar.setSelectedCount(count: selectedPlayListEpisodes.count)
            if selectedPlayListEpisodes.isEmpty {
                contentInseter.isMultiSelectEnabled = false
            } else {
                contentInseter.isMultiSelectEnabled = true
            }
            // While multi-select is being toggled the nav bar is updated (animated)
            // by `isMultiSelectEnabled`'s observer. Only react here to selection
            // changes that happen while multi-select is active, to switch between
            // the Select All / Deselect All buttons without fighting that animation.
            if isMultiSelectEnabled {
                updateNavBarButtons()
            }
        }
    }

    lazy var headerView: UIView = {
        let headerView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 48))

        // Queue controls live on the header's top row; the filter indicator line appears
        // below them when a filter is active (see heightForHeaderInSection).
        let controlsRow = UILayoutGuide()
        headerView.addLayoutGuide(controlsRow)

        NSLayoutConstraint.activate([
            controlsRow.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            controlsRow.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            // Fork layout: a touch of air between the card above and this line.
            controlsRow.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 8),
            controlsRow.heightAnchor.constraint(equalToConstant: 48)
        ])

        updateTimeRemainingLabel()

        headerView.addSubview(remainingLabel)
        NSLayoutConstraint.activate([
            remainingLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 20),
            remainingLabel.centerYAnchor.constraint(equalTo: controlsRow.centerYAnchor)
        ])

        if FeatureFlag.upNextSort.enabled {
            headerView.addSubview(sortButton)
            sortButton.translatesAutoresizingMaskIntoConstraints = false
            sortButton.setContentCompressionResistancePriority(.required, for: .horizontal)
            NSLayoutConstraint.activate([
                sortButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -20),
                sortButton.centerYAnchor.constraint(equalTo: controlsRow.centerYAnchor),
                sortButton.widthAnchor.constraint(equalToConstant: 24),
                sortButton.heightAnchor.constraint(equalToConstant: 24)
            ])
        }

        // When the sort button is shown, the shuffle/clear buttons sit to its left.
        let trailingButtonAnchor = FeatureFlag.upNextSort.enabled ? sortButton.leadingAnchor : headerView.trailingAnchor
        let trailingButtonConstant: CGFloat = FeatureFlag.upNextSort.enabled ? -16 : -20

        headerView.addSubview(shuffleButton)
        shuffleButton.translatesAutoresizingMaskIntoConstraints = false
        shuffleButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            shuffleButton.trailingAnchor.constraint(equalTo: trailingButtonAnchor, constant: trailingButtonConstant),
            shuffleButton.centerYAnchor.constraint(equalTo: controlsRow.centerYAnchor),
            shuffleButton.leadingAnchor.constraint(greaterThanOrEqualTo: remainingLabel.trailingAnchor, constant: 10),
            shuffleButton.widthAnchor.constraint(equalToConstant: 24),
            shuffleButton.heightAnchor.constraint(equalToConstant: 24)
        ])

        if FeatureFlag.upNextFilter.enabled {
            // The funnel sits left of the eye; the eye only appears while a filter is active,
            // so the funnel's trailing constraint swaps between the two anchors.
            headerView.addSubview(hideSkippedButton)
            hideSkippedButton.translatesAutoresizingMaskIntoConstraints = false
            hideSkippedButton.setContentCompressionResistancePriority(.required, for: .horizontal)
            NSLayoutConstraint.activate([
                hideSkippedButton.trailingAnchor.constraint(equalTo: shuffleButton.leadingAnchor, constant: -16),
                hideSkippedButton.centerYAnchor.constraint(equalTo: controlsRow.centerYAnchor),
                hideSkippedButton.widthAnchor.constraint(equalToConstant: 24),
                hideSkippedButton.heightAnchor.constraint(equalToConstant: 24)
            ])

            headerView.addSubview(filterButton)
            filterButton.translatesAutoresizingMaskIntoConstraints = false
            filterButton.setContentCompressionResistancePriority(.required, for: .horizontal)
            filterTrailingToHideSkipped = filterButton.trailingAnchor.constraint(equalTo: hideSkippedButton.leadingAnchor, constant: -16)
            filterTrailingToShuffle = filterButton.trailingAnchor.constraint(equalTo: shuffleButton.leadingAnchor, constant: -16)
            NSLayoutConstraint.activate([
                filterButton.centerYAnchor.constraint(equalTo: controlsRow.centerYAnchor),
                filterButton.leadingAnchor.constraint(greaterThanOrEqualTo: remainingLabel.trailingAnchor, constant: 10),
                filterButton.widthAnchor.constraint(equalToConstant: 24),
                filterButton.heightAnchor.constraint(equalToConstant: 24)
            ])

            // Indicator line under "Playing x of x": blue "Filter: Name (Type)" text that
            // opens the picker, and a cross that clears the filter.
            headerView.addSubview(filterIndicatorButton)
            filterIndicatorButton.translatesAutoresizingMaskIntoConstraints = false
            headerView.addSubview(clearFilterButton)
            clearFilterButton.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                filterIndicatorButton.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 20),
                filterIndicatorButton.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -6),
                filterIndicatorButton.heightAnchor.constraint(equalToConstant: 20),
                clearFilterButton.leadingAnchor.constraint(equalTo: filterIndicatorButton.trailingAnchor, constant: 8),
                clearFilterButton.centerYAnchor.constraint(equalTo: filterIndicatorButton.centerYAnchor),
                clearFilterButton.widthAnchor.constraint(equalToConstant: 20),
                clearFilterButton.heightAnchor.constraint(equalToConstant: 20),
                clearFilterButton.trailingAnchor.constraint(lessThanOrEqualTo: headerView.trailingAnchor, constant: -20)
            ])
            updateFilterHeaderButtons()
        }

        headerView.addSubview(clearQueueButton)
        clearQueueButton.translatesAutoresizingMaskIntoConstraints = false
        clearQueueButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            clearQueueButton.trailingAnchor.constraint(equalTo: trailingButtonAnchor, constant: trailingButtonConstant),
            clearQueueButton.centerYAnchor.constraint(equalTo: controlsRow.centerYAnchor),
            clearQueueButton.leadingAnchor.constraint(greaterThanOrEqualTo: remainingLabel.trailingAnchor, constant: 10)
        ])

        if FeatureFlag.upNextShuffle.enabled {
            clearQueueButton.isHidden = true
            shuffleButton.isHidden = PlaybackManager.shared.queue.upNextCount() == 0
        } else {
            shuffleButton.isHidden = true
            clearQueueButton.isEnabled = PlaybackManager.shared.queue.upNextCount() > 0
        }
        if FeatureFlag.upNextSort.enabled {
            sortButton.isHidden = PlaybackManager.shared.queue.upNextCount() == 0
        }
        updateSize()
        return headerView
    }()

    var multiSelectGestureInProgress = false
    var isReorderInProgress = false

    @IBOutlet var upNextTable: ThemeableTable! {
        didSet {
            upNextTable.themeOverride = themeOverride
            upNextTable.register(UINib(nibName: "PlayerCell", bundle: nil), forCellReuseIdentifier: UpNextViewController.playerCell)
            upNextTable.register(UINib(nibName: "UpNextNowPlayingCell", bundle: nil), forCellReuseIdentifier: UpNextViewController.nowPlayingCell)
            upNextTable.register(EmptyStateCell.self, forCellReuseIdentifier: UpNextViewController.emptyStateCell)
            upNextTable.backgroundView = nil
            upNextTable.isEditing = true
            upNextTable.addGestureRecognizer(customLongPressGesture)
            upNextTable.allowsMultipleSelectionDuringEditing = true
            upNextTable.allowsMultipleSelection = true
        }
    }

    @IBOutlet var multiSelectActionBar: MultiSelectFooterView! {
        didSet {
            multiSelectActionBar.delegate = self
            multiSelectActionBar.getActionsFunc = Settings.upNextMultiSelectActions
            multiSelectActionBar.setActionsFunc = Settings.updateUpNextMultiSelectActions
            multiSelectActionBar.themeOverride = themeOverride
        }
    }

    @IBOutlet var multiSelectActionBarBottomConstraint: NSLayoutConstraint!

    lazy var customLongPressGesture: UILongPressGestureRecognizer = {
        let longPressRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(tableLongPressed(_:)))
        longPressRecognizer.delegate = self

        return longPressRecognizer
    }()

    let source: UpNextViewSource
    let showingInTab: Bool

    init(source: UpNextViewSource, themeOverride: Theme.ThemeType? = nil, showingInTab: Bool = false) {
        self.source = source
        self.themeOverride = !showingInTab && Settings.darkUpNextTheme ? .dark : themeOverride
        self.showingInTab = showingInTab
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = L10n.upNext

        (view as? ThemeableView)?.style = .primaryUi04
        (view as? ThemeableView)?.themeOverride = themeOverride

        NotificationCenter.default.addObserver(self, selector: #selector(upNextChanged), name: Constants.Notifications.playbackTrackChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(upNextChanged), name: Constants.Notifications.playbackEnded, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(upNextChanged), name: Constants.Notifications.upNextQueueChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(upNextChanged), name: Constants.Notifications.upNextEpisodeAdded, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(upNextChanged), name: Constants.Notifications.upNextEpisodeRemoved, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateTimeRemainingLabel), name: Constants.Notifications.playbackProgress, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reorderingDidBegin), name: .tableViewReorderWillBegin, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reorderingDidEnd), name: .tableViewReorderDidEnd, object: nil)
        if showingInTab {
            NotificationCenter.default.addObserver(self, selector: #selector(upNextTabActivated), name: Constants.Notifications.upNextTabActivated, object: nil)
        }

        if FeatureFlag.upNextShuffle.enabled, showingInTab {
            NotificationCenter.default.addObserver(self, selector: #selector(updateShuffleButtonState), name: Constants.Notifications.upNextShuffleToggle, object: nil)
        }

        remainingLabel.font = UIFont.font(ofSize: 14, weight: .medium, scalingWith: .footnote)
        remainingLabel.adjustsFontSizeToFitWidth = true
        remainingLabel.adjustsFontForContentSizeCategory = true
        remainingLabel.minimumScaleFactor = 0.8
        remainingLabel.numberOfLines = 3
        remainingLabel.style = .primaryText02
        remainingLabel.themeOverride = themeOverride
        remainingLabel.translatesAutoresizingMaskIntoConstraints = false

        setupActionButtonsIfNecessary()

        contentInseter.setupInsetAdjustmentsForMiniPlayer(scrollView: upNextTable)

        // Sticky chrome pinned above the table: pill switcher on top, then the
        // active world's header. Content scrolls beneath it (via contentInset).
        let pillContainer = UIView()
        worldSwitcher.translatesAutoresizingMaskIntoConstraints = false
        worldSwitcher.addTarget(self, action: #selector(worldSwitcherChanged), for: .valueChanged)
        // Long-pressing the Session pill opens the Switch Session sheet.
        worldSwitcher.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(pillLongPressed(_:))))
        pillContainer.addSubview(worldSwitcher)
        NSLayoutConstraint.activate([
            pillContainer.heightAnchor.constraint(equalToConstant: 52),
            worldSwitcher.leadingAnchor.constraint(equalTo: pillContainer.leadingAnchor, constant: 20),
            worldSwitcher.trailingAnchor.constraint(equalTo: pillContainer.trailingAnchor, constant: -20),
            worldSwitcher.centerYAnchor.constraint(equalTo: pillContainer.centerYAnchor)
        ])

        stickyChrome.axis = .vertical
        stickyChrome.addArrangedSubview(pillContainer)

        stickyChrome.translatesAutoresizingMaskIntoConstraints = false
        // Opaque backing that also covers the status/nav area above the pill, so
        // scrolling rows never show through above the chrome.
        stickyChromeBackground.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stickyChromeBackground)
        view.addSubview(stickyChrome)
        NSLayoutConstraint.activate([
            // Below the navigation bar — the table's safe-area inset starts there too.
            stickyChrome.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stickyChrome.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stickyChrome.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            stickyChromeBackground.topAnchor.constraint(equalTo: view.topAnchor),
            stickyChromeBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stickyChromeBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stickyChromeBackground.bottomAnchor.constraint(equalTo: stickyChrome.bottomAnchor)
        ])

        refreshSections()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateNavBarButtons()
        setupActionButtonsIfNecessary()
        if FeatureFlag.upNextShuffle.enabled {
            themeDidChange()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // fix issues with the now playing cell not animating by reloading it on appear
        reloadTable()

        track(.upNextShown, properties: ["source": source])

        AnalyticsHelper.upNextOpened()

        showUpNextSortDurationTipIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        guard isViewLoaded else { return } // This method was called as a result of `setSelectedIndex` on UITabBarController. The view is not loaded at this point so we don't need to do anything to reset.
        selectedPlayListEpisodes.removeAll()
        isMultiSelectEnabled = false
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        track(.upNextDismissed)
    }

    @objc func clearQueueTapped() {
        let queueCount = PlaybackManager.shared.queue.upNextCount()

        if queueCount <= Constants.Limits.upNextClearWithoutWarning && !FeatureFlag.upNextShuffle.enabled {
            performClearAll()
        } else {
            let alert = UIAlertController(title: L10n.clearUpNext, message: L10n.clearUpNextMessage, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L10n.cancel, style: .cancel))
            alert.addAction(UIAlertAction(title: actionLabelText(queueCount), style: .destructive) { [weak self] _ in
                self?.performClearAll()
            })
            present(alert, animated: true)
        }

        selectedPlayListEpisodes.removeAll()
        isMultiSelectEnabled = false
    }

    @objc private func shuffleButtonTapped() {
        FileLog.shared.addMessage("UpNext shuffleButtonTapped: user has active subscription: \(SubscriptionHelper.hasActiveSubscription()) and is logged in: \(SyncManager.isUserLoggedIn())")

        if !SubscriptionHelper.hasActiveSubscription() || !SyncManager.isUserLoggedIn() {
            // Edge case where the UpNext is presented by the player container with a free user.
            // In this case we need to dismiss the UpNext to present the paywall
            if let mainTabBar = presentingViewController?.presentingViewController, presentingViewController is PlayerContainerViewController {
                dismiss(animated: true) {
                    NavigationManager.sharedManager.showUpsellView(from: mainTabBar, source: .upNextShuffle)
                }
            } else {
                NavigationManager.sharedManager.showUpsellView(from: self, source: .upNextShuffle)
            }
            return
        }
        Settings.upNextShuffleToggle()
        if !showingInTab {
            updateShuffleButtonState()
        }
        let upNextShuffleEnabled = Settings.upNextShuffleEnabled()
        if upNextShuffleEnabled {
            Toast.show(L10n.upNextShuffleToastMessage, aboveMiniPlayer: self.showingInTab ? true : false)
        }
        FileLog.shared.addMessage("UpNext shuffleButtonTapped: shuffle enabled: \(upNextShuffleEnabled)")
        track(.upNextShuffleEnabled, properties: ["value": upNextShuffleEnabled])
    }

    @objc private func themeDidChange() {
        FileLog.shared.addMessage("UpNext themeDidChange: user has active subscription: \(SubscriptionHelper.hasActiveSubscription()) and is logged in: \(SyncManager.isUserLoggedIn())")

        if !SubscriptionHelper.hasActiveSubscription() || !SyncManager.isUserLoggedIn() {
            shuffleButton.setImage(UIImage(named: "shuffle-plus"), for: .normal)
            shuffleButton.isSelected = false
        } else {
            let unselected = UIImage(named: "shuffle")?.withTintColor(AppTheme.colorForStyle(.primaryIcon02, themeOverride: themeOverride), renderingMode: .alwaysOriginal)
            let selected = UIImage(named: "shuffle-enabled")?.withTintColor(AppTheme.colorForStyle(.primaryIcon01, themeOverride: themeOverride), renderingMode: .alwaysOriginal)
            shuffleButton.setImage(unselected, for: .normal)
            shuffleButton.setImage(selected, for: .selected)
            updateShuffleButtonState()
        }
        shuffleButton.imageView?.adjustsImageSizeForAccessibilityContentSizeCategory = true
        shuffleButton.imageView?.contentMode = .scaleAspectFit
        shuffleButton.imageView?.translatesAutoresizingMaskIntoConstraints = false
    }

    @objc private func subscriptionStatusDidChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if FeatureFlag.upNextShuffle.enabled {
                // Update UI
                FileLog.shared.addMessage("UpNext subscriptionStatusDidChange: user has active subscription: \(SubscriptionHelper.hasActiveSubscription()) and is logged in: \(SyncManager.isUserLoggedIn())")

                setupActionButtonsIfNecessary()
                themeDidChange()
                updateNavBarButtons()
                reloadTable()
            }
        }
    }

    private func setupActionButtonsIfNecessary() {
        if FeatureFlag.upNextShuffle.enabled {
            guard shuffleButton.allTargets.isEmpty else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: Constants.Notifications.themeChanged, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(subscriptionStatusDidChange), name: ServerNotifications.subscriptionStatusChanged, object: nil)
            themeDidChange()
            shuffleButton.addTarget(self, action: #selector(shuffleButtonTapped), for: .touchUpInside)
        } else {
            guard clearQueueButton.allTargets.isEmpty else { return }
            clearQueueButton.setTitle(L10n.queueClearQueue, for: .normal)
            clearQueueButton.setTitleColor(AppTheme.colorForStyle(.primaryText02, themeOverride: themeOverride), for: .normal)
            clearQueueButton.setTitleColor(AppTheme.colorForStyle(.primaryText02, themeOverride: themeOverride).withAlphaComponent(0.5), for: .disabled)
            clearQueueButton.titleLabel?.font = UIFont.font(ofSize: 13, weight: .bold, scalingWith: .footnote)
            clearQueueButton.titleLabel?.adjustsFontForContentSizeCategory = true
            clearQueueButton.addTarget(self, action: #selector(clearQueueTapped), for: .touchUpInside)
        }
        setupSortButtonIfNecessary()
        setupFilterButtonIfNecessary()
    }

    private func setupFilterButtonIfNecessary() {
        guard FeatureFlag.upNextFilter.enabled, filterButton.allTargets.isEmpty else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(updateFilterButtonImage), name: Constants.Notifications.themeChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(upNextFilterDidChange), name: Constants.Notifications.upNextFilterChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(upNextFilterDidChange), name: Constants.Notifications.playbackSessionChanged, object: nil)
        updateFilterButtonImage()
        filterButton.addTarget(self, action: #selector(filterButtonTapped), for: .touchUpInside)
        hideSkippedButton.addTarget(self, action: #selector(hideSkippedButtonTapped), for: .touchUpInside)
        filterIndicatorButton.addTarget(self, action: #selector(filterButtonTapped), for: .touchUpInside)
        clearFilterButton.addTarget(self, action: #selector(clearFilterButtonTapped), for: .touchUpInside)

        sessionSortButton.addTarget(self, action: #selector(sessionSortTapped), for: .touchUpInside)
        // The session mirrors its playlist live — reflect order/content changes made
        // on the playlist's own screens.
        NotificationCenter.default.addObserver(self, selector: #selector(upNextFilterDidChange), name: Constants.Notifications.playlistChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionPlaybackProgressed), name: Constants.Notifications.playbackProgress, object: nil)
    }

    @objc private func sessionSortTapped() {
        guard let session = Settings.playbackSession(), session.type == .smartPlaylist || session.type == .playlist else { return }
        presentSessionSortPicker(for: session)
    }

    /// Shows/hides the header filter controls, and swaps the funnel's trailing constraint so
    /// no gap is left where the (hidden) eye button sits when no filter is active. These
    /// controls always describe the queue — during a session the session section above the
    /// queue carries its own header.
    func updateFilterHeaderButtons() {
        guard FeatureFlag.upNextFilter.enabled else { return }
        let queueEmpty = PlaybackManager.shared.queue.upNextCount() == 0
        let filterActive = Settings.upNextFilter() != nil
        filterButton.isHidden = queueEmpty
        hideSkippedButton.isHidden = queueEmpty || !filterActive
        filterIndicatorButton.isHidden = queueEmpty || !filterActive
        clearFilterButton.isHidden = filterIndicatorButton.isHidden
        filterTrailingToHideSkipped?.isActive = false
        filterTrailingToShuffle?.isActive = false
        (hideSkippedButton.isHidden ? filterTrailingToShuffle : filterTrailingToHideSkipped)?.isActive = true
    }

    /// Dragging a session row reorders the source playlist itself — the session is a live
    /// mirror. Manual playlists reorder directly; smart playlists reorder their custom-order
    /// lineup, switching to drag-and-drop sort first (seeded from the current order, so
    /// nothing lands in the inbox) if they weren't custom-ordered yet.
    func moveSessionEpisode(fromRow: Int, toRow: Int) {
        guard let sessionEpisodes, let session = Settings.playbackSession(),
              session.type == .playlist || session.type == .smartPlaylist,
              fromRow < sessionEpisodes.count, toRow < sessionEpisodes.count,
              let playlist = DataManager.sharedManager.findPlaylist(uuid: session.uuid) else { return }

        let moved = sessionEpisodes[fromRow]
        let target = sessionEpisodes[toRow]

        if playlist.sortType != PlaylistSort.dragAndDrop.rawValue {
            if !playlist.manual {
                playlist.customOrderLastInsertedUuid = ""
                DataManager.sharedManager.setCustomOrder(episodeUuids: session.orderedEpisodes().map { $0.uuid }, for: playlist)
            }
            playlist.syncStatus = SyncStatus.notSynced.rawValue
            playlist.sortType = PlaylistSort.dragAndDrop.rawValue
            DataManager.sharedManager.save(playlist: playlist)
        } else if !playlist.manual, DataManager.sharedManager.positionedEpisodeUuids(for: playlist).isEmpty {
            // Custom order without a seeded lineup (the session is playing the fallback
            // order): moving an episode would silently no-op against zero position rows.
            // Materialize the current order first so the move mirrors into the playlist.
            playlist.customOrderLastInsertedUuid = ""
            DataManager.sharedManager.setCustomOrder(episodeUuids: session.orderedEpisodes().map { $0.uuid }, for: playlist)
        }

        // Resolve the target after any sort switch: the session excludes played episodes,
        // so map the drop position onto the playlist's full order.
        guard let targetIndex = session.orderedEpisodes().firstIndex(where: { $0.uuid == target.uuid }) else { return }
        DataManager.sharedManager.moveEpisode(moved.uuid, in: playlist, to: targetIndex)
        NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged, object: playlist)

        var updated = sessionEpisodes
        updated.remove(at: fromRow)
        updated.insert(moved, at: toRow)
        self.sessionEpisodes = updated
    }

    /// Sorting during a playlist session edits the playlist's own sort order (the session
    /// is a live mirror), with the same options the playlist screen offers — including
    /// custom order. A new order means a new "up first", so playback restarts from the top.
    private func presentSessionSortPicker(for session: PlaybackSession) {
        guard let playlist = DataManager.sharedManager.findPlaylist(uuid: session.uuid) else { return }
        let optionsPicker = OptionsPicker(title: L10n.playbackSessionSortTitle.localizedUppercase, themeOverride: themeOverride)
        for option in [PlaylistSort.newestToOldest, .oldestToNewest, .shortestToLongest, .longestToShortest, .dragAndDrop] {
            optionsPicker.addAction(action: OptionAction(label: option.description, selected: playlist.sortType == option.rawValue) { [weak self] in
                guard let self, playlist.sortType != option.rawValue else { return }

                // Same semantics as the playlist screen: the first switch to custom order
                // seeds the lineup from the current order; switching away KEEPS the
                // positions, so returning to custom restores the hand-made order.
                if !playlist.manual, option == .dragAndDrop, DataManager.sharedManager.positionedEpisodeUuids(for: playlist).isEmpty {
                    playlist.customOrderLastInsertedUuid = ""
                    DataManager.sharedManager.setCustomOrder(episodeUuids: session.orderedEpisodes().map { $0.uuid }, for: playlist)
                }
                playlist.syncStatus = SyncStatus.notSynced.rawValue
                playlist.sortType = option.rawValue
                DataManager.sharedManager.save(playlist: playlist)
                NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged, object: playlist)

                // Sorting only re-orders the list — what's playing keeps playing; the new
                // order takes effect from the next advance.
                self.reloadTable()
            })
        }
        optionsPicker.present(from: self)
    }

    @objc private func hideSkippedButtonTapped() {
        Settings.setUpNextFilterHideSkipped(!Settings.upNextFilterHideSkipped())
    }


    @objc private func clearFilterButtonTapped() {
        Settings.setUpNextFilter(nil)
    }

    @objc private func updateFilterButtonImage() {
        let filterActive = Settings.upNextFilter() != nil
        // 18pt renders taller than the 24pt buttons and clips the funnel's tip — 16pt fits.
        let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        let funnelStyle: ThemeStyle = filterActive ? .primaryIcon01 : .primaryIcon02
        let funnel = (UIImage(systemName: filterActive ? "funnel.fill" : "funnel", withConfiguration: symbolConfiguration)
            ?? UIImage(systemName: "line.3.horizontal.decrease", withConfiguration: symbolConfiguration))?
            .withTintColor(AppTheme.colorForStyle(funnelStyle, themeOverride: themeOverride), renderingMode: .alwaysOriginal)
        filterButton.setImage(funnel, for: .normal)
        filterButton.imageView?.adjustsImageSizeForAccessibilityContentSizeCategory = true
        filterButton.imageView?.contentMode = .scaleAspectFit
        filterButton.accessibilityLabel = L10n.upNextFilterTitle

        let hideSkipped = Settings.upNextFilterHideSkipped()
        let eyeStyle: ThemeStyle = hideSkipped ? .primaryIcon01 : .primaryIcon02
        let eyeImage = UIImage(systemName: hideSkipped ? "eye.slash.fill" : "eye", withConfiguration: symbolConfiguration)?
            .withTintColor(AppTheme.colorForStyle(eyeStyle, themeOverride: themeOverride), renderingMode: .alwaysOriginal)
        hideSkippedButton.setImage(eyeImage, for: .normal)
        hideSkippedButton.imageView?.adjustsImageSizeForAccessibilityContentSizeCategory = true
        hideSkippedButton.imageView?.contentMode = .scaleAspectFit
        hideSkippedButton.accessibilityLabel = hideSkipped ? L10n.upNextFilterShowSkipped : L10n.upNextFilterHideSkipped

        // Indicator line: "Filter: Name (Type)" in the enabled blue; opens the picker.
        // (Sessions announce themselves through the pill switcher, not this line.)
        var indicatorConfig = filterIndicatorButton.configuration ?? .plain()
        indicatorConfig.contentInsets = .zero
        indicatorConfig.image = nil
        if let filter = Settings.upNextFilter(), let title = filter.title {
            let typeLabel: String
            switch filter.type {
            case .podcast: typeLabel = L10n.playbackSessionTypePodcast
            case .folder: typeLabel = L10n.upNextFilterTypeFolder
            case .smartPlaylist: typeLabel = L10n.upNextFilterTypeSmartPlaylist
            case .playlist: typeLabel = L10n.playbackSessionTypePlaylist
            }
            var attributedTitle = AttributedString(L10n.upNextFilterIndicator(title, typeLabel))
            attributedTitle.font = UIFont.font(ofSize: 13, weight: .medium, scalingWith: .footnote)
            attributedTitle.foregroundColor = AppTheme.colorForStyle(.primaryIcon01, themeOverride: themeOverride)
            indicatorConfig.attributedTitle = attributedTitle
        }
        filterIndicatorButton.configuration = indicatorConfig
        filterIndicatorButton.accessibilityLabel = L10n.upNextFilterTitle

        let clearImage = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))?
            .withTintColor(AppTheme.colorForStyle(.primaryIcon02, themeOverride: themeOverride), renderingMode: .alwaysOriginal)
        clearFilterButton.setImage(clearImage, for: .normal)
        clearFilterButton.accessibilityLabel = L10n.upNextFilterClear
    }

    @objc private func upNextFilterDidChange() {
        updateFilterButtonImage()
        updateFilterHeaderButtons()
        reloadTable()
    }

    /// Recomputes which queued episodes match the active filter (nil when no filter is set),
    /// which queue indices are visible when the compact "hide skipped" view is on, and the
    /// active session's remaining episodes.
    func refreshUpNextFilterMatches() {
        if let session = Settings.playbackSession() {
            let paused = Settings.playbackSessionPaused()

            // The pill auto-follows playback ownership: it snaps to whichever world is
            // playing when that changes, but the user can freely peek at the other one.
            let sessionActive = !paused
            if lastKnownSessionActive != sessionActive {
                displayedWorld = sessionActive ? .session : .upNext
                lastKnownSessionActive = sessionActive
            }

            sessionInboxCount = Self.inboxCount(for: session)

            // The playing episode is on the Now Playing card, so the list shows what's
            // still to come (while paused the queue is playing — nothing to exclude).
            // The header's counts and time still cover the whole session.
            sessionEpisodes = session.remainingEpisodes(excluding: paused ? nil : PlaybackManager.shared.currentEpisode()?.uuid)
        } else {
            sessionEpisodes = nil
            sessionInboxCount = 0
            // Ending a session keeps the Session view up (showing its empty state) —
            // only a pause transition hands the view to the queue.
            lastKnownSessionActive = nil
        }

        let episodes = PlaybackManager.shared.queue.allEpisodes(includeNowPlaying: false)

        var visible: [Int]?
        if FeatureFlag.upNextFilter.enabled, let filter = Settings.upNextFilter() {
            let matching = filter.matchingEpisodeUuids(in: episodes)
            upNextFilterMatchingUuids = matching
            if Settings.upNextFilterHideSkipped() {
                visible = episodes.enumerated().compactMap { matching.contains($0.element.uuid) ? $0.offset : nil }
            }
        } else {
            upNextFilterMatchingUuids = nil
        }

        visibleQueueIndices = visible
    }

    /// Slot-model reorder for the compact view: visible (matching) episodes swap among the
    /// queue positions they already occupy, so hidden episodes never move. Playback order of
    /// matching episodes always equals exactly what the compact list shows.
    func moveVisibleEpisode(fromVisibleRow: Int, toVisibleRow: Int) {
        guard let visibleIndices = visibleQueueIndices,
              fromVisibleRow < visibleIndices.count, toVisibleRow < visibleIndices.count else { return }

        let queue = PlaybackManager.shared.queue
        var newOrder = queue.allEpisodes(includeNowPlaying: false)
        guard let maxIndex = visibleIndices.max(), maxIndex < newOrder.count else {
            refreshUpNextFilterMatches()
            return
        }

        var visibleEpisodes = visibleIndices.map { newOrder[$0] }
        let moved = visibleEpisodes.remove(at: fromVisibleRow)
        visibleEpisodes.insert(moved, at: toVisibleRow)
        for (slot, queueIndex) in visibleIndices.enumerated() {
            newOrder[queueIndex] = visibleEpisodes[slot]
        }
        queue.reorderUpNext(sortedEpisodes: newOrder)
    }

    /// Step one of the two-step filter picker: choose the kind (or None to clear).
    /// The active filter's type row shows its current selection as a secondary label.
    @objc private func filterButtonTapped() {
        let optionsPicker = OptionsPicker(title: L10n.upNextFilterTitle.localizedUppercase, themeOverride: themeOverride)
        let activeFilter = Settings.upNextFilter()

        optionsPicker.addAction(action: OptionAction(label: L10n.upNextFilterEverything, selected: activeFilter == nil) {
            Settings.setUpNextFilter(nil)
        })

        // Shortcuts to the last few filters used, so the common case skips the drill-in.
        let recents = Settings.upNextRecentFilters().filter { $0.title != nil }
        if !recents.isEmpty {
            optionsPicker.addSectionTitle(L10n.upNextFilterRecentHeader.localizedUppercase)
            for recent in recents {
                let typeLabel = Self.filterTypeLabels.first(where: { $0.0 == recent.type })?.1
                optionsPicker.addAction(action: OptionAction(label: recent.title ?? "", secondaryLabel: typeLabel, selected: recent == activeFilter) {
                    Settings.setUpNextFilter(recent)
                })
            }
        }

        optionsPicker.addSectionTitle(L10n.upNextFilterTypeHeader.localizedUppercase)
        for (type, label) in Self.filterTypeLabels {
            let isActiveType = activeFilter?.type == type
            let action = OptionAction(label: label, secondaryLabel: isActiveType ? activeFilter?.title : nil) {}
            // A submenu presents the item list on top; choosing there dismisses both,
            // and the row renders a disclosure chevron.
            action.submenu = { [weak self] in
                self?.makeFilterItemPicker(for: type, title: label)
            }
            optionsPicker.addAction(action: action)
        }

        optionsPicker.present(from: self)
    }

    private static let filterTypeLabels: [(UpNextFilterType, String)] = [
        (.podcast, L10n.playbackSessionTypePodcast),
        (.folder, L10n.upNextFilterTypeFolder),
        (.smartPlaylist, L10n.upNextFilterTypeSmartPlaylist),
        (.playlist, L10n.playbackSessionTypePlaylist)
    ]

    /// Step two: the items of the chosen kind. Only one filter can be active — richer
    /// combinations are what smart playlists are for.
    private func makeFilterItemPicker(for type: UpNextFilterType, title: String) -> OptionsPicker {
        let optionsPicker = OptionsPicker(title: title.localizedUppercase, themeOverride: themeOverride)
        let activeFilter = Settings.upNextFilter()

        let items: [(uuid: String, name: String, icon: String?)]
        switch type {
        case .podcast:
            items = DataManager.sharedManager.allPodcastsOrderedByTitle().map { ($0.uuid, $0.title ?? "", nil) }
        case .folder:
            items = DataManager.sharedManager.allFolders()
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { ($0.uuid, $0.name, "folder-empty") }
        case .smartPlaylist:
            items = DataManager.sharedManager.allSmartPlaylists(includeDeleted: false).map { ($0.uuid, $0.playlistName, $0.iconImageName()) }
        case .playlist:
            items = DataManager.sharedManager.allManualPlaylists(includeDeleted: false).map { ($0.uuid, $0.playlistName, $0.iconImageName()) }
        }

        for item in items {
            let filter = UpNextFilter(type: type, uuid: item.uuid)
            optionsPicker.addAction(action: OptionAction(label: item.name, icon: item.icon, selected: filter == activeFilter) {
                Settings.setUpNextFilter(filter)
            })
        }

        return optionsPicker
    }

    private func setupSortButtonIfNecessary() {
        guard FeatureFlag.upNextSort.enabled, sortButton.allTargets.isEmpty else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(updateSortButtonImage), name: Constants.Notifications.themeChanged, object: nil)
        updateSortButtonImage()
        sortButton.addTarget(self, action: #selector(sortButtonTapped), for: .touchUpInside)
    }

    @objc private func updateSortButtonImage() {
        let image = UIImage(named: "podcast-sort")?
            .withTintColor(AppTheme.colorForStyle(.primaryIcon02, themeOverride: themeOverride), renderingMode: .alwaysOriginal)
        sortButton.setImage(image, for: .normal)
        sortButton.imageView?.adjustsImageSizeForAccessibilityContentSizeCategory = true
        sortButton.imageView?.contentMode = .scaleAspectFit
        sortButton.accessibilityLabel = L10n.upNextSortTitle
    }

    @objc private func sortButtonTapped() {
        // If the tooltip is still up, opening the picker counts as discovering the feature: dismiss and mark it seen.
        dismissUpNextSortDurationTip()
        let optionsPicker = makeSortOptionsPicker()
        optionsPicker.present(from: self)
    }

    private func makeSortOptionsPicker() -> OptionsPicker {
        let optionsPicker = OptionsPicker(title: L10n.upNextSortTitle.localizedUppercase, themeOverride: themeOverride)
        for option in UpNextSortOption.allCases {
            let action = OptionAction(label: option.description) { [weak self] in
                let queue = PlaybackManager.shared.queue
                queue.reorderUpNext(sortedEpisodes: option.sort(queue.allEpisodes(includeNowPlaying: false)))
                self?.reloadTable()
                self?.track(.upNextSort, properties: ["sort_type": option.analyticsDescription])
            }
            optionsPicker.addAction(action: action)
        }
        return optionsPicker
    }

    @objc private func updateShuffleButtonState() {
        shuffleButton.isSelected = Settings.upNextShuffleEnabled()
    }

    private func actionLabelText(_ queueCount: Int) -> String {
        if FeatureFlag.upNextShuffle.enabled, queueCount == 1 {
            return L10n.queueClearEpisodeQueueSingular
        }
        return L10n.queueClearEpisodeQueuePlural(queueCount.localized())
    }

    private func performClearAll() {
        PlaybackManager.shared.queue.clearUpNextList()
        reloadTable()
        track(.upNextQueueCleared)
    }

    var userEpisodeDetailVC: UserEpisodeDetailViewController?

    /// The "Sort by duration" tooltip popover, while it's on screen. See `UIViewController.presentTip` in TipView.swift.
    var upNextSortDurationTip: UIViewController?

    func showEpisodeDetailViewController(for episode: BaseEpisode?) {
        if let episode = episode as? Episode, let parentPodcast = episode.parentPodcast() {
            let episodeController = EpisodeDetailViewController(episode: episode, podcast: parentPodcast, source: .upNext)
            episodeController.modalPresentationStyle = .formSheet
            episodeController.themeOverride = themeOverride
            present(episodeController, animated: true, completion: nil)
        } else if let userEpisode = episode as? UserEpisode {
            if let fullEpisode = DataManager.sharedManager.findUserEpisode(uuid: userEpisode.uuid) {
                userEpisodeDetailVC = UserEpisodeDetailViewController(episode: fullEpisode)
                userEpisodeDetailVC?.delegate = self
                userEpisodeDetailVC?.themeOverride = themeOverride
                userEpisodeDetailVC?.present(from: self)
            }
        }
    }

    /// The queue's counts line ("N episodes · X left", or the filter's "Playing x of y").
    /// The playing episode's live remaining time is folded in only when it belongs to the
    /// queue (a parked queue under an active session doesn't own the playing episode).
    func queueCountsText(includeNowPlaying: Bool) -> String {
        // With a filter active the counts describe what will actually play.
        if FeatureFlag.upNextFilter.enabled, Settings.upNextFilter() != nil, let matchingUuids = upNextFilterMatchingUuids {
            let matching = PlaybackManager.shared.queue.allEpisodes(includeNowPlaying: false).filter { matchingUuids.contains($0.uuid) }
            let time = TimeFormatter.shared.multipleUnitFormattedShortTime(time: matching.reduce(0.0) { $0 + max(0, $1.duration - $1.playedUpTo) })
            if matching.isEmpty {
                return L10n.queueUpNextHeaderTimeLeft(time)
            } else if matching.count == 1 {
                return L10n.queueUpNextHeaderOneEpisode(time)
            }
            return L10n.queueUpNextHeaderPlural(matching.count.localized(), time)
        }

        var totalDuration = PlaybackManager.shared.queue.upNextTotalDuration(includePlayingEpisode: false)
        if includeNowPlaying, let episode = PlaybackManager.shared.currentEpisode() {
            totalDuration += episode.duration.seconds - PlaybackManager.shared.currentTime()
        }
        let time = TimeFormatter.shared.multipleUnitFormattedShortTime(time: totalDuration)
        let count = PlaybackManager.shared.queue.upNextCount()
        if count == 0 {
            return L10n.queueUpNextHeaderTimeLeft(time)
        } else if count == 1 {
            return L10n.queueUpNextHeaderOneEpisode(time)
        }
        return L10n.queueUpNextHeaderPlural(count.localized(), time)
    }

    @objc func updateTimeRemainingLabel() {
        // Counts cover what's still to come — the playing episode isn't included,
        // so the line doesn't need to tick with playback.
        remainingLabel.text = queueCountsText(includeNowPlaying: false)
    }

    // MARK: - UIGestureRecongizerDelegate

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer != customLongPressGesture { return true }

        let touchPoint = gestureRecognizer.location(in: upNextTable)
        return touchPoint.x < (view.bounds.width - UpNextViewController.rearrangeWidth)
    }

    // MARK: - Nav bar actions

    @objc func doneTapped() {
        dismiss(animated: true, completion: nil)
    }

    @objc func selectTapped() {
        isMultiSelectEnabled = true
    }

    @objc func selectAllTapped() {
        if displayedWorld == .session {
            guard let sectionIndex = tableData.firstIndex(of: .sessionSection), (sessionEpisodes?.count ?? 0) > 0 else { return }
            upNextTable.selectAllBelow(fromIndexPath: IndexPath(row: 0, section: sectionIndex))
        } else {
            guard DataManager.sharedManager.allUpNextEpisodes().count > 1 else { return }
            upNextTable.selectAllBelow(fromIndexPath: IndexPath(row: 0, section: tableData.firstIndex(of: .upNextSection) ?? 0))
        }

        track(.upNextSelectAllButtonTapped, properties: ["select_all": true])
        updateNavBarButtons()
    }

    @objc func cancelTapped() {
        isMultiSelectEnabled = false
    }

    @objc func deselectAllTapped() {
        upNextTable.deselectAll()
        track(.upNextSelectAllButtonTapped, properties: ["select_all": false])
    }

    func updateNavBarButtons(animated: Bool = false) {
        navigationController?.navigationBar.tintColor = AppTheme.navBarIconsColor(themeOverride: themeOverride)

        let leftButton: UIBarButtonItem?
        let rightButton: UIBarButtonItem?

        let inSession = displayedWorld == .session
        let selectedCount = inSession ? selectedSessionEpisodes.count : selectedPlayListEpisodes.count
        let worldCount = inSession ? (sessionEpisodes?.count ?? 0) : PlaybackManager.shared.queue.upNextCount()

        if isMultiSelectEnabled {
            if MultiSelectHelper.shouldSelectAll(onCount: selectedCount, totalCount: worldCount) {
                rightButton = UIBarButtonItem(title: L10n.selectAll, style: .plain, target: self, action: #selector(selectAllTapped))
            } else {
                rightButton = UIBarButtonItem(title: L10n.deselectAll, style: .plain, target: self, action: #selector(deselectAllTapped))
            }
            leftButton = UIBarButtonItem(title: L10n.cancel, style: .plain, target: self, action: #selector(cancelTapped))
        } else if !isMultiSelectEnabled, worldCount > 0 {
            rightButton = UIBarButtonItem(title: L10n.select, style: .plain, target: self, action: #selector(selectTapped))
            if showingInTab {
                if inSession {
                    leftButton = UIBarButtonItem(title: L10n.playbackSessionSwitchShort, style: .plain, target: self, action: #selector(switchSessionTapped))
                } else if FeatureFlag.upNextShuffle.enabled, PlaybackManager.shared.queue.upNextCount() > 0 {
                    leftButton = UIBarButtonItem(title: L10n.clear, style: .plain, target: self, action: #selector(clearQueueTapped))
                } else {
                    leftButton = nil
                }
            } else {
                leftButton = UIBarButtonItem(title: L10n.done, style: .plain, target: self, action: #selector(doneTapped))
            }
        } else if inSession, showingInTab {
            rightButton = nil
            leftButton = UIBarButtonItem(title: L10n.playbackSessionSwitchShort, style: .plain, target: self, action: #selector(switchSessionTapped))
        } else {
            rightButton = nil
            if showingInTab {
                leftButton = nil
            } else {
                leftButton = UIBarButtonItem(title: L10n.done, style: .plain, target: self, action: #selector(doneTapped))
            }
        }

        navigationItem.setRightBarButton(rightButton, animated: animated)
        navigationItem.setLeftBarButton(leftButton, animated: animated)
    }

    private func animateMultiSelectChange() {
        if !isMultiSelectEnabled {
            upNextTable.indexPathsForSelectedRows?.forEach {
                upNextTable.deselectRow(at: $0, animated: false)
            }
        }

        for case let cell as PlayerCell in upNextTable.visibleCells {
            cell.shouldShowSelect(show: isMultiSelectEnabled, animate: true)
        }
    }

    // MARK: - Orientation

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .portrait
    }
}

// MARK: - Reordering Notifications

extension UpNextViewController {
    @objc func reorderingDidBegin() {
        isReorderInProgress = true
        PlaybackManager.shared.recordUpNextUserInteraction()
    }

    @objc func reorderingDidEnd() {
        isReorderInProgress = false
    }
}

// MARK: - Analytics

extension UpNextViewController {
    func track(_ event: AnalyticsEvent, properties: [String: Any]? = nil) {
        let defaultProperties: [String: Any] = ["source": source]
        let props = defaultProperties.merging(properties ?? [:]) { current, _ in current }

        Analytics.track(event, properties: props)
    }
}

enum UpNextViewSource: String, AnalyticsDescribable {
    case miniPlayer = "mini_player"
    case nowPlaying = "now_playing"
    case player
    case lockScreenWidget = "lock_screen_widget"
    case tabBar = "tab_bar"
    case unknown

    var analyticsDescription: String { rawValue }
}

/// Sort orders offered by the Up Next sort button; a one-off reorder, so there's no persisted "current" option.
enum UpNextSortOption: CaseIterable, AnalyticsDescribable {
    case newestToOldest
    case oldestToNewest
    case shortestToLongest
    case longestToShortest

    /// User facing label shown in the options picker.
    var description: String {
        switch self {
        case .newestToOldest:
            return L10n.upNextSortNewestToOldest
        case .oldestToNewest:
            return L10n.upNextSortOldestToNewest
        case .shortestToLongest:
            return L10n.upNextSortShortestToLongest
        case .longestToShortest:
            return L10n.upNextSortLongestToShortest
        }
    }

    var analyticsDescription: String {
        switch self {
        case .newestToOldest:
            return "newest_to_oldest"
        case .oldestToNewest:
            return "oldest_to_newest"
        case .shortestToLongest:
            return "shortest_to_longest"
        case .longestToShortest:
            return "longest_to_shortest"
        }
    }

    /// Returns the episodes reordered for this option. Both publish-date and time-remaining sorts break ties by added date so the order is deterministic; for time-remaining sorts, episodes with unknown duration also sink to the bottom.
    func sort(_ episodes: [BaseEpisode]) -> [BaseEpisode] {
        switch self {
        case .newestToOldest:
            return sortedByPublishedDate(episodes, ascending: false)
        case .oldestToNewest:
            return sortedByPublishedDate(episodes, ascending: true)
        case .shortestToLongest:
            return sortedByTimeRemaining(episodes, ascending: true)
        case .longestToShortest:
            return sortedByTimeRemaining(episodes, ascending: false)
        }
    }

    private func sortedByPublishedDate(_ episodes: [BaseEpisode], ascending: Bool) -> [BaseEpisode] {
        // Missing dates sort last: to the future when ascending, to the past when descending.
        let fallback: Date = ascending ? .distantFuture : .distantPast
        return episodes.sorted { lhs, rhs in
            let lhsDate = lhs.publishedDate ?? fallback
            let rhsDate = rhs.publishedDate ?? fallback

            // Same published date (including both missing): keep the order they were added.
            if lhsDate == rhsDate {
                return (lhs.addedDate ?? .distantPast) < (rhs.addedDate ?? .distantPast)
            }

            return ascending ? lhsDate < rhsDate : lhsDate > rhsDate
        }
    }

    private func sortedByTimeRemaining(_ episodes: [BaseEpisode], ascending: Bool) -> [BaseEpisode] {
        episodes.sorted { lhs, rhs in
            let lhsHasDuration = lhs.duration > 0
            let rhsHasDuration = rhs.duration > 0

            // Episodes with no known duration always sink to the bottom.
            if lhsHasDuration != rhsHasDuration {
                return lhsHasDuration
            }

            // Compare by the episodes time remaining.
            let lhsRemaining = lhs.duration - lhs.playedUpTo
            let rhsRemaining = rhs.duration - rhs.playedUpTo

            // Same time remaining (including both unknown): keep the order they were added.
            if lhsRemaining == rhsRemaining {
                return (lhs.addedDate ?? .distantPast) < (rhs.addedDate ?? .distantPast)
            }

            return ascending ? lhsRemaining < rhsRemaining : lhsRemaining > rhsRemaining
        }
    }
}

extension UpNextViewController: AnalyticsSourceProvider {
    var analyticsSource: AnalyticsSource {
        .upNext
    }
}

// MARK: - Dynamic Type support
extension UpNextViewController {

    func updateSize() {
        let metric = UIFontMetrics(forTextStyle: .largeTitle)
        let buttonSize = max(24, metric.scaledValue(for: 24))
        shuffleButton.updateSizeConstraints(to: buttonSize)
        if FeatureFlag.upNextSort.enabled {
            sortButton.updateSizeConstraints(to: buttonSize)
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.preferredContentSizeCategory != previousTraitCollection?.preferredContentSizeCategory else { return }
        updateSize()
    }
}

// MARK: - Sort by Duration tooltip

/// Shows a one-time "Sort by duration" tooltip on the Up Next tab, only for upgrading users since AppDelegate suppresses the flag on fresh installs.
extension UpNextViewController {
    func showUpNextSortDurationTipIfNeeded() {
        guard
            Settings.shouldShowUpNextSortDurationTip,
            FeatureFlag.upNextSort.enabled,
            source == .tabBar,
            upNextSortDurationTip == nil,
            // Only when the sort button is actually on screen (it's hidden while the queue is empty).
            !sortButton.isHidden,
            PlaybackManager.shared.queue.upNextCount() > 0
        else {
            return
        }
        upNextSortDurationTip = presentTip(
            title: L10n.upNextSortDurationTooltipTitle,
            message: L10n.upNextSortDurationTooltipBody,
            anchor: .item(sortButton),
            onTap: { [weak self] in
                self?.dismissUpNextSortDurationTip()
            },
            onDismiss: { [weak self] in
                self?.dismissUpNextSortDurationTip()
            },
            onShow: { [weak self] in
                self?.track(.upNextSortTooltipShown)
            }
        )
    }

    func dismissUpNextSortDurationTip() {
        guard upNextSortDurationTip != nil else { return }
        Settings.shouldShowUpNextSortDurationTip = false
        track(.upNextSortTooltipClosed)
        upNextSortDurationTip?.dismiss(animated: true) { [weak self] in
            self?.upNextSortDurationTip = nil
        }
    }
}

/// Fork: the Switch Session sheet — mirrors the Playlists screen's rows (artwork grid,
/// name, episode count) so picking a session feels like picking a playlist. The first
/// row is "Up Next": it ends the session and hands playback back to the queue. With
/// `includeUpNext: false` it becomes the "Choose session" sheet (no session active yet,
/// so there is no queue mode to switch back to).
extension UpNextViewController {
    /// Fork: Remove from Session on session rows targets the playing session.
    func multiSelectCurrentSession() -> Session? {
        guard let playing = Settings.playbackSession() else { return nil }
        return SessionStore.shared.session(forStore: playing.uuid)
    }
}

class SwitchSessionViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let themeOverride: Theme.ThemeType?
    private let includeUpNext: Bool
    private let onSwitched: (Bool) -> Void
    /// Sessions ordered by recency of use, latest first; never-used ones keep their
    /// list order after the used ones. One row per session: a lens acting as a
    /// session's feeder IS that session — its store row (which plays the lineup)
    /// stands for both, so the lens row is dropped.
    private let playlists: [EpisodeFilter] = {
        let all = DataManager.sharedManager.allPlaylists(includeDeleted: false)
            .filter { !SessionStore.shared.feederPlaylistUuids.contains($0.uuid) }
        let listedUuids = Set(all.map(\.uuid))
        let unique = all.filter { playlist in
            guard !playlist.manual,
                  let session = SessionStore.shared.session(forSmartPlaylistFeeder: playlist.uuid),
                  let storeUuid = session.storePlaylistUuid, listedUuids.contains(storeUuid) else { return true }
            return false
        }
        return unique.enumerated().sorted { a, b in
            let aUsed = lastUsed(for: a.element)
            let bUsed = lastUsed(for: b.element)
            if aUsed == bUsed { return a.offset < b.offset }
            return aUsed > bUsed
        }.map(\.element)
    }()

    private static func lastUsed(for playlist: EpisodeFilter) -> Date {
        let session = SessionStore.shared.session(forStore: playlist.uuid)
            ?? SessionStore.shared.session(forSmartPlaylistFeeder: playlist.uuid)
        return session?.lastUsed ?? .distantPast
    }
    /// Shortcuts: the queue filtered by a recently used lens (switch sheet only).
    private let recentFilters: [UpNextFilter]
    private let table = UITableView(frame: .zero, style: .plain)

    init(themeOverride: Theme.ThemeType?, includeUpNext: Bool = true, onSwitched: @escaping (Bool) -> Void) {
        self.themeOverride = themeOverride
        self.includeUpNext = includeUpNext
        self.recentFilters = includeUpNext ? Array(Settings.upNextRecentFilters().filter { $0.title != nil }.prefix(3)) : []
        self.onSwitched = onSwitched
        super.init(nibName: nil, bundle: nil)
    }

    private var queueRowCount: Int { includeUpNext ? 1 + recentFilters.count : 0 }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = AppTheme.colorForStyle(.primaryUi04, themeOverride: themeOverride)

        // Title with the same left-right arrows glyph as the header's switch button —
        // or the session glyph when choosing a first session.
        let titleIcon = UIImageView(image: UIImage(systemName: includeUpNext ? "arrow.left.arrow.right" : "play.square.stack", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))?
            .withTintColor(AppTheme.colorForStyle(.primaryText01, themeOverride: themeOverride), renderingMode: .alwaysOriginal))
        let titleLabel = UILabel()
        titleLabel.text = includeUpNext ? L10n.playbackSessionSwitchShort : L10n.playbackSessionChoose
        titleLabel.font = UIFont.font(ofSize: 17, weight: .semibold, scalingWith: .headline)
        titleLabel.textColor = AppTheme.colorForStyle(.primaryText01, themeOverride: themeOverride)
        let titleStack = UIStackView(arrangedSubviews: [titleIcon, titleLabel])
        titleStack.axis = .horizontal
        titleStack.alignment = .center
        titleStack.spacing = 6
        navigationItem.titleView = titleStack

        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.register(NewPlaylistCell.self, forCellReuseIdentifier: NewPlaylistCell.reuseIdentifier)
        table.dataSource = self
        table.delegate = self
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        includeUpNext ? 2 : 1
    }

    private func isQueueSection(_ section: Int) -> Bool {
        includeUpNext && section == 0
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        isQueueSection(section) ? queueRowCount : playlists.count
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        NewPlaylistCell.cellHeight
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard includeUpNext else { return nil }
        let container = UIView()
        let label = UILabel()
        label.text = (isQueueSection(section) ? L10n.upNext : L10n.playbackSessionTabSession).localizedUppercase
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = AppTheme.colorForStyle(.primaryText02, themeOverride: themeOverride)
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6)
        ])
        return container
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        includeUpNext ? 32 : .leastNormalMagnitude
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = (tableView.dequeueReusableCell(withIdentifier: NewPlaylistCell.reuseIdentifier) as? NewPlaylistCell)
            ?? NewPlaylistCell(style: .default, reuseIdentifier: NewPlaylistCell.reuseIdentifier)
        cell.reset()

        if isQueueSection(indexPath.section) {
            if indexPath.row == 0 {
                cell.configureUpNext(episodeCount: PlaybackManager.shared.queue.upNextCount())
            } else {
                // A recent lens over the queue, in the same clothes as the Up Next row.
                let filter = recentFilters[indexPath.row - 1]
                let queueEpisodes = PlaybackManager.shared.queue.allEpisodes(includeNowPlaying: false)
                cell.configureUpNext(title: "\(L10n.upNext) · \(filter.title ?? "")",
                                     episodeCount: filter.matchingEpisodeUuids(in: queueEpisodes).count)
            }
            cell.hideSeparator(indexPath.row == queueRowCount - 1)
            return cell
        }

        let playlist = playlists[indexPath.row]
        // The section header already says "Session" — no per-row type subtitle needed.
        cell.set(playlistName: playlist.playlistName, isManualPlaylist: true)
        cell.loadMetadata(for: playlist)
        cell.hideSeparator(indexPath.row == playlists.count - 1)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        AnalyticsPlaybackHelper.shared.currentSource = .upNext

        if isQueueSection(indexPath.section) {
            if indexPath.row > 0 {
                // A recent lens: switch to the queue with that filter applied.
                Settings.setUpNextFilter(recentFilters[indexPath.row - 1])
            }
            if Settings.playbackSession() != nil {
                PlaybackManager.shared.endPlaybackSession()
            }
            // Switching to Up Next means the queue takes over — start it if it isn't
            // already playing (ending a paused session doesn't autoplay).
            if !PlaybackManager.shared.playing() {
                if PlaybackManager.shared.currentEpisode() != nil {
                    PlaybackManager.shared.play()
                } else if let first = PlaybackManager.shared.queue.allEpisodes(includeNowPlaying: false).first {
                    PlaybackManager.shared.load(episode: first, autoPlay: true, overrideUpNext: false)
                }
            }
            dismiss(animated: true) { [onSwitched] in
                onSwitched(true)
                // Choosing Up Next means going there — land on the Up Next tab.
                NavigationManager.sharedManager.navigateTo(NavigationManager.upNextPageKey)
            }
            return
        }

        let playlist = playlists[indexPath.row]
        // Recency for this sheet's ordering.
        SessionStore.shared.markUsed(playbackUuid: playlist.uuid)
        let session = PlaybackSession(type: playlist.manual ? .playlist : .smartPlaylist, uuid: playlist.uuid)
        if session != Settings.playbackSession() {
            PlaybackManager.shared.startPlaybackSession(session)
        } else if Settings.playbackSessionPaused() {
            // Re-picking the active-but-paused session resumes it.
            if let episode = session.nextEpisode(after: nil) {
                PlaybackManager.shared.play(sessionEpisode: episode)
            }
        } else if !PlaybackManager.shared.playing() {
            PlaybackManager.shared.play()
        }
        dismiss(animated: true) { [onSwitched] in
            onSwitched(false)
            // Switching to a session means going there — land on its feeder page.
            Self.navigateToSessionHome(storePlaylist: playlist)
        }
    }

    /// Fork: sessions land on their feeder page (podcast page's Session tab, or the
    /// lens playlist); anything else lands on the playlist itself.
    private static func navigateToSessionHome(storePlaylist playlist: EpisodeFilter) {
        if let session = SessionStore.shared.session(forStore: playlist.uuid) {
            switch session.feeder {
            case .podcast(let uuid):
                if let podcast = DataManager.sharedManager.findPodcast(uuid: uuid, includeUnsubscribed: true) {
                    SessionManager.pendingSessionLanding = uuid
                    NavigationManager.sharedManager.navigateTo(NavigationManager.podcastPageKey, data: [NavigationManager.podcastKey: podcast])
                    return
                }
            case .smartPlaylist(let uuid):
                // Hidden "— feed" machinery isn't a destination; fall through to the store.
                if !SessionStore.shared.feederPlaylistUuids.contains(uuid), DataManager.sharedManager.findPlaylist(uuid: uuid) != nil {
                    NavigationManager.sharedManager.navigateTo(NavigationManager.filterPageKey, data: [NavigationManager.filterUuidKey: uuid])
                    return
                }
            default:
                break
            }
        }
        NavigationManager.sharedManager.navigateTo(NavigationManager.filterPageKey, data: [NavigationManager.filterUuidKey: playlist.uuid])
    }
}
