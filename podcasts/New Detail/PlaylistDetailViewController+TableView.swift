import UIKit
import SwiftUI
import PocketCastsDataModel
import PocketCastsUtils

extension PlaylistDetailViewController: UITableViewDataSource {
    private static let cellIdentifier = "EpisodeCell"

    func registerCells() {
        tableView.register(UINib(nibName: "EpisodeCell", bundle: nil), forCellReuseIdentifier: Self.cellIdentifier)
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

        case .inbox, .episodes, .browse:
            guard let itemAtRow = viewModel.dataSource[safe: indexPath.section]?.elements[safe: indexPath.row] as? ListItem else {
                FileLog.shared.addMessage("Playlist Detail tableView: missing ListItem in section \(indexPath.section), row \(indexPath.row)")
                return UITableViewCell()
            }

            if let groupHeader = itemAtRow as? PlaylistGroupHeaderPlaceholder {
                let cell = tableView.dequeueReusableCell(withIdentifier: "GroupHeading", for: indexPath) as! HeadingCell
                cell.heading.text = groupHeader.title
                cell.button.isHidden = true
                cell.action = nil
                return cell
            }

            if itemAtRow is PlaylistTabEmptyPlaceholder {
                return configuredEmptyCell(
                    for: tableView,
                    at: indexPath,
                    title: L10n.episodeFilterNoEpisodesTitle.sentenceCased,
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

            let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellIdentifier, for: indexPath) as! EpisodeCell
            cell.episodeImageLeadConstraint.constant = 16.0
            cell.playlist = .filter(uuid: viewModel.playlist.uuid)
            cell.delegate = self
            if let listEpisode = itemAtRow as? ListEpisode {
                cell.populateFrom(episode: listEpisode.episode, tintColor: nil, playlistUuid: viewModel.playlist.uuid)
                // The green in-this-session mini icon, on Episodes rows only (Session
                // rows are all members; Inbox rows never are).
                cell.setSessionIndicator(visible: sectionModel(at: indexPath.section) == .browse
                    && viewModel.sessionMemberUuidsForDisplay.contains(listEpisode.episode.uuid))
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

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        showsInboxActionsFooter(at: section) ? PlaylistDetailViewController.inboxActionsFooterHeight : .leastNormalMagnitude
    }

    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        showsInboxActionsFooter(at: section) ? inboxActionsFooter() : UIView()
    }

    /// Fork: the Inbox tab closes with two action buttons — Add All to Session and
    /// Clear All (the same rounded style as the global Inbox's Clear).
    private func showsInboxActionsFooter(at section: Int) -> Bool {
        sectionModel(at: section) == .inbox && viewModel.usesTriageTabs
            && viewModel.selectedTriageTab == .new && viewModel.triageNewCount > 0 && !isMultiSelectEnabled
    }

    // MARK: - Selection

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return isEpisodeSection(at: indexPath.section) && viewModel.listEpisode(at: indexPath) != nil
    }

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
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
        !isMultiSelectEnabled && !viewModel.isSearching && viewModel.playlist.sortType == PlaylistSort.dragAndDrop.rawValue
            && TriageTabSort.order(.session, pageUuid: viewModel.playlist.uuid) == .custom
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

        // Triage by drag: a New (inbox) episode dropped into the lineup gets a position there.
        if viewModel.section(at: source.section) == .inbox {
            guard viewModel.listEpisode(at: source) != nil else { return }
            destination.row = min(destination.row, destinationElementCount)
            viewModel.moveInboxElementToLineup(fromInboxRow: source.row, toEpisodesRow: destination.row)
            tableView.performBatchUpdates {
                tableView.moveRow(at: source, to: destination)
            }
            coordinator.drop(item.dragItem, toRowAt: destination)
            viewModel.commitLineupOrder()
            NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged, object: viewModel.playlist)
            track(.filterManualEpisodesRearranged)
            return
        }

        guard viewModel.section(at: source.section) == .episodes else { return }
        destination.row = min(destination.row, max(destinationElementCount - 1, 0))
        guard source != destination else { return }

        viewModel.moveLineupElement(from: source.row, to: destination.row)
        tableView.performBatchUpdates {
            tableView.moveRow(at: source, to: destination)
        }
        coordinator.drop(item.dragItem, toRowAt: destination)

        if let moved = viewModel.listEpisode(at: destination) {
            let lineupUuids = viewModel.lineupEpisodes.map { $0.episode.uuid }
            let lineupIndex = lineupUuids.firstIndex(of: moved.episode.uuid) ?? destination.row
            viewModel.move(episode: moved, toIndex: lineupIndex)
            NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged, object: viewModel.playlist)
            track(.filterManualEpisodesRearranged)
        }
    }
}

