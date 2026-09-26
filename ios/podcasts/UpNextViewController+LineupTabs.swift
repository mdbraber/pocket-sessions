import PocketCastsDataModel
import PocketCastsUtils
import SwiftUI
import UIKit

/// Fork: the two tabs over a session lineup on the Queue screen — the lineup itself (Session), and
/// the Episodes its feeder could add. Same pair, same order and same look as a session's playlist
/// page, so the Queue can review and top up a session without leaving it.
enum LineupTab {
    case episodes
    case session
}

/// A row of the Episodes tab: a Group By heading, or an episode.
enum SessionBrowseRow {
    case header(String)
    case episode(BaseEpisode)

    /// Unique within a list (group titles are unique by construction) — for the search diff.
    var identity: String {
        switch self {
        case .header(let title): return "header:\(title)"
        case .episode(let episode): return "episode:\(episode.uuid)"
        }
    }
}

extension UpNextViewController {
    /// The tabs show on a session lineup whose feeder has episodes to browse — a podcast, a smart
    /// playlist, or all podcasts. A manual playlist (a season, say) has no feeder, so there is
    /// nothing to switch to and the lineup stands alone.
    var showsLineupTabs: Bool {
        guard displayedWorld == .session, !showingSessionList, let session = browsedSession else { return false }
        if case .none = session.feeder { return false }
        return !SessionManager.isOptedOut(feeder: session.feeder)
    }

    /// The Episodes tab is showing (the lineup's top block and rows are the browse list).
    var showingSessionBrowse: Bool {
        showsLineupTabs && lineupTab == .episodes
    }

    func selectLineupTab(_ tab: LineupTab) {
        guard lineupTab != tab else { return }
        // Neither mode carries across: reorder and multi-select both act on the lineup's rows.
        if isMultiSelectEnabled { isMultiSelectEnabled = false }
        lineupReorderMode = false
        clearLineupSearch()
        lineupTab = tab
        reloadTable()
        resetLineupScrollToTop()
    }

    /// A podcast's session browses that one podcast, so podcast/folder-limited presets don't apply.
    var sessionBrowseIsSinglePodcast: Bool {
        if case .podcast = browsedSession?.feeder { return true }
        return false
    }

    /// Rebuilds the Episodes tab's list. Only while it is showing — the domain query is the
    /// expensive part, and the Session tab never needs it.
    func refreshSessionBrowse() {
        sessionSectionRowsCache = nil
        guard showingSessionBrowse, let session = browsedSession else {
            sessionBrowseEpisodes = []
            sessionBrowseMemberUuids = []
            return
        }
        sessionBrowseMemberUuids = Set(SessionFeederEngine.storeMemberUuids(for: session))
        let domain: [BaseEpisode] = SessionFeederEngine.domainEpisodes(for: session, preset: FilterPresets.active(.sessionEpisodes, singlePodcast: sessionBrowseIsSinglePodcast))
        // The same display order the session's own page shows its Episodes tab in.
        let order = TriageTabSort.order(pageUuid: sessionBrowsePageUuid(for: session))
        sessionBrowseEpisodes = order == TriageTabSort.defaultOrder ? domain : order.sorted(domain)
    }

    /// A preset picked on the Episodes tab seeds its sort and grouping — the same thing picking it on
    /// the session's own page does (`applyPresetSortAndGroup`), into the same per-page settings.
    func applyBrowseSeeds(of preset: FilterPreset) {
        guard let session = browsedSession else { return }
        let pageUuid = sessionBrowsePageUuid(for: session)
        // A browsed list has no hand order, so Manual (like an empty sort) leaves its sort alone.
        if case .order(let order) = preset.sortSeed {
            TriageTabSort.setOrder(order, pageUuid: pageUuid)
        }
        if let groupBy = preset.groupSeed {
            let grouping = EpisodeListGrouping(pageUuid: pageUuid)
            grouping.groupBy = groupBy
            grouping.limit = preset.groupLimit
            grouping.reversed = preset.groupReversed
        }
    }

    /// The Session tab's preset narrows what the lineup shows (never what plays). Off in "Reorder
    /// Episodes" mode, whose grips need the whole list.
    var sessionLineupPresetNarrowing: Bool {
        guard displayedWorld == .session, !showingSessionList, !showingSessionBrowse, browsedSession != nil, !lineupReorderMode else { return false }
        return FilterPresets.isNarrowing(.session, singlePodcast: sessionBrowseIsSinglePodcast)
    }

    /// Something hides part of the Session tab's lineup — a search or a preset. Rows are then a
    /// subset, so position-based moves (drag, Move to Top/Bottom) stand down.
    var lineupIsNarrowed: Bool { lineupSearchActive || sessionLineupPresetNarrowing }

