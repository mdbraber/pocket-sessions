import UIKit
import SwiftUI
import PocketCastsDataModel
import PocketCastsUtils

extension PlaylistDetailViewController: UITableViewDataSource {
    private static let cellIdentifier = "EpisodeCell"
    // Fork: the now-playing episode in the Session (lineup) tab borrows the exact Up Next card.
    private static let sessionNowPlayingCardId = "SessionNowPlayingCard"

    func registerCells() {
        tableView.register(UINib(nibName: "EpisodeCell", bundle: nil), forCellReuseIdentifier: Self.cellIdentifier)
        tableView.register(UINib(nibName: "UpNextNowPlayingCell", bundle: nil), forCellReuseIdentifier: Self.sessionNowPlayingCardId)
        tableView.register(EmptyStateCell.self, forCellReuseIdentifier: EmptyStateCell.reuseIdentifier)
        tableView.register(DummyEmptyCell.self, forCellReuseIdentifier: DummyEmptyCell.reuseIdentifier)
        tableView.register(PlaylistHeaderViewCell.self, forCellReuseIdentifier: PlaylistHeaderViewCell.reuseIdentifier)
        tableView.register(PlaylistArchiveViewCell.self, forCellReuseIdentifier: PlaylistArchiveViewCell.reuseIdentifier)
        tableView.register(UINib(nibName: "HeadingCell", bundle: nil), forCellReuseIdentifier: "GroupHeading")
    }

