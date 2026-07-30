import Combine
import DifferenceKit
import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils
import UIKit
import UIDeviceIdentifier
import SwiftUI
import SafariServices

enum PodcastFeedReloadSource {
    case menu
    case refreshControl

    var analyticsValue: String {
        switch self {
        case .menu:
            return "refresh_button"
        case .refreshControl:
            return "pull_to_refresh"
        }
    }
}

protocol PodcastActionsDelegate: AnyObject {
    var hasSimilarShowsPublisher: AnyPublisher<Bool, Never> { get }
    var currentViewModePublisher: AnyPublisher<PodcastViewController.ViewMode, Never> { get }
    func isSummaryExpanded() -> Bool
    func setSummaryExpanded(expanded: Bool)
    func isDescriptionExpanded() -> Bool
    func setDescriptionExpanded(expanded: Bool)

    func tableView() -> UITableView
    func displayedPodcast() -> Podcast?
    func episodeCount() -> Int
    func archivedEpisodeCount() -> Int
    func unseenEpisodeCount() -> Int

    func manageSubscriptionTapped()
    func settingsTapped()
    func fundingTapped()
    func folderTapped()
    func notificationTapped()
    func categoryTapped(_ category: String)
    func subscribe()
    func unsubscribe()
    func refreshArtwork()
    func searchEpisodes(query: String)
    func clearSearch()
    func toggleShowArchived()
    func episodesDidChange()
    func showingArchived() -> Bool
    func archiveAllTapped(playedOnly: Bool)
    func unarchiveAllTapped()
    func downloadAllTapped()
    func queueAllTapped()
    func downloadableEpisodeCount(items: [ListItem]?) -> Int

    func didActivateSearch()

    func enableMultiSelect()

    var podcastRatingViewModel: PodcastRatingViewModel { get }
    var ratingView: UIView { get }

    func showBookmarks()
    func showEpisodes()
    func showSession()
    func isShowingSession() -> Bool

    /// Fork: the Session lineup's two reorder affordances — drag grips, and a one-shot
    /// re-arrangement of the saved order.
    func enterLineupReorderMode()
    func reorderSessionLineup(order: EpisodeOrder)
    func showYouMightLike()
    func showLogin(message: String?)

    func shouldDisplayPodcastFeedReloadButton() -> Bool
    func reloadPodcastFeed(source: PodcastFeedReloadSource)

    func open(url: URL)
}

class PodcastViewController: PCViewController, PodcastActionsDelegate, SyncSigninDelegate, MultiSelectActionDelegate {
    var podcast: Podcast?
    var episodeInfo = [ArraySection<String, ListItem>]()
    var uuidsThatMatchSearch = [String]()
    var featuredPodcast = false
    var listUuid: String?
    var summaryExpanded = false
    var descriptionExpanded = false
    var currentViewMode: ViewMode = .episodes

    /// Fork: which list the episodes surface renders — the podcast's episode list,
    /// the session's store (inline Session tab), or the feeder's offers (Inbox tab).
    enum EpisodesListMode {
        case episodes
        case session
    }

    var episodesListMode: EpisodesListMode = .episodes
    var showingSession: Bool { episodesListMode == .session }
    /// Fork: the podcast session's store members, cached per reload — drives the
    /// little green in-this-session indicator on Episodes rows.
    var cachedSessionMemberUuids: Set<String> = []
    /// Inbox membership — the unread dot. Fetched ONCE per list load; the cell reads the Set.
    var cachedUnseenUuids: Set<String> = []
    /// Fork: the Episodes tab's last sections — switching back restores them
    /// instantly while the async refresh runs, instead of showing the old tab's rows.
    private var cachedEpisodesTabData: [ArraySection<String, ListItem>]?

    var hasSimilarShows = CurrentValueSubject<Bool, Never>(false)
    var isLoadingRecommendations = CurrentValueSubject<Bool, Never>(false)
    var currentViewModeSubject = CurrentValueSubject<ViewMode, Never>(.episodes)

    var hasSimilarShowsPublisher: AnyPublisher<Bool, Never> {
        hasSimilarShows.eraseToAnyPublisher()
    }

    var currentViewModePublisher: AnyPublisher<ViewMode, Never> {
        currentViewModeSubject.eraseToAnyPublisher()
    }

    var recommendations: PodcastCollection?
    var bookmarkViewModel: BookmarkPodcastListViewModel?

    enum ViewMode {
        case episodes
        case bookmarks
        case youMightLike

        var analyticsValue: String {
            switch self {
            case .episodes: return "episodes"
            case .bookmarks: return "bookmarks"
            case .youMightLike: return "you_might_like"
            }
        }
    }

    var searchController: EpisodeListSearchController?

    var cellHeights: [IndexPath: CGFloat] = [:]

    var podcastRatingViewModel = PodcastRatingViewModel()

    private var podcastInfo: PodcastInfo?
    var loadingPodcastInfo = false
    lazy var isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()

    @IBOutlet var episodesTableTopConstraint: NSLayoutConstraint!

    @IBOutlet var episodesTable: ThemeableTable! {
        didSet {
            registerCells()
            registerLongPress()
            registerSessionReorder()
            episodesTable.rowHeight = UITableView.automaticDimension
            episodesTable.estimatedRowHeight = 80.0
            episodesTable.allowsMultipleSelectionDuringEditing = true
            episodesTable.sectionHeaderTopPadding = 0
            episodesTable.separatorStyle = .none
        }
    }

    @IBOutlet var loadingIndicator: UIActivityIndicatorView!
    @IBOutlet var loadingBgView: UIView! {
        didSet {
            loadingBgView.backgroundColor = .clear
        }
    }

    @IBOutlet var loadingImageBg: UIView! {
        didSet {
            loadingImageBg.backgroundColor = .clear
        }
    }

    /// Fork: "Reorder Episodes" mode on the Session tab — real grips, everything else suspended.
    /// See `PodcastViewController+LineupReorder`.
    @MainActor
    var lineupReorderMode = false

    @MainActor
    var isMultiSelectEnabled = false {
        didSet {
            setEnclosingTabBarHidden(isMultiSelectEnabled, animated: false)
            // For non-episode cells we don't enable editing. It needs to be for Bookmarks and already if for You Might Like.
            if currentViewMode == .episodes {
                self.episodesTable.beginUpdates()
                self.episodesTable.setEditing(isMultiSelectEnabled, animated: true)
                self.episodesTable.endUpdates()
            }

            if self.isMultiSelectEnabled {
                if self.selectedEpisodes.isEmpty, self.longPressMultiSelectIndexPath == nil, !self.multiSelectGestureInProgress {
                    self.tableView().scrollToRow(at: IndexPath(row: NSNotFound, section: PodcastViewController.allEpisodesSection), at: .top, animated: true)
                }
                self.multiSelectFooter.setSelectedCount(count: self.selectedEpisodes.count)
                if let selectedIndexPath = self.longPressMultiSelectIndexPath {
                    self.tableView().selectIndexPath(selectedIndexPath)
                    self.longPressMultiSelectIndexPath = nil
                }
                self.multiSelectFooterBottomConstraint.constant = Constants.effectiveFooterViewPadding
            } else {
                self.selectedEpisodes.removeAll()
            }
            self.updateMultiSelectNavBar()
            searchController?.isOverflowButtonEnabled = !self.isMultiSelectEnabled
        }
    }

    var multiSelectGestureInProgress = false
    var longPressMultiSelectIndexPath: IndexPath?
    @IBOutlet var multiSelectFooter: MultiSelectFooterView! {
        didSet {
            multiSelectFooter.delegate = self
            // Sessions exist only for subscribed podcasts — scrub the session verbs on a
            // page that has no session and could not create one (Add to Playlist stays the
            // bulk verb there). Evaluated per open, so subscribing fixes it live.
            multiSelectFooter.getActionsFunc = { [weak self] in
                let actions = Settings.multiSelectActions()
                guard let podcast = self?.podcast,
                      !podcast.isSubscribed(), SessionStore.shared.session(forPodcast: podcast.uuid) == nil else { return actions }
                return actions.filter { $0 != .addToSession && $0 != .removeFromSession }
            }
        }
    }

    @IBOutlet var multiSelectFooterBottomConstraint: NSLayoutConstraint!

    var selectedEpisodes = [ListEpisode]() {
        didSet {
            multiSelectFooter.setSelectedCount(count: selectedEpisodes.count)
            updateSelectAllBtn()
        }
    }

    private let operationQueue = OperationQueue()

    private var shareBarButtonItem: UIBarButtonItem?
    private var defaultBackBarButton: UIBarButtonItem?
    var multiSelectAllBarButton: UIBarButtonItem?
    var multiSelectCancelBarButton: UIBarButtonItem?

