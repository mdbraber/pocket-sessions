import PocketCastsDataModel
import PocketCastsUtils
import PocketCastsServer
import UIKit

class UpNextViewController: UIViewController, UIGestureRecognizerDelegate {
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
                track(.upNextMultiSelectExited)
            } else {
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
    let endSessionButton = HitTargetButton(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
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

    let hideSessionButton = HitTargetButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))

    let worldSwitcher = UISegmentedControl(items: [L10n.upNext, L10n.playbackSessionTabSession])

    private static let worldSwitcherFont = UIFont.systemFont(ofSize: 13, weight: .medium)

    @objc private func worldSwitcherChanged() {
        displayedWorld = DisplayedWorld(rawValue: worldSwitcher.selectedSegmentIndex) ?? .upNext
        reloadTable()
    }

    /// Pill titles carry each world's episode count (including the playing episode)
    /// so the parked world stays visible in the periphery while peeking.
    func updateWorldSwitcher() {
        guard FeatureFlag.playbackSessions.enabled else { return }
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
        sessionHeaderLabel.font = UIFont.font(ofSize: 15, weight: .semibold, scalingWith: .subheadline)
        view.addSubview(sessionHeaderLabel)
        sessionHeaderLabel.translatesAutoresizingMaskIntoConstraints = false

        sessionMetaLabel.style = .primaryText02
        sessionMetaLabel.font = UIFont.font(ofSize: 13, scalingWith: .footnote)
        view.addSubview(sessionMetaLabel)
        sessionMetaLabel.translatesAutoresizingMaskIntoConstraints = false

        sessionInboxLabel.font = UIFont.font(ofSize: 13, weight: .medium, scalingWith: .footnote)
        view.addSubview(sessionInboxLabel)
        sessionInboxLabel.translatesAutoresizingMaskIntoConstraints = false

        // Trailing controls in a stack so hidden buttons collapse — whatever is visible
        // (e.g. only the switcher in the "Session: None" state) hugs the right edge.
        switchSessionButton.addTarget(self, action: #selector(switchSessionTapped), for: .touchUpInside)
        goToSessionButton.addTarget(self, action: #selector(openSessionSource), for: .touchUpInside)
        let buttonsStack = UIStackView(arrangedSubviews: [goToSessionButton, sessionSortButton, switchSessionButton, endSessionButton])
        buttonsStack.axis = .horizontal
        buttonsStack.alignment = .center
        buttonsStack.spacing = 16
        view.addSubview(buttonsStack)
        buttonsStack.translatesAutoresizingMaskIntoConstraints = false


        NSLayoutConstraint.activate([
            sessionHeaderLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            sessionHeaderLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            sessionHeaderLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttonsStack.leadingAnchor, constant: -10),

            sessionMetaLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            sessionMetaLabel.topAnchor.constraint(equalTo: sessionHeaderLabel.bottomAnchor, constant: 1),
            sessionMetaLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),

            sessionInboxLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            sessionInboxLabel.topAnchor.constraint(equalTo: sessionMetaLabel.bottomAnchor, constant: 3),
            sessionInboxLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),

            buttonsStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            buttonsStack.centerYAnchor.constraint(equalTo: sessionHeaderLabel.centerYAnchor),
            goToSessionButton.widthAnchor.constraint(equalToConstant: 24),
            goToSessionButton.heightAnchor.constraint(equalToConstant: 24),
            endSessionButton.widthAnchor.constraint(equalToConstant: 20),
            endSessionButton.heightAnchor.constraint(equalToConstant: 20),
            switchSessionButton.widthAnchor.constraint(equalToConstant: 24),
            switchSessionButton.heightAnchor.constraint(equalToConstant: 24),
            sessionSortButton.widthAnchor.constraint(equalToConstant: 24),
            sessionSortButton.heightAnchor.constraint(equalToConstant: 24)
        ])

        // The title opens the session's source (the session is a live mirror of it);
        // the inbox line opens the same place to triage.
        sessionHeaderLabel.isUserInteractionEnabled = true
        sessionHeaderLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openSessionSource)))
        sessionInboxLabel.isUserInteractionEnabled = true
        sessionInboxLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(sessionInboxNoticeTapped)))
        return view
    }()

    let sessionInboxLabel = UILabel()
    let sessionMetaLabel = ThemeableLabel()
    let switchSessionButton = HitTargetButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
    let goToSessionButton = HitTargetButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))

    /// Offers the most recently played sessions (limit configurable in Settings › General);
    /// picking one starts a session on that source.
    @objc func switchSessionTapped() {
        let recents = Settings.recentPlaybackSessions()
        guard !recents.isEmpty else { return }

        let optionsPicker = OptionsPicker(title: L10n.playbackSessionSwitchTitle.localizedUppercase, themeOverride: themeOverride)
        let current = Settings.playbackSession()
        for recent in recents {
            let typeLabel: String
            switch recent.type {
            case .podcast: typeLabel = L10n.playbackSessionTypePodcast
            case .playlist: typeLabel = L10n.playbackSessionTypePlaylist
            case .smartPlaylist: typeLabel = L10n.upNextFilterTypeSmartPlaylist
            }
            optionsPicker.addAction(action: OptionAction(label: recent.title ?? "", secondaryLabel: typeLabel, selected: recent == current) {
                guard recent != current else { return }
                AnalyticsPlaybackHelper.shared.currentSource = .upNext
                PlaybackManager.shared.startPlaybackSession(recent)
            })
        }
        optionsPicker.present(from: self)
    }

    /// "N episodes · X left" for the whole session. DB progress lags playback, so the
    /// playing episode's remaining time comes from the player — that's what keeps the
    /// line ticking down.
    func sessionMetaText() -> String? {
        guard let session = Settings.playbackSession() else { return nil }
        let remainingEpisodes = session.remainingEpisodes(excluding: nil)
        var totalDuration = remainingEpisodes.reduce(0.0) { $0 + max(0, $1.duration - $1.playedUpTo) }
        if !Settings.playbackSessionPaused(), let current = PlaybackManager.shared.currentEpisode(),
           let sessionCurrent = remainingEpisodes.first(where: { $0.uuid == current.uuid }) {
            totalDuration -= max(0, sessionCurrent.duration - sessionCurrent.playedUpTo)
            totalDuration += max(0, PlaybackManager.shared.duration() - PlaybackManager.shared.currentTime())
        }
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

        let switchImage = UIImage(systemName: "arrow.left.arrow.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))?
            .withTintColor(AppTheme.colorForStyle(.primaryIcon02, themeOverride: themeOverride), renderingMode: .alwaysOriginal)
        switchSessionButton.setImage(switchImage, for: .normal)
        switchSessionButton.accessibilityLabel = L10n.playbackSessionSwitchTitle
        switchSessionButton.isHidden = Settings.recentPlaybackSessions().isEmpty && session == nil

        // Go to the source this session mirrors (podcast, playlist, or smart playlist).
        let goToImage = UIImage(systemName: "arrow.up.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))?
            .withTintColor(AppTheme.colorForStyle(.primaryIcon02, themeOverride: themeOverride), renderingMode: .alwaysOriginal)
        goToSessionButton.setImage(goToImage, for: .normal)
        goToSessionButton.accessibilityLabel = L10n.playbackSessionGoTo
        goToSessionButton.isHidden = session == nil

        // With no session the view shows a dimmed "Session" bar with the switcher
        // (and the Switch Session row) as the way back in.
        guard let session else {
            sessionHeaderLabel.text = L10n.playbackSessionTabSession
            sessionHeaderLabel.style = .primaryText02
            sessionMetaLabel.text = nil
            sessionInboxLabel.isHidden = true
            sessionSortButton.isHidden = true
            endSessionButton.isHidden = true
            return
        }
        endSessionButton.isHidden = false

        // The source's name (tapping opens it); the counts line always sits beneath it
        // and covers the full session including the playing episode.
        let sourceName: String
        switch session.type {
        case .podcast:
            sourceName = DataManager.sharedManager.findPodcast(uuid: session.uuid, includeUnsubscribed: true)?.title ?? L10n.playbackSessionTabSession
        case .playlist, .smartPlaylist:
            sourceName = DataManager.sharedManager.findPlaylist(uuid: session.uuid)?.playlistName ?? L10n.playbackSessionTabSession
        }
        sessionHeaderLabel.text = sourceName
        sessionHeaderLabel.style = Settings.playbackSessionPaused() ? .primaryText02 : .primaryText01
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
        let endImage = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))?
            .withTintColor(AppTheme.colorForStyle(.primaryIcon02, themeOverride: themeOverride), renderingMode: .alwaysOriginal)
        endSessionButton.setImage(endImage, for: .normal)
        endSessionButton.accessibilityLabel = L10n.playbackSessionEnd
    }

    /// Ticks the under-card "… left" line while a session episode plays.
    @objc func sessionPlaybackProgressed() {
        guard FeatureFlag.playbackSessions.enabled, Settings.playbackSession() != nil, !Settings.playbackSessionPaused() else { return }
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

    /// Fork: navigates to the session's source — the playlist (manual or smart) or podcast
    /// it plays from. Reached from the session title and the inbox notice row. With no
    /// session, the title tap opens the switcher instead.
    @objc func openSessionSource() {
        guard let session = Settings.playbackSession() else {
            switchSessionTapped()
            return
        }

        let navigate: () -> Void
        switch session.type {
        case .podcast:
            guard let podcast = DataManager.sharedManager.findPodcast(uuid: session.uuid, includeUnsubscribed: true) else { return }
            navigate = {
                NavigationManager.sharedManager.navigateTo(
                    NavigationManager.podcastPageKey,
                    data: [NavigationManager.podcastKey: podcast]
                )
            }
        case .playlist, .smartPlaylist:
            navigate = {
                NavigationManager.sharedManager.navigateTo(
                    NavigationManager.filterPageKey,
                    data: [NavigationManager.filterUuidKey: session.uuid]
                )
            }
        }

        if presentingViewController is PlayerContainerViewController {
            dismiss(animated: true, completion: navigate)
        } else {
            navigate()
        }
    }

    /// Fork: how many episodes of the session's playlist are still in its inbox.
    static func inboxCount(for session: PlaybackSession) -> Int {
        guard session.type == .smartPlaylist,
              let filter = DataManager.sharedManager.findPlaylist(uuid: session.uuid),
              filter.usesCustomOrderOverlay, !filter.newEpisodesAutoAdd else { return 0 }
        let members = DataManager.sharedManager.playlistEpisodes(for: filter).map { $0.uuid }
        let positioned = Set(DataManager.sharedManager.positionedEpisodeUuids(for: filter))
        return members.filter { !positioned.contains($0) }.count
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
            controlsRow.topAnchor.constraint(equalTo: headerView.topAnchor),
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

            // The session's eye: hides queue episodes that belong to the active session's
            // source. Only visible while a session shares the screen.
            if FeatureFlag.playbackSessions.enabled {
                headerView.addSubview(hideSessionButton)
                hideSessionButton.translatesAutoresizingMaskIntoConstraints = false
                hideSessionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
                NSLayoutConstraint.activate([
                    hideSessionButton.trailingAnchor.constraint(equalTo: filterButton.leadingAnchor, constant: -16),
                    hideSessionButton.centerYAnchor.constraint(equalTo: controlsRow.centerYAnchor),
                    hideSessionButton.widthAnchor.constraint(equalToConstant: 24),
                    hideSessionButton.heightAnchor.constraint(equalToConstant: 24)
                ])
                hideSessionButton.addTarget(self, action: #selector(hideSessionButtonTapped), for: .touchUpInside)
            }

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

        if FeatureFlag.playbackSessions.enabled {
            // The pill switcher floats above the list as the table's header; each pill
            // shows its world's episode count and switching is view-only peeking.
            let pillContainer = UIView(frame: CGRect(x: 0, y: 0, width: upNextTable.bounds.width, height: 52))
            pillContainer.autoresizingMask = [.flexibleWidth]
            worldSwitcher.translatesAutoresizingMaskIntoConstraints = false
            worldSwitcher.addTarget(self, action: #selector(worldSwitcherChanged), for: .valueChanged)
            pillContainer.addSubview(worldSwitcher)
            NSLayoutConstraint.activate([
                worldSwitcher.leadingAnchor.constraint(equalTo: pillContainer.leadingAnchor, constant: 20),
                worldSwitcher.trailingAnchor.constraint(equalTo: pillContainer.trailingAnchor, constant: -20),
                worldSwitcher.centerYAnchor.constraint(equalTo: pillContainer.centerYAnchor)
            ])
            upNextTable.tableHeaderView = pillContainer
        }

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

        if FeatureFlag.playbackSessions.enabled {
            endSessionButton.addTarget(self, action: #selector(endSessionTapped), for: .touchUpInside)
            sessionSortButton.addTarget(self, action: #selector(sessionSortTapped), for: .touchUpInside)
            // The session mirrors its playlist live — reflect order/content changes made
            // on the playlist's own screens.
            NotificationCenter.default.addObserver(self, selector: #selector(upNextFilterDidChange), name: Constants.Notifications.playlistChanged, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(sessionPlaybackProgressed), name: Constants.Notifications.playbackProgress, object: nil)
        }
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
        hideSessionButton.isHidden = queueEmpty || !FeatureFlag.playbackSessions.enabled || Settings.playbackSession() == nil
        filterIndicatorButton.isHidden = queueEmpty || !filterActive
        clearFilterButton.isHidden = filterIndicatorButton.isHidden
        filterTrailingToHideSkipped?.isActive = false
        filterTrailingToShuffle?.isActive = false
        (hideSkippedButton.isHidden ? filterTrailingToShuffle : filterTrailingToHideSkipped)?.isActive = true
    }

    @objc private func endSessionTapped() {
        PlaybackManager.shared.endPlaybackSession()
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

                // Start playing whatever the new order puts on top (unless it already is).
                if let top = session.nextEpisode(after: nil), top.uuid != PlaybackManager.shared.currentEpisode()?.uuid {
                    AnalyticsPlaybackHelper.shared.currentSource = .upNext
                    PlaybackManager.shared.play(sessionEpisode: top)
                }
                self.reloadTable()
            })
        }
        optionsPicker.present(from: self)
    }

    @objc private func hideSkippedButtonTapped() {
        Settings.setUpNextFilterHideSkipped(!Settings.upNextFilterHideSkipped())
    }

    @objc private func hideSessionButtonTapped() {
        Settings.setUpNextHideSessionEpisodes(!Settings.upNextHideSessionEpisodes())
    }


    @objc private func clearFilterButtonTapped() {
        Settings.setUpNextFilter(nil)
    }

    @objc private func updateFilterButtonImage() {
        let filterActive = Settings.upNextFilter() != nil
        let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
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

        let hideSession = Settings.upNextHideSessionEpisodes()
        let sessionToggleStyle: ThemeStyle = hideSession ? .primaryIcon01 : .primaryIcon02
        let sessionToggleImage = UIImage(systemName: hideSession ? "play.square.stack.fill" : "play.square.stack", withConfiguration: symbolConfiguration)?
            .withTintColor(AppTheme.colorForStyle(sessionToggleStyle, themeOverride: themeOverride), renderingMode: .alwaysOriginal)
        hideSessionButton.setImage(sessionToggleImage, for: .normal)
        hideSessionButton.imageView?.adjustsImageSizeForAccessibilityContentSizeCategory = true
        hideSessionButton.imageView?.contentMode = .scaleAspectFit
        hideSessionButton.accessibilityLabel = L10n.upNextHideSessionEpisodes

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
        if FeatureFlag.playbackSessions.enabled, let session = Settings.playbackSession() {
            let paused = Settings.playbackSessionPaused()

            // The pill auto-follows playback ownership: it snaps to whichever world is
            // playing when that changes, but the user can freely peek at the other one.
            let sessionActive = !paused
            if lastKnownSessionActive != sessionActive {
                displayedWorld = sessionActive ? .session : .upNext
                lastKnownSessionActive = sessionActive
            }

            sessionInboxCount = Self.inboxCount(for: session)

            // Self-heal the recents list: sessions persisted from before the switcher
            // existed register themselves (idempotent — MRU front insert).
            Settings.rememberRecentPlaybackSession(session)

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

        // The session's eye: hide queue episodes that belong to the session's source —
        // they're already on stage above. Visual only; positions and playback untouched.
        if Settings.upNextHideSessionEpisodes(), let session = Settings.playbackSession() {
            let sessionUuids = session.matchingEpisodeUuids(in: episodes)
            let base = visible ?? Array(episodes.indices)
            visible = base.filter { !sessionUuids.contains(episodes[$0].uuid) }
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
        // In the header, the playing episode counts toward the queue unless a session
        // owns it (session active → the parked queue's numbers are queue-only).
        let sessionActive = FeatureFlag.playbackSessions.enabled && Settings.playbackSession() != nil && !Settings.playbackSessionPaused()
        remainingLabel.text = queueCountsText(includeNowPlaying: !sessionActive)
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
        guard DataManager.sharedManager.allUpNextEpisodes().count > 1 else { return }
        upNextTable.selectAllBelow(fromIndexPath: IndexPath(row: 0, section: tableData.firstIndex(of: .upNextSection) ?? 0))

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

        if isMultiSelectEnabled {
            if MultiSelectHelper.shouldSelectAll(onCount: selectedPlayListEpisodes.count, totalCount: PlaybackManager.shared.queue.upNextCount()) {
                rightButton = UIBarButtonItem(title: L10n.selectAll, style: .plain, target: self, action: #selector(selectAllTapped))
            } else {
                rightButton = UIBarButtonItem(title: L10n.deselectAll, style: .plain, target: self, action: #selector(deselectAllTapped))
            }
            leftButton = UIBarButtonItem(title: L10n.cancel, style: .plain, target: self, action: #selector(cancelTapped))
        } else if !isMultiSelectEnabled, PlaybackManager.shared.queue.upNextCount() > 0 {
            rightButton = UIBarButtonItem(title: L10n.select, style: .plain, target: self, action: #selector(selectTapped))
            if showingInTab {
                if FeatureFlag.upNextShuffle.enabled, PlaybackManager.shared.queue.upNextCount() > 0 {
                    leftButton = UIBarButtonItem(title: L10n.clear, style: .plain, target: self, action: #selector(clearQueueTapped))
                } else {
                    leftButton = nil
                }
            } else {
                leftButton = UIBarButtonItem(title: L10n.done, style: .plain, target: self, action: #selector(doneTapped))
            }
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