    func registerLongPress() {
        let longPressRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(tableLongPressed(_:)))
        // Gated via the delegate: if this recognizer begins while inline reorder is on,
        // it cancels the drag interaction's touches and the drag lift never happens.
        longPressRecognizer.delegate = self
        tableView.addGestureRecognizer(longPressRecognizer)
    }

    @objc private func tableLongPressed(_ sender: UILongPressGestureRecognizer) {
        if sender.state == .began {
            // With custom order on, long-press means drag-to-reorder (multi-select stays
            // available via the ⋯ menu).
            if canReorderInline { return }
            let touchPoint = sender.location(in: tableView)
            guard let indexPath = tableView.indexPathForRow(at: touchPoint),
                  sectionModel(at: indexPath.section) == .episodes,
                  let episode = viewModel.listEpisode(at: indexPath)?.episode,
                  episode.wasDeleted == false else { return }
            if isMultiSelectEnabled {
                longPressSelectOptions(
                    for: indexPath,
                    in: tableView,
                    statusBarStyle: preferredStatusBarStyle
                ) { [weak self] allAboveAreSelected in
                    self?.track(allAboveAreSelected ? .filterDeselectAllAbove : .filterSelectAllAbove)
                } allBelowAction: { [weak self] allBelowAreSelected in
                    self?.track(allBelowAreSelected ? .filterDeselectAllBelow : .filterSelectAllBelow)
                }
            } else if viewModel.usesTriageTabs, viewModel.selectedTriageTab == .lineup,
                      let session = viewModel.session ?? viewModel.lensSession {
                // Fork: Session rows behave like Up Next — long-press is the inverse
                // of the tap setting.
                if !Settings.playUpNextOnTap() {
                    SessionManager.shared.play(episode: episode, in: session)
                } else if let parentPodcast = episode.parentPodcast() {
                    let episodeController = EpisodeDetailViewController(episode: episode, podcast: parentPodcast, source: .filters, playlist: .filter(uuid: viewModel.playlist.uuid))
                    episodeController.modalPresentationStyle = .formSheet
                    present(episodeController, animated: true, completion: nil)
                }
            } else {
                longPressMultiSelectIndexPath = indexPath
                isMultiSelectEnabled = true
            }
        }
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        return viewModel.dataSource.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        viewModel.dataSource[safe: section]?.elements.count ?? 0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let onToggleChange: (Bool) -> Void = { [weak self] selected in
            guard let self else { return }

            self.track(selected ? .filterShowArchivedTapped : .filterHideArchivedTapped)
            self.viewModel.updateShowArchivedEpisodes(show: selected)
            self.viewModel.reloadEpisodeList(animated: true)
        }

        switch sectionModel(at: indexPath.section) {
        case .header:
            let cell = tableView.dequeueReusableCell(withIdentifier: PlaylistHeaderViewCell.reuseIdentifier, for: indexPath) as! PlaylistHeaderViewCell
            cell.configure(viewModel: viewModel)
            return cell

        case .archive:
            guard let placeholder = viewModel.dataSource[safe: indexPath.section]?.elements[safe: indexPath.row] as? PlaylistArchiveViewCellPlaceholder else {
                FileLog.shared.addMessage("Playlist Detail tableView: missing ListItem in section \(indexPath.section), row \(indexPath.row)")
                return UITableViewCell()
            }
            if viewModel.archivedEpisodesCount == 0 {
                return tableView.dequeueReusableCell(withIdentifier: DummyEmptyCell.reuseIdentifier, for: indexPath) as! DummyEmptyCell
            }
            let isSelected = Binding<Bool>(
                get: { [weak self] in
                    guard let self else { return false }
                    return self.viewModel.shouldShowArchived
                },
                set: { newValue in
                    onToggleChange(newValue)
                }
            )
            let cell = tableView.dequeueReusableCell(withIdentifier: PlaylistArchiveViewCell.reuseIdentifier, for: indexPath) as! PlaylistArchiveViewCell
            cell.configure(archivedEpisodesCount: placeholder.archived, isSelected: isSelected)
            return cell

        case .episodes, .browse:
            guard let itemAtRow = viewModel.dataSource[safe: indexPath.section]?.elements[safe: indexPath.row] as? ListItem else {
                FileLog.shared.addMessage("Playlist Detail tableView: missing ListItem in section \(indexPath.section), row \(indexPath.row)")
                return UITableViewCell()
            }

            if let groupHeader = itemAtRow as? PlaylistGroupHeaderPlaceholder {
                let cell = tableView.dequeueReusableCell(withIdentifier: "GroupHeading", for: indexPath) as! HeadingCell
                cell.button.isHidden = true
                cell.action = nil
                // Fork: Podcast / Folder groups get a small chevron right AFTER the title that opens
                // that podcast/folder (tap the row — see didSelectRowAt). Other groupings (dates,
                // "No Folder", …) have no destination, so plain title, no chevron.
                if groupHeader.target != nil {
                    cell.configureWithTrailingChevron(title: groupHeader.title)
                } else {
                    cell.heading.attributedText = nil
                    cell.heading.text = groupHeader.title
                }
                return cell
            }

            if itemAtRow is PlaylistTabEmptyPlaceholder {
                // "No episodes match this filter" when something is narrowing; plain "No episodes"
                // when the list is genuinely empty.
                let narrowed = viewModel.isPresetNarrowing || viewModel.isSearching
                // On the Session tab with a genuinely empty lineup, tell the user how to fill it.
                if viewModel.usesTriageTabs, viewModel.selectedTriageTab == .lineup, viewModel.triageLineupCount == 0, !narrowed {
                    return configuredEmptyCell(
                        for: tableView,
                        at: indexPath,
                        title: L10n.sessionEmptyTitle.sentenceCased,
                        message: L10n.sessionEmptyMessage
                    )
                }
                return configuredEmptyCell(
                    for: tableView,
                    at: indexPath,
                    title: (narrowed ? L10n.playlistNoEpisodesMatchFilter : L10n.episodeFilterNoEpisodesTitle).sentenceCased,
                    message: ""
                )
            }

            if itemAtRow is NoSearchResultsPlaceholder {
                return configuredEmptyCell(
                    for: tableView,
                    at: indexPath,
                    title: L10n.discoverNoEpisodesFound,
                    message: L10n.discoverNoPodcastsFoundMsg
                )
            } else if let archivedPlaceholder = itemAtRow as? AllArchivedPlaceholder {
                return configuredEmptyCell(
                    for: tableView,
                    at: indexPath,
                    title: L10n.episodeFilterNoEpisodesTitle.sentenceCased,
                    message: archivedPlaceholder.message,
                    actions: [
                        .init(title: L10n.podcastShowArchived.sentenceCased, action: { [weak self] in
                            self?.track(.filterShowArchivedCtaEmptyTapped)
                            onToggleChange(true)
                        })
                    ]
                )
            }

            // Fork: on the Session (lineup) tab, the now-playing episode (playing OR paused) renders
            // as the exact Up Next now-playing card; other rows keep the normal layout below.
            if viewModel.usesTriageTabs, viewModel.selectedTriageTab == .lineup, !isMultiSelectEnabled,
               let listEpisode = itemAtRow as? ListEpisode,
               PlaybackManager.shared.isNowPlayingEpisode(episodeUuid: listEpisode.episode.uuid) {
                let card = tableView.dequeueReusableCell(withIdentifier: Self.sessionNowPlayingCardId, for: indexPath) as! UpNextNowPlayingCell
                card.themeOverride = nil
                card.populateFrom(episode: listEpisode.episode)
                card.setSessionInfoLine(listEpisode.episode.displayableInfo(includeSize: false))
                return card
            }

            let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellIdentifier, for: indexPath) as! EpisodeCell
            cell.episodeImageLeadConstraint.constant = 16.0
            cell.playlist = .filter(uuid: viewModel.playlist.uuid)
            // Session lineup rows: the play button joins the session (like tapping the row).
            cell.playInSession = (viewModel.usesTriageTabs && viewModel.selectedTriageTab == .lineup)
                ? (viewModel.session ?? viewModel.lensSession) : nil
            cell.delegate = self
            if let listEpisode = itemAtRow as? ListEpisode {
                cell.populateFrom(episode: listEpisode.episode, tintColor: nil, playlistUuid: viewModel.playlist.uuid)
                // The green in-this-session mini icon, on Episodes/Inbox rows only. On the
                // Session (lineup) tab every row is a member, so the badge is redundant.
                let onSessionLineup = viewModel.usesTriageTabs && viewModel.selectedTriageTab == .lineup
                cell.setSessionIndicator(onSessionLineup ? .none : viewModel.sessionIndicatorState(for: listEpisode.episode.uuid))
                // The unread dot: this episode is still in the Inbox.
                cell.setUnseenIndicator(visible: viewModel.unseenUuidsForDisplay.contains(listEpisode.episode.uuid))
                cell.shouldShowSelect = isMultiSelectEnabled
                if isMultiSelectEnabled {
                    cell.showTick = selectedEpisodesContains(uuid: listEpisode.episode.uuid)
                }
            }
            return cell

        case .none:
            FileLog.shared.addMessage("Playlist Detail tableView: unknown section \(indexPath.section)")
            return UITableViewCell()
        }
    }

    private func configuredEmptyCell(
        for tableView: UITableView,
        at indexPath: IndexPath,
        title: String,
        message: String,
        actions: [EmptyStateAction] = []
    ) -> EmptyStateCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: EmptyStateCell.reuseIdentifier,
            for: indexPath
        ) as! EmptyStateCell
        cell.configure(
            title: title,
            message: message,
            icon: {
                Image(systemName: "info.circle")
            },
            actions: actions)
        return cell
    }
}

