import PocketCastsDataModel
import PocketCastsUtils
import PocketCastsServer
import UIKit

class UpNextViewController: UIViewController, UIGestureRecognizerDelegate, FilterCreatedDelegate {
    static let playerCell = "PlayerCell"
    static let episodeCell = "EpisodeCell"
    static let nowPlayingCell = "UpNextNowPlayingCell"
    static let emptyStateCell = "EmptyStateCell"
    static let sessionInboxNoticeCell = "SessionInboxNoticeCell"
    static let sessionPausedBannerCell = "SessionPausedBannerCell"
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
    /// Suppresses the per-append selection didSet work (count/inset/nav rebuild) during a bulk change
    /// like Select All — the caller applies it ONCE afterwards instead of N times (N nav rebuilds
    /// made Select All very slow on a long session).
    var bulkSelecting = false

    var selectedSessionEpisodes = [BaseEpisode]() {
        didSet {
            guard !bulkSelecting else { return }
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
    let sessionHeaderLabel = ThemeableLabel()
    let sessionSortButton = HitTargetButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
    /// Fork: the session CHOOSER's own controls — sort order, and a ⋯ menu of "Show"
    /// toggles. Same construction as the queue's `sortButton`.
    let sessionListSortButton = HitTargetButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
    let sessionListMoreButton = HitTargetButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))

    /// Which world the screen is showing. The session list (`.session` + `.list`) is the home:
    /// it lists every session plus a pinned "Up Next" row. Tapping the Up Next row drops into
    /// the queue lineup (`.upNext`); tapping a session drops into that session's lineup
    /// (`.session` + `.lineup`). The top-left back chevron returns to the list.
    enum DisplayedWorld: Int {
        case upNext = 0
        case session = 1
    }

    var displayedWorld: DisplayedWorld = .session

    /// Fork: the Session world has two levels — the chooser listing every session, and
    /// the lineup of one session. View state only: never persisted, and it has no
    /// meaning while `displayedWorld == .upNext`.
    enum SessionLevel {
        case list
        case lineup
    }

    var sessionLevel: SessionLevel = .list {
        didSet {
            guard oldValue != sessionLevel, sessionLevel == .list else { return }
            // The chooser has no episode rows to act on.
            isMultiSelectEnabled = false
        }
    }

    /// Fork: which session the LINEUP level is showing. View state only — never persisted,
    /// and it never touches playback: browsing a session is navigation, nothing more. Holds
    /// the session's store-playlist uuid, i.e. the same uuid a `PlaybackSession` carries, so
    /// it compares directly against `Settings.playbackSession()`.
    var browsedSessionUuid: String?

    /// The session the lineup renders: whatever is being browsed, falling back to the
    /// active one (entering the Session world mid-session lands on it). Every lineup-level
    /// read — episodes, header, counts, sort, swipes, moves — goes through this.
    var browsedPlaybackSession: PlaybackSession? {
        let active = Settings.playbackSession()
        guard let browsedSessionUuid else { return active }
        // Browsing the active session keeps its own type (a podcast session has no store
        // playlist); anything reached from the chooser plays its store, a manual playlist.
        if let active, active.uuid == browsedSessionUuid { return active }
        return PlaybackSession(type: .playlist, uuid: browsedSessionUuid)
    }

    /// The store `Session` behind the browsed lineup — what lineup edits act on.
    var browsedSession: Session? {
        guard let uuid = browsedPlaybackSession?.uuid else { return nil }
        return SessionStore.shared.session(forStore: uuid)
    }

    /// True when the lineup being browsed is also the one that owns playback. Everything
    /// player-facing at the lineup level (the Now Playing card, the paused banner, the
    /// "true top" re-prime) is gated on this: a browsed, non-active session has no
    /// relationship with the player at all.
    var browsingActiveSession: Bool {
        guard let active = Settings.playbackSession() else { return false }
        return browsedPlaybackSession == active
    }

    /// Whether the browsed session's playlist is in Drag & Drop sort — the ONLY sort where the lineup
    /// is hand-reorderable. Under any other sort the list is sorted, so dragging is disabled (no
    /// handles) and the info-line sort icon is drawn in the accent colour to show a sort is active.
    var browsedSessionSortIsDragAndDrop: Bool {
        guard let uuid = browsedPlaybackSession?.uuid,
              let playlist = DataManager.sharedManager.findPlaylist(uuid: uuid) else { return false }
        return playlist.sortType == PlaylistSort.dragAndDrop.rawValue
    }

    /// The lineup shows a Now Playing card only when the session it is browsing is the active one
    /// AND the player is holding one of its episodes — the card lives in whichever world owns
    /// playback (green here in the Session world, blue in Up Next).
    var browsedSessionOwnsCard: Bool {
        sessionOwnsCard && browsingActiveSession
    }

    /// Fork: the now-playing accent for the Up Next sheet — green in the Session world, blue in the
    /// Up Next world. Colours the card's (and Up Next head row's) title and equalizer by the world
    /// you're viewing, not by playback source.
    var nowPlayingWorldAccent: UIColor {
        displayedWorld == .session
            ? ThemeColor.support02(for: themeOverride)
            : ThemeColor.support01(for: themeOverride)
    }

    /// Entering the Session world lands on the lineup whenever a session is active
    /// (playing or paused — mid-session, continuity wins), on the chooser otherwise.
    var sessionLandingLevel: SessionLevel {
        Settings.playbackSession() != nil ? .lineup : .list
    }

    /// Entering the Session world: browse the active session (landing on its lineup) or,
    /// with none, land on the chooser with nothing browsed.
    func enterSessionWorld() {
        browsedSessionUuid = Settings.playbackSession()?.uuid
        sessionLevel = sessionLandingLevel
    }

    /// Fork: the chooser's rows, cached per reload (see `refreshSessionState`).
    var sessionListRows = [SessionListRow]()


    /// Fork: which session occupies the "current" slot (row 1, just under Up Next). Set when the user
    /// opens or plays a session; the active playback session always wins. The rest of the sessions
    /// list below it as the pool, in the manual drag order.
    var currentSessionUuid: String?

    var showingSessionList: Bool {
        displayedWorld == .session && sessionLevel == .list
    }

    /// Fork: where a session-list row sits — row 0 is Up Next, row 1 is the current session (each
    /// its own tinted card); the rest are the flat pool.
    func sessionPlacement(at index: Int) -> SessionListCell.Placement {
        if index == 0 { return .upNext }
        if index == 1, sessionListHasCurrent { return .current }
        return .pool
    }

    // MARK: - Session list search (fork)

    /// Set while a coalesced `reloadTable()` is queued for the next runloop turn (see `setNeedsReload`).
    var reloadScheduled = false

    /// True while a drag is in progress — the active (playing) row drops its accent box for the
    /// duration so the list reads uniform while reordering. Cleared in `dragSessionDidEnd`.
    var activeBoxSuppressed = false

    /// One-shot: on first appearance the session list rests with the search bar scrolled out of view.
    private var didRestSearchOnAppear = false

    /// Fork: "Reorder Items" mode (⋯ sheet) — pool rows swap their play button for a drag handle and
    /// tap-to-open / swipe are suspended until Done. Normally the pool shows white play buttons.
    var sessionListReorderMode = false

    /// The current search term filtering the pool (Up Next + current session always stay).
    var sessionSearchText = ""

    static let sessionSearchRowHeight: CGFloat = 56

    /// Whether the list currently has a "current session" card (row 1). False when nothing is
    /// playing or opened — then every session sits in the pool and the search row moves up under
    /// Up Next.
    var sessionListHasCurrent = false

    /// Fork: the search + ⋯ header sits directly UNDER the pinned Up Next (row 0) and Current Session
    /// (row 1) rows — so table row 2 (or row 1 when there are no sessions). The pool follows.
    var sessionSearchTableRow: Int { 1 + (sessionListHasCurrent ? 1 : 0) }

    /// The pool's size BEFORE the search filter — so the search bar stays put when a query filters
    /// every pool row out.
    var sessionListPoolCount = 0

    var showSessionSearchRow: Bool {
        guard showingSessionList else { return false }
        return sessionListPoolCount > 0 || !sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func isSessionSearchRow(_ indexPath: IndexPath) -> Bool {
        showSessionSearchRow && tableData[safe: indexPath.section] == .sessionSection && indexPath.row == sessionSearchTableRow
    }


    /// Maps a session-section TABLE row to its index in `sessionListRows`, or nil for the search row.
    func sessionListIndex(forTableRow row: Int) -> Int? {
        guard showSessionSearchRow else { return row }
        if row == sessionSearchTableRow { return nil }
        return row > sessionSearchTableRow ? row - 1 : row
    }

    /// The search bar — same component + dimensions as the podcast/playlist page.
    lazy var sessionSearchController: PCSearchBarController = {
        let controller = PCSearchBarController()
        // Sit on the queue screen's own background — without this the component paints its
        // stock secondaryUi01 strip, a visibly different rectangle behind the field.
        controller.backgroundColorOverride = AppTheme.colorForStyle(.primaryUi04, themeOverride: themeOverride)
        controller.searchDebounce = 0.2
        controller.placeholderText = L10n.sessionSearchPlaceholder
        controller.searchDelegate = self
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(controller)
        controller.didMove(toParent: self)
        controller.searchTextField.font = UIFont.font(ofSize: 15, weight: .regular, scalingWith: .subheadline)
        // Match the podcast page's search box exactly: rounded-rect corners (8), not a pill, and a
        // fixed 36pt field (overriding the collapse-on-scroll 2/3-height rule) so it can be centred
        // in the row for equal top/bottom padding rather than hugging the top.
        controller.roundedBackgroundView.layer.cornerRadius = 8
        controller.roundedBackgroundView.heightAnchor.constraint(equalToConstant: 36).isActive = true
        return controller
    }()

    /// The ⋯ button beside the search field — carries the session-list menu (Sort, hides), matching
    /// the playlist page's search + sort row.
    lazy var sessionSearchOverflowButton: ThemeSecondaryButton = {
        let button = ThemeSecondaryButton(type: .custom)
        button.setImage(UIImage(named: "podcast-more-options")?.withRenderingMode(.alwaysTemplate), for: .normal)
        button.accessibilityLabel = L10n.accessibilityMoreActions
        button.addTarget(self, action: #selector(sessionListMoreTapped), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    /// The search row's content view — the search field with the ⋯ beside it (playlist-page layout).
    lazy var sessionSearchHeaderView: UIView = {
        let header = UIView()
        let search = sessionSearchController.view!
        header.addSubview(search)
        header.addSubview(sessionSearchOverflowButton)
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            search.trailingAnchor.constraint(equalTo: sessionSearchOverflowButton.leadingAnchor, constant: 4),
            search.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            search.heightAnchor.constraint(equalToConstant: 36),
            sessionSearchOverflowButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -13),
            sessionSearchOverflowButton.centerYAnchor.constraint(equalTo: sessionSearchController.searchTextField.centerYAnchor),
            sessionSearchOverflowButton.widthAnchor.constraint(equalToConstant: 36),
            sessionSearchOverflowButton.heightAnchor.constraint(equalToConstant: 36)
        ])
        return header
    }()