    /// Rebuilds the Session tab's preset-filtered lineup (see `sessionLineupFilteredEpisodes`).
    func refreshSessionLineupFilter() {
        guard sessionLineupPresetNarrowing, let session = browsedSession, let tail = sessionEpisodes else {
            sessionLineupFilteredEpisodes = nil
            return
        }
        let preset = FilterPresets.active(.session, singlePodcast: sessionBrowseIsSinglePodcast)
        sessionLineupFilteredEpisodes = FilterPresets.filter(tail, by: preset, thisSessionStoreUuid: session.storePlaylistUuid,
                                                             singlePodcast: sessionBrowseIsSinglePodcast) { $0 }
        sessionSectionRowsCache = nil
    }

    /// The page whose Episodes-tab sort and grouping apply: a smart playlist's session is browsed on
    /// the smart playlist's own page; every other session on its store's page. Sharing the page uuid
    /// keeps the Queue's Episodes tab and the page's arranged alike.
    func sessionBrowsePageUuid(for session: Session) -> String {
        if case .smartPlaylist(let uuid) = session.feeder { return uuid }
        return session.storePlaylistUuid ?? session.uuid
    }

    /// The Session tab of a GROUPED session: its rows carry headings (see `sessionSectionRows`).
    var sessionLineupIsGrouped: Bool {
        guard displayedWorld == .session, !showingSessionList, !showingSessionBrowse, let session = browsedSession else { return false }
        return LineupSort.grouping(of: session) != .none
    }

    /// Whether the session section's rows are `sessionSectionRows` (with headings) rather than the
    /// plain tail, one row per episode.
    var usesSessionSectionRows: Bool { showingSessionBrowse || sessionLineupIsGrouped }

    /// The session section's rows when they carry headings. On the Episodes tab: the searched browse
    /// list, grouped per the page's Group By. On a grouped Session tab: the lineup (already in group
    /// order — `LineupSort` keeps it arranged) labelled with its runs. Cached — grouping a whole
    /// feeder domain on every row lookup would be far too slow — and invalidated whenever the list
    /// or the search changes.
    var sessionSectionRows: [SessionBrowseRow] {
        if let sessionSectionRowsCache { return sessionSectionRowsCache }
        let episodes = filteredLineupTail
        let rows: [SessionBrowseRow]
        if sessionLineupIsGrouped, let session = browsedSession {
            rows = EpisodeGrouper.runs(episodes, by: LineupSort.grouping(of: session)) { $0 }
                .flatMap { run in [SessionBrowseRow.header(run.title)] + run.items.map(SessionBrowseRow.episode) }
        } else if let session = browsedSession, case let grouping = EpisodeListGrouping(pageUuid: sessionBrowsePageUuid(for: session)), grouping.isActive {
            rows = EpisodeGrouper.group(episodes, by: grouping.groupBy, limit: grouping.limit, reversed: grouping.reversed) { $0 }
                .flatMap { group -> [SessionBrowseRow] in
                    let items = group.items.map(SessionBrowseRow.episode)
                    guard let title = group.title else { return items }
                    return [.header(title)] + items
                }
        } else {
            rows = episodes.map(SessionBrowseRow.episode)
        }
        sessionSectionRowsCache = rows
        return rows
    }

    /// The episode on a session-section row, in either tab (nil for a heading or placeholder).
    func sessionRowEpisode(at row: Int) -> BaseEpisode? {
        guard usesSessionSectionRows else { return filteredLineupTail[safe: row] }
        if case .episode(let episode) = sessionSectionRows[safe: row] { return episode }
        return nil
    }

    /// The episodes a list-wide action (Download All) covers: what the tab shows.
    var lineupEpisodesOnScreen: [BaseEpisode] {
        if showingSessionBrowse { return sessionSectionRows.compactMap { if case .episode(let episode) = $0 { return episode } else { return nil } } }
        return (lineupHeadEpisode.map { [$0] } ?? []) + filteredLineupTail
    }

    /// "N episodes · time" for the Episodes tab, matching the Session tab's line.
    func sessionBrowseMetaText() -> String? {
        let count = sessionBrowseEpisodes.count
        guard count > 0 else { return nil }
        let duration = sessionBrowseEpisodes.reduce(0.0) { $0 + max(0, $1.duration - $1.playedUpTo) }
        let time = TimeFormatter.shared.multipleUnitFormattedShortTime(time: duration)
        return count == 1 ? L10n.queueUpNextHeaderOneEpisode(time) : L10n.queueUpNextHeaderPlural(count.localized(), time)
    }