extension PlaylistDetailViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if sectionModel(at: indexPath.section) == .archive {
            return viewModel.archivedEpisodesCount == 0 ? 1 : 49.0
        }
        return UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let model = sectionModel(at: section)
        let title = overlayHeaderTitle(for: model)
        let showsSearch = model == searchHeaderSection

        // Every playlist type shows the counts line under the search bar (manual
        // playlists included), so the composite header covers both cases.
        if title != nil || showsSearch {
            return triageTabsHeader(includingSearch: showsSearch)
        }
        return nil
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        let model = sectionModel(at: section)
        let showsCounts = overlayHeaderTitle(for: model) != nil || model == searchHeaderSection
        let titleHeight: CGFloat = showsCounts ? Self.triageTabsHeaderHeight : 0
        let searchHeight: CGFloat = model == searchHeaderSection ? PlaylistDetailViewController.searchRowHeight : 0
        let total = titleHeight + searchHeight
        // Grouped tables treat a literal 0 as "use the default section spacing" —
        // leastNormalMagnitude actually collapses it.
        return total > 0 ? total : .leastNormalMagnitude
    }

    // MARK: - Selection

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return isEpisodeSection(at: indexPath.section) && viewModel.listEpisode(at: indexPath) != nil
    }

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        // Fork: a Podcast/Folder group header (with a destination) is tappable to open it.
        if (viewModel.dataSource[safe: indexPath.section]?.elements[safe: indexPath.row] as? PlaylistGroupHeaderPlaceholder)?.target != nil {
            return indexPath
        }
        guard isEpisodeSection(at: indexPath.section), viewModel.listEpisode(at: indexPath) != nil else { return nil }
        if tableView.isEditing,
           let episode = viewModel.listEpisode(at: indexPath)?.episode,
           episode.wasDeleted {
            return nil
        }
        guard tableView.isEditing, !multiSelectGestureInProgress else { return indexPath }
        if let selectedEpisode = viewModel.listEpisode(at: indexPath), selectedEpisodes.contains(selectedEpisode) {
            tableView.delegate?.tableView?(tableView, didDeselectRowAt: indexPath)
            return nil
        }
        return indexPath
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        // Fork: tapping a Podcast/Folder group header opens that podcast/folder.
        if let groupHeader = viewModel.dataSource[safe: indexPath.section]?.elements[safe: indexPath.row] as? PlaylistGroupHeaderPlaceholder,
           let target = groupHeader.target {
            tableView.deselectRow(at: indexPath, animated: true)
            navigateToGroup(target)
            return
        }
        if !isEpisodeSection(at: indexPath.section) { return }
        guard let selectedEpisode = viewModel.listEpisode(at: indexPath)?.episode, let parentPodcast = selectedEpisode.parentPodcast() else { return }

        if isMultiSelectEnabled {
            guard let listEpisode = viewModel.listEpisode(at: indexPath) else { return }
            if listEpisode.episode.wasDeleted {
                return
            }

            if !multiSelectGestureInProgress {
                // If the episode is already selected move to the end of the array
                selectedEpisodesRemove(uuid: listEpisode.episode.uuid)
            }

            if !multiSelectGestureInProgress || multiSelectGestureInProgress, !selectedEpisodesContains(uuid: listEpisode.episode.uuid) {
                selectedEpisodes.append(listEpisode)
                // the cell below is optional because cellForRow only returns a cell if it's visible, and we don't need to tick cells that don't exist
                if let cell = tableView.cellForRow(at: indexPath) as? EpisodeCell? {
                    cell?.showTick = true
                }
            }
        } else {
            tableView.deselectRow(at: indexPath, animated: true)

            if selectedEpisode.wasDeleted {
                let episodeUuid = selectedEpisode.uuid
                let view = ModalMessageViewController.episodeUnavailableAlert { [weak self] in
                    guard let self else { return }
                    self.track(.filterRemoveFromPlaylistTapped)
                    self.track(episode: selectedEpisode, added: false, to: self.viewModel.playlist, source: "unavailable_episode")
                    self.viewModel.remove(episode: episodeUuid, at: indexPath.row)
                }
                BottomSheetSwiftUIWrapper.present(
                    view.environmentObject(Theme.sharedTheme),
                    autoSize: true,
                    showingGrabber: true,
                    in: self
                )
                return
            }

            // Fork: tapping the row that's already sounding opens the Now Playing
            // player, matching the Up Next now-playing row.
            if PlaybackManager.shared.isNowPlayingEpisode(episodeUuid: selectedEpisode.uuid) {
                if let miniPlayer = UIApplication.shared.appDelegate()?.miniPlayer(), miniPlayer.playerOpenState == .closed {
                    miniPlayer.openFullScreenPlayer()
                }
                return
            }

            // Fork: Session rows behave like Up Next — the tap setting decides
            // between playing the episode in this session and showing its card.
            if viewModel.usesTriageTabs, viewModel.selectedTriageTab == .lineup,
               Settings.playUpNextOnTap(),
               let session = viewModel.session ?? viewModel.lensSession {
                SessionManager.shared.play(episode: selectedEpisode, in: session)
                return
            }

            let episodeController = EpisodeDetailViewController(episode: selectedEpisode, podcast: parentPodcast, source: .filters, playlist: .filter(uuid: viewModel.playlist.uuid))
            episodeController.modalPresentationStyle = .formSheet
            present(episodeController, animated: true, completion: nil)
        }
    }

    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        if !isEpisodeSection(at: indexPath.section) { return }
        guard isMultiSelectEnabled else { return }
        if let listEpisode = viewModel.listEpisode(at: indexPath), let index = selectedEpisodes.firstIndex(of: listEpisode) {
            selectedEpisodes.remove(at: index)
            if let cell = tableView.cellForRow(at: indexPath) as? EpisodeCell {
                cell.showTick = false
            }
        }
    }

    // MARK: - multi select support

    func tableView(_ tableView: UITableView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
        if sectionModel(at: indexPath.section) != .episodes { return false }
        if let episode = viewModel.listEpisode(at: indexPath)?.episode, episode.wasDeleted {
            return false
        }
        return Settings.multiSelectGestureEnabled()
    }

    func tableView(_ tableView: UITableView, didBeginMultipleSelectionInteractionAt indexPath: IndexPath) {
        if sectionModel(at: indexPath.section) != .episodes { return }
        isMultiSelectEnabled = true
        multiSelectGestureInProgress = true
    }

    func tableViewDidEndMultipleSelectionInteraction(_ tableView: UITableView) {
        multiSelectGestureInProgress = false
    }
}

