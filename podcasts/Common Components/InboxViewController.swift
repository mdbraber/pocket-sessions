import UIKit
import SwiftUI
import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils
import SwipeCellKit

/// Fork: the global Inbox tab — one triage stream of newly-arrived episodes. Tap opens
/// the episode card (never plays); swipes queue, shelve, keep, or archive. Decisive
/// actions anywhere in the app clear entries, so the list tends to zero by itself.
/// Episode search under the counts line, and a ⋯ options button mirroring the playlist
/// page's: Chromecast, multi-select, grouping (release-date buckets by default),
/// download all, archive all.
class InboxViewController: PCViewController, UITableViewDataSource, UITableViewDelegate, SwipeTableViewCellDelegate {
    private static let episodeCellId = "EpisodeCell"
    private static let groupByKey = "SJInboxGroupBy"
    private static let groupLimitKey = "SJInboxGroupLimit"

    private struct Group {
        let title: String?
        let episodes: [BaseEpisode]
    }

    private let table = ThemeableTable()
    private let countsLabel = ThemeableLabel()
    private var allEpisodes: [BaseEpisode] = []
    private var groups: [Group] = []
    private var searchTerm = ""
    private var searchController: PCSearchBarController?
    private var clearButton: UIBarButtonItem?
    private var ellipsisButton: UIBarButtonItem?
    private var clearFooterHost: UIHostingController<AnyView>?

    // MARK: - Multi-select state

    var selectedEpisodes = [BaseEpisode]() {
        didSet {
            multiSelectFooter.setSelectedCount(count: selectedEpisodes.count)
            updateSelectAllBtn()
        }
    }

    var multiSelectGestureInProgress = false
    var multiSelectActionInProgress = false
    var multiSelectFooter: MultiSelectFooterView!
    var multiSelectFooterBottomConstraint: NSLayoutConstraint!
    var multiSelectAllBarButton: UIBarButtonItem?

    var isMultiSelectEnabled = false {
        didSet {
            guard oldValue != isMultiSelectEnabled else { return }
            setEnclosingTabBarHidden(isMultiSelectEnabled, animated: false)
            table.beginUpdates()
            table.setEditing(isMultiSelectEnabled, animated: true)
            table.endUpdates()

            if isMultiSelectEnabled {
                multiSelectFooter.setSelectedCount(count: selectedEpisodes.count)
                multiSelectFooter.isHidden = false
                multiSelectFooterBottomConstraint.constant = Constants.effectiveFooterViewPadding
                table.contentInset.bottom = Constants.effectiveMiniPlayerOffset + 80
            } else {
                multiSelectFooter.isHidden = true
                selectedEpisodes.removeAll()
                table.contentInset.bottom = Constants.effectiveMiniPlayerOffset
            }
            updateMultiSelectNavBar()
            updateClearFooter()
            table.reloadData()
        }
    }