    /// Syncs the tab strip and the info line's controls with the tab. Called on every chrome update.
    func updateSessionBrowseControls() {
        // The ⋯ rides beside a session lineup's search field; Up Next details keeps a full-width one.
        let showsMore = displayedWorld == .session && !showingSessionList
        lineupMoreButton.isHidden = !showsMore
        lineupMoreButton.tintColor = AppTheme.colorForStyle(.primaryIcon02, themeOverride: themeOverride)
        // Deactivate before activating, so the two trailing constraints are never on together.
        let (on, off) = showsMore
            ? (lineupSearchBesideMoreConstraint, lineupSearchFullWidthConstraint)
            : (lineupSearchFullWidthConstraint, lineupSearchBesideMoreConstraint)
        off?.isActive = false
        on?.isActive = true

        let browsing = showingSessionBrowse
        if showsLineupTabs {
            let count = (sessionCurrentEpisode != nil ? 1 : 0) + (sessionEpisodes?.count ?? 0)
            lineupTabsView.configure(selected: lineupTab, sessionCount: count, themeOverride: themeOverride)
        }
        sessionBrowsePresetButton.isHidden = !browsing
        // The counts line's own reorder arrows are gone: Sort By lives in the ⋯ beside the search,
        // as on the playlist page.
        sessionSortButton.isHidden = true
        let onSessionTab = displayedWorld == .session && !showingSessionList && !browsing && browsedSession != nil
        sessionLineupPresetButton.isHidden = !onSessionTab
        if onSessionTab {
            style(presetButton: sessionLineupPresetButton, scope: .session)
        }
        guard browsing else { return }
        // The Episodes tab's line is counts + filter: the lineup's reorder control has nothing to
        // reorder here.
        sessionSortButton.isHidden = true
        sessionMetaLabel.text = sessionMetaText()
        style(presetButton: sessionBrowsePresetButton, scope: .sessionEpisodes)
    }

    private func style(presetButton button: UIButton, scope: FilterScope) {
        FilterPresetPicker.style(button, scope: scope, singlePodcast: sessionBrowseIsSinglePodcast)
        // `style` reads the app theme; this sheet can wear an override (opened from the player).
        let narrowing = FilterPresets.isNarrowing(scope, singlePodcast: sessionBrowseIsSinglePodcast)
        button.tintColor = AppTheme.colorForStyle(narrowing ? .primaryInteractive01 : .primaryIcon02, themeOverride: themeOverride)
        button.setTitleColor(AppTheme.colorForStyle(narrowing ? .primaryInteractive01 : .primaryText02, themeOverride: themeOverride), for: .normal)
    }

    /// A preset was picked, edited or reset elsewhere — the Episodes tab re-queries.
    @objc func sessionBrowsePresetsChanged() {
        guard displayedWorld == .session, !showingSessionList else { return }
        setNeedsReload()
    }

    /// The ⋯ beside the lineup search — the same menu as the session's playlist page, per tab: the
    /// Session tab re-arranges its one saved order; the Episodes tab sorts and groups.
    @objc func lineupMoreTapped() {
        let optionsPicker = OptionsPicker(title: nil, themeOverride: themeOverride)

        optionsPicker.addAction(action: EpisodeListMenu.chromecastAction { [weak self] in
            guard let self else { return }
            EpisodeListMenu.presentCastPicker(from: self)
        })

        if !lineupEpisodesOnScreen.isEmpty {
            optionsPicker.addAction(action: EpisodeListMenu.multiSelectAction { [weak self] in
                self?.selectTapped()
            })
        }

        if showingSessionBrowse, let session = browsedSession {
            let pageUuid = sessionBrowsePageUuid(for: session)
            optionsPicker.addAction(action: EpisodeListMenu.browseSortAction(pageUuid: pageUuid, themeOverride: themeOverride) { [weak self] in
                self?.reloadTable()
            })
            EpisodeListMenu.addGroupByActions(to: optionsPicker, grouping: EpisodeListGrouping(pageUuid: pageUuid), themeOverride: themeOverride) { [weak self] in
                self?.reloadTable()
            }
        } else if let session = browsedSession {
            EpisodeListMenu.addLineupArrangementActions(to: optionsPicker, session: session, themeOverride: themeOverride, onChange: { [weak self] in
                self?.reloadTable()
            }, onReorderEpisodes: { [weak self] in
                self?.enterLineupReorderMode()
            })
        }

        optionsPicker.addAction(action: EpisodeListMenu.downloadAllAction(themeOverride: themeOverride, episodes: { [weak self] in
            self?.lineupEpisodesOnScreen ?? []
        }))

        optionsPicker.present(from: self)
    }

    /// A Group By heading on the Episodes tab — the playlist page's heading cell.
    func sessionBrowseHeaderCell(title: String, at indexPath: IndexPath) -> UITableViewCell {
        let cell = upNextTable.dequeueReusableCell(withIdentifier: Self.groupHeadingCell, for: indexPath) as! HeadingCell
        cell.themeOverride = themeOverride
        cell.button.isHidden = true
        cell.action = nil
        cell.heading.attributedText = nil
        cell.heading.text = title
        return cell
    }

