import SwiftUI
import DifferenceKit
import UIKit
import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils
import Combine

class PlaylistsViewController: PCViewController, FilterCreatedDelegate {

    private let playlistMetadataLoader = PlaylistMetadataLoader.shared
    private let cacheInvalidationCoordinator = PlaylistCacheInvalidationCoordinator.shared

    private var staleCancellable: AnyCancellable?
    @IBOutlet var filtersTable: ThemeableTable! {
        didSet {
            registerCells()
            filtersTable.themeStyle = .primaryUi02
            filtersTable.dragDelegate = self
            filtersTable.dropDelegate = self
            filtersTable.separatorStyle = .none
            filtersTable.sectionFooterHeight = UITableView.automaticDimension
            filtersTable.estimatedSectionFooterHeight = UITableView.automaticDimension
        }
    }

    var listPlaylistItems: [ListPlaylist] = [] {
        didSet {
            DispatchQueue.main.async { [weak self] in
                self?.refreshContentUnavailable()
            }
        }
    }

    var sourceIndexPath: IndexPath?
    var snapshot: UIView?
    var previouslyDisplayedDetail = false
    var presentingPlaylistDetail: Bool = false

    private let debounce = Debounce(delay: Constants.defaultDebounceTime)

    @IBOutlet var footerView: ThemeableView! {
        didSet {
            footerView.style = .primaryUi04
        }
    }

    @IBOutlet var newFilterButton: UIButton! {
        didSet {
            newFilterButton.isHidden = true
            newFilterButton.setTitle(L10n.filtersNewFilterButton, for: .normal)
        }
    }

    private var loadingIndicator: ThemeLoadingIndicator! {
        didSet {
            view.addSubview(loadingIndicator)
            loadingIndicator.center = view.center
        }
    }

    var newFilterTip: UIViewController? = nil

    // Fork: podcast-page style sort and layout for the playlists overview.
    private static let sortOrderKey = "SJPlaylistsSortOrder" // LibrarySort raw (custom or titleAtoZ)
    private static let layoutKey = "SJPlaylistsLibraryType" // LibraryType raw

    private var playlistsSortOrder: LibrarySort {
        get { LibrarySort(rawValue: Int32(UserDefaults.standard.integer(forKey: Self.sortOrderKey))) ?? .custom }
        set {
            UserDefaults.standard.set(Int(newValue.rawValue), forKey: Self.sortOrderKey)
            reloadFilters()
        }
    }

    private var playlistsLayout: LibraryType {
        get {
            guard UserDefaults.standard.object(forKey: Self.layoutKey) != nil else { return .list }
            return LibraryType(rawValue: Int32(UserDefaults.standard.integer(forKey: Self.layoutKey))) ?? .list
        }
        set {
            UserDefaults.standard.set(Int(newValue.rawValue), forKey: Self.layoutKey)
            applyLayout()
        }
    }

    private var gridHost: UIHostingController<AnyView>?

    private var firstTimeLoading = true