    private var groupBy: EpisodeGroupBy {
        get {
            guard UserDefaults.standard.object(forKey: Self.groupByKey) != nil else { return .releaseDate }
            return EpisodeGroupBy(rawValue: UserDefaults.standard.integer(forKey: Self.groupByKey)) ?? .releaseDate
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.groupByKey)
            reloadData()
        }
    }

    /// Episodes per group; 0 means no limit.
    private var groupLimit: Int {
        get { UserDefaults.standard.integer(forKey: Self.groupLimitKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.groupLimitKey)
            reloadData()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = L10n.inboxTitle
        view.backgroundColor = AppTheme.viewBackgroundColor()

        table.register(UINib(nibName: "EpisodeCell", bundle: nil), forCellReuseIdentifier: Self.episodeCellId)
        table.register(EmptyStateCell.self, forCellReuseIdentifier: EmptyStateCell.reuseIdentifier)
        table.dataSource = self
        table.delegate = self
        table.separatorStyle = .none
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 100
        table.sectionHeaderTopPadding = 0
        table.allowsMultipleSelectionDuringEditing = true
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)

        multiSelectFooter = MultiSelectFooterView(frame: .zero)
        multiSelectFooter.translatesAutoresizingMaskIntoConstraints = false
        multiSelectFooter.isHidden = true
        multiSelectFooter.delegate = self
        view.addSubview(multiSelectFooter)
        multiSelectFooterBottomConstraint = view.safeAreaLayoutGuide.bottomAnchor.constraint(equalTo: multiSelectFooter.bottomAnchor)

        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            multiSelectFooter.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8.0),
            multiSelectFooter.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8.0),
            multiSelectFooterBottomConstraint,
            multiSelectFooter.heightAnchor.constraint(equalToConstant: 64)
        ])

        // Opaque slab behind the nav chrome (Clear / Inbox / ⋯) so scrolled rows don't
        // show through it.
        // Same style as ThemeableTable's default so the slab is indistinguishable
        // from the list background.
        let chromeBackground = ThemeableView()
        chromeBackground.style = .primaryUi04
        chromeBackground.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(chromeBackground)
        NSLayoutConstraint.activate([
            chromeBackground.topAnchor.constraint(equalTo: view.topAnchor),
            chromeBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chromeBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chromeBackground.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        ])

        let clear = UIBarButtonItem(title: L10n.clear, style: .plain, target: self, action: #selector(clearTapped))
        clearButton = clear
        navigationItem.leftBarButtonItem = clear
        // PCViewController manages the right slot — setting rightBarButtonItem directly
        // gets clobbered.
        let ellipsis = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), style: .plain, target: self, action: #selector(optionsTapped))
        ellipsisButton = ellipsis
        customRightBtn = ellipsis

        countsLabel.style = .primaryText02
        countsLabel.font = UIFont.font(ofSize: 14, weight: .medium, scalingWith: .footnote)

        setupSearchHeader()
        setupClearFooter()

        // Fork: long-press toggles seen/unseen (a local attention mark).
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(rowLongPressed(_:)))
        table.addGestureRecognizer(longPress)

        NotificationCenter.default.addObserver(self, selector: #selector(reloadData), name: SessionStore.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reloadData), name: Constants.Notifications.episodeDownloadStatusChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reloadData), name: Constants.Notifications.episodePlayStatusChanged, object: nil)
        reloadData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadData()
    }

    /// Counts line + episode search, riding above the groups as the table's header.
    private func setupSearchHeader() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: table.bounds.width, height: PCSearchBarController.defaultHeight + 30))
        container.autoresizingMask = [.flexibleWidth]

        countsLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(countsLabel)

        let search = PCSearchBarController()
        search.searchDebounce = 0.2
        search.placeholderText = L10n.search
        search.searchDelegate = self
        addChild(search)
        container.addSubview(search.view)
        search.didMove(toParent: self)
        search.view.translatesAutoresizingMaskIntoConstraints = false
        searchController = search

        NSLayoutConstraint.activate([
            countsLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            countsLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),

            search.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            search.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            search.view.heightAnchor.constraint(equalToConstant: PCSearchBarController.defaultHeight),
            search.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        table.tableHeaderView = container
    }

    /// The Clear button under the list — the inbox pill every other inbox surface
    /// uses, offered once the reader reaches the bottom of the stream.
    private func setupClearFooter() {
        let host = UIHostingController(rootView: AnyView(
            InboxClearPill { [weak self] in self?.clearTapped() }
                .environmentObject(Theme.sharedTheme)
        ))
        host.view.backgroundColor = .clear
        addChild(host)
        host.didMove(toParent: self)
        clearFooterHost = host
    }

    private func updateClearFooter() {
        guard let footerView = clearFooterHost?.view else { return }
        if allEpisodes.isEmpty || isMultiSelectEnabled {
            table.tableFooterView = nil
        } else {
            let height = footerView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height
            footerView.frame = CGRect(x: 0, y: 0, width: table.bounds.width, height: max(height, 88))
            table.tableFooterView = footerView
        }
    }

    @objc private func reloadData() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let global = SessionStore.shared.globalInbox
            self.allEpisodes = SessionFeederEngine.inboxEpisodes(for: global)
                .filter { global.showSeen || !$0.isSeen }
            self.rebuildGroups()
            self.refreshMultiSelectEpisodes()
            self.navigationItem.leftBarButtonItem?.isEnabled = self.isMultiSelectEnabled || !self.allEpisodes.isEmpty
            self.updateCountsLabel()
            self.updateClearFooter()
            self.table.reloadData()
        }
    }

    private var visibleEpisodes: [BaseEpisode] {
        guard !searchTerm.isEmpty else { return allEpisodes }
        let term = searchTerm.lowercased()
        return allEpisodes.filter { episode in
            if episode.displayableTitle().lowercased().contains(term) { return true }
            if let episode = episode as? Episode, episode.parentPodcast()?.title?.lowercased().contains(term) == true { return true }
            return false
        }
    }

    private func rebuildGroups() {
        groups = EpisodeGrouper.group(visibleEpisodes, by: groupBy, limit: groupLimit) { $0 }
            .map { Group(title: $0.title, episodes: $0.items) }
        if groups.isEmpty {
            groups = [Group(title: nil, episodes: [])]
        }
    }

    private func updateCountsLabel() {
        let episodes = visibleEpisodes
        let totalDuration = episodes.reduce(0.0) { $0 + max(0, $1.duration - $1.playedUpTo) }
        let time = TimeFormatter.shared.multipleUnitFormattedShortTime(time: totalDuration)
        if episodes.isEmpty {
            countsLabel.text = nil
        } else if episodes.count == 1 {
            countsLabel.text = L10n.playlistDetailDescriptionOneEpisode(time)
        } else {
            countsLabel.text = L10n.playlistDetailDescription(episodes.count, time)
        }
    }

    private func episode(at indexPath: IndexPath) -> BaseEpisode? {
        groups[safe: indexPath.section]?.episodes[safe: indexPath.row]
    }

    @objc private func rowLongPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, !isMultiSelectEnabled,
              let indexPath = table.indexPathForRow(at: recognizer.location(in: table)),
              let episode = episode(at: indexPath) else { return }

        let optionsPicker = OptionsPicker(title: episode.displayableTitle().localizedUppercase)
        optionsPicker.addAction(action: OptionAction(label: episode.isSeen ? L10n.episodeMarkUnseen : L10n.episodeMarkSeen, icon: nil) {
            EpisodeSeenManager.toggleSeen(episode: episode)
        })
        optionsPicker.present(from: self)
    }

    // MARK: - Nav actions

    @objc private func clearTapped() {
        let optionsPicker = OptionsPicker(title: L10n.clear.localizedUppercase)

        // Mark All as Seen: the soft clear — synced attention marks, nothing else moves.
        optionsPicker.addAction(action: OptionAction(label: L10n.inboxClearKeepAll, icon: "eye.slash") { [weak self] in
            guard let self else { return }
            EpisodeSeenManager.setSeen(true, episodes: self.allEpisodes)
        })

        // Archive: archives every inbox episode (which also clears them).
        // Recoverable, so it reads as a normal action — not destructive red.
        optionsPicker.addAction(action: OptionAction(label: L10n.inboxClearArchiveAll, icon: "list_archive") { [weak self] in
            self?.archiveAllInboxEpisodes()
        })

        optionsPicker.present(from: self)
    }

    /// The ⋯ menu — same options as the playlist page's, minus what a self-clearing
    /// stream has no use for (sort orders, playlist settings).
    @objc private func optionsTapped() {
        let optionsPicker = OptionsPicker(title: nil)

        optionsPicker.addAction(action: OptionAction(label: "Chromecast", icon: "nav_cast_off") { [weak self] in
            self?.castButtonTapped()
        })

        let multiSelectAction = OptionAction(label: L10n.selectEpisodes, icon: "option-multiselect") { [weak self] in
            self?.isMultiSelectEnabled = true
        }
        optionsPicker.addAction(action: multiSelectAction)

        let groupAction = OptionAction(label: L10n.inboxGroupBy, secondaryLabel: groupBy.title, icon: "option-group") {}
        groupAction.submenu = { [weak self] in
            guard let self else { return nil }
            let picker = OptionsPicker(title: L10n.inboxGroupBy.localizedUppercase)
            for option in EpisodeGroupBy.menuOrder {
                picker.addAction(action: OptionAction(label: option.title, selected: self.groupBy == option) {
                    self.groupBy = option
                })
            }
            return picker
        }
        optionsPicker.addAction(action: groupAction)

        let limitAction = OptionAction(label: L10n.episodeGroupLimit, secondaryLabel: groupLimit > 0 ? "\(groupLimit)" : L10n.off, icon: "option-group") {}
        limitAction.submenu = { [weak self] in
            guard let self else { return nil }
            let picker = OptionsPicker(title: L10n.episodeGroupLimit.localizedUppercase)
            picker.addAction(action: OptionAction(label: L10n.off, selected: self.groupLimit == 0) {
                self.groupLimit = 0
            })
            for limit in EpisodeGrouper.limitOptions {
                picker.addAction(action: OptionAction(label: "\(limit)", selected: self.groupLimit == limit) {
                    self.groupLimit = limit
                })
            }
            return picker
        }
        optionsPicker.addAction(action: limitAction)

        let downloadAllAction = OptionAction(label: L10n.downloadAll, icon: "filter_downloaded") {}
        downloadAllAction.submenu = { [weak self] in self?.makeDownloadAllPicker() }
        optionsPicker.addAction(action: downloadAllAction)

        if visibleEpisodes.contains(where: { ($0 as? Episode)?.archived == false }) {
            optionsPicker.addAction(action: OptionAction(label: L10n.podcastArchiveAll, icon: "podcast-archiveall") { [weak self] in
                self?.archiveAllInboxEpisodes()
            })
        }

        optionsPicker.present(from: self)
    }

    private func archiveAllInboxEpisodes() {
        let episodes = allEpisodes.compactMap { $0 as? Episode }.filter { !$0.archived }
        DispatchQueue.global().async {
            // Archived episodes never match an inbox, so no dismissal bookkeeping needed.
            EpisodeManager.bulkArchive(episodes: episodes, updateSyncFlag: true)
        }
    }

    // MARK: - Download all

    private func makeDownloadAllPicker() -> OptionsPicker? {
        let downloadableCount = downloadableCount(episodes: visibleEpisodes)
        let downloadLimitExceeded = downloadableCount > Constants.Limits.maxBulkDownloads
        let actualDownloadCount = downloadLimitExceeded ? Constants.Limits.maxBulkDownloads : downloadableCount
        if actualDownloadCount == 0 { return nil }
        let downloadText = L10n.downloadCountPrompt(actualDownloadCount)
        let downloadAction = OptionAction(label: downloadText, icon: nil) { [weak self] in
            self?.downloadAll()
        }

        let confirmPicker = OptionsPicker(title: nil)
        var warningMessage = downloadLimitExceeded ? L10n.bulkDownloadMax : ""

        if NetworkUtils.shared.isConnectedToUnexpensiveConnection() {
            confirmPicker.addDescriptiveActions(title: L10n.downloadAll, message: warningMessage, icon: "filter_downloaded", actions: [downloadAction])
        } else {
            downloadAction.destructive = true

            let queueAction = OptionAction(label: L10n.queueForLater, icon: nil) { [weak self] in
                self?.queueAllForLater()
            }

            if !Settings.mobileDataAllowed() {
                warningMessage = L10n.downloadDataWarningWithSettingsLink("pktc://settings/storage-and-data") + "\n" + warningMessage
            }

            confirmPicker.addAttributedDescriptiveActions(title: L10n.notOnWifi, message: warningMessage, icon: "option-alert", actions: [downloadAction, queueAction])
        }
        return confirmPicker
    }

    private func downloadableCount(episodes: [BaseEpisode]) -> Int {
        episodes.filter { !$0.downloaded(pathFinder: DownloadManager.shared) && !$0.downloading() && !$0.queued() }.count
    }

    private func downloadAll() {
        bulkFetch(queueForLater: false)
    }

    private func queueAllForLater() {
        bulkFetch(queueForLater: true)
    }

    private func bulkFetch(queueForLater: Bool) {
        let episodes = visibleEpisodes
        DispatchQueue.global().async {
            var queuedEpisodes = 0
            for episode in episodes {
                if episode.downloading() || episode.downloaded(pathFinder: DownloadManager.shared) || episode.queued() {
                    continue
                }

                if queueForLater {
                    DownloadManager.shared.queueForLaterDownload(episodeUuid: episode.uuid, fireNotification: true, autoDownloadStatus: .notSpecified)
                } else {
                    DownloadManager.shared.addToQueue(episodeUuid: episode.uuid, fireNotification: true, autoDownloadStatus: .notSpecified)
                }

                queuedEpisodes += 1
                if queuedEpisodes == Constants.Limits.maxBulkDownloads {
                    return
                }
            }
        }
    }

    // MARK: - Table

    func numberOfSections(in tableView: UITableView) -> Int {
        groups.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let group = groups[section]
        if groups.count == 1, group.episodes.isEmpty { return 1 } // empty state
        return group.episodes.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let episode = episode(at: indexPath) else {
            let emptyCell = tableView.dequeueReusableCell(withIdentifier: EmptyStateCell.reuseIdentifier, for: indexPath) as! EmptyStateCell
            emptyCell.configure(title: searchTerm.isEmpty ? L10n.inboxEmptyTitle : L10n.discoverNoEpisodesFound,
                                message: searchTerm.isEmpty ? L10n.inboxEmptyMessage : L10n.discoverNoPodcastsFoundMsg,
                                icon: { Image(systemName: "tray") })
            return emptyCell
        }

        let cell = tableView.dequeueReusableCell(withIdentifier: Self.episodeCellId, for: indexPath) as! EpisodeCell
        cell.delegate = self
        cell.populateFrom(episode: episode, tintColor: nil)
        cell.shouldShowSelect = isMultiSelectEnabled
        if isMultiSelectEnabled {
            cell.showTick = selectedEpisodesContains(uuid: episode.uuid)
        }
        return cell
    }

    /// Group headers, same type treatment as the podcast page's Group By headings.
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let title = groups[safe: section]?.title else { return nil }
        let container = UIView()
        container.backgroundColor = AppTheme.colorForStyle(.primaryUi02)
        let label = UILabel()
        label.text = title
        label.font = UIFont.font(ofSize: 22, weight: .medium, scalingWith: .title2)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = AppTheme.colorForStyle(.primaryText01)
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])
        return container
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        groups[safe: section]?.title != nil ? 52 : .leastNormalMagnitude
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        episode(at: indexPath) != nil
    }

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        guard episode(at: indexPath) != nil else { return nil }
        guard tableView.isEditing, !multiSelectGestureInProgress else { return indexPath }
        if let episode = episode(at: indexPath), selectedEpisodesContains(uuid: episode.uuid) {
            tableView.delegate?.tableView?(tableView, didDeselectRowAt: indexPath)
            return nil
        }
        return indexPath
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let episode = episode(at: indexPath) else { return }

        if isMultiSelectEnabled {
            if !multiSelectGestureInProgress {
                // If the episode is already selected move it to the end of the array.
                selectedEpisodesRemove(uuid: episode.uuid)
            }
            if !multiSelectGestureInProgress || !selectedEpisodesContains(uuid: episode.uuid) {
                selectedEpisodes.append(episode)
                if let cell = tableView.cellForRow(at: indexPath) as? EpisodeCell {
                    cell.showTick = true
                }
            }
            return
        }

        tableView.deselectRow(at: indexPath, animated: true)
        // Pure triage: a tap never starts playback — it opens the episode card.
        if let episode = episode as? Episode, let parentPodcast = episode.parentPodcast() {
            let episodeController = EpisodeDetailViewController(episode: episode, podcast: parentPodcast, source: .upNext)
            episodeController.modalPresentationStyle = .formSheet
            present(episodeController, animated: true)
        }
    }

    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        guard isMultiSelectEnabled, let episode = episode(at: indexPath) else { return }
        selectedEpisodesRemove(uuid: episode.uuid)
        if let cell = tableView.cellForRow(at: indexPath) as? EpisodeCell {
            cell.showTick = false
        }
    }

    func tableView(_ tableView: UITableView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
        guard episode(at: indexPath) != nil else { return false }
        return Settings.multiSelectGestureEnabled()
    }

    func tableView(_ tableView: UITableView, didBeginMultipleSelectionInteractionAt indexPath: IndexPath) {
        guard episode(at: indexPath) != nil else { return }
        isMultiSelectEnabled = true
        multiSelectGestureInProgress = true
    }

    func tableViewDidEndMultipleSelectionInteraction(_ tableView: UITableView) {
        multiSelectGestureInProgress = false
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        episode(at: indexPath) == nil ? UpNextViewController.emptyStateRowHeight : UITableView.automaticDimension
    }

    // MARK: - Swipes

    func tableView(_ tableView: UITableView, editActionsForRowAt indexPath: IndexPath, for orientation: SwipeActionsOrientation) -> [SwipeAction]? {
        guard !isMultiSelectEnabled, let episode = episode(at: indexPath) else { return nil }

        switch orientation {
        case .left:
            return TriageSwipes.leftActions(for: episode) { [weak self] in
                guard let self, let episode = episode as? Episode else { return }
                SessionManager.shared.addToSessions(episodeUuids: [episode.uuid], preferred: nil, presenting: self) { landed in
                    guard !landed.isEmpty else { return }
                    // Lineup membership hides it from every inbox — no dismissal, so a
                    // later remove-from-lineup returns it to triage.
                    let names = landed.compactMap { SessionManager.shared.store(for: $0)?.playlistName }
                    Toast.show(L10n.inboxShelvedToast(names.joined(separator: ", ")))
                }
            }
        case .right:
            return TriageSwipes.rightActions(for: episode) { [weak self] in
                self?.reloadData()
            }
        }
    }

    func tableView(_ tableView: UITableView, editActionsOptionsForRowAt indexPath: IndexPath, for orientation: SwipeActionsOrientation) -> SwipeOptions {
        var options = SwipeOptions()
        options.expansionStyle = orientation == .left ? .selection : .none
        return options
    }
}