    private lazy var navTitleLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        label.textAlignment = .center
        label.alpha = 0
        return label
    }()

    static let headerSection = 0
    static let allEpisodesSection = 1
    static let podrollSection = 1
    static let similarShowsSection = 2

    private var isSearching = false
    private var cancellables = Set<AnyCancellable>()
    private var podcastFeedViewModel: PodcastFeedViewModel?
    private var refreshController: PodcastFeedRefreshController?
    private var podcastFeedReloadTooltip: UIViewController?

    // Hosting for the SwiftUI action bar used by the Bookmarks list when embedded
    private var bookmarksActionBarHost: UIHostingController<AnyView>?
    private var bookmarksActionBarBottomConstraint: NSLayoutConstraint?

    lazy var ratingView: UIView = {
        let view = StarRatingView(viewModel: podcastRatingViewModel,
                                  onRate: { [weak self] in
            self?.podcastRatingViewModel.update(podcast: self?.podcast, ignoringCache: true)
        })
            .padding(.top, 10)
            .themedUIView
        view.backgroundColor = .clear
        return view
    }()

    init(podcast: Podcast) {
        self.podcast = podcast

        // show the expanded view for unsubscribed podcasts, as well as paid podcasts that have expired and you no longer have access to play/download
        summaryExpanded = !podcast.isSubscribed()

        AnalyticsHelper.podcastOpened(uuid: podcast.uuid)
        podcastRatingViewModel.update(podcast: podcast)

        super.init(nibName: "PodcastViewController", bundle: nil)
    }

    init(podcastInfo: PodcastInfo, existingImage: UIImage?) {
        if let uuid = podcastInfo.uuid, let existingPodcast = DataManager.sharedManager.findPodcast(uuid: uuid, includeUnsubscribed: true) {
            podcast = existingPodcast
            summaryExpanded = !existingPodcast.isSubscribed()
        } else {
            self.podcastInfo = podcastInfo
            summaryExpanded = true
        }

        if let uuid = podcastInfo.uuid {
            podcastRatingViewModel.update(podcast: podcast)
            AnalyticsHelper.podcastOpened(uuid: uuid)
        }

        super.init(nibName: "PodcastViewController", bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        operationQueue.cancelAllOperations()
    }

    override func viewDidLoad() {
        supportsGoogleCast = true
        useTransparentNavigationBarAppearance = true

        super.viewDidLoad()

        view.backgroundColor = ThemeColor.primaryUi01()

        if FeatureFlag.podcastFeedUpdate.enabled {
            podcastFeedViewModel = PodcastFeedViewModel(uuid: podcast?.uuid ?? podcastInfo?.uuid)

            // Let's collapse the header if the tooltip has never been showed before
            forceCollapsingHeaderIfNeeded()
        }

        let searchController = EpisodeListSearchController()
        searchController.podcastDelegate = self
        addChild(searchController)
        searchController.didMove(toParent: self)
        self.searchController = searchController

        operationQueue.maxConcurrentOperationCount = 1

        episodesTable.themeStyle = .primaryUi02
        episodesTable.addSubview(blurHeaderView)
        let blurHeaderPositionConstraint = blurHeaderView.bottomAnchor.constraint(equalTo: episodesTable.topAnchor, constant: blurHeaderPosition)
        NSLayoutConstraint.activate([
            blurHeaderPositionConstraint,
            blurHeaderView.heightAnchor.constraint(equalTo: view.widthAnchor, constant: 40),
            blurHeaderView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: -20),
            blurHeaderView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: 20),
        ])
        self.blurHeaderPositionConstraint = blurHeaderPositionConstraint

        navigationItem.titleView = {
            // The label has to go inside a container view other view navigationBar changes its alpha
            let view = UIView()
            view.addSubview(navTitleLabel)
            navTitleLabel.anchorToAllSidesOf(view: view)
            return view
        }()
        shareBarButtonItem = FakeNavBarButton.makeBarButtonItem(
            image: UIImage(named: "podcast-share"),
            accessibilityLabel: L10n.share,
            target: self,
            action: #selector(shareTapped)
        )
        customRightBtn = shareBarButtonItem

        if !LiquidGlass.isEnabled {
            defaultBackBarButton = FakeNavBarButton.makeBarButtonItem(
                image: UIImage(systemName: "chevron.backward"),
                accessibilityLabel: L10n.back,
                target: self,
                action: #selector(backButtonTapped)
            )
            navigationItem.leftBarButtonItem = defaultBackBarButton
            navigationItem.setHidesBackButton(true, animated: false)

            if let navController = navigationController as? PCNavigationController {
                navController.enableInteractivePopGestureWorkaround()
            } else {
                assertionFailure("Expected PCNavigationController")
            }
        }

        if podcast != nil, episodeInfo.isEmpty {
            let searchHeader = ListHeader(headerTitle: L10n.search, isSectionHeader: true, sectionNumber: -1)
            episodeInfo = [ArraySection(model: searchHeader.headerTitle, elements: [searchHeader])]
            reloadData()
        }

        loadPodcastInfo()

        NotificationCenter.default.addObserver(self, selector: #selector(podcastUpdated(_:)), name: Constants.Notifications.podcastUpdated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(folderChanged(_:)), name: Constants.Notifications.folderChanged, object: nil)

        listenForBookmarkChanges()
        setupLogin()

        setupRefreshControl()

        // Keep external action bar aligned with mini player
        NotificationCenter.default.addObserver(self, selector: #selector(miniPlayerStatusDidChange), name: Constants.Notifications.miniPlayerDidAppear, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(miniPlayerStatusDidChange), name: Constants.Notifications.miniPlayerDidDisappear, object: nil)
    }

    private var isScrolledPastHeader = false
    private var isNavBarBlurred = false

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let offset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        let scrolled = offset > PodcastHeaderView.Constants.smallImageSize + view.safeAreaInsets.top
        if scrolled != isScrolledPastHeader {
            isScrolledPastHeader = scrolled
            UIView.animate(withDuration: Constants.Animation.defaultAnimationTime) {
                self.navTitleLabel.alpha = scrolled ? 1 : 0
            }
            updateNavBarBlur()
        }
    }

    /// Forces the standard (blurred) navigation bar appearance whenever multi-select is on or the
    /// user has scrolled past the header. Multi-select uses plain text bar buttons that can't sit
    /// on the transparent over-artwork chrome (pre-iOS 26), so we lock the bar to its blurred state
    /// while it's active. On iOS 26 `setTransparentNavBarScrolled` is a no-op for the bar visuals,
    /// so this is effectively a pre-26 fix.
    private func updateNavBarBlur() {
        let shouldBlur = isMultiSelectEnabled || isScrolledPastHeader
        guard shouldBlur != isNavBarBlurred else { return }
        isNavBarBlurred = shouldBlur
        setTransparentNavBarScrolled(shouldBlur)
    }

    private func setupLogin() {
        podcastRatingViewModel.presentLogin = { [weak self] _ in
            self?.showLogin(message: L10n.ratingLoginRequired)
        }
    }

    private func setupBookmarkViewModel() {
        guard let podcast else { return }

        let sortOption = Settings.podcastBookmarksSort
        let viewModel = BookmarkPodcastListViewModel(podcast: podcast,
                                                      bookmarkManager: PlaybackManager.shared.bookmarkManager,
                                                      sortOption: sortOption)
        viewModel.analyticsSource = .podcasts
        viewModel.router = self

        self.bookmarkViewModel = viewModel
    }

    func showLogin(message: String?) {
        let loginViewController = LoginCoordinator.make()
        present(loginViewController, animated: true)
        if let message {
            Toast.show(message)
        }
    }

    private func listenForBookmarkChanges() {
        let bookmarkManager = PlaybackManager.shared.bookmarkManager

        // Refresh when a bookmark is added to our podcast
        bookmarkManager.onBookmarkCreated
            .filter({ [weak self] event in
                event.podcast == self?.podcast?.uuid
            })
            .receive(on: DispatchQueue.main)
            .sink(receiveValue: { [weak self] _ in
                self?.upNextChanged()
            })
            .store(in: &cancellables)

        // Reload when a bookmark is deleted
        bookmarkManager.onBookmarksDeleted
            .filter({ [weak self] event in
                event.items.contains(where: { $0.podcast == self?.podcast?.uuid })
            })
            .receive(on: DispatchQueue.main)
            .sink(receiveValue: { [weak self] _ in
                self?.upNextChanged()
            })
            .store(in: &cancellables)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        // Load the ratings even if we've already started loading them to cover all other potential view states
        // The view model will ignore extra calls
        if let _ = [podcast?.uuid, podcastInfo?.uuid].compactMap({ $0 }).first {
            podcastRatingViewModel.update(podcast: podcast)
        }
        updateColors()
    }

    lazy var blurHeaderView: UIView = {
        let headerView = PodcastBlurHeaderView(podcastUUID: self.podcastUUID).uiView
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.backgroundColor = .clear
        headerView.layer.zPosition = -1000
        headerView.isUserInteractionEnabled = false
        return headerView
    }()

    var blurHeaderPositionConstraint: NSLayoutConstraint?

    private var blurHeaderPosition: CGFloat {
        summaryExpanded ? PodcastHeaderView.Constants.largeImageSize : PodcastHeaderView.Constants.smallImageSize / 2
    }

    lazy var podcastHeaderCell: PodcastHeaderCell = {
        return PodcastHeaderCell(podcast: self.podcast!, vc: self)
    }()

    private var hasAppearedAlready = false
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        addCustomObserver(Constants.Notifications.podcastColorsDownloaded, selector: #selector(colorsDidDownload(_:)))
        addCustomObserver(Constants.Notifications.episodeArchiveStatusChanged, selector: #selector(refreshEpisodes))
        addCustomObserver(Constants.Notifications.manyEpisodesChanged, selector: #selector(refreshEpisodes))
        // Fork: the session sweep removes archived/played members from the store and
        // posts playlistChanged — refresh so the Session tab reflects the removal
        // immediately instead of lagging until the next tab switch.
        addCustomObserver(Constants.Notifications.playlistChanged, selector: #selector(refreshEpisodes))
        addCustomObserver(Constants.Notifications.episodeStarredChanged, selector: #selector(refreshEpisodes))
        addCustomObserver(Constants.Notifications.playbackTrackChanged, selector: #selector(refreshEpisodes))
        addCustomObserver(Constants.Notifications.playbackStarted, selector: #selector(hideSearchKeyboard))
        addCustomObserver(Constants.Notifications.playbackEnded, selector: #selector(refreshEpisodes))
        addCustomObserver(Constants.Notifications.playbackFailed, selector: #selector(refreshEpisodes))
        addCustomObserver(Constants.Notifications.searchRequested, selector: #selector(searchRequested))

        // Episode grouping can change based on download and play status, so listen for both those events and refresh when they happen
        addCustomObserver(Constants.Notifications.episodeDownloadStatusChanged, selector: #selector(refreshEpisodes))
        addCustomObserver(Constants.Notifications.episodeDownloaded, selector: #selector(refreshEpisodes))
        addCustomObserver(Constants.Notifications.episodePlayStatusChanged, selector: #selector(refreshEpisodes))
        addCustomObserver(SessionStore.changed, selector: #selector(refreshEpisodes))

        if featuredPodcast, !hasAppearedAlready {
            Analytics.track(.discoverFeaturedPodcastTapped, properties: ["uuid": podcastUUID])
            AnalyticsHelper.openedFeaturedPodcast()
        }

        // if it's a local podcast, refresh it when the view appears, eg: when you tab back to it
        if let podcast, podcast.isSubscribed(), hasAppearedAlready {
            refreshEpisodes()
        }

        hasAppearedAlready = true // we use this so the page doesn't double load from viewDidLoad and viewDidAppear

        var properties = ["uuid": podcastUUID]
        if let listUuid {
            properties["list_id"] = listUuid
        }
        Analytics.track(.podcastScreenShown, properties: properties)

        if FeatureFlag.podcastFeedUpdate.enabled {
            showPodcastFeedReloadTipIfNeeded()
        }
        showViewChangesTipIfNeeded()

        // Load recommendations when view appears
        if FeatureFlag.recommendations.enabled && recommendations == nil {
            Task {
                await loadRecommendations()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        if FeatureFlag.podcastFeedUpdate.enabled {
            podcastFeedViewModel?.cancelTask()
            Toast.dismiss()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        removeAllCustomObservers()

        if FeatureFlag.podcastFeedUpdate.enabled, let refreshControl = refreshController?.refreshControl, refreshControl.isRefreshing {
            refreshControl.endRefreshing()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        episodesTable.contentInset.bottom = miniPlayerClearance() + (isMultiSelectEnabled ? 80 : 0)
        episodesTable.verticalScrollIndicatorInsets.bottom = episodesTable.contentInset.bottom
    }

    /// Fork: bottom clearance for the now-playing pill. Under Liquid Glass the pill is a
    /// UITabAccessory that is supposed to ride the bottom safe area, but on this screen it
    /// doesn't always reach the table — so measure the pill's actual overlap with the table
    /// and top up exactly the part the safe area misses (zero when it's already covered,
    /// so this can never double-pad).
    private func miniPlayerClearance() -> CGFloat {
        LiquidGlass.isEnabled ? episodesTable.miniPlayerOverlapClearance() : Constants.effectiveMiniPlayerOffset
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .default
    }

    override func contentScrollView(for edge: NSDirectionalRectEdge) -> UIScrollView? {
        episodesTable
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        dismissKeyboardForScrollIfNeeded()
    }

    private func dismissKeyboardForScrollIfNeeded() {
        searchController?.hideKeyboard()
        view.endEditing(true)
    }

    @objc private func searchRequested() {
        guard podcast != nil, let searchBar = searchController?.searchTextField else { return }

        searchBar.becomeFirstResponder()
    }

    @objc private func colorsDidDownload(_ notification: Notification) {
        guard let uuidLoaded = notification.object as? String else { return }

        if let uuid = podcast?.uuid, uuid == uuidLoaded {
            if let podcast = DataManager.sharedManager.findPodcast(uuid: uuid, includeUnsubscribed: true) {
                self.podcast = podcast
            }
            updateColors()
        }
    }

    func reloadData() {
        episodesTable.reloadData()
    }

    private func updateColors() {
        view.backgroundColor = ThemeColor.primaryUi01()
        reloadData()
        navTitleLabel.textColor = ThemeColor.primaryText01()
    }

    override func handleThemeChanged() {
        updateColors()
    }

    @objc private func podcastUpdated(_ notification: Notification) {
        guard let podcastUuid = notification.object as? String, podcastUuid == podcast?.uuid else { return }

        podcast = DataManager.sharedManager.findPodcast(uuid: podcastUuid, includeUnsubscribed: true)
        if viewIfLoaded?.window != nil {
            refreshEpisodes()
        }
    }

    @objc private func folderChanged(_ notification: Notification) {
        guard let podcastUuid = podcast?.uuid else { return }

        podcast = DataManager.sharedManager.findPodcast(uuid: podcastUuid, includeUnsubscribed: true)
        if viewIfLoaded?.window != nil {
            refreshEpisodes()
        }
    }

    @objc private func refreshEpisodes() {
        guard let podcast else { return }

        loadLocalEpisodes(podcast: podcast, animated: true)
    }

    @objc private func upNextChanged() {
        reloadData()
    }

    @objc private func shareTapped() {
        guard let podcast else { return }

        // - warning: important to pass shareBarButtonItem
        SharingHelper.shared.shareLinkTo(podcast: podcast, fromController: self, fromSource: analyticsSource, barButtonItem: shareBarButtonItem)
        Analytics.track(.podcastScreenShareTapped, properties: ["podcast_uuid": podcast.uuid, "is_private": podcast.isPrivate])
    }

    private func loadPodcastInfo() {
        if let podcast {
            if podcast.isSubscribed() {
                loadLocalEpisodes(podcast: podcast, animated: false)
                checkIfPodcastNeedsUpdating()
            } else {
                let podcastUuid = podcast.uuid
                Task {
                    await PodcastManager.shared.deletePodcastIfUnused(podcast)
                    if let _ = DataManager.sharedManager.findPodcast(uuid: podcastUuid, includeUnsubscribed: true) {
                        // podcast wasn't deleted, but needs to be updated
                        loadLocalEpisodes(podcast: podcast, animated: false)
                        checkIfPodcastNeedsUpdating()
                    } else {
                        // podcast was deleted, reload the entire thing
                        self.podcast = nil
                        loadPodcastInfoFromUuid(podcastUuid)
                    }
                }
            }
        } else if let uuid = podcastInfo?.uuid {
            loadPodcastInfoFromUuid(uuid)
        } else if let iTunesId = podcastInfo?.iTunesId {
            loadPodcastInfoFromiTunesId(iTunesId)
        }
    }

    func loadLocalEpisodes(podcast: Podcast, animated: Bool) {
        cachedSessionMemberUuids = SessionStore.shared.session(forPodcast: podcast.uuid)
            .map { Set(SessionFeederEngine.storeMemberUuids(for: $0)) } ?? []
        cachedUnseenUuids = InboxManager.shared.unseenUuids()

        switch episodesListMode {
        case .session:
            loadSessionEpisodes(podcast: podcast, animated: animated)
            return
            return
        case .episodes:
            break
        }

        let uuidsToFilter = (searchController?.searchInProgress() ?? false) ? uuidsThatMatchSearch : nil
        let refreshOperation = PodcastEpisodesRefreshOperation(podcast: podcast, uuidsToFilter: uuidsToFilter) { [weak self] newData in
            guard let self else { return }

            self.navTitleLabel.text = podcast.title

            // add the episode limit placehold if it's needed
            var finalData = newData
            var needsNoEpisodesMessage = false
            var needsNoSearchResultsMessage = false
            let searching = self.searchController?.searchTextField?.text?.count ?? 0 > 0
            if podcast.podcastGrouping() == .none {
                let episodeLimit = Int(podcast.autoArchiveEpisodeLimit)
                var episodes = newData[safe: 1]?.elements
                let episodeCount = episodes?.count ?? 0
                if episodeCount > 0, episodeLimit > 0, podcast.overrideGlobalArchive {
                    var indexToInsertAt = -1

                    let episodeSortOrder = podcast.podcastSortOrder

                    switch episodeSortOrder {
                    case .newestToOldest:
                        indexToInsertAt = episodeLimit <= episodeCount ? episodeLimit : episodeCount
                    case .oldestToNewest:
                        indexToInsertAt = episodeCount > episodeLimit ? episodeCount - episodeLimit : episodeCount - 1
                    default:
                        ()
                    }

                    if indexToInsertAt >= 0 {
                        let message = episodeLimit == 1 ? L10n.podcastLimitSingular : L10n.podcastLimitPluralFormat(episodeLimit.localized())
                        let placeholder = EpisodeLimitPlaceholder(limit: episodeLimit, message: message)
                        episodes?.insert(placeholder, at: indexToInsertAt)
                        finalData[1] = ArraySection(model: "episodes", elements: episodes!)
                    }
                } else if episodeCount == 0, searching {
                    needsNoSearchResultsMessage = true
                } else if episodeCount == 0, !self.showingArchived() {
                    needsNoEpisodesMessage = true
                }
            } else {
                var totalEpisodeCount = -1 // the search header counts as an item below, so start from -1
                for group in finalData {
                    totalEpisodeCount += group.elements.count
                }

                needsNoEpisodesMessage = totalEpisodeCount == 0 && !self.showingArchived() && !searching
                needsNoSearchResultsMessage = totalEpisodeCount == 0 && searching
            }

            if needsNoSearchResultsMessage {
                let placeholder = NoSearchResultsPlaceholder()
                finalData[1] = ArraySection(model: "episodes", elements: [placeholder])
            } else if needsNoEpisodesMessage {
                let archivedCount = self.archivedEpisodeCount()
                let message = L10n.podcastArchivedMsg(archivedCount.localized())
                let placeholder = AllArchivedPlaceholder(archived: archivedCount, message: message)
                finalData[1] = ArraySection(model: "episodes", elements: [placeholder])
            }

            if animated {
                let oldData = self.episodeInfo
                let changeSet = StagedChangeset(source: oldData, target: finalData)
                do {
                    try SJCommonUtils.catchException {
                        self.episodesTable.reload(using: changeSet, with: .none, setData: { data in
                            self.episodeInfo = data
                        })
                    }
                } catch {
                    self.episodeInfo = finalData
                    reloadData()
                }
            } else {
                self.episodeInfo = finalData
                reloadData()
            }
            // Instant restore when switching back to this tab later.
            self.cachedEpisodesTabData = finalData
            self.searchController?.episodesDidReload()
            if self.isMultiSelectEnabled {
                self.updateSelectAllBtn()
            }
        }

        operationQueue.addOperation(refreshOperation)
    }

    /// Fork: builds episodeInfo from the session store's lineup so the inline Session
    /// tab reuses the entire standard episodes pipeline (cells, taps, multi-select).
    private func loadSessionEpisodes(podcast: Podcast, animated: Bool) {
        let searchHeader = ListHeader(headerTitle: L10n.search, isSectionHeader: true, sectionNumber: -1)
        var finalData = [ArraySection<String, ListItem>(model: searchHeader.headerTitle, elements: [searchHeader])]

        // Search applies here too: server matches by uuid, plus a local title match so
        // store members from other podcasts don't silently vanish while searching.
        let uuidsToFilter = (searchController?.searchInProgress() ?? false) ? uuidsThatMatchSearch : nil
        let searchTerm = searchController?.searchTextField?.text ?? ""

        var episodes = [ListItem]()
        if let session = SessionStore.shared.session(forPodcast: podcast.uuid),
           let storeUuid = session.storePlaylistUuid,
           let store = DataManager.sharedManager.findPlaylist(uuid: storeUuid) {
            let tintColor = AppTheme.appTintColor()
            episodes = DataManager.sharedManager.positionedEpisodeUuids(for: store)
                .compactMap { DataManager.sharedManager.findEpisode(uuid: $0) }
                .filter { episode in
                    guard let uuidsToFilter else { return true }
                    return uuidsToFilter.contains(episode.uuid) || (!searchTerm.isEmpty && episode.displayableTitle().localizedCaseInsensitiveContains(searchTerm))
                }
                .map { ListEpisode(episode: $0, tintColor: tintColor) }
        }
        // Fork: the lineup renders in its one saved order — no display sort on top of it. Changing
        // that order is an explicit re-arrangement (see `reorderSessionLineup`).
        var listEpisodes = episodes.compactMap { $0 as? ListEpisode }

        // Fork: if you're listening to an episode of this podcast AS PART OF A SESSION,
        // surface it at the top of this podcast's Session tab even when the store it's
        // playing from is a different session (e.g. a smart-playlist session). Gated on
        // session playback — a plain queue episode must NOT appear here.
        if !(searchController?.searchInProgress() ?? false),
           PlaybackManager.shared.isPlayingSessionEpisode,
           let current = PlaybackManager.shared.currentEpisode() as? Episode,
           current.parentPodcast()?.uuid == podcast.uuid,
           !listEpisodes.contains(where: { $0.episode.uuid == current.uuid }) {
            listEpisodes.insert(ListEpisode(episode: current, tintColor: AppTheme.appTintColor()), at: 0)
        }
        episodes = listEpisodes
        if episodes.isEmpty, !searchTerm.isEmpty {
            episodes = [NoSearchResultsPlaceholder()]
        }
        finalData.append(ArraySection(model: "episodes", elements: episodes))

        let apply = { [weak self] in
            guard let self else { return }

            self.navTitleLabel.text = podcast.title
            if animated {
                let changeSet = StagedChangeset(source: self.episodeInfo, target: finalData)
                do {
                    try SJCommonUtils.catchException {
                        self.episodesTable.reload(using: changeSet, with: .none, setData: { data in
                            self.episodeInfo = data
                        })
                    }
                } catch {
                    self.episodeInfo = finalData
                    self.reloadData()
                }
            } else {
                self.episodeInfo = finalData
                self.reloadData()
            }
            self.searchController?.episodesDidReload()
            if self.isMultiSelectEnabled {
                self.updateSelectAllBtn()
            }
        }

        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    @objc func hideSearchKeyboard() {
        searchController?.hideKeyboard()
    }

    // MARK: - PodcastActionsDelegate

    func refreshArtwork() {
        guard let podcast else { return }

        let optionsPicker = OptionsPicker(title: nil)
        let refreshAction = OptionAction(label: L10n.podcastRefreshArtwork, icon: "option-download-retry") {
            ImageManager.sharedManager.clearCache(podcastUuid: podcast.uuid, recacheWhenDone: true)
        }
        optionsPicker.addAction(action: refreshAction)

        optionsPicker.present(from: self)
    }

    func unsubscribe() {
        var downloadedCount = 0
        for object in episodeInfo[1].elements {
            guard let listEpisode = object as? ListEpisode else { continue }

            if listEpisode.episode.episodeStatus == DownloadStatus.downloaded.rawValue {
                downloadedCount += 1
            }
        }

        let label = FeatureFlag.useFollowNaming.enabled ? L10n.unfollow : L10n.unsubscribe
        let title: String
        let message: String?
        if downloadedCount > 0 {
            title = L10n.downloadedFilesConf(downloadedCount)
            message = FeatureFlag.useFollowNaming.enabled ? L10n.downloadedFilesConfMessageNew : L10n.downloadedFilesConfMessage
        } else {
            title = L10n.areYouSure
            message = nil
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: label, style: .destructive) { [weak self] _ in
            self?.performUnsubscribe()
        })
        present(alert, animated: true)

        Analytics.track(.podcastScreenUnsubscribeTapped)
    }

    private func performUnsubscribe() {
        guard let podcast else { return }

        PodcastManager.shared.unsubscribe(podcast: podcast)
        navigationController?.popViewController(animated: true)
        Analytics.track(.podcastUnsubscribed, properties: ["source": analyticsSource, "uuid": podcast.uuid])
    }

    func subscribe() {
        guard let podcast else { return }

        podcast.subscribed = 1
        podcast.syncStatus = SyncStatus.notSynced.rawValue
        podcast.autoDownloadSetting = (FeatureFlag.autoDownloadOnSubscribe.enabled && Settings.autoDownloadEnabled() && Settings.autoDownloadOnFollow() ? AutoDownloadSetting.latest : AutoDownloadSetting.off).rawValue
        DataManager.sharedManager.save(podcast: podcast)
        ServerPodcastManager.shared.updateLatestEpisodeInfo(podcast: podcast, setDefaults: true, autoDownloadLimit: Settings.autoDownloadOnFollow() ? Settings.autoDownloadLimits().rawValue : 0)
        loadLocalEpisodes(podcast: podcast, animated: true)

        if featuredPodcast {
            Analytics.track(.discoverFeaturedPodcastSubscribed, properties: ["podcast_uuid": podcast.uuid])
            AnalyticsHelper.subscribedToFeaturedPodcast()
        }
        if let listId = listUuid {
            AnalyticsHelper.podcastSubscribedFromList(listId: listId, podcastUuid: podcast.uuid)
        }

        HapticsHelper.triggerSubscribedHaptic()

        Analytics.track(.podcastScreenSubscribeTapped)
        Analytics.track(.podcastSubscribed, properties: ["source": analyticsSource, "uuid": podcast.uuid])
    }

    // MARK: - Multi-select nav bar

    func updateMultiSelectNavBar() {
        if isMultiSelectEnabled {
            supportsGoogleCast = false
            let cancel = UIBarButtonItem(title: L10n.cancel, style: .plain, target: self, action: #selector(cancelTapped))
            cancel.accessibilityLabel = L10n.accessibilityCancelMultiselect
            multiSelectCancelBarButton = cancel
            customRightBtn = cancel

            let selectAll = UIBarButtonItem(title: L10n.selectAll, style: .plain, target: self, action: #selector(selectAllTapped))
            multiSelectAllBarButton = selectAll
            navigationItem.setLeftBarButton(selectAll, animated: true)
            if LiquidGlass.isEnabled {
                navigationItem.setHidesBackButton(true, animated: true)
            }
            updateSelectAllBtn()
        } else {
            multiSelectCancelBarButton = nil
            multiSelectAllBarButton = nil
            customRightBtn = shareBarButtonItem
            if LiquidGlass.isEnabled {
                navigationItem.setLeftBarButton(nil, animated: true)
                navigationItem.setHidesBackButton(false, animated: true)
            } else {
                navigationItem.setLeftBarButton(defaultBackBarButton, animated: false)
            }
            supportsGoogleCast = true
            refreshRightButtons()
        }
        updateNavBarBlur()
    }

    @objc private func backButtonTapped() {
        navigationController?.popViewController(animated: true)
    }

    func isSummaryExpanded() -> Bool {
        summaryExpanded
    }

    func setSummaryExpanded(expanded: Bool) {
        summaryExpanded = expanded
        blurHeaderPositionConstraint?.constant = blurHeaderPosition
        UIView.animate(withDuration: 0.2) {
            self.view.layoutIfNeeded()
        }
    }

    func isDescriptionExpanded() -> Bool {
        descriptionExpanded
    }

    func setDescriptionExpanded(expanded: Bool) {
        descriptionExpanded = expanded
    }

    @objc private func miniPlayerStatusDidChange() {
        updateBookmarksActionBarBottomConstraint()
        // The pill appears/disappears without changing the table's bounds, so nothing would
        // recompute its bottom clearance — force a layout pass so the last row clears the pill.
        view.setNeedsLayout()
    }

    func tableView() -> UITableView {
        episodesTable
    }

    func displayedPodcast() -> Podcast? {
        podcast
    }

    func episodeCount() -> Int {
        guard let podcast else { return 0 }

        return DataManager.sharedManager.count(query: "SELECT COUNT(*) FROM \(DataManager.episodeTableName) WHERE podcast_id == ?", values: [podcast.id])
    }

    /// Fork: what the Episodes tab currently shows, after the display filters.
    func archivedEpisodeCount() -> Int {
        guard let podcast else { return 0 }

        return DataManager.sharedManager.count(query: "SELECT COUNT(*) FROM \(DataManager.episodeTableName) WHERE podcast_id == ? AND archived = 1", values: [podcast.id])
    }

    /// Fork: how many of the rows on screen still wear the unread dot. Counted from the
    /// member Set already cached for this load — never a query per row, and never a second
    /// query here.
    func unseenEpisodeCount() -> Int {
        episodeInfo
            .flatMap(\.elements)
            .compactMap { ($0 as? ListEpisode)?.episode }
            .count { cachedUnseenUuids.contains($0.uuid) }
    }

    func settingsTapped() {
        guard let podcast else { return }

        let settingsController = PodcastSettingsViewController(podcast: podcast)
        settingsController.episodes = episodeInfo
        navigationController?.pushViewController(settingsController, animated: true)
        Analytics.track(.podcastScreenSettingsTapped)
    }

    func fundingTapped() {
        Analytics.track(.podcastScreenFundingTapped, properties: ["podcast_uuid": podcast?.uuid ?? ""])
        guard let urlString = podcast?.fundingURL, let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    func manageSubscriptionTapped() {
        guard SyncManager.isUserLoggedIn() else {
            let signinPage = SyncSigninViewController()
            signinPage.delegate = self

            navigationController?.pushViewController(signinPage, animated: true)
            return
        }
        guard let podcast, let bundle = SubscriptionHelper.bundleSubscriptionForPodcast(podcastUuid: podcast.uuid) else { return }
        let subscriptionController = SupporterPodcastViewController(bundleSubscription: bundle)
        navigationController?.pushViewController(subscriptionController, animated: true)
    }

    func didActivateSearch() {
        // Add padding to the bottom of the table to allow it to scroll up
        let tableBounds = tableView().bounds
        let view = UIView()
        view.frame = CGRect(x: 0, y: 0, width: tableBounds.width, height: tableBounds.height - 320)
        view.backgroundColor = UIColor.clear
        tableView().tableFooterView = view

        // scroll the search box to the top of the page
        tableView().scrollToRow(at: IndexPath(row: NSNotFound, section: PodcastViewController.allEpisodesSection), at: .top, animated: true)
    }

    func folderTapped() {
        Analytics.track(.podcastScreenFolderTapped)
        if !SubscriptionHelper.hasActiveSubscription() {
            NavigationManager.sharedManager.showUpsellView(from: self, source: .folders)
            return
        }

        guard let podcast else { return }

        if let currentFolder = podcast.folderUuid, !currentFolder.isEmpty {
            // podcast is already in a folder, present the options for removing/moving it
            showPodcastFolderMoveOptions(currentFolderUuid: currentFolder)

            return
        }

        showFolderPickerDialog()
    }

    func notificationTapped() {
        guard let podcast else {
            return
        }
        let newValue = !podcast.pushEnabled
        Analytics.track(.podcastScreenNotificationsTapped, properties: ["enabled": newValue])
        NotificationsHelper.shared.setNotificationsEnabled(newValue, for: podcast)
    }

    func categoryTapped(_ category: String) {
        NavigationManager.sharedManager.navigateTo(NavigationManager.discoverPageKey, data: [NavigationManager.discoverCategoryKey: category])
        Analytics.track(.podcastScreenCategoryTapped, properties: ["category": category])
    }

    func searchEpisodes(query: String) {
        performEpisodeSearch(query: query)
        if !isSearching {
            isSearching = true
            Analytics.track(.podcastScreenSearchPerformed)
        }
    }

    func clearSearch() {
        guard let podcast else { return }

        uuidsThatMatchSearch.removeAll()
        loadLocalEpisodes(podcast: podcast, animated: true)
        isSearching = false
        Analytics.track(.podcastScreenSearchCleared)
    }

    /// Fork: archived visibility is a Filter Preset rule now, edited via the preset picker — this
    /// stays only to satisfy the delegate protocol.
    func toggleShowArchived() {
        guard let podcast else { return }
        var preset = FilterPresets.active()
        preset.archived = (preset.archived == false) ? nil : false
        FilterPresetStore.shared.upsert(preset)
        loadLocalEpisodes(podcast: podcast, animated: true)
    }

    /// Whether the active preset is surfacing archived episodes — drives the "all archived"
    /// placeholder. nil ("don't care") and true ("archived only") both surface them; only an
    /// explicit false hides them.
    func showingArchived() -> Bool {
        FilterPresets.active().archived != false
    }

    /// Fork: display filters (played/seen) changed — rebuild the episode list.
    func episodesDidChange() {
        guard let podcast else { return }
        loadLocalEpisodes(podcast: podcast, animated: true)
    }

    func archiveAllTapped(playedOnly: Bool) {
        archiveAll(playedOnly: playedOnly)
    }

    func unarchiveAllTapped() {
        guard let podcast else { return }

        DispatchQueue.global().async {
            DataManager.sharedManager.markAllUnarchivedForPodcast(id: podcast.id)

            AnalyticsEpisodeHelper.shared.currentSource = .podcastScreen
            AnalyticsEpisodeHelper.shared.bulkUnarchiveEpisodes(count: self.episodeCount())

            DispatchQueue.main.async { [weak self] in
                guard let strongSelf = self else { return }

                strongSelf.loadLocalEpisodes(podcast: podcast, animated: false)
            }
        }
    }

    func archiveAll(playedOnly: Bool = false) {
        guard let podcast else { return }

        DispatchQueue.global().async { [weak self] in
            guard let allObjects = self?.episodeInfo[safe: 1]?.elements, !allObjects.isEmpty else { return }

            var count = 0
            for object in allObjects {
                guard let listEpisode = object as? ListEpisode else { continue }
                if listEpisode.episode.archived || (playedOnly && !listEpisode.episode.played()) { continue }

                EpisodeManager.archiveEpisode(episode: listEpisode.episode, fireNotification: false, userInitiated: false)
                count += 1
            }

            AnalyticsEpisodeHelper.shared.currentSource = .podcastScreen
            AnalyticsEpisodeHelper.shared.bulkArchiveEpisodes(count: count)

            DispatchQueue.main.async { [weak self] in
                guard let strongSelf = self else { return }

                strongSelf.loadLocalEpisodes(podcast: podcast, animated: false)
            }
        }
    }

    func downloadAllTapped() {
        DispatchQueue.global().async { [weak self] in
            guard let self, let allObjects = self.episodeInfo[safe: 1]?.elements, !allObjects.isEmpty else { return }

            let episodes = allObjects.compactMap { ($0 as? ListEpisode)?.episode }
            AnalyticsEpisodeHelper.shared.currentSource = .podcastScreen
            AnalyticsEpisodeHelper.shared.bulkDownloadEpisodes(episodes: episodes)

            self.downloadItems(allObjects: allObjects)
        }
    }

    /// Fork: the actions menu for ANY grouped header (seasons, played/unplayed,
    /// downloaded, starred groups) — everything routes through the podcast's one
    /// session. `season` is analytics-only.
    func showOptionsFor(groupStartingAt headerIndexPath: IndexPath, season: Int?) {
        guard podcast != nil else { return }
        let group = episodes(forGroupStartingAt: headerIndexPath)
        guard !group.isEmpty else { return }

        if let season {
            Analytics.track(.podcastScreenSeasonOptionsTapped, properties: ["season": season])
        }

        let optionPicker = OptionsPicker(title: nil)

        // Fork: the session verbs only exist for a podcast you actually follow — an unsubscribed
        // podcast has no session to play, queue, add to or replace, so offering them here promised
        // something the rest of the app can't deliver. Add to Playlist stands outside that: a
        // manual playlist is yours regardless of what you're subscribed to.
        var firstBlock = [OptionAction]()
        if podcast?.isSubscribed() == true {
            firstBlock += [
                .init(label: L10n.sessionPlayAs, icon: "filter_play") { [weak self] in
                    self?.playGroupAsSession(group)
                },
                .init(label: L10n.sessionQueueAs, icon: "rectangle.stack") { [weak self] in
                    self?.queueGroupAsSession(group)
                },
                .init(label: L10n.playlistAddToLineup, icon: "rectangle.stack.badge.plus") { [weak self] in
                    self?.addGroupToSession(group)
                },
                .init(label: L10n.sessionReplaceWith, icon: "rectangle.stack") { [weak self] in
                    self?.replaceSessionWithGroup(group)
                }
            ]
        }
        firstBlock.append(.init(label: L10n.playlistManualEpisodeAddToPlaylist, icon: "plus-circle") { [weak self] in
            self?.addGroupToPlaylist(group)
        })
        optionPicker.addActions(firstBlock)
        optionPicker.addActions([
            .init(label: L10n.selectAll, icon: "option-multiselect") { [weak self] in
                self?.selectGroup(group)
                if let season { Analytics.track(.podcastScreenSeasonOptionsSelectAllTapped, properties: ["season": season]) }
            },
            downloadAction(for: group, season: season),
            archiveAction(for: group, season: season)
        ].compactMap(\.self))

        optionPicker.present(from: self)
    }

    /// The run of episode rows under a grouped header, up to the next header.
    private func episodes(forGroupStartingAt headerIndexPath: IndexPath) -> [ListEpisode] {
        guard let elements = episodeInfo[safe: headerIndexPath.section]?.elements else { return [] }
        var result = [ListEpisode]()
        var index = headerIndexPath.row + 1
        while index < elements.count, !(elements[index] is ListHeader) {
            if let listEpisode = elements[index] as? ListEpisode {
                result.append(listEpisode)
            }
            index += 1
        }
        return result
    }

    /// Fork: the group joins the podcast's session at the marker and playback starts
    /// at the group's first episode.
    private func playGroupAsSession(_ group: [ListEpisode]) {
        guard let podcast, let first = group.first?.episode,
              let session = SessionManager.shared.findOrCreateSession(forPodcast: podcast) else { return }
        // Explicit USER add — pinned, so the feeder's prune never removes it.
        SessionManager.shared.addToLineup(episodeUuids: group.map { $0.episode.uuid }, session: session, pinning: true)
        SessionManager.shared.play(episode: first, in: session)
    }

    /// Fork: standard Add to Session routing for the whole group.
    private func addGroupToSession(_ group: [ListEpisode]) {
        guard let podcast else { return }
        let session = SessionManager.shared.findOrCreateSession(forPodcast: podcast)
        SessionManager.shared.addToSessions(episodeUuids: group.map { $0.episode.uuid }, preferred: session, presenting: self)
    }

    /// Fork: queue the group without playing it — the group joins the podcast's session and that
    /// session floats to the top of the Queue screen, so it's the next thing you'd reach for. Same
    /// shape as the playlist page's Queue button (`PlaylistDetailViewController.queueSession`).
    private func queueGroupAsSession(_ group: [ListEpisode]) {
        guard let podcast, !group.isEmpty,
              let session = SessionManager.shared.findOrCreateSession(forPodcast: podcast) else { return }
        SessionManager.shared.addToLineup(episodeUuids: group.map { $0.episode.uuid }, session: session)
        // Float it to the front of the session order, keeping every other session's relative order.
        let order = [session.uuid] + SessionStore.shared.sessions.map(\.uuid).filter { $0 != session.uuid }
        SessionStore.shared.reorderSessions(order)
        Toast.show(L10n.playlistQueueSessionToast)
    }

    /// Fork: the group goes to a manual playlist of the user's choosing — the same bulk chooser
    /// multi-select uses, so a group header and a hand-made selection behave identically.
    private func addGroupToPlaylist(_ group: [ListEpisode]) {
        let episodes = group.compactMap { $0.episode as? Episode }
        guard !episodes.isEmpty else { return }
        let chooser = ManualPlaylistsChooserViewController(episodes: episodes, analyticsSource: "podcast_group")
        present(UINavigationController(rootViewController: chooser), animated: true)
    }

    /// Fork: the lineup becomes exactly this group. Former members return to triage.
    /// Nothing plays — that's Play as Session's job.
    private func replaceSessionWithGroup(_ group: [ListEpisode]) {
        guard let podcast, !group.isEmpty,
              let session = SessionManager.shared.findOrCreateSession(forPodcast: podcast) else { return }
        // Explicit USER choice — the new lineup is pinned against the feeder's prune.
        SessionManager.shared.replaceLineup(episodeUuids: group.map { $0.episode.uuid }, session: session, pinning: true)
    }

    private func downloadAction(for group: [ListEpisode], season: Int?) -> OptionAction? {
        let episodes = group.map(\.episode)
        let allDownloaded = episodes.allSatisfy { $0.downloaded(pathFinder: DownloadManager.shared) }
        if allDownloaded {
            return .init(label: L10n.removeAll, icon: "episode-remove-download") {
                EpisodeManager.removeDownloadForEpisodes(episodes)
                if let season { Analytics.track(.podcastScreenSeasonOptionsRemoveAllTapped, properties: ["season": season]) }
            }
        } else {
            return .init(label: L10n.downloadAll, icon: "player-download") { [weak self] in
                self?.downloadGroup(group)
                if let season { Analytics.track(.podcastScreenSeasonOptionsDownloadAllTapped, properties: ["season": season]) }
            }
        }
    }

    private func archiveAction(for group: [ListEpisode], season: Int?) -> OptionAction? {
        let episodes = group.map(\.episode)
        if episodes.contains(where: { !$0.archived }) {
            return OptionAction(label: L10n.podcastArchiveAll, icon: "options-archiveall") {
                EpisodeManager.bulkArchive(episodes: episodes, updateSyncFlag: true)
                if let season { Analytics.track(.podcastScreenSeasonOptionsArchiveAllTapped, properties: ["season": season]) }
            }
        } else {
            return OptionAction(label: L10n.podcastUnarchiveAll, icon: "list_unarchive") {
                EpisodeManager.bulkUnarchive(episodes: episodes)
                if let season { Analytics.track(.podcastScreenSeasonOptionsUnarchiveAllTapped, properties: ["season": season]) }
            }
        }
    }

    private func selectGroup(_ group: [ListEpisode]) {
        selectedEpisodes = group
        enableMultiSelect()
        DispatchQueue.main.async { [weak self] in
            self?.reloadData()
        }
    }

    private func downloadGroup(_ group: [ListEpisode]) {
        let episodes = group.map(\.episode)
        NetworkUtils.shared.downloadEpisodeRequested(autoDownloadStatus: .notSpecified, { [weak self] later in
            DispatchQueue.global().async {
                guard let self else { return }

                AnalyticsEpisodeHelper.shared.currentSource = .podcastScreen
                AnalyticsEpisodeHelper.shared.bulkDownloadEpisodes(episodes: episodes)

                if later {
                    self.queueItems(allObjects: group)
                } else {
                    self.downloadItems(allObjects: group)
                }
            }
        }, disallowed: nil)
    }

    func downloadItems(allObjects: [ListItem]) {
        var queuedEpisodes = 0
        for object in allObjects {
            guard let listEpisode = object as? ListEpisode else { continue }

            if listEpisode.episode.downloading() || listEpisode.episode.downloaded(pathFinder: DownloadManager.shared) || listEpisode.episode.queued() {
                continue
            }

            DownloadManager.shared.addToQueue(episodeUuid: listEpisode.episode.uuid, fireNotification: true, autoDownloadStatus: .notSpecified)
            queuedEpisodes += 1
            if queuedEpisodes == Constants.Limits.maxBulkDownloads {
                return
            }
        }
    }

    func queueAllTapped() {
        DispatchQueue.global().async { [weak self] in
            guard let self, let allObjects = self.episodeInfo[safe: 1]?.elements, !allObjects.isEmpty else { return }
            self.queueItems(allObjects: allObjects)
        }
    }

    func queueItems(allObjects: [ListItem]) {
        var queuedEpisodes = 0
        for object in allObjects {
            guard let listEpisode = object as? ListEpisode else { continue }

            if listEpisode.episode.downloading() || listEpisode.episode.downloaded(pathFinder: DownloadManager.shared) || listEpisode.episode.queued() {
                continue
            }

            DownloadManager.shared.queueForLaterDownload(episodeUuid: listEpisode.episode.uuid, fireNotification: true, autoDownloadStatus: .notSpecified)

            queuedEpisodes += 1
            if queuedEpisodes == Constants.Limits.maxBulkDownloads {
                return
            }
        }
    }

    func downloadableEpisodeCount(items: [ListItem]? = nil) -> Int {
        guard let allObjects = items == nil ? episodeInfo[safe: 1]?.elements : items, !allObjects.isEmpty else { return 0 }

        var count = 0

        for object in allObjects {
            guard let listEpisode = object as? ListEpisode else { continue }

            if !listEpisode.episode.downloaded(pathFinder: DownloadManager.shared), !listEpisode.episode.downloading(), !listEpisode.episode.queued() {
                count += 1
            }
        }
        return count
    }

    func enableMultiSelect() {
        isMultiSelectEnabled = true
    }

    // MARK: - External Bookmarks Action Bar

    func updateBookmarksActionBar(state: ExternalActionBarState, viewModel: BookmarkPodcastListViewModel) {
        if state.isMultiSelecting {
            // Ensure top nav/selection header matches multiselect state
            if !isMultiSelectEnabled {
                isMultiSelectEnabled = true
            }
            // Hide the table's native multiSelectFooter; we present a SwiftUI bar instead
            multiSelectFooter.isHidden = true

            let actions: [ActionBarView<ThemedActionBarStyle>.Action] = makeBookmarkActions(BookmarkActionConfig(
                showShare: state.showShare,
                showEdit: state.showEdit,
                onShare: { viewModel.shareSelectedBookmarks() },
                onEdit: { viewModel.editSelectedBookmarks() },
                onDelete: { viewModel.deleteSelectedBookmarks() }
            ))

            let bar = ActionBarView(title: state.title, style: ThemedActionBarStyle(), actions: actions)
                .padding(.bottom) // match internal spacing

            if let host = bookmarksActionBarHost {
                host.rootView = AnyView(bar)
            } else {
                let host = UIHostingController(rootView: AnyView(bar))
                host.view.backgroundColor = .clear
                bookmarksActionBarHost = host

                addChild(host)
                view.addSubview(host.view)
                host.view.translatesAutoresizingMaskIntoConstraints = false

                let bottom = host.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
                bookmarksActionBarBottomConstraint = bottom

                NSLayoutConstraint.activate([
                    host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                    bottom
                ])

                host.didMove(toParent: self)

                // Ensure initial layout has the correct offset without animating from the top
                updateBookmarksActionBarBottomConstraint(animated: false)
            }

            if state.visible {
                // Subsequent updates can animate
                updateBookmarksActionBarBottomConstraint(animated: true)
            } else {
                // If not visible (no selected items), remove bar if present
                removeBookmarksActionBar()
            }
            // Keep Select All button title in sync
            updateSelectAllBtn()
        } else {
            removeBookmarksActionBar()
            if isMultiSelectEnabled {
                isMultiSelectEnabled = false
            }
        }
    }

    private func updateBookmarksActionBarBottomConstraint(animated: Bool = true) {
        guard let bottom = bookmarksActionBarBottomConstraint else { return }
        guard let host = bookmarksActionBarHost else { return }
        bottom.constant = -bookmarksActionBarBottomOffset()
        if animated {
            UIView.animate(withDuration: 0.1) { host.view.layoutIfNeeded(); self.view.layoutIfNeeded() }
        } else {
            host.view.layoutIfNeeded()
            self.view.layoutIfNeeded()
        }
    }

    func removeBookmarksActionBar() {
        if let host = bookmarksActionBarHost {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }
        bookmarksActionBarHost = nil
        bookmarksActionBarBottomConstraint = nil
    }

    private func bookmarksActionBarBottomOffset() -> CGFloat {
        Constants.effectiveMiniPlayerOffset
    }

    private func showPodcastFolderMoveOptions(currentFolderUuid: String) {
        guard let podcast, let folder = DataManager.sharedManager.findFolder(uuid: currentFolderUuid) else { return }

        let optionsPicker = OptionsPicker(title: folder.name.localizedUppercase)
        let removeAction = OptionAction(label: L10n.folderRemoveFrom.localizedCapitalized, icon: "folder-remove") {
            podcast.sortOrder = ServerPodcastManager.shared.highestSortOrderForHomeGrid() + 1
            podcast.folderUuid = nil
            podcast.syncStatus = SyncStatus.notSynced.rawValue
            DataManager.sharedManager.save(podcast: podcast)

            DataManager.sharedManager.updateFolderSyncModified(folderUuid: currentFolderUuid, syncModified: TimeFormatter.currentUTCTimeInMillis())

            NotificationCenter.postOnMainThread(notification: Constants.Notifications.folderChanged, object: currentFolderUuid)

            Analytics.track(.folderPodcastModalOptionTapped, properties: ["option": "remove"])
        }
        optionsPicker.addAction(action: removeAction)

        let changeFolderAction = OptionAction(label: L10n.folderChange.localizedCapitalized, icon: "folder-arrow") { [weak self] in
            guard let self else { return }

            self.showFolderPickerDialog()

            Analytics.track(.folderPodcastModalOptionTapped, properties: ["option": "change"])
        }
        optionsPicker.addAction(action: changeFolderAction)

        let goToFolderAction = OptionAction(label: L10n.folderGoTo.localizedCapitalized, icon: "folder-goto") {
            NavigationManager.sharedManager.navigateTo(NavigationManager.folderPageKey, data: [NavigationManager.folderKey: folder])
            Analytics.track(.folderPodcastModalOptionTapped, properties: ["option": "go_to"])
        }
        optionsPicker.addAction(action: goToFolderAction)

        optionsPicker.present(from: self)
    }

    private func showFolderPickerDialog() {
        guard let podcast else { return }

        let model = ChoosePodcastFolderModel(pickingFor: podcast.uuid, currentFolder: podcast.folderUuid)
        let chooseFolderView = ChoosePodcastFolderView(model: model) { [weak self] _ in
            self?.dismiss(animated: true, completion: nil)
        }
        let hostingController = PCHostingController(rootView: chooseFolderView.environmentObject(Theme.sharedTheme))

        present(hostingController, animated: true, completion: nil)
    }

    func showEpisodes() {
        episodesListMode = .episodes
        episodesTable.tableFooterView = nil
        // Instant: restore the tab's last rows; the refresh operation follows.
        if let cached = cachedEpisodesTabData {
            episodeInfo = cached
            reloadData()
        }
        switchViewMode(to: .episodes)
    }

    /// Fork: the inline Session tab — find or create the podcast's session, then
    /// render its store through the standard episodes surface.
    func showSession() {
        guard let podcast, SessionManager.shared.findOrCreateSession(forPodcast: podcast) != nil else { return }

        episodesListMode = .session
        episodesTable.tableFooterView = nil
        switchViewMode(to: .episodes)
    }

    func isShowingSession() -> Bool {
        showingSession
    }

    func multiSelectPreferredSession() -> Session? {
        guard let podcast else { return nil }
        return SessionManager.shared.findOrCreateSession(forPodcast: podcast)
    }

    func multiSelectCurrentSession() -> Session? {
        guard let podcast else { return nil }
        return SessionStore.shared.session(forPodcast: podcast.uuid)
    }

    func showBookmarks() {
        if FeatureFlag.podcastBookmarksInline.enabled {
            switchViewMode(to: .bookmarks)
        } else {
            guard let podcast else { return }
            let controller = BookmarksPodcastListController(podcast: podcast)
            present(controller, animated: true)
        }
    }

    func showYouMightLike() {
        switchViewMode(to: .youMightLike)
    }

    // MARK: - Podcast Feed Reload

    private func setupRefreshControl() {
        if shouldDisplayPodcastFeedReloadButton() {
            let controller = PodcastFeedRefreshController()
            controller.refreshControl.customTintColor = UIColor.label
            controller.perform = { [weak self] in
                self?.reloadPodcastFeed(source: .refreshControl)
            }
            episodesTable.refreshControl = controller.refreshControl
            refreshController = controller

            // `UIImage.isDark` walks every byte of the artwork (~40 ms for grid-size art),
            // so resolve the contrast color off the main thread and apply when ready.
            let uuid = podcastUUID
            Task.detached(priority: .utility) { [refreshControl = controller.refreshControl] in
                guard let image = ImageManager.sharedManager.cachedImageFor(podcastUuid: uuid, size: .grid) else { return }
                let isDark = image.isDark
                await MainActor.run {
                    refreshControl.customTintColor = isDark ? .white : .black
                }
            }
        }
    }

    func shouldDisplayPodcastFeedReloadButton() -> Bool {
        return FeatureFlag.podcastFeedUpdate.enabled && podcastFeedViewModel?.uuid != nil
    }

    func reloadPodcastFeed(source: PodcastFeedReloadSource) {
        // In case the FF is switched off
        guard shouldDisplayPodcastFeedReloadButton() else {
            refreshController?.refreshControl.endRefreshing()
            return
        }
        if podcastFeedViewModel?.loadingState == .loading {
            return
        }

        //TODO: Add analytics based on source

        Task { @MainActor [weak self] in
            let podcastNeedsReload = await self?.podcastFeedViewModel?.checkIfNewEpisodesAreAvailable(from: source) ?? false
            if podcastNeedsReload {
                self?.loadPodcastInfo()
            }
        }
    }

    func refreshPodcastFeed() {
        // In case the FF is switched off
        guard shouldDisplayPodcastFeedReloadButton() else {
            refreshController?.refreshControl.endRefreshing()
            return
        }
        reloadPodcastFeed(source: .refreshControl)
    }

    func open(url: URL) {
        if Settings.openLinks {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        } else {
            if URLHelper.isValidScheme(url.scheme) {
                let safariViewController = SFSafariViewController(with: url)
                safariViewController.delegate = self

                SceneHelper.rootViewController()?.present(safariViewController, animated: true, completion: nil)
            } else if URLHelper.isMailtoScheme(url.scheme), UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        }
    }

    private func dismissPodcastFeedReloadTip() {
        guard Settings.shouldShowPodcastFeeReloadTip,
            let podcastFeedReloadTooltip
        else {
            return
        }
        Analytics.track(.podcastRefreshEpisodeTooltipDismissed)
        Settings.shouldShowPodcastFeeReloadTip = false
        podcastFeedReloadTooltip.dismiss(animated: true) { [weak self] in
            self?.podcastFeedReloadTooltip = nil
        }
    }

    func forceCollapsingHeaderIfNeeded() {
        if FeatureFlag.podcastFeedUpdate.enabled {
            if Settings.shouldShowPodcastFeeReloadTip, summaryExpanded {
                summaryExpanded = false
            }
        }
    }

    func showPodcastFeedReloadTipIfNeeded() {
        guard
            Settings.shouldShowPodcastFeeReloadTip,
            FeatureFlag.podcastFeedUpdate.enabled,
            podcastFeedReloadTooltip == nil
        else {
            return
        }
        if let vc = showPodcastFeedReloadTip() {
            present(vc, animated: true) {
                Analytics.track(.podcastRefreshEpisodeTooltipShown)
            }
            podcastFeedReloadTooltip = vc
        }
    }

    private func showPodcastFeedReloadTip() -> UIViewController? {
        guard let button = searchController?.overflowButton else {
            return nil
        }
        let vc = UIHostingController(rootView: AnyView (EmptyView()) )
        let idealSize = CGSizeMake(290, 100)
        let tipView = TipViewStatic(title: L10n.podcastFeedReloadTipTitle,
                                    message: L10n.podcastFeedReloadTipMessage,
                              onTap: { [weak self] in
            self?.dismissPodcastFeedReloadTip()
        })
            .frame(idealWidth: idealSize.width, minHeight: idealSize.height)
            .setupDefaultEnvironment()
        vc.rootView = AnyView(tipView)
        vc.view.backgroundColor = .clear
        vc.view.clipsToBounds = false
        vc.modalPresentationStyle = .popover
        vc.sizingOptions = [.preferredContentSize]
        if let popoverPresentationController = vc.popoverPresentationController {
            popoverPresentationController.delegate = self
            popoverPresentationController.permittedArrowDirections = [.down]
            popoverPresentationController.sourceView = button
            popoverPresentationController.sourceRect = button.bounds
            popoverPresentationController.backgroundColor = ThemeColor.primaryUi01()
        }
        return vc
    }

    private var viewChangesTipVC: UIViewController?
    private var dimmingView: UIView?

    func showViewChangesTipIfNeeded() {
        guard Settings.shouldShowPodcastViewChangesTip,
              self.podcast != nil,
              viewChangesTipVC == nil
        else {
            return
        }
        Settings.shouldShowPodcastViewChangesTip = false
        var point = podcastHeaderCell.center
        point.y = summaryExpanded ? 1.4 * PodcastHeaderView.Constants.largeImageSize : 1.4 * PodcastHeaderView.Constants.smallImageSize
        let rect = CGRect(origin: point, size: .zero)
        viewChangesTipVC = showTip(title: L10n.podcastViewChangesTipTitle, message: L10n.podcastViewChangesTipDetails, sourceView: podcastHeaderCell, sourceRect: rect) { [weak self] in
            self?.dismissViewChangesTip()
        }
    }

    private func dismissViewChangesTip() {
        guard let viewChangesTipVC else {
            return
        }
        viewChangesTipVC.dismiss(animated: true)
        dimmingView?.removeFromSuperview()
        self.viewChangesTipVC = nil
    }

    private func showTip(title: String, message: String, sourceView: UIView, sourceRect: CGRect = CGRectNull, dimBackground: Bool = true, action: @escaping () -> ()) -> UIViewController {
        if dimBackground {
            let dimmingView = UIView(frame: self.view.bounds)
            dimmingView.backgroundColor = .black.withAlphaComponent(0.3)
            self.tabBarController?.view.addSubview(dimmingView)
            self.dimmingView = dimmingView
        }
        let vc = UIHostingController(rootView: AnyView (EmptyView()) )
        let idealSize = CGSizeMake(290, 100)
        let tipView = TipViewStatic(title: title,
                                    message: message,
                                    showClose: true,
                              onTap: {
            action()
        })
            .frame(idealWidth: idealSize.width, minHeight: idealSize.height)
            .setupDefaultEnvironment()
        vc.rootView = AnyView(tipView)
        vc.view.backgroundColor = .clear
        vc.view.clipsToBounds = false
        vc.modalPresentationStyle = .popover
        vc.sizingOptions = [.preferredContentSize]
        if let popoverPresentationController = vc.popoverPresentationController {
            popoverPresentationController.delegate = self
            popoverPresentationController.permittedArrowDirections = [.down]
            popoverPresentationController.sourceView = sourceView
            popoverPresentationController.sourceRect = sourceRect
            popoverPresentationController.backgroundColor = ThemeColor.primaryUi01()
        }
        present(vc, animated: true)
        return vc
    }

    // MARK: - Long press actions

    func archiveAll(startingAt: Episode) {
        guard let podcast else { return }

        DispatchQueue.global().async { [weak self] in
            guard let allObjects = self?.episodeInfo[safe: 1]?.elements, !allObjects.isEmpty else { return }

            var haveFoundFirst = false
            for object in allObjects {
                guard let listEpisode = object as? ListEpisode else { continue }

                if !haveFoundFirst, listEpisode.episode.uuid != startingAt.uuid { continue }

                haveFoundFirst = true
                if listEpisode.episode.archived { continue }

                EpisodeManager.archiveEpisode(episode: listEpisode.episode, fireNotification: false)
            }

            DispatchQueue.main.async { [weak self] in
                guard let strongSelf = self else { return }

                strongSelf.loadLocalEpisodes(podcast: podcast, animated: false)
            }
        }
    }

    // MARK: - Accessibility fix

    // Not quite sure why this view controller won't close with the z-gesture
    // I suspect it has something to do with the way it is pushed in MainTabController
    // Implementing the following function restores expected functionality
    override func accessibilityPerformEscape() -> Bool {
        navigationController?.popViewController(animated: true)
        return true
    }

    // MARK: - SyncSigninDelegate

    func signingProcessCompleted() {
        navigationController?.popToViewController(self, animated: true)
    }

    @MainActor
    func loadRecommendations() async {
        guard let podcast else { return }

        isLoadingRecommendations.send(true)
        updateEmptyStateVisibility()

        do {
            var originalRecommendations = try await ServerPodcastManager.shared.loadRecommendations(for: podcast.uuid, in: Settings.userRegion())
            filterCurrentPodcast(from: &originalRecommendations)
            recommendations = originalRecommendations
            guard !Task.isCancelled else { return }
            hasSimilarShows.send(recommendations?.podcasts?.isEmpty == false)
        } catch {
            // We won't do anything in the interface here since the You Might Like button is optional and hidden by default
            FileLog.shared.addMessage("[PodcastViewController] Failed to load recommendations \(error)")
            guard !Task.isCancelled else { return }
            hasSimilarShows.send(false)
        }

        isLoadingRecommendations.send(false)
        updateEmptyStateVisibility()
    }

    private func filterCurrentPodcast(from collection: inout PodcastCollection?) {
        if var podcasts = collection?.podcasts {
            podcasts = podcasts.filter { $0.uuid != self.podcast?.uuid }
            collection?.podcasts = podcasts
        }
    }

    private func updateEmptyStateVisibility() {
        if currentViewMode == .youMightLike {
            episodesTable.reloadData()
        }
    }

    private func switchViewMode(to mode: ViewMode) {
        // Clear any externally presented action bar when switching modes
        removeBookmarksActionBar()
        if isMultiSelectEnabled {
            isMultiSelectEnabled = false
        }
        // Grips on a browsed episode list would promise a reorder with nowhere to be saved.
        exitLineupReorderModeIfNeeded()
        currentViewMode = mode
        currentViewModeSubject.send(mode)
        switch mode {
        case .episodes:
            if let podcast {
                // Tab switches hard-swap the list — diff-animating between two
                // unrelated lists parades the old tab's rows/headers through the new.
                loadLocalEpisodes(podcast: podcast, animated: false)
            }
        case .youMightLike:
            updateEmptyStateVisibility()
            if recommendations == nil {
                Task {
                    await loadRecommendations()
                }
            }
        case .bookmarks:
            if bookmarkViewModel == nil {
                setupBookmarkViewModel() // Reloads on init
            } else {
                bookmarkViewModel?.reload()
            }
        }
        Analytics.track(.podcastsScreenTabTapped, properties: ["value": mode.analyticsValue])
        reloadData()
    }
}

// MARK: - Analytics

extension PodcastViewController: AnalyticsSourceProvider {
    var analyticsSource: AnalyticsSource {
        .podcastScreen
    }
}

private extension PodcastViewController {
    var podcastUUID: String {
        podcast?.uuid ?? podcastInfo?.analyticsDescription ?? "unknown"
    }
}

extension PodcastViewController: UIPopoverPresentationControllerDelegate {
    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
        // Return no adaptive presentation style, use default presentation behaviour
        return .none
    }

    func popoverPresentationControllerDidDismissPopover(_ popoverPresentationController: UIPopoverPresentationController) {
        dismissPodcastFeedReloadTip()
        dismissViewChangesTip()
    }
}

extension PodcastViewController: SFSafariViewControllerDelegate {
    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        controller.delegate = nil
    }
}

// MARK: - BookmarkListRouter

extension PodcastViewController: BookmarkListRouter {
    func bookmarkPlay(_ bookmark: Bookmark) async throws {
        try await PlaybackManager.shared.playBookmark(bookmark, source: .podcasts)
    }

    func bookmarkEdit(_ bookmark: Bookmark) {
        let controller = BookmarkEditTitleViewController(manager: PlaybackManager.shared.bookmarkManager, bookmark: bookmark, state: .updating, style: .themed)
        controller.source = .podcasts

        present(controller, animated: true)
    }

    func bookmarkShare(_ bookmark: Bookmark) {
        guard let episode = bookmark.episode as? Episode else {
            return
        }
        Analytics.track(.bookmarkShareTapped, source: analyticsSource, properties: ["podcast_uuid": episode.podcastUuid, "episode_uuid": bookmark.episodeUuid])
        SharingModal.show(option: .bookmark(episode, bookmark.time), from: .podcastScreen, in: self)
    }

    func dismissBookmarksList() {
        // For tab-based bookmarks, we switch to episodes view instead of dismissing
        switchViewMode(to: .episodes)
    }
}