// MARK: - Fork: inline drag reorder (custom order)

extension PlaylistDetailViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // The multi-select long-press must yield entirely while custom order owns the
        // gesture — merely returning early from its handler still cancels the drag's touches.
        !(gestureRecognizer is UILongPressGestureRecognizer && canReorderInline)
    }
}

extension PlaylistDetailViewController: UITableViewDragDelegate, UITableViewDropDelegate {
    /// Reorder is always live while custom order is on — episode rows and the insert
    /// marker both drag; inbox rows are triaged via swipe instead.
    var canReorderInline: Bool {
        // A date-sorted Session view is display-only — reordering it would write the
        // wrong lineup order.
        guard !isMultiSelectEnabled, !viewModel.isSearching,
              TriageTabSort.order(.session, pageUuid: viewModel.playlist.uuid) == .custom else { return false }
        if viewModel.playlist.sortType == PlaylistSort.dragAndDrop.rawValue { return true }
        // Fork: lens pages reorder their fed session's lineup on the Session tab.
        return viewModel.isLensPage && viewModel.selectedTriageTab == .lineup && viewModel.lensSession != nil
    }

    func tableView(_ tableView: UITableView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        // Lineup rows reorder; inbox (New) rows drag INTO the lineup as triage-by-drag.
        // Drops are constrained to the lineup either way.
        guard canReorderInline, isEpisodeSection(at: indexPath.section),
              viewModel.section(at: indexPath.section) != .browse,
              viewModel.listEpisode(at: indexPath)?.episode.wasDeleted == false else { return [] }

        let dragItem = UIDragItem(itemProvider: NSItemProvider())
        dragItem.localObject = indexPath
        return [dragItem]
    }

