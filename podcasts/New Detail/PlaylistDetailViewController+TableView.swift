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

        case .inbox, .episodes:
            guard let itemAtRow = viewModel.dataSource[safe: indexPath.section]?.elements[safe: indexPath.row] as? ListItem else {
                FileLog.shared.addMessage("Playlist Detail tableView: missing ListItem in section \(indexPath.section), row \(indexPath.row)")
                return UITableViewCell()
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

        if let title {
            // The New section header carries a one-tap bulk triage on its trailing edge.
            var trailingAction: (title: String, handler: () -> Void)?
            if model == .inbox {
                trailingAction = (L10n.playlistAddAllToLineup, { [weak self] in
                    guard let self else { return }
                    self.viewModel.addToLineup(episodeUuids: self.viewModel.inboxEpisodes.map { $0.episode.uuid })
                })
            }
            return overlaySectionHeader(title: title, includingSearch: showsSearch, trailingAction: trailingAction)
        }
        if showsSearch {
            // The composite overlay header pins the search bar with autolayout; restore
            // frame-based sizing when it's returned as a plain section header again.
            searchHeaderView.removeFromSuperview()
            searchHeaderView.translatesAutoresizingMaskIntoConstraints = true
            return searchHeaderView
        }
        return nil
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        let model = sectionModel(at: section)
        let titleHeight: CGFloat = overlayHeaderTitle(for: model) != nil ? Self.overlayHeaderTitleHeight : 0
        let searchHeight: CGFloat = model == searchHeaderSection ? PCSearchBarController.defaultHeight : 0
        let total = titleHeight + searchHeight
        return total > 0 ? total : 0
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        return .leastNormalMagnitude
    }

    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        return UIView()
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
        !isMultiSelectEnabled && !viewModel.isSearching && viewModel.playlist.sortType == PlaylistSort.dragAndDrop.rawValue
    }

    func tableView(_ tableView: UITableView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        // Lineup rows reorder; inbox (New) rows drag INTO the lineup as triage-by-drag.
        // Drops are constrained to the lineup either way.
        guard canReorderInline, isEpisodeSection(at: indexPath.section),
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

private extension PlaylistDetailViewController {
    static let overlayHeaderTitleHeight: CGFloat = 30

    func sectionModel(at index: Int) -> PlaylistDetailViewModel.Section? {
        viewModel.dataSource[safe: index]?.model
    }

    func isEpisodeSection(at index: Int) -> Bool {
        let model = sectionModel(at: index)
        return model == .episodes || model == .inbox
    }

    var searchHeaderSection: PlaylistDetailViewModel.Section {
        if viewModel.isManualPlaylist { return .archive }
        // Fork: with the overlay's New section present, the search bar anchors above it.
        return viewModel.hasInboxSection ? .inbox : .episodes
    }

    /// Fork: New/Lineup section titles when the custom-order overlay is active.
    func overlayHeaderTitle(for model: PlaylistDetailViewModel.Section?) -> String? {
        guard viewModel.usesCustomOrderOverlay, !viewModel.isSearching else { return nil }
        switch model {
        case .inbox:
            return L10n.playlistInboxSectionHeader(viewModel.inboxEpisodes.count.localized())
        case .episodes:
            return L10n.playlistLineupSectionHeader
        default:
            return nil
        }
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
                searchHeaderView.heightAnchor.constraint(equalToConstant: PCSearchBarController.defaultHeight)
            ])
        }

        NSLayoutConstraint.activate(constraints)
        return container
    }
}

/// Fork: the insert-marker row — a thin accent line with a label showing where
/// "Add to lineup" places episodes.
class PlaylistInsertMarkerCell: ThemeableCell {
    static let reuseIdentifier = "PlaylistInsertMarkerCell"
    static let height: CGFloat = 28

    private let line = UIView()
    private let label = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        line.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.text = L10n.playlistInsertMarkerTitle.localizedUppercase

        contentView.addSubview(line)
        contentView.addSubview(label)

        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            line.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            line.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 1.5),

            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])

        updateMarkerColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func handleThemeDidChange() {
        updateMarkerColors()
    }

    private func updateMarkerColors() {
        let accent = ThemeColor.primaryInteractive01()
        line.backgroundColor = accent.withAlphaComponent(0.5)
        label.textColor = accent
        label.backgroundColor = ThemeColor.primaryUi02()
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