    static let groupHeadingCell = "GroupHeading"

    /// An Episodes-tab row: the feeder's episode, badged when it's already in this session. The play
    /// button plays it on its own (it's not a lineup member to move to the top), and nothing drags.
    func sessionBrowseEpisodeCell(for episode: BaseEpisode, at indexPath: IndexPath) -> EpisodeCell {
        let cell = upNextTable.dequeueReusableCell(withIdentifier: UpNextViewController.episodeCell, for: indexPath) as! EpisodeCell
        cell.themeOverride = themeOverride
        cell.hidesArtwork = false
        cell.episodeImageLeadConstraint.constant = 16.0
        cell.delegate = self
        cell.showsReorderControl = false
        cell.hidesActionButton = false
        cell.managesOwnSelectControl = true
        cell.addsLineupTrailingInset = true
        cell.shouldShowSelect = isMultiSelectEnabled
        cell.playlist = nil
        cell.playButtonTintOverride = AppTheme.colorForStyle(.primaryText01, themeOverride: themeOverride)
        cell.populateFrom(episode: episode, tintColor: nil)
        cell.setSessionIndicator(SessionIndicatorState.resolve(episode.uuid, thisSession: sessionBrowseMemberUuids))
        cell.setUnseenIndicator(visible: InboxManager.shared.unseenUuids().contains(episode.uuid))
        cell.setActiveSurface(accent: nil)
        cell.showTick = selectedEpisodesContains(uuid: episode.uuid)
        cell.contentView.alpha = 1
        return cell
    }

    /// The Episodes tab's empty row: nothing matched the search, nothing matched the preset, or the
    /// feeder genuinely has nothing.
    func sessionBrowseEmptyCell(at indexPath: IndexPath) -> UITableViewCell {
        let emptyCell = upNextTable.dequeueReusableCell(withIdentifier: UpNextViewController.emptyStateCell, for: indexPath) as! EmptyStateCell
        if lineupSearchActive {
            emptyCell.configure(title: L10n.discoverNoEpisodesFound, icon: { Image(systemName: "magnifyingglass") })
        } else {
            let narrowed = FilterPresets.isNarrowing(.sessionEpisodes, singlePodcast: sessionBrowseIsSinglePodcast)
            emptyCell.configure(title: (narrowed ? L10n.playlistNoEpisodesMatchFilter : L10n.episodeFilterNoEpisodesTitle).sentenceCased,
                                icon: { Image(systemName: "line.3.horizontal.decrease") })
        }
        return emptyCell
    }
}

/// Fork: the Episodes | Session tab strip, in UIKit so it can wear the sheet's theme override. Looks
/// exactly like the playlist page's SwiftUI strip (`PlaylistHeaderView.triageTabs`): the selected
/// tab is a filled pill in the primary text colour, the other plain secondary text.
final class LineupTabsView: UIView {
    private let episodesButton = UIButton(type: .custom)
    private let sessionButton = UIButton(type: .custom)
    private let onSelect: (LineupTab) -> Void

    init(onSelect: @escaping (LineupTab) -> Void) {
        self.onSelect = onSelect
        super.init(frame: .zero)

        let stack = UIStackView(arrangedSubviews: [episodesButton, sessionButton])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        for (button, tab) in [(episodesButton, LineupTab.episodes), (sessionButton, .session)] {
            var config = UIButton.Configuration.plain()
            config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
            // A capsule under Liquid Glass, rounded rectangles otherwise — as the playlist page.
            config.cornerStyle = LiquidGlass.isEnabled ? .capsule : .fixed
            config.background.cornerRadius = 8
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = UIFont.font(ofSize: 15, weight: .medium, scalingWith: .subheadline)
                return attributes
            }
            button.configuration = config
            button.addAction(UIAction { [weak self] _ in self?.onSelect(tab) }, for: .touchUpInside)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The Session tab carries the lineup's count (hidden at zero), as on the playlist page.
    func configure(selected: LineupTab, sessionCount: Int, themeOverride: Theme.ThemeType?) {
        let sessionTitle = sessionCount > 0
            ? "\(L10n.playbackSessionTabSession) · \(sessionCount.localized())"
            : L10n.playbackSessionTabSession

        for (button, tab, title) in [(episodesButton, LineupTab.episodes, L10n.episodes), (sessionButton, .session, sessionTitle)] {
            let highlighted = tab == selected
            guard var config = button.configuration else { continue }
            config.title = title
            config.baseForegroundColor = AppTheme.colorForStyle(highlighted ? .primaryUi01 : .primaryText02, themeOverride: themeOverride)
            config.background.backgroundColor = highlighted ? AppTheme.colorForStyle(.primaryText01, themeOverride: themeOverride) : .clear
            button.configuration = config
            button.accessibilityTraits = highlighted ? [.button, .selected] : .button
        }
    }
}