    func tableView(_ tableView: UITableView, dragSessionWillBegin session: UIDragSession) {
        reloader.pause(for: .seconds(30))
    }

    func tableView(_ tableView: UITableView, dragSessionDidEnd session: UIDragSession) {
        reloader.resume(after: .seconds(1))
    }

    func tableView(_ tableView: UITableView, dropSessionDidUpdate session: UIDropSession, withDestinationIndexPath destinationIndexPath: IndexPath?) -> UITableViewDropProposal {
        guard session.localDragSession != nil,
              let destinationIndexPath,
              viewModel.section(at: destinationIndexPath.section) == .episodes else {
            return UITableViewDropProposal(operation: .cancel)
        }
        return UITableViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func tableView(_ tableView: UITableView, performDropWith coordinator: UITableViewDropCoordinator) {
        guard let item = coordinator.items.first,
              let source = item.sourceIndexPath,
              var destination = coordinator.destinationIndexPath,
              viewModel.section(at: destination.section) == .episodes else { return }

        let destinationElementCount = viewModel.dataSource[safe: destination.section]?.elements.count ?? 0

        guard viewModel.section(at: source.section) == .episodes else { return }
        destination.row = min(destination.row, max(destinationElementCount - 1, 0))
        guard source != destination else { return }

        viewModel.moveLineupElement(from: source.row, to: destination.row)
        tableView.performBatchUpdates {
            tableView.moveRow(at: source, to: destination)
        }
        coordinator.drop(item.dragItem, toRowAt: destination)

        // One whole-order write covers store pages and lens pages alike (the lens's
        // fed session owns the lineup there).
        viewModel.commitLineupOrder()
        NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged, object: viewModel.playlist)
        track(.filterManualEpisodesRearranged)
    }
}