    /// A single, persistent cell that hosts the search header — returning the SAME instance from
    /// cellForRow keeps the text field's focus across reloads (a dequeued cell would drop it).
    lazy var sessionSearchCell: UITableViewCell = {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.backgroundColor = .clear
        cell.contentView.backgroundColor = .clear
        sessionSearchHeaderView.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(sessionSearchHeaderView)
        NSLayoutConstraint.activate([
            sessionSearchHeaderView.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
            sessionSearchHeaderView.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor),
            sessionSearchHeaderView.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
            sessionSearchHeaderView.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor)
        ])
        return cell
    }()

    /// The lineup episode search — a SECOND search bar (Session details / Up Next details), filtering
    /// the tail episodes by title. Same component + delegate as the session-list search; the delegate
    /// routes by world (`showingSessionList`), so the two never collide.
    lazy var lineupSearchController: PCSearchBarController = {
        let controller = PCSearchBarController()
        // Same background rule as the session-list search — the queue screen's own color.
        controller.backgroundColorOverride = AppTheme.colorForStyle(.primaryUi04, themeOverride: themeOverride)
        controller.searchDebounce = 0.2
        controller.placeholderText = L10n.search
        controller.searchDelegate = self
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(controller)
        controller.didMove(toParent: self)
        controller.searchTextField.font = UIFont.font(ofSize: 15, weight: .regular, scalingWith: .subheadline)
        controller.roundedBackgroundView.layer.cornerRadius = 8
        controller.roundedBackgroundView.heightAnchor.constraint(equalToConstant: 36).isActive = true
        return controller
    }()

    lazy var lineupSearchCell: UITableViewCell = {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.backgroundColor = .clear
        cell.contentView.backgroundColor = .clear
        let search = lineupSearchController.view!
        search.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(search)
        NSLayoutConstraint.activate([
            // Full width — the search view's own XIB carries the 16pt side margins (matching the row
            // artwork inset), so pin flush to the cell edges rather than adding a second inset.
            search.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
            search.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor),
            // More breathing room above (below the card), tight to the info line below it.
            search.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 18),
            search.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: 0),
            search.heightAnchor.constraint(equalToConstant: 36)
        ])
        return cell
    }()

    // Sticky chrome above the table: the active world's header (session title block or queue
    // controls line). The list scrolls underneath it.
    private let stickyChrome = UIStackView()
    private let stickyChromeBackground = UIView()
    private var sessionHeaderHeightConstraint: NSLayoutConstraint?

    /// Fork: the session-lineup "detail" chrome — a blurred artwork backdrop plus a collapsing
    /// title, matching the playlist detail. Active only while a session lineup is shown; the
    /// queue and the chooser keep the pinned chrome.
    private let sessionArtworkModel = SessionArtworkBackdropModel()
    private weak var sessionArtworkBackdrop: UIView?
    private var sessionLineupChromeActive = false

    /// Activating the tab lands on the session list — the home of the Queue tab, with the
    /// pinned "Up Next" row at the top and the sessions below it.
    @objc private func upNextTabActivated() {
        exitToSessionList()
    }

    /// Only the pill switcher is sticky; everything below it — session title, card,
    /// counts line, and rows — scrolls as one. The title rides along as the table's
    /// header view (which, unlike section headers, never pins).
    func updateStickyChrome() {
        stickyChrome.backgroundColor = AppTheme.colorForStyle(.primaryUi04, themeOverride: themeOverride)
        stickyChromeBackground.backgroundColor = stickyChrome.backgroundColor

        let metrics = UIFontMetrics(forTextStyle: .footnote)
        let inSession = displayedWorld == .session
        var showsHeader = true
        if inSession, sessionLevel == .list {
            // Fork: the session list is the home of the Queue tab, so its nav title is "Queue"
            // (the tab bar item's name); the pinned "Up Next" row and each session drop into a
            // lineup that renames the nav title to that world. "Show Session Playlists" is the
            // round top-right nav button; the info row keeps the counts + list sort.
            sessionHeaderLabel.text = L10n.tabQueue
            showsHeader = false
            sessionMetaLabel.text = sessionListCountsText()
            sessionMetaLabel.isHidden = false
            sessionSortButton.isHidden = true
            sessionInboxLabel.isHidden = true
        } else if inSession, browsedPlaybackSession != nil {
            // The lineup uses the scrolling "detail" chrome (artwork backdrop + collapsing title)
            // instead of the pinned block — but updateSessionHeader still computes the name/meta
            // strings that chrome reuses (see updateSessionLineupPresentation). The title is the
            // standard nav-bar title now, so the counts stay in the info row alongside the sort.
            updateSessionHeader()
            showsHeader = false
        } else if !inSession {
            // The queue also uses the scrolling "detail" chrome (collapsing "Up Next" title +
            // translucent bar + artwork) so it scrolls like a playlist. updateSessionHeader isn't
            // needed — the name is fixed; the counts/controls stay their own scrolling row.
            sessionHeaderLabel.text = L10n.upNext
            sessionHeaderLabel.style = .primaryText01
            sessionBackChevron.isHidden = true
            sessionInboxLabel.isHidden = true
            showsHeader = false
        } else {
            showsHeader = false
        }

        sessionHeaderView.isHidden = !showsHeader
        let headerHeight = showsHeader ? metrics.scaledValue(for: sessionHeaderHeight) : 0
        sessionHeaderHeightConstraint?.constant = headerHeight

        // One call for every branch above: the chooser's controls only exist at `.list`.
        updateSessionListControls()

        // The lineup owns the table header (its scrolling detail chrome + artwork backdrop +
        // nav-bar treatment); every other level clears it and keeps the pinned block.
        updateSessionLineupPresentation()
        if !sessionLineupChromeActive {
            upNextTable.tableHeaderView = nil
        }

        // Only the title block is sticky at the top now. A lineup — Session details OR Up Next details
        // — has a TRANSPARENT nav bar (the artwork backdrop bleeds behind it) and no header to hold the
        // top space, so its content needs an inset to clear the nav bar. The chooser keeps the safe-area
        // default.
        let inLineup = (inSession && sessionLevel == .lineup && browsedPlaybackSession != nil) || !inSession
        let chromeHeight: CGFloat = showsHeader ? headerHeight : (inLineup ? 8 : 0)
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

    /// Header of the session section: one "Session: <name> ›" line (tap navigates — the
    /// session is a live mirror of that playlist/podcast) with sort and end-session buttons,
    /// a metadata line, and — when the playlist has untriaged episodes — the tappable inbox
    /// notice, sitting above the Now Playing card. Sessions always show their full list.
    lazy var sessionHeaderView: UIView = {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 52))

        sessionHeaderLabel.style = .primaryText01
        sessionHeaderLabel.font = UIFont.font(ofSize: 22, weight: .bold, scalingWith: .title2)
        sessionHeaderLabel.textAlignment = .center
        sessionHeaderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The title stays centred at every level; the back arrow is a separate top-left button.
        let titleRow = UIStackView(arrangedSubviews: [sessionHeaderLabel])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = 4
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleRow)

        // Fork: the way back up to the chooser is a top-left back arrow, like navigating out of a
        // folder — not an inline chevron beside the centred title.
        sessionBackChevron.isUserInteractionEnabled = true
        sessionBackChevron.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(sessionBreadcrumbTapped)))
        view.addSubview(sessionBackChevron)

        sessionInboxLabel.font = UIFont.font(ofSize: 13, weight: .medium, scalingWith: .footnote)
        view.addSubview(sessionInboxLabel)
        sessionInboxLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            // Centred at every level so "Up Next", "Sessions" and a session's own name stay put.
            titleRow.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            titleRow.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleRow.leadingAnchor.constraint(greaterThanOrEqualTo: sessionBackChevron.trailingAnchor, constant: 8),
            titleRow.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),

            // Top-left back arrow, vertically centred on the title.
            sessionBackChevron.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            sessionBackChevron.centerYAnchor.constraint(equalTo: titleRow.centerYAnchor),

            sessionInboxLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            sessionInboxLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            sessionInboxLabel.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 3)
        ])

        // The title also steps back up to the session chooser (a larger tap target than the arrow
        // alone); the inbox line opens the session's source to triage.
        titleRow.isUserInteractionEnabled = true
        titleRow.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(sessionBreadcrumbTapped)))
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

        // A stack, not individual anchors: hidden arranged subviews collapse, so the
        // chooser's controls can come and go (progressive disclosure) without leaving a
        // gap at the trailing edge or nudging the counts label.
        let buttons = UIStackView(arrangedSubviews: [sessionSortButton, sessionListSortButton, sessionListMoreButton])
        buttons.axis = .horizontal
        buttons.alignment = .center
        buttons.spacing = 16
        buttons.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(buttons)

        for button in [sessionSortButton, sessionListSortButton, sessionListMoreButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 24),
                button.heightAnchor.constraint(equalToConstant: 24)
            ])
        }

        // Identical geometry to the queue's header (see `headerView`): the label centres in
        // a 48pt row inset 8 from the top, so the gap between the info line and the rows
        // below it is the same in both worlds and at both session levels.
        let controlsRow = UILayoutGuide()
        view.addLayoutGuide(controlsRow)

        NSLayoutConstraint.activate([
            controlsRow.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controlsRow.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controlsRow.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            controlsRow.heightAnchor.constraint(equalToConstant: 48),

            sessionMetaLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            sessionMetaLabel.centerYAnchor.constraint(equalTo: controlsRow.centerYAnchor),
            sessionMetaLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -10),

            buttons.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            buttons.centerYAnchor.constraint(equalTo: controlsRow.centerYAnchor)
        ])
        return view
    }()

    let sessionInboxLabel = UILabel()
    let sessionMetaLabel = ThemeableLabel()

    /// Fork: the lineup header's leading chevron — the way back up to the chooser.
    lazy var sessionBackChevron: UIImageView = {
        let view = UIImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        return view
    }()

    /// Fork: at the lineup level the header title steps back up to the chooser.
    @objc func sessionBreadcrumbTapped() {
        exitToSessionList()
    }

    /// Fork: open the queue world from the pinned "Up Next" list row.
    func enterUpNextWorld() {
        clearLineupSearch()
        displayedWorld = .upNext
        reloadTable()
        resetLineupScrollToTop()
    }

    /// Fork: enter Reorder Items mode (⋯ → Reorder Items). Pool rows show drag handles; play buttons,
    /// swipe and tap-to-open are suspended until Done.
    func enterSessionReorderMode() {
        guard showingSessionList else { return }
        sessionListReorderMode = true
        reloadTable()
    }

    /// Fork: leave Reorder Items mode (the Done button).
    @objc func exitSessionReorderMode() {
        sessionListReorderMode = false
        reloadTable()
    }

    /// Fork: from the session-list home, drill straight into the ACTIVE lane — the active session's
    /// lineup if a session is playing, otherwise the Up Next queue. Used when the Queue tab is
    /// re-tapped while already on the list home (see MainTabBarController).
    func openActiveLane() {
        guard showingSessionList else { return }
        if Settings.playbackSession() != nil, let row = sessionListRows.first(where: { $0.isActive && !$0.isUpNext }) {
            openSessionFromList(row)
        } else {
            enterUpNextWorld()
        }
    }

    /// The resting scroll position for the session list — the top (Up Next). The search bar is an
    /// inline row below the pinned Up Next / Current Session rows now, not hidden under the nav bar.
    var sessionListRestingTopOffsetY: CGFloat {
        -upNextTable.adjustedContentInset.top
    }

    /// Fork: back to the session list (the home) from a session lineup OR the queue world.
    @objc func exitToSessionList() {
        clearLineupSearch()
        displayedWorld = .session
        browsedSessionUuid = nil
        sessionLevel = .list
        reloadTable()
        upNextTable.setContentOffset(CGPoint(x: 0, y: sessionListRestingTopOffsetY), animated: false)
    }

    /// Fork: drop any lineup title filter (and its keyboard) when leaving / switching a lineup, so the
    /// next lineup opens unfiltered.
    func clearLineupSearch() {
        lineupSearchController.searchTextField?.resignFirstResponder()
        lineupSearchController.searchTextField?.text = ""
        lineupSearchText = ""
    }


    /// Fork: the search box filters the pool live. It re-filters the already-built source in place —
    /// NO per-keystroke DB rebuild — and only reloads the table rows (the persistent search cell keeps
    /// the field's focus across reloadData).
    private func applySessionSearch(_ term: String) {
        sessionSearchText = term
        guard showingSessionList else { return }
        // The search field lives in a table CELL, so reloadData resigns its first-responder even with
        // the persistent-cell reuse. Capture focus + cursor and restore them so the user can keep
        // typing without the keyboard dropping after each letter.
        let field = sessionSearchController.searchTextField
        let wasFocused = field?.isFirstResponder ?? false
        let cursor = field?.selectedTextRange
        deriveSessionListRows(from: lastSessionSource)
        upNextTable.reloadData()
        if wasFocused, field?.isFirstResponder == false {
            field?.becomeFirstResponder()
            if let cursor { field?.selectedTextRange = cursor }
        }
    }

    /// Fork: the lineup search — filters the tail episodes of the browsed session / Up Next by title.
    /// `lineupSearchText`'s didSet reloads the table; capture + restore focus so typing survives.
    private func applyLineupSearch(_ term: String) {
        guard !showingSessionList else { return }
        let field = lineupSearchController.searchTextField
        let wasFocused = field?.isFirstResponder ?? false
        let cursor = field?.selectedTextRange
        lineupSearchText = term // didSet reloads the table
        if wasFocused, field?.isFirstResponder == false {
            field?.becomeFirstResponder()
            if let cursor { field?.selectedTextRange = cursor }
        }
    }

    /// Cheap: builds the displayed `[Up Next, current, ...pool]` from an already-built source, applying
    /// the current-session extraction and the search filter. No DB work — safe to run per keystroke.
    private func deriveSessionListRows(from all: [SessionListRow]) {
        let activeUuid = all.first(where: { $0.isActive })?.sessionUuid
        if let activeUuid { currentSessionUuid = activeUuid }
        // Fork: the layout is [Up Next] [Current Session] [search + ⋯] [pool]. The Current Session is
        // ALWAYS shown (the sticky pointer — active or last-opened); it reads paused when the queue is
        // playing. Up Next and Current are pinned ABOVE the search, so the search filters the POOL only.
        let pointerUuid = currentSessionUuid.flatMap { uuid in all.contains { $0.sessionUuid == uuid } ? uuid : nil }
        let currentUuid = activeUuid ?? pointerUuid ?? all.first?.sessionUuid
        let currentRow = currentUuid.flatMap { uuid in all.first { $0.sessionUuid == uuid } }
        sessionListHasCurrent = currentRow != nil
        var pool = all.filter { $0.sessionUuid != currentUuid }
        sessionListPoolCount = pool.count
        let query = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            pool = pool.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        sessionListRows = [upNextListRow()] + (currentRow.map { [$0] } ?? []) + pool
    }

    /// Fork: a single tap on a session-list row PEEKS at that lane's page (its lineup) — pure
    /// navigation, no playback change and NO promotion to the current session. A session only becomes
    /// current when you actually play it (the play button).
    func openSessionLanePage(_ row: SessionListRow) {
        if row.isUpNext {
            enterUpNextWorld()
        } else {
            openSessionFromList(row)
        }
    }

    /// Fork: make `newUuid` the current session (row 1). The session it REPLACES floats to the TOP of
    /// the pool (most-recently-current), rather than dropping back to wherever it previously sat — so
    /// the last thing you were on is always the first session under the current one. The caller reloads
    /// afterward (once the new session is actually active), which re-derives the rows from this order.
    private func makeCurrentSession(_ newUuid: String) {
        let previous = currentSessionUuid
        currentSessionUuid = newUuid
        guard let previous, previous != newUuid,
              let idx = lastSessionSource.firstIndex(where: { $0.sessionUuid == previous }) else { return }
        let row = lastSessionSource.remove(at: idx)
        lastSessionSource.insert(row, at: 0)
        SessionStore.shared.reorderSessions(lastSessionSource.map(\.sessionUuid))
    }

    /// Fork: the play/pause button on a session-list row. Sounding → pause; paused/idle → play,
    /// resume, or start that lane. Playing a session makes it the current one (row 1). The list
    /// repaints from the playback notifications (see `sessionPlayStateChanged`), NOT here — a second
    /// `reloadTable` would double-reload and flicker.
    func playSessionLane(_ row: SessionListRow) {
        // This lane is the one sounding — the button is a pause.
        if row.isPlaying {
            PlaybackManager.shared.pause()
            return
        }

        AnalyticsPlaybackHelper.shared.currentSource = .upNext
        if row.isUpNext {
            if queueOwnsCard {
                PlaybackManager.shared.play() // resume the paused queue
            } else if let current = PlaybackManager.shared.currentEpisode(),
                      upNextCardEpisode?.uuid == current.uuid, PlaybackManager.shared.playing() {
                // The SAME episode heads both worlds and is already sounding — just move the pointer
                // to the queue. No restart, and it stays in the session too (see adoptCurrentEpisodeIntoQueue).
                PlaybackManager.shared.adoptCurrentEpisodeIntoQueue()
                setNeedsReload()
            } else {
                // A session owns the card — hand playback back to the queue's OWN next episode. This is a
                // SWITCH, not a deliberate end, so it doesn't toast "Session ended" (the session stays).
                PlaybackManager.shared.endPlaybackSession()
                if !PlaybackManager.shared.playing() { PlaybackManager.shared.play() }
            }
            return
        }
        makeCurrentSession(row.sessionUuid)
        if row.ownsCard {
            // The session owns the card (paused in place) → just resume it.
            PlaybackManager.shared.play()
            return
        }
        if row.isActive {
            // Active pointer but PARKED behind the queue — play() would resume the queue's episode,
            // so switch playback back to the session at its last-played episode instead.
            resumePausedSession()
            return
        }
        guard let storeUuid = row.storeUuid else { return }
        PlaybackManager.shared.startPlaybackSession(PlaybackSession(type: .playlist, uuid: storeUuid), autoPlay: true)
    }

    /// Fork: long-pressing a session's play button on the Queue screen makes it the current session and
    /// INHERITS the current play state — if something was playing, the session plays; if paused, it
    /// becomes current but stays paused. (A TAP on the play button always makes-current-and-plays.)
    func makeSessionCurrentInheritingPlayState(_ row: SessionListRow) {
        guard !row.isUpNext else { return }
        let wasPlaying = PlaybackManager.shared.playing()
        makeCurrentSession(row.sessionUuid)
        if wasPlaying {
            playSessionLane(row) // resumes / starts it playing
        } else if !row.ownsCard, let storeUuid = row.storeUuid {
            // Make it the current session but parked/paused (no autoplay).
            PlaybackManager.shared.startPlaybackSession(PlaybackSession(type: .playlist, uuid: storeUuid), autoPlay: false)
        }
        // Defer + coalesce the reload: a synchronous reloadData() here fires WHILE the play-button
        // long-press is still active, which yanks the row out mid-gesture (the "row disappears and
        // everything reflows" flash). setNeedsReload lets the gesture settle first and folds in the
        // playback notification's reload so the rows rearrange exactly once.
        setNeedsReload()
    }

    /// Fork: the chooser's counts line — "N sessions", plus "· k empty" when some
    /// sessions have nothing left to play.
    func sessionListCountsText() -> String {
        let count = sessionListRows.count
        let base = count == 1 ? L10n.sessionCountSingular : L10n.sessionCountPluralFormat(count.localized())
        let emptyCount = sessionListRows.filter { $0.episodeCount == 0 }.count
        guard emptyCount > 0 else { return base }
        return base + " · " + L10n.sessionCountEmptySuffix(emptyCount.localized())
    }

    /// Fork: picking a session in the chooser BROWSES it — the lineup opens, and nothing
    /// about playback changes: no session is started, no episode is primed, the player and
    /// the Up Next world carry on exactly as they were. A session only becomes active when
    /// the user plays something from it (see the session row tap in +Table).
    func openSessionFromList(_ row: SessionListRow) {
        clearLineupSearch()
        browsedSessionUuid = SessionStore.shared.session(uuid: row.sessionUuid)?.storePlaylistUuid ?? row.storeUuid
        sessionLevel = .lineup
        reloadTable()
        // Reset to the top so the lineup starts below the nav bar. Done after layout settles: entering
        // a lineup flips the nav bar transparent, which changes the safe area (and thus adjustedContentInset)
        // a beat after the sync reload — a sync reset would use the stale inset and leave rows under the bar.
        resetLineupScrollToTop()
    }

    /// Reset the lineup's scroll so its first row sits just below the nav bar, after forcing any pending
    /// layout so `adjustedContentInset` reflects the (now transparent) nav bar's safe area.
    private func resetLineupScrollToTop() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.layoutIfNeeded()
            self.upNextTable.setContentOffset(CGPoint(x: 0, y: -self.upNextTable.adjustedContentInset.top), animated: false)
        }
    }

    /// Fork: playing an episode of a browsed, not-yet-active session — the one moment
    /// browsing turns into listening. `startPlaybackSession` is what publishes the pointer
    /// (and pulls in any pending auto-adds), so it runs first, silently; `play(sessionEpisode:)`
    /// then needs that pointer to exist and lands on the episode the user actually tapped.
    /// Audio starts here: a tap on an episode row is a request to play it.
    func playFromBrowsedSession(episode: BaseEpisode) {
        guard let session = browsedPlaybackSession else { return }
        AnalyticsPlaybackHelper.shared.currentSource = .upNext
        if session != Settings.playbackSession() {
            PlaybackManager.shared.startPlaybackSession(session, autoPlay: false)
            // The session must actually have started for the pointer to be there.
            guard Settings.playbackSession() == session else { return }
        }
        // startPlaybackSession primes the session's FIRST episode; if that's the tapped
        // one there is nothing to switch to, just start the audio.
        if PlaybackManager.shared.currentEpisode()?.uuid == episode.uuid {
            PlaybackManager.shared.play()
        } else {
            PlaybackManager.shared.play(sessionEpisode: episode)
        }
        browsedSessionUuid = session.uuid
        reloadTable()
    }

    /// The Switch Session sheet: looks like the Playlists screen (artwork, name, count),
    /// with "Up Next" as the first row to hand playback back to the queue.
    @objc func switchSessionTapped() {
        presentSessionPicker(includeUpNext: true)
    }

    /// The empty state's "Choose session" variant omits the Up Next row — with no
    /// session active there is no queue mode to switch back to.
    func presentSessionPicker(includeUpNext: Bool) {
        let controller = SwitchSessionViewController(themeOverride: themeOverride, includeUpNext: includeUpNext) { [weak self] switched in
            guard switched, let self else { return }
            // Snap to whichever world now owns playback: picking a session
            // activates it (Session world); picking Up Next / End Session ends
            // the session (queue world).
            self.displayedWorld = self.sessionOwnsCard ? .session : .upNext
            // The sheet switches PLAYBACK, so the view follows it: browse whatever now plays.
            if self.displayedWorld == .session { self.enterSessionWorld() }
            self.reloadTable()
        }
        let nav = UINavigationController(rootViewController: controller)
        nav.modalPresentationStyle = .pageSheet
        nav.sheetPresentationController?.detents = [.medium(), .large()]
        present(nav, animated: true)
    }

    /// "N episodes · X left" for what's still to come in the session — the playing
    /// episode isn't counted, so the line stays put during playback.
    func sessionMetaText() -> String? {
        guard let session = browsedPlaybackSession else { return nil }
        // The info line always covers the FULL session (including the currently-playing episode), so
        // the current session's line reads the same "N episodes · time left" as every other session's
        // — even though that episode is shown as the now-playing card rather than a list row.
        let remainingEpisodes = session.remainingEpisodes(excluding: nil)
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
        let session = browsedPlaybackSession



        // Back-to-chooser now lives in the nav bar as a native iOS back chevron
        // (see updateNavBarButtons), so the in-content breadcrumb chevron stays hidden.
        sessionBackChevron.isHidden = true

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
        sessionHeaderLabel.text = sourceName
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
        // Accent the sort icon while a non-default (non-Drag & Drop) sort is active, so it's clear the
        // lineup is sorted (and therefore not hand-reorderable); neutral under Drag & Drop.
        let sortTint = browsedSessionSortIsDragAndDrop
            ? AppTheme.colorForStyle(.primaryIcon02, themeOverride: themeOverride)
            : nowPlayingWorldAccent
        let sortImage = UIImage(named: "podcast-sort")?.withTintColor(sortTint, renderingMode: .alwaysOriginal)
        sessionSortButton.setImage(sortImage, for: .normal)
        sessionSortButton.accessibilityLabel = L10n.playbackSessionSortTitle
    }

    /// Ticks the under-card "… left" line while a session episode plays.
    @objc func sessionPlayStateChanged() {
        guard displayedWorld == .session else { return }
        // Fork: switching which lane plays (e.g. Up Next → current session) only flips play/pause
        // state on the SAME rows, so re-populate the visible cells IN PLACE — a full reloadData
        // dequeues fresh cells and flashes their artwork. Only fall back to a full reload when the
        // rows actually change (a pool session becoming current, order shifts, etc.).
        guard showingSessionList else { reloadTable(); return }

        let before = Set(sessionListRows.map(\.sessionUuid))
        refreshSessionState()
        let after = Set(sessionListRows.map(\.sessionUuid))

        // Only the MEMBERSHIP changing (a session added/removed) is a structural change that needs a
        // full reload. Switching which session is current keeps the same members — just moves one
        // into the current slot and the other back into the pool — so re-populate the visible cells
        // IN PLACE at their new positions; a reloadData here would dequeue fresh cells and flash
        // their artwork.
        guard before == after else {
            refreshSections()
            updateStickyChrome()
            updateNavBarButtons()
            upNextTable.reloadData()
            return
        }

        for case let cell as SessionListCell in upNextTable.visibleCells {
            guard let indexPath = upNextTable.indexPath(for: cell),
                  tableData[safe: indexPath.section] == .sessionSection,
                  let listIndex = sessionListIndex(forTableRow: indexPath.row),
                  let row = sessionListRows[safe: listIndex] else { continue }
            cell.onPlayTapped = { [weak self] in self?.playSessionLane(row) }
            cell.populate(from: row, placement: sessionPlacement(at: listIndex), reordering: sessionListReorderMode)
        }
        updateStickyChrome()
        updateNavBarButtons()
    }

    @objc func sessionPlaybackProgressed() {
        // Only the lineup of the session that's actually sounding has a ticking line.
        guard browsingActiveSession, !Settings.playbackSessionPaused() else { return }
        sessionMetaLabel.text = sessionMetaText()
    }

    // MARK: - Lineup (Model B: pinned head + reorderable tail)
    //
    // A "lineup" is a detail screen with a pinned head episode on a card and a reorderable tail
    // below it. BOTH worlds are lineups with the SAME shape — Session details and Up Next details —
    // so their display reads through one set of accessors (`lineupHeadEpisode` / `lineupTail` /
    // `filteredLineupTail`). Only the backing store differs: Session details mirrors a playlist
    // (`sessionEpisodes`, populated in `updateSessionEpisodes`); Up Next details reads the live
    // PlaybackQueue below its pinned head. The write paths (reorder, multi-select) stay world-
    // specific because those stores reorder differently (playlist move vs queue move).

    /// Session details backing: the browsed session's remaining episodes BELOW its pinned current
    /// (`sessionCurrentEpisode`), never including it, so tail indices map cleanly onto reorder math.
    var sessionEpisodes: [BaseEpisode]?

    /// Session details backing: the pinned current episode (the active session's now-playing/paused
    /// episode, or a browsed non-active session's next-up). Surfaced via `lineupHeadEpisode`.
    var sessionCurrentEpisode: BaseEpisode?

    /// The pinned head episode of the current lineup — the session's current (Session details) or the
    /// queue's own head (Up Next details). Rendered as the top-block card; the tail never moves it.
    var lineupHeadEpisode: BaseEpisode? {
        displayedWorld == .session ? sessionCurrentEpisode : upNextCardEpisode
    }

    /// The reorderable tail below the head — one shape in both worlds. Session details reads its
    /// populated `sessionEpisodes`; Up Next details reads the queue's own episodes below the head.
    var lineupTail: [BaseEpisode] {
        if displayedWorld == .session { return sessionEpisodes ?? [] }
        return Array(PlaybackManager.shared.queue.allEpisodes(includeNowPlaying: false).dropFirst(upNextListOffset))
    }

    /// Fork: the lineup episode search (Session details / Up Next details). Filters the tail by
    /// title; the pinned head and the info line stay put.
    var lineupSearchText = "" {
        didSet {
            guard oldValue != lineupSearchText else { return }
            reloadTable()
        }
    }

    var lineupSearchActive: Bool {
        !lineupSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The tail after the lineup title filter — what the list section renders in BOTH worlds.
    var filteredLineupTail: [BaseEpisode] {
        let query = lineupSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return lineupTail }
        return lineupTail.filter { $0.displayableTitle().localizedCaseInsensitiveContains(query) }
    }

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
        guard let session = browsedPlaybackSession else {
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


    var selectedPlayListEpisodes = [PlaylistEpisode]() {
        didSet {
            guard !bulkSelecting else { return }
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

        // Queue controls live on the header's top row.
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

        // When the sort button is shown, the shuffle button sits to its left.
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

        shuffleButton.isHidden = !FeatureFlag.upNextShuffle.enabled || PlaybackManager.shared.queue.upNextCount() == 0
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
            upNextTable.register(UINib(nibName: "EpisodeCell", bundle: nil), forCellReuseIdentifier: UpNextViewController.episodeCell)
            upNextTable.register(UINib(nibName: "UpNextNowPlayingCell", bundle: nil), forCellReuseIdentifier: UpNextViewController.nowPlayingCell)
            upNextTable.register(EmptyStateCell.self, forCellReuseIdentifier: UpNextViewController.emptyStateCell)
            upNextTable.register(SessionPausedBannerCell.self, forCellReuseIdentifier: UpNextViewController.sessionPausedBannerCell)
            upNextTable.register(SessionListCell.self, forCellReuseIdentifier: SessionListCell.reuseIdentifier)
            upNextTable.estimatedRowHeight = 72
            upNextTable.backgroundView = nil
            upNextTable.isEditing = true
            upNextTable.addGestureRecognizer(customLongPressGesture)
            upNextTable.allowsMultipleSelectionDuringEditing = true
            upNextTable.allowsMultipleSelection = true
            // Fork: long-press to drag-reorder the session chooser. Drag-and-drop is enabled ONLY in
            // the chooser (toggled in reloadTable) — in a lineup it's off so the built-in editing-mode
            // handle reorder (moveRowAt) isn't intercepted by the drag session.
            upNextTable.dragDelegate = self
            upNextTable.dropDelegate = self
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

        // No nav-bar title — the world's name lives in the title block above the pills.
        title = nil

        (view as? ThemeableView)?.style = .primaryUi04
        (view as? ThemeableView)?.themeOverride = themeOverride

        NotificationCenter.default.addObserver(self, selector: #selector(upNextChanged), name: Constants.Notifications.playbackTrackChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(upNextChanged), name: Constants.Notifications.playbackEnded, object: nil)
        // The chooser's Playing marker tracks actual audio, so it has to redraw when
        // playback starts or pauses — priming a session alone never lights it up.
        NotificationCenter.default.addObserver(self, selector: #selector(sessionPlayStateChanged), name: Constants.Notifications.playbackStarted, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionPlayStateChanged), name: Constants.Notifications.playbackPaused, object: nil)
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

        // Sticky chrome pinned above the table: the active world's header. Content scrolls
        // beneath it (via contentInset).
        stickyChrome.axis = .vertical
        sessionHeaderView.translatesAutoresizingMaskIntoConstraints = false
        stickyChrome.addArrangedSubview(sessionHeaderView)
        let headerHeightConstraint = sessionHeaderView.heightAnchor.constraint(equalToConstant: Self.titleBlockHeight)
        headerHeightConstraint.isActive = true
        sessionHeaderHeightConstraint = headerHeightConstraint

        stickyChrome.translatesAutoresizingMaskIntoConstraints = false
        // Opaque backing that also covers the status/nav area above the title, so
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

        setupSessionLineupChrome()
        refreshSections()
    }

    // MARK: - Session lineup "detail" chrome (fork)

    /// One-time setup for the lineup's artwork backdrop and its scrolling/nav title labels.
    private func setupSessionLineupChrome() {
        // The blurred artwork sits behind the rows (clear-backed cells) and bleeds up behind the
        // transparent nav bar, exactly like the playlist detail's `PlaylistBlurHeaderView`.
        let host = ThemedHostingController(rootView: SessionArtworkBackdropView(model: sessionArtworkModel))
        addChild(host)
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.view.layer.zPosition = -1000
        host.view.isHidden = true
        host.view.translatesAutoresizingMaskIntoConstraints = false
        upNextTable.addSubview(host.view)
        host.didMove(toParent: self)
        sessionArtworkBackdrop = host.view
        // Inside a scroll view, edge anchors attach to the CONTENT origin — a
        // trailing constraint would collapse the view into a 40pt sliver at the
        // left edge (it renders as a dark gutter strip). Width must come from the
        // controller's view; only the leading edge is content-anchored.
        NSLayoutConstraint.activate([
            host.view.bottomAnchor.constraint(equalTo: upNextTable.topAnchor, constant: 220),
            host.view.heightAnchor.constraint(equalTo: view.widthAnchor, constant: 40),
            host.view.leadingAnchor.constraint(equalTo: upNextTable.leadingAnchor, constant: -20),
            host.view.widthAnchor.constraint(equalTo: view.widthAnchor, constant: 40)
        ])
    }

    /// Which "detail" screen the artwork-backdrop chrome is presenting. The title itself is the
    /// standard nav-bar title on every one; only the backdrop and info row differ.
    private enum DetailChromeKind { case queue, chooser, lineup }

    private func updateSessionLineupPresentation() {
        let kind: DetailChromeKind?
        if displayedWorld == .upNext {
            kind = .queue
        } else if sessionLevel == .lineup, browsedPlaybackSession != nil {
            kind = .lineup
        } else if showingSessionList {
            kind = .chooser
        } else {
            kind = nil
        }
        if let kind {
            applyDetailChrome(kind)
        } else if sessionLineupChromeActive {
            removeSessionLineupChrome()
        }
    }

    private func applyDetailChrome(_ kind: DetailChromeKind) {
        sessionLineupChromeActive = true

        // The world's name renders as the standard nav-bar title, styled by PCNavigationController
        // exactly like the Podcasts and Playlists tabs — no custom header label. The tab bar item
        // stays "Queue" (set explicitly on it), so this only names the world in the nav bar.
        // Set navigationItem.title (nav bar) directly, NOT self.title — self.title bleeds into the
        // tab bar item, which must always read "Queue".
        // Fork: a standard centered nav-bar title (never a large left-aligned one), so "Queue",
        // "Up Next", and a session name all read the same way the app's other tab titles do.
        navigationItem.largeTitleDisplayMode = .never
        upNextTable.tableHeaderView = nil
        stickyChromeBackground.isHidden = true
        // A session lineup's title is TAPPABLE — it opens that session's SOURCE (playlist / podcast /
        // folder). The queue ("Up Next") has no source, so it stays a plain title.
        if kind == .lineup {
            navigationItem.title = nil
            navigationItem.titleView = makeTappableSessionTitleView(sessionHeaderLabel.text)
        } else {
            navigationItem.titleView = nil
            navigationItem.title = sessionHeaderLabel.text
        }

        // The queue and a session lineup show a blurred artwork backdrop behind the list; the
        // chooser is a plain list of sessions, so it has none.
        let episodes: [BaseEpisode]?
        switch kind {
        case .queue: episodes = DataManager.sharedManager.allUpNextEpisodes()
        case .lineup: episodes = sessionEpisodes
        case .chooser: episodes = nil
        }
        let items = artworkItems(from: episodes)
        if sessionArtworkModel.items != items { sessionArtworkModel.items = items }
        sessionArtworkBackdrop?.isHidden = items.isEmpty
    }

    /// Fork: a session lineup's nav title, styled like the standard centered title but tappable — it
    /// opens the session's source (its playlist / podcast / folder), via `openSessionSource`.
    private func makeTappableSessionTitleView(_ text: String?) -> UIView {
        let button = UIButton(type: .system)
        let font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        let color = AppTheme.colorForStyle(.primaryText01, themeOverride: themeOverride)
        let isSmart: Bool = { if case .smartPlaylist = browsedSession?.feeder { return true } else { return false } }()
        // Fork: a smart-playlist session's nav title carries a white sparkle right after it (single space).
        if isSmart, let text,
           let symbol = UIImage(systemName: "sparkles", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))?
               .withTintColor(AppTheme.colorForStyle(.primaryText01, themeOverride: themeOverride), renderingMode: .alwaysOriginal) {
            let result = NSMutableAttributedString(string: text + " ", attributes: [.font: font, .foregroundColor: color])
            let attachment = NSTextAttachment()
            attachment.image = symbol
            attachment.bounds = CGRect(x: 0, y: (font.capHeight - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height)
            result.append(NSAttributedString(attachment: attachment))
            button.setAttributedTitle(result, for: .normal)
        } else {
            button.setTitle(text, for: .normal)
            button.titleLabel?.font = font
            button.setTitleColor(color, for: .normal)
        }
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.addTarget(self, action: #selector(openSessionSource), for: .touchUpInside)
        button.accessibilityTraits = [.button, .header]
        button.sizeToFit()
        return button
    }

    private func removeSessionLineupChrome() {
        sessionLineupChromeActive = false
        upNextTable.tableHeaderView = nil
        sessionArtworkBackdrop?.isHidden = true
        navigationItem.titleView = nil
        navigationItem.title = nil
        stickyChromeBackground.isHidden = false
    }

    /// Distinct podcast artworks of the given episodes (up to 4), for the blurred backdrop.
    private func artworkItems(from episodes: [BaseEpisode]?) -> [PlaylistArtworkView.ImageItem] {
        var seen = Set<String>()
        var uuids: [String] = []
        for episode in episodes ?? [] {
            guard let uuid = (episode as? Episode)?.podcastUuid, !uuid.isEmpty else { continue }
            if seen.insert(uuid).inserted { uuids.append(uuid) }
            if uuids.count == 4 { break }
        }
        return uuids.map {
            PlaylistArtworkView.ImageItem(id: $0, url: ImageManager.sharedManager.podcastUrl(imageSize: .detail, uuid: $0))
        }
    }

    /// Tells the nav controller which scroll view drives the scroll-edge → standard bar
    /// transition, so the title collapses under the bar exactly as on the tab list screens.
    override func contentScrollView(for edge: NSDirectionalRectEdge) -> UIScrollView? {
        upNextTable
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

        // Fork: the embedded search bars sit on the screen's own background — refresh their
        // override so a theme switch doesn't leave them wearing the old theme's color.
        let searchBackground = AppTheme.colorForStyle(.primaryUi04, themeOverride: themeOverride)
        sessionSearchController.backgroundColorOverride = searchBackground
        lineupSearchController.backgroundColorOverride = searchBackground

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
        if FeatureFlag.upNextShuffle.enabled, shuffleButton.allTargets.isEmpty {
            NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: Constants.Notifications.themeChanged, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(subscriptionStatusDidChange), name: ServerNotifications.subscriptionStatusChanged, object: nil)
            themeDidChange()
            shuffleButton.addTarget(self, action: #selector(shuffleButtonTapped), for: .touchUpInside)
        }
        setupSortButtonIfNecessary()
        setupSessionButtonsIfNecessary()
    }

    private func setupSessionButtonsIfNecessary() {
        guard sessionSortButton.allTargets.isEmpty else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(sessionStateDidChange), name: Constants.Notifications.playbackSessionChanged, object: nil)
        sessionSortButton.addTarget(self, action: #selector(sessionSortTapped), for: .touchUpInside)
        sessionListSortButton.addTarget(self, action: #selector(sessionListSortTapped), for: .touchUpInside)
        sessionListMoreButton.addTarget(self, action: #selector(sessionListMoreTapped), for: .touchUpInside)
        // The session mirrors its playlist live — reflect order/content changes made
        // on the playlist's own screens.
        NotificationCenter.default.addObserver(self, selector: #selector(sessionStateDidChange), name: Constants.Notifications.playlistChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionPlaybackProgressed), name: Constants.Notifications.playbackProgress, object: nil)
    }

    // MARK: - Session chooser controls (fork)

    /// Shows or hides the chooser's sort and ⋯ buttons, and re-tints them for the current
    /// theme and preference state. Called from `updateStickyChrome` on every path.
    private func updateSessionListControls() {
        // The session list is manually ordered (drag to reorder), so it has no in-row sort control;
        // and the ⋯ (now just a Hide-Empty toggle) lives in the round top-right nav button. Both
        // in-row buttons stay hidden — the info row shows only the counts.
        sessionListSortButton.isHidden = true
        sessionListMoreButton.isHidden = true
    }

    /// Fork: the round top-right ⋯ for the session chooser — opens the same "Show Session
    /// Playlists" selector the in-header button used to, now that the "Sessions" title block
    /// is gone. A circular button matching the iOS 26 nav-bar treatment.
    private func roundSessionListMoreButton() -> UIBarButtonItem {
        // Fork: a plain bar button (the system draws it as a round glass button on iOS 26); tapping
        // opens a sheet of the session list's view toggles, matching the app's other ⋯ menus.
        let button = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), style: .plain, target: self, action: #selector(sessionListMoreTapped))
        button.accessibilityLabel = L10n.accessibilityMoreActions
        return button
    }

    @objc private func sessionListSortTapped() {
        makeSessionSortPicker().present(from: self)
    }

    /// The Sort sub-picker (Manual + episode-style sorts). Returned so the ⋯ menu can present it as
    /// a submenu — matching the podcast page's "Sort Episodes" row.
    private func makeSessionSortPicker() -> OptionsPicker {
        let picker = OptionsPicker(title: L10n.sessionSortOnce.localizedUppercase, themeOverride: themeOverride)
        // One-shot: sorting is NOT a sticky mode. The list is always drag-and-drop; each option here
        // re-arranges that drag order ONCE (baked into the synced `sortIndex`), then it stays manual.
        // So there's no "Manual"/"Drag & Drop" option (that's the base state) and no persistent selection.
        for option in SessionListSort.sessionMenuOrder where option != .manual {
            picker.addAction(action: OptionAction(label: option.title) { [weak self] in
                guard let self else { return }
                let sorted = SessionListRows.current(sort: option, filters: .unfiltered).map(\.sessionUuid)
                SessionStore.shared.reorderSessions(sorted)
                self.reloadSessionListAndScrollToTop()
            })
        }
        return picker
    }

    @objc private func sessionListMoreTapped() {
        // Fork: the session list's view toggles as a sheet, matching the app's other ⋯ menus.
        let picker = OptionsPicker(title: nil, themeOverride: themeOverride)
        // "Reorder Sessions" — a one-shot re-arrange of the drag order (submenu, no sticky selection).
        let sortAction = OptionAction(label: L10n.sessionSortOnce, icon: "podcastlist_sort") {}
        sortAction.submenu = { [weak self] in self?.makeSessionSortPicker() }
        picker.addAction(action: sortAction)
        // Visibility toggles: noun label + a Hide/Show secondary that reads back the current state.
        let emptyHidden = Settings.hideEmptySessions()
        picker.addAction(action: OptionAction(label: L10n.sessionEmptySessions, secondaryLabel: emptyHidden ? L10n.settingsGeneralHide : L10n.settingsGeneralShow, icon: "square.stack") { [weak self] in
            Settings.setHideEmptySessions(!emptyHidden)
            self?.reloadSessionListAndScrollToTop()
        })
        let smartHidden = Settings.hidePodcastSessionsInSmartPlaylist()
        picker.addAction(action: OptionAction(label: L10n.sessionPodcastsInSmartPlaylists, secondaryLabel: smartHidden ? L10n.settingsGeneralHide : L10n.settingsGeneralShow, icon: "podcasts_tab") { [weak self] in
            Settings.setHidePodcastSessionsInSmartPlaylist(!smartHidden)
            self?.reloadSessionListAndScrollToTop()
        })
        picker.present(from: self)
    }

    /// A re-sorted or re-filtered list is a different list — start it at the top rather than
    /// leaving the user parked at an offset that now means something else.
    private func reloadSessionListAndScrollToTop() {
        reloadTable()
        upNextTable.setContentOffset(CGPoint(x: 0, y: sessionListRestingTopOffsetY), animated: false)
    }

    /// Fork: swipe-to-remove a session from the list. A podcast/folder session's store is a
    /// dedicated lineup, safe to delete fully (and "Play as Session" recreates it). A smart-playlist
    /// or manual session's store may be a user-facing playlist, so only the session bookkeeping is
    /// removed — the playlist survives.
    func removeSessionFromList(_ session: Session) {
        switch session.feeder {
        case .podcast, .folder:
            SessionManager.shared.deleteSession(session)
        default:
            SessionStore.shared.delete(sessionUuid: session.uuid)
            NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged)
        }
    }

    /// Fork: commit a drag-reorder of the session chooser to the persisted manual order. The data
    /// source is updated immediately so it matches the moved row; persisting posts
    /// SessionStore.changed, which rebuilds the list in the same order (no flash).
    func reorderSessionList(from: Int, to: Int) {
        guard from != to, sessionListRows.indices.contains(from) else { return }
        var reordered = sessionListRows
        let moved = reordered.remove(at: from)
        reordered.insert(moved, at: min(max(0, to), reordered.count))
        sessionListRows = reordered
        SessionStore.shared.reorderSessions(reordered.map(\.sessionUuid))
    }

    @objc private func sessionSortTapped() {
        guard let session = browsedPlaybackSession, session.type == .smartPlaylist || session.type == .playlist else { return }
        presentSessionSortPicker(for: session)
    }

    /// Dragging a session row reorders the source playlist itself — the session is a live
    /// mirror. Manual playlists reorder directly; smart playlists reorder their custom-order
    /// lineup, switching to drag-and-drop sort first (seeded from the current order, so
    /// nothing lands in the inbox) if they weren't custom-ordered yet.
    func moveSessionEpisode(fromRow: Int, toRow: Int) {
        guard let sessionEpisodes,
              fromRow < sessionEpisodes.count, toRow < sessionEpisodes.count,
              let (session, playlist) = sessionPlaylistPreparedForReorder() else { return }

        let moved = sessionEpisodes[fromRow]
        let target = sessionEpisodes[toRow]

        // Resolve the target after any sort switch: the session excludes played episodes,
        // so map the drop position onto the playlist's full order.
        guard let targetIndex = session.orderedEpisodes().firstIndex(where: { $0.uuid == target.uuid }) else { return }
        DataManager.sharedManager.moveEpisode(moved.uuid, in: playlist, to: targetIndex)
        Self.mirrorOrderIntoSmartFeeder(episodeUuid: moved.uuid, storePlaylist: playlist, to: targetIndex)
        // See `writeSessionLineupTop`: announce after the drop animation, not during it.
        DispatchQueue.main.async {
            NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged, object: playlist)
        }

        var updated = sessionEpisodes
        updated.remove(at: fromRow)
        updated.insert(moved, at: toRow)
        self.sessionEpisodes = updated
    }

    /// Fork: the now-playing session card dragged DOWN into its own lineup — the current episode
    /// takes the drop position in the playlist order (parallel to the queue card's
    /// `moveEpisode(from: -1, ...)`). It stays on the card and keeps playing; only its place in the
    /// lineup order changes, so the next advance follows the new order.
    func moveSessionCardEpisode(toRow: Int) {
        guard let currentUuid = PlaybackManager.shared.currentEpisode()?.uuid,
              let sessionEpisodes,
              let (session, playlist) = sessionPlaylistPreparedForReorder() else { return }

        // Map the drop row (an index among the card-excluded list rows) onto the playlist's full
        // order. Past the last row → the end of the lineup.
        let ordered = session.orderedEpisodes()
        let targetIndex: Int
        if let target = sessionEpisodes[safe: toRow], let idx = ordered.firstIndex(where: { $0.uuid == target.uuid }) {
            targetIndex = idx
        } else {
            targetIndex = max(ordered.count - 1, 0)
        }
        DataManager.sharedManager.moveEpisode(currentUuid, in: playlist, to: targetIndex)
        Self.mirrorOrderIntoSmartFeeder(episodeUuid: currentUuid, storePlaylist: playlist, to: targetIndex)
        DispatchQueue.main.async {
            NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged, object: playlist)
        }
        reloadTable()
    }

    /// Fork: every manual session reorder writes through the mirrored playlist, and a
    /// manual order can only live in custom sort — so the sort switch (and, for smart
    /// playlists, seeding the positions) has to happen before any move lands. Shared by
    /// the row-to-row move and the "true top" move so there's one order-writing path.
    func sessionPlaylistPreparedForReorder() -> (session: PlaybackSession, playlist: EpisodeFilter)? {
        // The lineup on screen is the one being edited — browsed, not necessarily active.
        guard let session = browsedPlaybackSession,
              session.type == .playlist || session.type == .smartPlaylist,
              let playlist = DataManager.sharedManager.findPlaylist(uuid: session.uuid) else { return nil }

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

        return (session, playlist)
    }

    /// The order-writing half of the true-top move, split out from the player-facing half
    /// so it can run (and be covered by tests) without a live player: the episode becomes
    /// first in the session's lineup.
    static func writeSessionLineupTop(episodeUuid: String, in playlist: EpisodeFilter) {
        DataManager.sharedManager.moveEpisode(episodeUuid, in: playlist, to: 0)
        mirrorOrderIntoSmartFeeder(episodeUuid: episodeUuid, storePlaylist: playlist, to: 0)
        // Deferred by one runloop: posting inline runs every observer synchronously, which
        // means a full table refresh executes in the middle of the drop animation.
        DispatchQueue.main.async {
            NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged, object: playlist)
        }
    }

    /// Fork: a smart-fed session's store MIRRORS its feeder, so the reconciler can rewrite
    /// the store's order back from the smart playlist and undo a hand move. When the store
    /// belongs to a smart-fed session whose feeder carries a custom order, the move is
    /// written to the feeder as well — the two orders then agree and the move survives.
    static func mirrorOrderIntoSmartFeeder(episodeUuid: String, storePlaylist: EpisodeFilter, to index: Int) {
        guard let session = SessionStore.shared.session(forStore: storePlaylist.uuid),
              case .smartPlaylist(let feederUuid) = session.feeder,
              let feeder = DataManager.sharedManager.findPlaylist(uuid: feederUuid),
              feeder.sortType == PlaylistSort.dragAndDrop.rawValue else { return }

        // Deliberately silent: announcing the feeder here would trigger the smart-feeder
        // reconcile, which re-derives the store from this very playlist — pure duplicate
        // work right after a move, and the reason a reorder felt sluggish. The store's own
        // notification (posted by the caller) is what the UI listens to.
        DataManager.sharedManager.moveEpisode(episodeUuid, in: feeder, to: index)
    }

    /// Fork: the single "move this row to the top" entry point — used by the left-swipe
    /// action and by a drag dropped on row 0 of the session section.
    ///
    /// While the session is sounding, the card is the episode you're listening to and the
    /// top of the list is the row right under it (today's behaviour). While nothing is
    /// sounding the card is merely "what's next", so the top of the list has to mean the
    /// top of the lineup — otherwise no row can ever be made the next episode.
    ///
    /// A BROWSED, non-active session has no card and no player involvement at all, so
    /// "top" can only mean the top of its stored lineup — a pure order write to position 0.
    func moveSessionEpisodeToTop(fromRow: Int) {
        // A non-active session isn't the current world, so dragging to the top only re-orders it.
        guard browsingActiveSession else {
            moveBrowsedSessionEpisodeToLineupTop(fromRow: fromRow)
            return
        }
        // Fork: the TOP item becomes the CURRENT item — the now-playing episode — regardless of play
        // state. It INHERITS that state: if the session was playing, the new top takes over and keeps
        // playing (equalizer + box); if paused, it becomes the current item but stays paused (box, no
        // equalizer — "active" doesn't require sounding). Never unconditional autoplay.
        guard let sessionEpisodes, fromRow < sessionEpisodes.count else { return }
        let moved = sessionEpisodes[fromRow]
        makeSessionEpisodeCurrentAtTop(moved, autoPlay: PlaybackManager.shared.playing())
    }

    /// Fork: make `episode` the CURRENT item of the active session AND its top row. `autoPlay` carries
    /// the play state (true = keeps playing, false = current-but-paused). Order matters:
    /// `play(sessionEpisode:)` shoves the INTERRUPTED episode to the top of the lineup, so the moved
    /// episode is written to the top AFTER, else it lands right under the one it replaced (accent box on
    /// the new top, equalizer on the old one — the reported mismatch).
    func makeSessionEpisodeCurrentAtTop(_ episode: BaseEpisode, autoPlay: Bool) {
        guard let (_, playlist) = sessionPlaylistPreparedForReorder() else { return }
        AnalyticsPlaybackHelper.shared.currentSource = .upNext
        PlaybackManager.shared.play(sessionEpisode: episode, autoPlay: autoPlay)
        Self.writeSessionLineupTop(episodeUuid: episode.uuid, in: playlist)
        reloadTable()
    }

    /// The browsed (non-active) variant of the true-top move: order only, no priming —
    /// there is nothing on the player belonging to this session to re-point.
    private func moveBrowsedSessionEpisodeToLineupTop(fromRow: Int) {
        guard let sessionEpisodes, fromRow < sessionEpisodes.count,
              let (_, playlist) = sessionPlaylistPreparedForReorder() else { return }

        let moved = sessionEpisodes[fromRow]
        Self.writeSessionLineupTop(episodeUuid: moved.uuid, in: playlist)

        // No card and no membership change here, and the table has already animated the row
        // into place — so mirror the move in the local list rather than rebuilding every row
        // (a full reload re-reads every session's members and stutters the drop).
        var updated = sessionEpisodes
        updated.remove(at: fromRow)
        updated.insert(moved, at: 0)
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

    @objc private func sessionStateDidChange() {
        // In the session world, play/pause/switch keeps the SAME set of sessions, so repaint IN PLACE
        // (sessionPlayStateChanged decides in-place vs full) rather than a full reloadData that flashes
        // every row and briefly shows stale playing icons. Elsewhere, a coalesced reload.
        if displayedWorld == .session {
            sessionPlayStateChanged()
        } else {
            setNeedsReload()
        }
    }

    /// Recomputes the active session's remaining episodes and snaps the pill switcher
    /// to whichever world owns playback.
    /// The last-built session SOURCE (the expensive `SessionListRows.current` result — one DB read per
    /// session). Cached so the search box can re-filter it in place without rebuilding from the DB.
    private var lastSessionSource: [SessionListRow] = []

    func refreshSessionState() {
        // Only the session world shows the chooser + a session lineup; in the Up Next world none of
        // this is visible, so skip the O(sessions) DB rebuild entirely (a queue action like removing
        // the playing episode was paying for a full session-list rebuild on every reload). It's
        // recomputed when you switch back into the session world.
        guard displayedWorld == .session else { return }

        // Fork: the session list is [Up Next, current session, ...pool]. Up Next is always row 0.
        // Row 1 is the "current" session — the one playing, else the last one opened/played, else the
        // top of the sorted order. The pool below is every other session in the MANUAL (drag) order —
        // the list is always drag-and-drop; ⋯ → "Sort Session (once)" only re-arranges that order once
        // (it's not a sticky sort), so the display always reads the manual `sortIndex`.
        //
        // The expensive part — building the source from the DB — happens here; deriving the displayed
        // rows (current extraction + search filter) is cheap and factored out so a search keystroke
        // can reuse the cached source (see `applySessionSearch`).
        let all = SessionListRows.current(sort: .manual, filters: .unfiltered)
        lastSessionSource = all
        deriveSessionListRows(from: all)

        // A browsed session whose store went away (deleted while it was open) stops being
        // browsable — fall back to the active session, or to the chooser.
        if let browsedSessionUuid, browsedSessionUuid != Settings.playbackSession()?.uuid,
           DataManager.sharedManager.findPlaylist(uuid: browsedSessionUuid) == nil {
            self.browsedSessionUuid = nil
        }

        if let session = browsedPlaybackSession {
            sessionInboxCount = Self.inboxCount(for: session)

            // Fork (Model B): only the ACTIVE session pins its current episode as the card — the
            // sort/reorder then applies to the tail below it. A browsed, NON-active session has no
            // "now playing", so there's no card, the search sits at the very top, and sorting applies
            // to the whole list.
            let remaining = session.remainingEpisodes(excluding: nil)
            if browsingActiveSession {
                sessionCurrentEpisode = remaining.first
                sessionEpisodes = Array(remaining.dropFirst())
            } else {
                sessionCurrentEpisode = nil
                sessionEpisodes = remaining
            }
        } else {
            sessionEpisodes = nil
            sessionCurrentEpisode = nil
            sessionInboxCount = 0
            // Nothing browsed and nothing active — the Session world is the chooser.
            sessionLevel = .list
        }
    }

    static let upNextListRowUuid = "fork-up-next-list-row"

    /// Fork: the pinned "Up Next" row that heads the session list — the queue described the same way
    /// a session row is, so it sits naturally at the top. Tapping it opens the queue world.
    private func upNextListRow() -> SessionListRow {
        let queue = PlaybackManager.shared.queue
        let current = PlaybackManager.shared.currentEpisode()
        let ownsCard = queueOwnsCard
        // A shared session episode is a genuine Up Next member at the head, even though the session (not
        // the queue) is what's sounding — so the row frames it just like a queue-owned now-playing.
        let headIsCurrent = ownsCard || PlaybackManager.shared.currentSessionEpisodeIsSharedToQueue
        let count = queue.upNextCount() + (headIsCurrent ? 1 : 0)
        let next: BaseEpisode? = headIsCurrent ? current : queue.episodeAt(index: 0)
        var totalDuration = queue.upNextTotalDuration(includePlayingEpisode: false)
        if headIsCurrent, let current { totalDuration += max(0, current.duration - PlaybackManager.shared.currentTime()) }
        // The backdrop fill tracks this card's head episode: the now-playing's LIVE progress while the
        // queue is active (or a shared session episode is playing), otherwise the queue head's saved
        // progress — so the Up Next top card still shows its fill while a session is the one sounding.
        let progress: Double
        if headIsCurrent, let current, current.duration > 0 {
            progress = min(1, max(0, PlaybackManager.shared.currentTime() / current.duration))
        } else if let next, next.duration > 0, next.playedUpTo > 0 {
            progress = min(1, max(0, next.playedUpTo / next.duration))
        } else {
            progress = 0
        }
        return SessionListRow(
            sessionUuid: Self.upNextListRowUuid,
            storeUuid: nil,
            name: L10n.upNext,
            nextEpisodePodcastUuid: (next as? Episode)?.podcastUuid,
            isPlaying: ownsCard && PlaybackManager.shared.playing(),
            isActive: ownsCard,
            nextEpisodeTitle: next?.displayableTitle(),
            nextEpisodePodcast: next?.subTitle(),
            nextEpisodeDuration: nil,
            progress: progress,
            episodeCount: count,
            timeLeft: count > 0 ? TimeFormatter.shared.multipleUnitFormattedShortTime(time: totalDuration) : nil,
            isUpNext: true,
            nextEpisodeSeasonEpisode: (next as? Episode).flatMap {
                $0.seasonNumber > 0
                    ? L10n.seasonEpisodeShorthand(seasonNumber: $0.seasonNumber, episodeNumber: $0.episodeNumber)
                    : nil
            },
            ownsCard: ownsCard
        )
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

    var userEpisodeDetailVC: UserEpisodeDetailViewController?

    /// The "Sort by duration" tooltip popover, while it's on screen. See `UIViewController.presentTip` in TipView.swift.
    var upNextSortDurationTip: UIViewController?

    func showEpisodeDetailViewController(for episode: BaseEpisode?, fromSession: Bool = false) {
        if let episode = episode as? Episode, let parentPodcast = episode.parentPodcast() {
            let episodeController = EpisodeDetailViewController(episode: episode, podcast: parentPodcast, source: .upNext)
            if fromSession {
                episodeController.playFromSessionStoreUuid = browsedPlaybackSession?.uuid
            }
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

    /// The queue's counts line ("N episodes · X left").
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
        // Counts cover what's still to come — the playing episode isn't included,
        // so the line doesn't need to tick with playback.
        remainingLabel.text = queueCountsText(includeNowPlaying: false)
    }

    // MARK: - UIGestureRecongizerDelegate

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer != customLongPressGesture { return true }

        let touchPoint = gestureRecognizer.location(in: upNextTable)
        // On a reorderable row, defer to the drag interaction's own long-press lift rather than
        // firing the custom gesture (which would otherwise play/open the row).
        if let ip = upNextTable.indexPathForRow(at: touchPoint), dragReorderAllowed(at: ip) {
            return false
        }
        return true
    }

    // MARK: - Nav bar actions

    @objc func doneTapped() {
        dismiss(animated: true, completion: nil)
    }

    @objc func selectTapped() {
        isMultiSelectEnabled = true
    }

    @objc func selectAllTapped() {
        // Bulk-select: suppress the per-row selection didSet (which rebuilds the nav bar each append)
        // and apply the count/inset update once at the end.
        if displayedWorld == .session {
            // The chooser has no episode rows to select.
            guard !showingSessionList else { return }
            bulkSelecting = true
            // Fork: Select All includes the pinned current CARD (the session's now-playing episode),
            // which lives in the top block rather than the tail — the tail-only selectAllBelow missed it.
            if let card = sessionCurrentEpisode, !selectedEpisodesContains(uuid: card.uuid) {
                selectedSessionEpisodes.append(card)
                if let npSection = tableData.firstIndex(of: .nowPlayingSection), let cardRow = topBlockCardRow,
                   let cardCell = upNextTable.cellForRow(at: IndexPath(row: cardRow, section: npSection)) as? EpisodeCell {
                    cardCell.showTick = true
                }
            }
            if let sectionIndex = tableData.firstIndex(of: .sessionSection), !filteredLineupTail.isEmpty {
                upNextTable.selectAllBelow(fromIndexPath: IndexPath(row: 0, section: sectionIndex))
            }
            bulkSelecting = false
            multiSelectActionBar.setSelectedCount(count: selectedSessionEpisodes.count)
            contentInseter.isMultiSelectEnabled = !selectedSessionEpisodes.isEmpty
        } else {
            guard DataManager.sharedManager.allUpNextEpisodes().count > 1 else { return }
            bulkSelecting = true
            upNextTable.selectAllBelow(fromIndexPath: IndexPath(row: 0, section: tableData.firstIndex(of: .upNextSection) ?? 0))
            bulkSelecting = false
            multiSelectActionBar.setSelectedCount(count: selectedPlayListEpisodes.count)
            contentInseter.isMultiSelectEnabled = !selectedPlayListEpisodes.isEmpty
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
        // The chooser lists sessions, not episodes — nothing there to multi-select.
        let worldCount = inSession
            ? (showingSessionList ? 0 : (sessionEpisodes?.count ?? 0))
            : PlaybackManager.shared.queue.upNextCount()

        // A session lineup is a level down from the chooser — the top-left carries a native
        // iOS back button (chevron) that steps back up to the session list, in place of the
        // world's usual Clear/Done.
        let inSessionLineup = inSession && sessionLevel == .lineup && browsedPlaybackSession != nil

        if isMultiSelectEnabled {
            if MultiSelectHelper.shouldSelectAll(onCount: selectedCount, totalCount: worldCount) {
                rightButton = UIBarButtonItem(title: L10n.selectAll, style: .plain, target: self, action: #selector(selectAllTapped))
            } else {
                rightButton = UIBarButtonItem(title: L10n.deselectAll, style: .plain, target: self, action: #selector(deselectAllTapped))
            }
            leftButton = UIBarButtonItem(title: L10n.cancel, style: .plain, target: self, action: #selector(cancelTapped))
        } else if inSessionLineup {
            rightButton = worldCount > 0 ? UIBarButtonItem(title: L10n.select, style: .plain, target: self, action: #selector(selectTapped)) : nil
            let backButton = UIBarButtonItem(image: UIImage(systemName: "chevron.backward"), style: .plain, target: self, action: #selector(sessionBreadcrumbTapped))
            backButton.accessibilityLabel = L10n.sessions
            leftButton = backButton
        } else if inSession, sessionLevel == .list {
            if sessionListReorderMode {
                // Reorder Items mode owns the bar: Done exits it.
                rightButton = UIBarButtonItem(title: L10n.done, style: .done, target: self, action: #selector(exitSessionReorderMode))
                leftButton = nil
            } else {
                // Fork: the ⋯ rides beside the inline search bar (see sessionSearchOverflowButton), so
                // the nav bar carries nothing here (just Done when presented modally).
                rightButton = nil
                leftButton = showingInTab ? nil : UIBarButtonItem(title: L10n.done, style: .plain, target: self, action: #selector(doneTapped))
            }
        } else {
            let selectButton = worldCount > 0 ? UIBarButtonItem(title: L10n.select, style: .plain, target: self, action: #selector(selectTapped)) : nil
            if showingInTab {
                // Fork: the queue is a lineup entered from the pinned "Up Next" row in the session
                // list, so the top-left is a native back chevron to the list (mirroring a session
                // lineup). Select rides top-right; the nav-bar "Clear" was dropped — the scrolling
                // controls row still carries the native "Clear Queue" text button.
                let backButton = UIBarButtonItem(image: UIImage(systemName: "chevron.backward"), style: .plain, target: self, action: #selector(exitToSessionList))
                backButton.accessibilityLabel = L10n.sessions
                navigationItem.setLeftBarButton(backButton, animated: animated)
                navigationItem.setRightBarButtonItems(selectButton.map { [$0] }, animated: animated)
                return
            }
            leftButton = UIBarButtonItem(title: L10n.done, style: .plain, target: self, action: #selector(doneTapped))
            rightButton = selectButton
        }

        navigationItem.setRightBarButtonItems(rightButton.map { [$0] }, animated: animated)
        navigationItem.setLeftBarButton(leftButton, animated: animated)
    }

    private func animateMultiSelectChange() {
        if !isMultiSelectEnabled {
            upNextTable.indexPathsForSelectedRows?.forEach {
                upNextTable.deselectRow(at: $0, animated: false)
            }
        }

        // The queue's now-playing card swaps to a selectable player row (and back) with
        // multi-select, so reload that row to change its cell type.
        if displayedWorld == .upNext, topBlockHasCard, let cardRow = topBlockCardRow,
           let sectionIndex = tableData.firstIndex(of: .nowPlayingSection) {
            upNextTable.reloadRows(at: [IndexPath(row: cardRow, section: sectionIndex)], with: .none)
        }

        for case let cell as PlayerCell in upNextTable.visibleCells {
            cell.shouldShowSelect(show: isMultiSelectEnabled, animate: true)
        }
        // Fork: the session/up-next episode rows are EpisodeCells — update the ALREADY-VISIBLE ones
        // in place so their selection circle appears the moment Select is tapped, instead of only
        // when they're re-displayed on scroll (which read as "Select is slow / dots missing"). Because
        // they manage their own select control, set `shouldShowSelect` explicitly.
        for case let cell as EpisodeCell in upNextTable.visibleCells {
            cell.setEditing(isMultiSelectEnabled, animated: true)
            cell.shouldShowSelect = isMultiSelectEnabled
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
        sessionListSortButton.updateSizeConstraints(to: buttonSize)
        sessionListMoreButton.updateSizeConstraints(to: buttonSize)
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
    /// Fork: Remove from Session on session rows targets the lineup on screen — the
    /// browsed session (which is the active one whenever nothing else is being browsed).
    func multiSelectCurrentSession() -> Session? {
        browsedSession
    }
}

class SwitchSessionViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let themeOverride: Theme.ThemeType?
    private let includeUpNext: Bool
    private let onSwitched: (Bool) -> Void
    /// The sheet is the fast path: always the complete list, and it carries no sort/filter controls
    /// (the chooser's own sort and "Show" toggles are deliberately not applied — switching from here
    /// must never miss a session the user hid from a browsing list). Ordered to MATCH the Queue tab:
    /// the manual (drag) order with the current/active session hoisted first, so Up Next (its own
    /// section above) then the current session lead, exactly as the Queue VC arranges them.
    private let rows: [SessionListRow] = {
        var all = SessionListRows.current(sort: .manual, filters: .unfiltered)
        if let activeIndex = all.firstIndex(where: { $0.isActive }) {
            all.insert(all.remove(at: activeIndex), at: 0)
        }
        return all
    }()
    private let table = UITableView(frame: .zero, style: .plain)

    /// An active session gets an "End Session" row at the bottom of the Up Next section.
    private let showsEndSession: Bool

    init(themeOverride: Theme.ThemeType?, includeUpNext: Bool = true, onSwitched: @escaping (Bool) -> Void) {
        self.themeOverride = themeOverride
        self.includeUpNext = includeUpNext
        self.showsEndSession = includeUpNext && Settings.playbackSession() != nil
        self.onSwitched = onSwitched
        super.init(nibName: nil, bundle: nil)
    }

    private var queueRowCount: Int { includeUpNext ? 1 + (showsEndSession ? 1 : 0) : 0 }

    private func isEndSessionRow(_ indexPath: IndexPath) -> Bool {
        isQueueSection(indexPath.section) && showsEndSession && indexPath.row == queueRowCount - 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = AppTheme.colorForStyle(.primaryUi04, themeOverride: themeOverride)

        // Title with the same left-right arrows glyph as the header's switch button —
        // or the session glyph when choosing a first session.
        let titleIcon = UIImageView(image: UIImage(systemName: includeUpNext ? "arrow.left.arrow.right" : "rectangle.stack", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))?
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
        table.register(SessionListCell.self, forCellReuseIdentifier: SessionListCell.reuseIdentifier)
        table.estimatedRowHeight = 72
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
        isQueueSection(section) ? queueRowCount : rows.count
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if isEndSessionRow(indexPath) { return 56 }
        if isQueueSection(indexPath.section) { return NewPlaylistCell.cellHeight }
        return UITableView.automaticDimension
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

    /// The destructive "End Session" row at the bottom of the Up Next section — same
    /// leading inset as the sheet's rows, in the theme's danger red.
    private func makeEndSessionCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.backgroundColor = AppTheme.colorForStyle(.primaryUi02, themeOverride: themeOverride)
        cell.contentView.backgroundColor = .clear
        var config = cell.defaultContentConfiguration()
        config.text = L10n.playbackSessionEnd
        config.textProperties.font = UIFont.font(ofSize: 15, weight: .medium, scalingWith: .subheadline)
        config.textProperties.color = AppTheme.colorForStyle(.support05, themeOverride: themeOverride)
        config.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
        cell.contentConfiguration = config
        return cell
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if isEndSessionRow(indexPath) {
            return makeEndSessionCell()
        }

        if isQueueSection(indexPath.section) {
            let cell = (tableView.dequeueReusableCell(withIdentifier: NewPlaylistCell.reuseIdentifier) as? NewPlaylistCell)
                ?? NewPlaylistCell(style: .default, reuseIdentifier: NewPlaylistCell.reuseIdentifier)
            cell.reset()
            cell.configureUpNext(episodeCount: PlaybackManager.shared.queue.upNextCount())
            cell.hideSeparator(indexPath.row == queueRowCount - 1)
            return cell
        }

        let cell = (tableView.dequeueReusableCell(withIdentifier: SessionListCell.reuseIdentifier) as? SessionListCell)
            ?? SessionListCell(style: .default, reuseIdentifier: SessionListCell.reuseIdentifier)
        cell.themeOverride = themeOverride
        // The Switch Session sheet is a flat list — no platform, no play button (no handler), no handle.
        cell.populate(from: rows[indexPath.row], placement: .pool, reordering: false)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        AnalyticsPlaybackHelper.shared.currentSource = .upNext

        if isQueueSection(indexPath.section) {
            if isEndSessionRow(indexPath) {
                // End the session without forcing playback over to the queue — whatever
                // was playing keeps playing; the Up Next world is simply shown.
                if Settings.playbackSession() != nil {
                    PlaybackManager.shared.endPlaybackSession()
                }
                dismiss(animated: true) { [onSwitched] in
                    onSwitched(true)
                    NavigationManager.sharedManager.navigateTo(NavigationManager.upNextPageKey)
                }
                return
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

        let row = rows[indexPath.row]
        guard let storeUuid = SessionStore.shared.session(uuid: row.sessionUuid)?.storePlaylistUuid ?? row.storeUuid else { return }
        // A session always plays its store — a manual playlist holding the lineup.
        let session = PlaybackSession(type: .playlist, uuid: storeUuid)
        if session != Settings.playbackSession() {
            // Switching activates the session and primes its next episode as Now
            // Playing, but never starts audio — the user presses play when ready.
            PlaybackManager.shared.startPlaybackSession(session, autoPlay: false)
        } else if Settings.playbackSessionPaused() {
            // Re-picking the active-but-paused session un-pauses and primes it,
            // again without starting audio.
            if let episode = session.nextEpisode(after: nil) {
                PlaybackManager.shared.play(sessionEpisode: episode, autoPlay: false)
            }
        }
        // Same session, already active: nothing to change — just land on it.
        dismiss(animated: true) { [onSwitched] in
            onSwitched(true)
            // Switching to a session means going there — land on the Up Next tab
            // showing the Session world (the tab-activated snap follows whichever
            // world owns playback, which is now the session).
            NavigationManager.sharedManager.navigateTo(NavigationManager.upNextPageKey)
            NotificationCenter.postOnMainThread(notification: Constants.Notifications.upNextTabActivated)
        }
    }
}

// MARK: - Session list search (fork)

extension UpNextViewController: PCSearchBarDelegate {
    func searchDidBegin() {}
    func searchDidEnd() {}

    func searchWasCleared() {
        // Both search bars share this delegate; the visible screen decides which query is cleared.
        if showingSessionList { applySessionSearch("") } else { applyLineupSearch("") }
    }

    func searchTermChanged(_ searchTerm: String) {}

    func performSearch(searchTerm: String, triggeredByTimer: Bool, completion: @escaping (() -> Void)) {
        if showingSessionList { applySessionSearch(searchTerm) } else { applyLineupSearch(searchTerm) }
        completion()
    }
}