    lazy var informationalBannerCoordinator: InformationalBannerViewCoordinator = {
        let invertedColor: Bool? = true
        let bannerType: InformationalBannerType = .playlists
        let viewModel = InformationalBannerViewModel(bannerType: bannerType, invertedColor: invertedColor)
        return InformationalBannerViewCoordinator(viewModel: viewModel)
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        // Fork: podcast-page arrangement — creation on the left, options on the right.
        let addButton = UIBarButtonItem(image: UIImage(named: "playlist_add_icon"), style: .plain, target: self, action: #selector(addNewFilter))
        addButton.accessibilityLabel = L10n.playlistsDefaultNewPlaylist
        if !LiquidGlass.isEnabled {
            addButton.tintColor = ThemeColor.secondaryIcon01()
        }
        navigationItem.leftBarButtonItem = addButton

        customRightBtn = UIBarButtonItem(image: UIImage(named: "more"), style: .plain, target: self, action: #selector(playlistOptionsTapped))
        customRightBtn?.accessibilityLabel = L10n.accessibilityMoreActions

        title = L10n.playlists

        if !previouslyDisplayedDetail {
            autoPushPlaylist()
        }

        loadingIndicator = ThemeLoadingIndicator()
        insetAdjuster.setupInsetAdjustmentsForMiniPlayer(scrollView: filtersTable)
        handleThemeChanged()

        // Start cache invalidation coordinator and subscribe to stale updates
        if FeatureFlag.playlistCacheInvalidation.enabled {
            cacheInvalidationCoordinator.startObserving()
            subscribeToStaleUpdates()
        }
    }

    func autoPushPlaylist() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            if let lastFilterUuid = UserDefaults.standard.string(forKey: Constants.UserDefaults.lastFilterShown), let filter = DataManager.sharedManager.findPlaylist(uuid: lastFilterUuid) {
                DispatchQueue.main.async {
                    self.showFilter(filter)
                }
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        // Invalidate stale playlist metadata cache (>30s) to ensure fresh data on screen entry.
        // This is lightweight and won't block - just clears dictionaries if threshold exceeded.
        if !FeatureFlag.playlistCacheInvalidation.enabled {
            Task {
                await playlistMetadataLoader.invalidateCacheIfStale()
            }
        }

        reloadFilters()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateNavTintColors()
        addCustomObserver(Constants.Notifications.playlistChanged, selector: #selector(filtersUpdated))
        addCustomObserver(PlaylistFolderManager.foldersChanged, selector: #selector(filtersUpdated))
        addCustomObserver(Constants.Notifications.tappedOnSelectedTab, selector: #selector(checkForScrollTap(_:)))
        // Fork: row badges follow triage/play state; skipped entirely when off.
        addCustomObserver(SessionStore.changed, selector: #selector(badgeStateChanged))
        addCustomObserver(Constants.Notifications.episodePlayStatusChanged, selector: #selector(badgeStateChanged))
        addCustomObserver(Constants.Notifications.episodeArchiveStatusChanged, selector: #selector(badgeStateChanged))
        addCustomObserver(Constants.Notifications.upNextQueueChanged, selector: #selector(badgeStateChanged))

        Analytics.track(.filterListShown, properties: ["filter_count": listPlaylistItems.count])

        showPlaylistsTipIfNeeded()
        showOnboardingScreenIfNeeded()

        UserDefaults.standard.set(nil, forKey: Constants.UserDefaults.lastFilterShown)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        removeAllCustomObservers()
        navigationController?.navigationBar.shadowImage = nil
    }

    @objc private func checkForScrollTap(_ notification: Notification) {
        let topOffset = view.safeAreaInsets.top
        if let index = notification.object as? Int, index == tabBarItem.tag, filtersTable.contentOffset.y > -topOffset {
            filtersTable.setContentOffset(CGPoint(x: 0, y: -topOffset), animated: true)
        }
    }

    @objc private func filtersUpdated() {
        if !firstTimeLoading {
            debounce.call { [weak self] in
                self?.reloadFilters()
            }
        } else {
            reloadFilters()
        }
    }

    /// Only rows wearing a badge care about triage/play state. Counts change
    /// without row changes, so the diff reload alone would leave cells stale.
    @objc private func badgeStateChanged() {
        guard Settings.playlistsBadgeType() != .off else { return }
        debounce.call { [weak self] in
            self?.filtersTable.reloadData()
            self?.reloadFilters()
        }
    }

    @IBAction func addNewFilter() {
        Analytics.track(.filterCreateButtonTapped)
        presentFilterPreview()
    }

    /// Fork: the podcast page's ⋯ options, where they apply to playlists.
    @objc private func playlistOptionsTapped() {
        let optionsPicker = OptionsPicker(title: nil)

        // Fork: which session playlists appear here (Manual / Smart / per-folder-or-podcast sessions).
        optionsPicker.addAction(action: OptionAction(label: L10n.sessionPlaylistsShow, icon: "option-multiselect") { [weak self] in
            DispatchQueue.main.async {
                let settings = SessionPlaylistsSettingsViewController { [weak self] in self?.reloadFilters() }
                self?.navigationController?.pushViewController(settings, animated: true)
            }
        })

        let sortAction = OptionAction(label: L10n.sortBy, secondaryLabel: playlistsSortOrder.description, icon: "podcast-sort") {}
        sortAction.submenu = { [weak self] in self?.makeSortOptionsPicker() }
        optionsPicker.addAction(action: sortAction)

        // Fork: row badges, same option set as the podcast grid's. A badge replaces
        // the row's plain episode count.
        if FeatureFlag.libraryBadges.enabled {
            let badgeAction = OptionAction(label: L10n.podcastsBadges, secondaryLabel: Settings.playlistsBadgeType().description, icon: "badges") {}
            badgeAction.submenu = { [weak self] in self?.makeBadgeOptionsPicker() }
            optionsPicker.addAction(action: badgeAction)
        }

        let largeGridAction = OptionAction(label: L10n.podcastsLargeGrid, icon: "podcastlist_largegrid", selected: playlistsLayout == .threeByThree) { [weak self] in
            self?.playlistsLayout = .threeByThree
        }
        let smallGridAction = OptionAction(label: L10n.podcastsSmallGrid, icon: "podcastlist_smallgrid", selected: playlistsLayout == .fourByFour) { [weak self] in
            self?.playlistsLayout = .fourByFour
        }
        let listAction = OptionAction(label: L10n.podcastsList, icon: "podcastlist_listview", selected: playlistsLayout == .list) { [weak self] in
            self?.playlistsLayout = .list
        }
        optionsPicker.addSegmentedAction(name: L10n.podcastsLayout, icon: "podcastlist_largegrid", actions: [largeGridAction, smallGridAction, listAction])

        if FeatureFlag.playlistFolders.enabled {
            optionsPicker.addAction(action: OptionAction(label: L10n.folderCreateNew, icon: "folder-create") { [weak self] in
                self?.presentNewPlaylistFolder()
            })
        }

        // Reordering needs the list layout and the custom order to mean anything.
        if playlistsLayout == .list, playlistsSortOrder == .custom {
            let editAction = OptionAction(label: L10n.playlistsEditPlaylists, icon: "filter_manual_episode_order") { [weak self] in
                self?.setReorderMode(true)
            }
            optionsPicker.addAction(action: editAction)
        }

        optionsPicker.present(from: self)
    }

    private func makeBadgeOptionsPicker() -> OptionsPicker {
        let options = OptionsPicker(title: L10n.podcastsBadges.localizedUppercase)
        let current = Settings.playlistsBadgeType()
        let orderedTypes: [BadgeType] = [.off, .allUnplayed, .latestEpisode, .anyInInbox, .inboxCount, .sessionCount]
        for type in orderedTypes {
            options.addAction(action: OptionAction(label: type.description, selected: current == type) { [weak self] in
                Settings.setPlaylistsBadgeType(type)
                // The row set is unchanged, so the diff reload won't reconfigure
                // cells — force it so the new badge type renders immediately.
                self?.filtersTable.reloadData()
                self?.reloadFilters()
            })
        }
        return options
    }

    private func makeSortOptionsPicker() -> OptionsPicker {
        let options = OptionsPicker(title: L10n.sortBy.localizedUppercase)
        for order in [LibrarySort.custom, .titleAtoZ] {
            options.addAction(action: OptionAction(label: order.description, selected: playlistsSortOrder == order) { [weak self] in
                self?.playlistsSortOrder = order
            })
        }
        return options
    }

    /// Fork: grid layouts render in a hosted SwiftUI grid over the table.
    private func applyLayout() {
        refreshGrid()
        filtersTable.isHidden = playlistsLayout != .list && !listPlaylistItems.isEmpty
        gridHost?.view.isHidden = playlistsLayout == .list || listPlaylistItems.isEmpty
    }

    private func refreshGrid() {
        if gridHost == nil {
            let host = UIHostingController(rootView: AnyView(EmptyView()))
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            addChild(host)
            view.addSubview(host.view)
            host.didMove(toParent: self)
            NSLayoutConstraint.activate([
                host.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            gridHost = host
        }

        var folders = FeatureFlag.playlistFolders.enabled ? PlaylistFolderManager.shared.allFolders() : []
        let feederUuids = SessionStore.shared.feederPlaylistUuids
        var playlists = DataManager.sharedManager.allPlaylists(includeDeleted: false)
            .filter { PlaylistFolderManager.shared.folderUuid(forPlaylist: $0.uuid) == nil && !feederUuids.contains($0.uuid) }
            .filter { SessionManager.shared.sessionStoreVisible(playlistUuid: $0.uuid) }
        if playlistsSortOrder == .titleAtoZ {
            folders.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            playlists.sort { $0.playlistName.localizedCaseInsensitiveCompare($1.playlistName) == .orderedAscending }
        }

        let grid = PlaylistsGridView(
            columns: playlistsLayout == .fourByFour ? 4 : 3,
            onFolderTapped: { [weak self] folder in
                self?.navigationController?.pushViewController(PlaylistFolderViewController(folderUuid: folder.uuid), animated: true)
            },
            onPlaylistTapped: { [weak self] playlist in
                self?.showFilter(playlist)
            },
            folders: folders,
            playlists: playlists
        )
        gridHost?.rootView = AnyView(grid.environmentObject(Theme.sharedTheme))
        gridHost?.view.isHidden = playlistsLayout == .list || listPlaylistItems.isEmpty
        filtersTable.isHidden = playlistsLayout != .list && !listPlaylistItems.isEmpty
    }

    /// Reorder mode, like the podcast page's Edit: drag handles plus a Done button.
    private func setReorderMode(_ editing: Bool) {
        filtersTable.setEditing(editing, animated: true)
        if editing {
            customRightBtn = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(reorderDoneTapped))
        } else {
            customRightBtn = UIBarButtonItem(image: UIImage(named: "more"), style: .plain, target: self, action: #selector(playlistOptionsTapped))
            customRightBtn?.accessibilityLabel = L10n.accessibilityMoreActions
        }
    }

    @objc private func reorderDoneTapped() {
        setReorderMode(false)
    }

    private func presentNewPlaylistFolder() {
        let createView = CreatePlaylistFolderView { [weak self] in
            self?.dismiss(animated: true)
        }
        let host = PCHostingController(rootView: createView.environmentObject(Theme.sharedTheme))
        present(host, animated: true)
    }

    private func presentFilterPreview() {
        let createPlaylistVC = NewPlaylistViewController()
        createPlaylistVC.delegate = self
        let navVC = SJUIUtils.navController(for: createPlaylistVC)
        present(navVC, animated: true, completion: nil)
    }

    override func handleThemeChanged() {
        filtersTable.reloadData()
        updateNavTintColors()
        newFilterButton.layer.borderColor = ThemeColor.primaryInteractive01().cgColor
        newFilterButton.titleLabel?.textColor = ThemeColor.primaryInteractive01()
        view.backgroundColor = ThemeColor.primaryUi04()
        if !LiquidGlass.isEnabled {
            customRightBtn?.tintColor = ThemeColor.secondaryIcon01()
        }
    }

    private func updateNavTintColors() {
        changeNavTint(titleColor: AppTheme.navBarTitleColor(), iconsColor: AppTheme.navBarIconsColor())
    }

    func showFilter(_ filter: EpisodeFilter) {
        previouslyDisplayedDetail = true
        presentingPlaylistDetail = true

        let viewController = PlaylistDetailViewController(playlist: filter, delegate: self)
        navigationController?.popToRootViewController(animated: false)
        navigationController?.pushViewController(viewController, animated: true)

        UserDefaults.standard.set(filter.uuid, forKey: Constants.UserDefaults.lastFilterShown)
    }

    private func reloadFilters() {
        if firstTimeLoading {
            loadingIndicator.startAnimating()
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // Fork: Playlist Folders lead the list; playlists inside a folder show on
            // the folder's own page instead of the top level.
            var folderRows: [ListPlaylist] = FeatureFlag.playlistFolders.enabled
                ? PlaylistFolderManager.shared.allFolders().map { folder in
                    ListPlaylistFolder(folder: folder, count: PlaylistFolderManager.shared.playlistUuids(inFolder: folder.uuid).count)
                }
                : []
            let feederUuids = SessionStore.shared.feederPlaylistUuids
            var playlistRows = DataManager.sharedManager.allPlaylists(includeDeleted: false)
                .filter { PlaylistFolderManager.shared.folderUuid(forPlaylist: $0.uuid) == nil && !feederUuids.contains($0.uuid) }
                .filter { SessionManager.shared.sessionStoreVisible(playlistUuid: $0.uuid) }
                .map { ListPlaylist(playlist: $0) }
            if self.playlistsSortOrder == .titleAtoZ {
                folderRows.sort { ($0 as? ListPlaylistFolder)?.folder.name.localizedCaseInsensitiveCompare(($1 as? ListPlaylistFolder)?.folder.name ?? "") == .orderedAscending }
                playlistRows.sort { $0.playlist.playlistName.localizedCaseInsensitiveCompare($1.playlist.playlistName) == .orderedAscending }
            }
            let newData = folderRows + playlistRows

            DispatchQueue.main.async {
                self.refreshGrid()
            }

            let oldData = self.listPlaylistItems
            let isFirstLoad = self.firstTimeLoading

            if oldData.isContentEqual(to: newData) {
                DispatchQueue.main.async {
                    self.newFilterButton.isHidden = false
                    self.loadingIndicator.stopAnimating()
                    self.firstTimeLoading = false
                }
                return
            }

            DispatchQueue.main.async {
                self.newFilterButton.isHidden = false
                self.loadingIndicator.stopAnimating()

                if isFirstLoad {
                    self.listPlaylistItems = newData
                    self.filtersTable.reloadData()
                    self.firstTimeLoading = false
                } else {
                    let changeSet = StagedChangeset(source: oldData, target: newData)
                    do {
                        try SJCommonUtils.catchException { [weak self] in
                            self?.filtersTable.reload(using: changeSet, with: .fade) { [weak self] newData in
                                self?.listPlaylistItems = newData
                            }
                        }
                    } catch {
                        if let data = changeSet.last?.data {
                            self.listPlaylistItems = data
                        }
                        self.filtersTable.reloadData()
                    }
                }
            }
        }
    }

    private func showOnboardingScreenIfNeeded() {
        let userIsLoggedIn = SyncManager.isUserLoggedIn()
        let appInstallStateUpdated = (UIApplication.shared.delegate as? AppDelegate)?.appInstallState == .updated
        let shouldDisplayOnboarding = appInstallStateUpdated && Settings.shouldShowPlaylistsOnboarding && userIsLoggedIn
        guard shouldDisplayOnboarding else { return }
        let vc = ThemedHostingController(
            rootView: PlaylistsOnboardingView(
                onClose: { [weak self] in
                    self?.dismiss(animated: true)
                }
            )
        )
        present(vc, animated: true)
    }

    private func refreshContentUnavailable() {
        customRightBtn?.isHidden = listPlaylistItems.isEmpty
        navigationItem.leftBarButtonItem?.isHidden = listPlaylistItems.isEmpty

        var config: UIContentConfiguration?

        if listPlaylistItems.isEmpty {
            // Empty State when playlists is empty
            let title = L10n.playlistsEmptyStateTitle
            let message = L10n.playlistsEmptyStateDescription
            config = ContentUnavailableConfiguration.emptyState(
                title: title,
                message: message,
                icon: {
                    Image("filter_list")
                },
                actions: [
                .init(
                    title: L10n.playlistsDefaultNewPlaylist,
                    action: { [weak self] in
                    self?.addNewFilter()
                    }
                )
                ])
        }
        set(configuration: config)
    }

    private func set(configuration: UIContentConfiguration?) {
        self.contentUnavailableConfiguration = configuration
    }

    // MARK: - Stale Cache Handling

    private func subscribeToStaleUpdates() {
        staleCancellable = playlistMetadataLoader.stalePlaylistsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] stalePlaylistIDs in
                self?.refreshStaleCells(playlistIDs: stalePlaylistIDs)
            }
    }

    /// Refreshes visible cells for playlists that have become stale.
    /// Only triggers reload for cells that are currently visible.
    private func refreshStaleCells(playlistIDs: Set<String>) {
        guard !playlistIDs.isEmpty else { return }

        // Get visible cells and their index paths
        guard let visibleIndexPaths = filtersTable.indexPathsForVisibleRows else { return }

        var indexPathsToRefresh: [IndexPath] = []

        for indexPath in visibleIndexPaths {
            guard indexPath.row < listPlaylistItems.count else { continue }
            let playlist = listPlaylistItems[indexPath.row]
            if playlistIDs.contains(playlist.playlist.uuid) {
                indexPathsToRefresh.append(indexPath)
            }
        }

        // Reload only the affected visible cells
        if !indexPathsToRefresh.isEmpty {
            filtersTable.reloadRows(at: indexPathsToRefresh, with: .none)
        }
    }

    // MARK: - FilterCreationDelegate

    func filterCreated(newFilter: EpisodeFilter) {
        showFilter(newFilter)
    }
}