extension PlaylistDetailViewController {
    /// Fork: opens the podcast or folder behind a Group By header's chevron.
    func navigateToGroup(_ target: PlaylistGroupHeaderPlaceholder.GroupNavTarget) {
        switch target {
        case .podcast(let uuid):
            guard let podcast = DataManager.sharedManager.findPodcast(uuid: uuid, includeUnsubscribed: true) else { return }
            if let nav = navigationController {
                nav.pushViewController(PodcastViewController(podcast: podcast), animated: true)
            } else {
                NavigationManager.sharedManager.navigateTo(NavigationManager.podcastPageKey, data: [NavigationManager.podcastKey: podcast])
            }
        case .folder(let uuid):
            guard let folder = DataManager.sharedManager.findFolder(uuid: uuid) else { return }
            NavigationManager.sharedManager.navigateTo(NavigationManager.folderPageKey, data: [NavigationManager.folderKey: folder])
        }
    }

    /// The selected tab's "x episodes · time" line — nil when the tab is empty (the
    /// empty state already says so). Section headers survive row diffs, so reloads
    /// call this again to keep the line honest.
    func triageCountsText() -> String? {
        let count: Int
        let duration: TimeInterval
        if viewModel.usesTriageTabs {
            switch viewModel.selectedTriageTab {
            case .lineup:
                count = viewModel.triageLineupCount
                duration = viewModel.triageLineupDuration
            case .browse:
                count = viewModel.triageBrowseCount
                duration = viewModel.triageBrowseDuration
            }
        } else {
            let episodes = viewModel.episodes
            count = episodes.count
            duration = episodes.reduce(0.0) { $0 + max(0, $1.episode.duration - $1.episode.playedUpTo) }
        }
        guard count > 0 else { return nil }
        let time = TimeFormatter.shared.multipleUnitFormattedShortTime(time: duration)
        return count == 1 ? L10n.playlistDetailDescriptionOneEpisode(time) : L10n.playlistDetailDescription(count, time)
    }

    func refreshTriageCountsLine() {
        triageCountsLabel?.text = triageCountsText()
    }