// MARK: - Multi-select

extension InboxViewController: MultiSelectActionDelegate {
    func multiSelectPresentingViewController() -> UIViewController {
        self
    }

    func multiSelectedBaseEpisodes() -> [BaseEpisode] {
        selectedEpisodes
    }

    func multiSelectedPlayListEpisodes() -> [PlaylistEpisode]? {
        nil
    }

    func multiSelectActionBegan(status: String) {
        multiSelectActionInProgress = true
        multiSelectFooter.setStatus(status: status)
    }

    func multiSelectActionCompleted() {
        view.layoutIfNeeded()
        UIView.animate(withDuration: Constants.Animation.defaultAnimationTime, animations: {
            self.multiSelectFooterBottomConstraint.constant = 0
            self.view.layoutIfNeeded()
        }, completion: { _ in
            self.multiSelectActionInProgress = false
            self.isMultiSelectEnabled = false
        })
    }

    var multiSelectViewSource: AnalyticsSource {
        .unknown
    }

    func selectedEpisodesContains(uuid: String) -> Bool {
        selectedEpisodes.contains { $0.uuid == uuid }
    }

    func selectedEpisodesRemove(uuid: String) {
        if let index = selectedEpisodes.firstIndex(where: { $0.uuid == uuid }) {
            selectedEpisodes.remove(at: index)
        }
    }