extension PlaylistDetailViewController {
    /// The selected tab's "x episodes · time" line — nil when the tab is empty (the
    /// empty state already says so). Section headers survive row diffs, so reloads
    /// call this again to keep the line honest.
    func triageCountsText() -> String? {
        let count: Int
        let duration: TimeInterval
        if viewModel.usesTriageTabs {
            switch viewModel.selectedTriageTab {
            case .new:
                count = viewModel.triageNewCount
                duration = viewModel.triageNewDuration
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
    func presentTriageSortPicker() {
        let tab = viewModel.selectedTriageTab.sortKey
        let pageUuid = viewModel.playlist.uuid
        let picker = OptionsPicker(title: L10n.sortBy.localizedUppercase)
        let current = TriageTabSort.order(tab, pageUuid: pageUuid)
        for option in tab.options {
            picker.addAction(action: OptionAction(label: option.title, selected: current == option) { [weak self] in
                TriageTabSort.setOrder(option, tab: tab, pageUuid: pageUuid)
                self?.viewModel.reloadEpisodeList(animated: false)
            })
        }
        picker.present(from: self)
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
        return model == .episodes || model == .inbox || model == .browse
    }

    var searchHeaderSection: PlaylistDetailViewModel.Section {
        if viewModel.isManualPlaylist, viewModel.session == nil { return .archive }
        // Fork: the search bar anchors above whichever tab section is visible.
        if viewModel.usesTriageTabs {
            switch viewModel.selectedTriageTab {
            case .new: return viewModel.hasInboxSection ? .inbox : .episodes
            case .lineup: return .episodes
            case .browse: return .browse
            }
        }
        return viewModel.hasInboxSection ? .inbox : .episodes
    }

    /// Fork: marks the sections that carry the counts/controls header — the overlay's
    /// triage sections, and smart playlists on any sort order (their archived toggle
    /// lives on that line).
    func overlayHeaderTitle(for model: PlaylistDetailViewModel.Section?) -> String? {
        guard !viewModel.isSearching else { return nil }
        if viewModel.usesTriageTabs {
            switch model {
            case .inbox:
                return L10n.inboxTitle
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

        // Fork: the Episodes tab carries the filter funnel, exactly like the podcast
        // page — Show Archived / Show Played as checkable rows.
        var funnelButton: UIButton?
        if viewModel.usesTriageTabs, viewModel.selectedTriageTab == .browse {
            let funnel = UIButton(type: .system)
            funnel.setImage(UIImage(named: "podcast-filter"), for: .normal)
            // The cue: neutral when everything is default, accent when filtering.
            funnel.tintColor = AppTheme.colorForStyle(viewModel.isEpisodesFunnelActive ? .primaryInteractive01 : .primaryIcon02)
            funnel.accessibilityLabel = L10n.filters
            funnel.addAction(UIAction { [weak self] _ in
                self?.presentEpisodesFunnel()
            }, for: .touchUpInside)
            funnel.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(funnel)
            constraints.append(contentsOf: [
                funnel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
                funnel.centerYAnchor.constraint(equalTo: countsLabel.centerYAnchor)
            ])
            funnelButton = funnel
        }

        // Fork: the per-tab sort control, left of the funnel (or at its spot on tabs
        // without one). Accented whenever the tab isn't in its natural order.
        if viewModel.usesTriageTabs {
            let sortKey = viewModel.selectedTriageTab.sortKey
            let sort = UIButton(type: .system)
            sort.setImage(UIImage(systemName: "arrow.up.arrow.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)), for: .normal)
            sort.tintColor = AppTheme.colorForStyle(TriageTabSort.isNonDefault(sortKey, pageUuid: viewModel.playlist.uuid) ? .primaryInteractive01 : .primaryIcon02)
            sort.accessibilityLabel = L10n.sortBy
            sort.addAction(UIAction { [weak self] _ in
                self?.presentTriageSortPicker()
            }, for: .touchUpInside)
            sort.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(sort)
            if let funnelButton {
                constraints.append(sort.trailingAnchor.constraint(equalTo: funnelButton.leadingAnchor, constant: -12))
            } else {
                constraints.append(sort.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16))
            }
            constraints.append(contentsOf: [
                sort.centerYAnchor.constraint(equalTo: countsLabel.centerYAnchor),
                countsLabel.trailingAnchor.constraint(lessThanOrEqualTo: sort.leadingAnchor, constant: -10)
            ])
        } else if let funnelButton {
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

    /// Fork: the Episodes-tab funnel, matching the podcast page's — display filters
    /// as checkable rows, backed by the session's settings.
    func presentEpisodesFunnel() {
        let optionPicker = OptionsPicker(title: nil)

        // Per-state switches (they keep the sheet open): all on = everything shows;
        // switching one off hides that state. Grouped by axis, smart-rules style.
        let currentFilter = viewModel.episodesFilter
        for section in EpisodeStateFilter.sheetSections {
            if let title = section.title {
                optionPicker.addSectionTitle(title.localizedUppercase)
            }
            for option in section.options {
                let action = OptionAction(label: option.title, icon: nil, selected: currentFilter.enabled.contains(option)) { [weak self] in
                    self?.viewModel.toggleEpisodesFilter(option)
                }
                action.onOffAction = true
                optionPicker.addAction(action: action)
            }
        }

        optionPicker.present(from: self)
    }

    /// Fork: the Inbox tab's closing action buttons — pills matching the header's
    /// Play-as-Session button.
    private func inboxActionsFooter() -> UIView {
        if inboxActionsFooterHost == nil {
            let host = UIHostingController(rootView: AnyView(
                InboxActionsFooterView(
                    addAll: { [weak self] in self?.inboxAddAllTapped() },
                    markAllSeen: { [weak self] in self?.inboxMarkAllSeenTapped() }
                )
                .environmentObject(Theme.sharedTheme)
            ))
            host.view.backgroundColor = .clear
            addChild(host)
            host.didMove(toParent: self)
            inboxActionsFooterHost = host
        }
        return inboxActionsFooterHost!.view
    }

    private func inboxAddAllTapped() {
        viewModel.addToSessionsPerSetting(episodeUuids: viewModel.inboxEpisodes.map { $0.episode.uuid }, presenting: self)
    }

    private func inboxMarkAllSeenTapped() {
        EpisodeSeenManager.setSeen(true, episodes: viewModel.inboxEpisodes.map(\.episode))
        viewModel.reloadEpisodeList(animated: true)
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