    /// Fork: the tab's sort picker — Session offers its custom lineup order plus the
    /// date orders; Inbox and Episodes the date orders.
    /// Applies a preset's sort/group to this page when the preset is selected. The list's own sort
    /// and group controls (in the ⋯ menu) then override these — the preset only seeds the defaults.
    func applyPresetSortAndGroup(_ preset: FilterPreset) {
        // Fork: a plain manual playlist is hand-ordered — a preset filters it, but must not impose
        // the preset's sort or grouping. (Session stores are also manual, but sort/group via tabs.)
        guard !(viewModel.isManualPlaylist && viewModel.session == nil) else { return }
        if let raw = preset.sortOrder, let order = TriageTabSortOrder(rawValue: raw) {
            TriageTabSort.setOrder(order, tab: viewModel.selectedTriageTab.sortKey, pageUuid: viewModel.playlist.uuid)
        }
        // Group (with its limit and reverse) applies to the Episodes tab only — the Session
        // lineup never groups.
        if viewModel.selectedTriageTab == .browse, let group = EpisodeGroupBy(rawValue: preset.groupBy) {
            viewModel.groupBy = group
            viewModel.groupLimit = preset.groupLimit
            viewModel.reverseGroup = preset.groupReversed
        }
    }
}

private extension PlaylistDetailViewController {
    static let overlayHeaderTitleHeight: CGFloat = 30
    /// The selected tab's counts line (the tab selector lives in the header cell).
    static let triageTabsHeaderHeight: CGFloat = 44

    func sectionModel(at index: Int) -> PlaylistDetailViewModel.Section? {
        viewModel.dataSource[safe: index]?.model
    }

    func isEpisodeSection(at index: Int) -> Bool {
        let model = sectionModel(at: index)
        return model == .episodes || model == .browse
    }

    var searchHeaderSection: PlaylistDetailViewModel.Section {
        if viewModel.isManualPlaylist, viewModel.session == nil { return .archive }
        // Fork: the search bar anchors above whichever tab section is visible.
        if viewModel.usesTriageTabs {
            switch viewModel.selectedTriageTab {
            case .lineup: return .episodes
            case .browse: return .browse
            }
        }
        return .episodes
    }

    /// Fork: marks the sections that carry the counts/controls header — the overlay's
    /// triage sections, and smart playlists on any sort order (their archived toggle
    /// lives on that line).
    func overlayHeaderTitle(for model: PlaylistDetailViewModel.Section?) -> String? {
        guard !viewModel.isSearching else { return nil }
        if viewModel.usesTriageTabs {
            switch model {
            case .episodes:
                return L10n.playbackSessionTabSession
            case .browse:
                return L10n.episodes
            default:
                return nil
            }
        }
        return nil
    }

    /// Fork: the Lineup | New tab selector (styled like the podcast page's tabs) with
    /// the selected tab's "x episodes · time" line beneath, optionally stacking the
    /// search bar above.
    func triageTabsHeader(includingSearch: Bool) -> UIView {
        let container = UIView()
        container.backgroundColor = AppTheme.colorForStyle(.primaryUi02)

        // The counts block sits between two hairlines, podcast-page style: one under
        // the search bar, one closing the header off from the rows.
        let topDivider = UIView()
        topDivider.backgroundColor = AppTheme.colorForStyle(.primaryUi05)
        topDivider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(topDivider)
        let bottomDivider = UIView()
        bottomDivider.backgroundColor = AppTheme.colorForStyle(.primaryUi05)
        bottomDivider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bottomDivider)

        // The selected tab's counts line, with bulk triage on the Inbox tab. Outside
        // the overlay (any other sort) the line covers the whole list.
        let countsLabel = UILabel()
        countsLabel.text = triageCountsText()
        countsLabel.font = UIFont.font(ofSize: 14, weight: .regular, scalingWith: .footnote)
        countsLabel.textColor = AppTheme.colorForStyle(.primaryText02)
        countsLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(countsLabel)
        triageCountsLabel = countsLabel