    private func updateMultiSelectNavBar() {
        if isMultiSelectEnabled {
            let cancel = UIBarButtonItem(title: L10n.cancel, style: .plain, target: self, action: #selector(cancelTapped))
            cancel.accessibilityLabel = L10n.accessibilityCancelMultiselect
            customRightBtn = cancel

            let selectAll = UIBarButtonItem(title: L10n.selectAll, style: .plain, target: self, action: #selector(selectAllTapped))
            multiSelectAllBarButton = selectAll
            navigationItem.setLeftBarButton(selectAll, animated: true)
            updateSelectAllBtn()
        } else {
            multiSelectAllBarButton = nil
            customRightBtn = ellipsisButton
            navigationItem.setLeftBarButton(clearButton, animated: false)
        }
    }

    func updateSelectAllBtn() {
        guard isMultiSelectEnabled, let multiSelectAllBarButton else { return }
        multiSelectAllBarButton.title = MultiSelectHelper.shouldSelectAll(onCount: selectedEpisodes.count, totalCount: visibleEpisodes.count) ? L10n.selectAll : L10n.deselectAll
    }

    @objc private func selectAllTapped() {
        if MultiSelectHelper.shouldSelectAll(onCount: selectedEpisodes.count, totalCount: visibleEpisodes.count) {
            table.selectAll()
        } else {
            table.deselectAll()
        }
        updateSelectAllBtn()
    }

    @objc private func cancelTapped() {
        isMultiSelectEnabled = false
    }

    /// Drops selections that fell out of the inbox behind our back.
    private func refreshMultiSelectEpisodes() {
        guard isMultiSelectEnabled, !multiSelectActionInProgress else { return }
        let currentUuids = Set(allEpisodes.map(\.uuid))
        selectedEpisodes = selectedEpisodes.filter { currentUuids.contains($0.uuid) }
    }
}

// MARK: - Search

extension InboxViewController: PCSearchBarDelegate {
    func searchDidBegin() {}

    func searchDidEnd() {
        searchTerm = ""
        reloadData()
    }

    func searchWasCleared() {
        searchTerm = ""
        reloadData()
    }

    func searchTermChanged(_ searchTerm: String) {}

    func performSearch(searchTerm: String, triggeredByTimer: Bool, completion: @escaping (() -> Void)) {
        self.searchTerm = searchTerm
        reloadData()
        completion()
    }
}

/// The global Inbox's Clear pill — outlined, theme-reactive, in the shared inbox
/// pill shape.
private struct InboxClearPill: View {
    @EnvironmentObject var theme: Theme
    let action: () -> Void

    var body: some View {
        InboxPillButton(
            icon: Image(systemName: "eye.slash"),
            title: L10n.clear,
            color: theme.primaryUi01,
            background: theme.primaryInteractive01,
            stroke: nil,
            action: action
        )
        .padding(16)
    }
}