        var constraints = [
            countsLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            countsLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -13),
            countsLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16)
        ]

        // Fork: the Filter Preset control belongs on every episode list EXCEPT a session
        // lineup — matching the podcast page's Session tab: the lineup is a hand-made list
        // presets never narrow, so the funnel hides there and shapes the Episodes/Browse
        // views only. Plain manual playlists keep it (filter-only, order untouched).
        var funnelButton: UIButton?
        let onLineupTab = viewModel.usesTriageTabs && viewModel.selectedTriageTab == .lineup
        if !onLineupTab, viewModel.usesTriageTabs || viewModel.isManualPlaylist {
            let funnel = FilterPresetPicker.makeButton(
                target: self,
                scope: viewModel.filterScope,
                searchActive: { [weak self] in self?.viewModel.isSearching ?? false },
                onSelect: { [weak self] preset in self?.applyPresetSortAndGroup(preset) }
            ) { [weak self] in
                self?.viewModel.reloadEpisodeList(animated: false)
            }
            funnel.translatesAutoresizingMaskIntoConstraints = false
            presetFunnelButton = funnel
            container.addSubview(funnel)
            constraints.append(contentsOf: [
                funnel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
                funnel.centerYAnchor.constraint(equalTo: countsLabel.centerYAnchor)
            ])
            funnelButton = funnel
        }

        // Fork: sort and group by are NOT on the counts line — they live in the ⋯ menu only. The
        // counts line carries just the preset control.
        if let funnelButton {
            constraints.append(countsLabel.trailingAnchor.constraint(lessThanOrEqualTo: funnelButton.leadingAnchor, constant: -10))
        }

        if includingSearch {
            searchHeaderView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(searchHeaderView)
            constraints.append(contentsOf: [
                searchHeaderView.topAnchor.constraint(equalTo: container.topAnchor),
                searchHeaderView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                searchHeaderView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                searchHeaderView.heightAnchor.constraint(equalToConstant: PlaylistDetailViewController.searchRowHeight)
            ])
            constraints.append(topDivider.topAnchor.constraint(equalTo: searchHeaderView.bottomAnchor))
        } else {
            constraints.append(topDivider.topAnchor.constraint(equalTo: container.topAnchor))
        }

        constraints.append(contentsOf: [
            topDivider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            topDivider.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),

            bottomDivider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bottomDivider.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bottomDivider.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale)
        ])

        NSLayoutConstraint.activate(constraints)
        return container
    }


    /// Builds a section header with a themed title, optionally stacking the search bar
    /// above it and an accent action button on the trailing edge.
    func overlaySectionHeader(title: String, includingSearch: Bool, trailingAction: (title: String, handler: () -> Void)? = nil) -> UIView {
        let container = UIView()
        container.backgroundColor = AppTheme.colorForStyle(.primaryUi02)

        let titleLabel = UILabel()
        titleLabel.text = title.localizedUppercase
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = AppTheme.colorForStyle(.primaryText02)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        var constraints = [
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            titleLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6)
        ]

        if let trailingAction {
            let button = UIButton(type: .system)
            button.setTitle(trailingAction.title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
            button.setTitleColor(AppTheme.colorForStyle(.primaryInteractive01), for: .normal)
            button.addAction(UIAction { _ in trailingAction.handler() }, for: .touchUpInside)
            button.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(button)
            constraints.append(contentsOf: [
                button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
                button.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -10)
            ])
        }

        if includingSearch {
            searchHeaderView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(searchHeaderView)
            constraints.append(contentsOf: [
                searchHeaderView.topAnchor.constraint(equalTo: container.topAnchor),
                searchHeaderView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                searchHeaderView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                searchHeaderView.heightAnchor.constraint(equalToConstant: PlaylistDetailViewController.searchRowHeight)
            ])
        }

        NSLayoutConstraint.activate(constraints)
        return container
    }
}


fileprivate class DummyEmptyCell: ThemeableCell {
    static let reuseIdentifier = "DummyEmptyCell"

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setSelected(_ selected: Bool, animated: Bool) {}
    override func setHighlighted(_ highlighted: Bool, animated: Bool) {}
    override func setEditing(_ editing: Bool, animated: Bool) {}
}
