import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils
import UIKit

class EpisodeListSearchController: SimpleNotificationsViewController, UISearchBarDelegate {
    weak var podcastDelegate: PodcastActionsDelegate?

    // search
    @IBOutlet var roundedBackgroundView: UIView!
    @IBOutlet var searchTextField: UITextField! {
        didSet {
            searchTextField.addTarget(self, action: #selector(textFieldDidChange), for: .editingChanged)
            searchTextField.font = UIFont.font(ofSize: 15, weight: .regular, scalingWith: .subheadline)
        }
    }

    @IBOutlet var searchIcon: UIImageView!
    @IBOutlet var loadingSpinner: ThemeLoadingIndicator!
    @IBOutlet var clearSearchBtn: UIButton!

    var searchTimer: Timer?
    var searching = false

    @IBOutlet var episodeInfoLabel: ThemeableLabel! {
        didSet {
            episodeInfoLabel.style = .primaryText02
            episodeInfoLabel.font = UIFont.font(ofSize: 14, weight: .regular, scalingWith: .footnote)
        }
    }

    @IBOutlet var limitLabel: ThemeableLabel! {
        didSet {
            limitLabel.style = .support08
            limitLabel.font = UIFont.font(ofSize: 14, weight: .regular, scalingWith: .footnote)
        }
    }

    @IBOutlet var showHideArchiveBtn: UIButton! {
        didSet {
            showHideArchiveBtn.titleLabel?.font = UIFont.font(ofSize: 15, weight: .regular, scalingWith: .footnote)
            showHideArchiveBtn.titleLabel?.adjustsFontForContentSizeCategory = true
            showHideArchiveBtn.titleLabel?.numberOfLines = 0
        }
    }
    @IBOutlet var overflowButton: ThemeSecondaryButton!

    // Fork: the per-tab sort toggle, left of the funnel (or at its spot when the
    // funnel hides on the Inbox/Session tabs).
    private let sortButton = UIButton(type: .system)
    private var sortTrailingToFunnel: NSLayoutConstraint?
    private var sortTrailingToEdge: NSLayoutConstraint?
    var isOverflowButtonEnabled = true {
        didSet {
            overflowButton.isEnabled = isOverflowButtonEnabled
        }
    }

    @IBOutlet var dividerHeightConstraint: NSLayoutConstraint! {
        didSet {
            dividerHeightConstraint.constant = 1 / UIScreen.main.scale
        }
    }

    @IBOutlet var middleDividerHeightConstraint: NSLayoutConstraint! {
        didSet {
            middleDividerHeightConstraint.constant = 1 / UIScreen.main.scale
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(filtersWereReset), name: FilterPresets.resetAll, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(presetChanged), name: FilterPresetStore.changed, object: nil)
        showHideArchiveBtn.titleLabel?.textAlignment = .center
        showHideArchiveBtn.titleLabel?.heightAnchor.constraint(equalTo: showHideArchiveBtn.heightAnchor).isActive = true

        sortButton.translatesAutoresizingMaskIntoConstraints = false
        sortButton.accessibilityLabel = L10n.sortBy
        sortButton.addTarget(self, action: #selector(sortToggleTapped), for: .touchUpInside)
        view.addSubview(sortButton)
        sortTrailingToFunnel = sortButton.trailingAnchor.constraint(equalTo: showHideArchiveBtn.leadingAnchor, constant: -2)
        sortTrailingToEdge = sortButton.trailingAnchor.constraint(equalTo: showHideArchiveBtn.trailingAnchor)
        NSLayoutConstraint.activate([
            sortButton.centerYAnchor.constraint(equalTo: showHideArchiveBtn.centerYAnchor),
            sortButton.widthAnchor.constraint(equalToConstant: 32),
            sortButton.heightAnchor.constraint(equalToConstant: 32)
        ])

        updateInfoView()
        themeChanged()
        addCustomObserver(Constants.Notifications.themeChanged, selector: #selector(themeChanged))
    }

    deinit {
        removeAllCustomObservers()
    }

    @objc private func textFieldDidChange() {
        handleTextFieldDidChange()
    }

    @objc private func themeChanged() {
        view.backgroundColor = ThemeColor.primaryUi02()

        searchTextField.backgroundColor = UIColor.clear
        searchTextField.textColor = ThemeColor.primaryText02()
        searchTextField.attributedPlaceholder = NSAttributedString(string: L10n.searchEpisodes, attributes: [NSAttributedString.Key.foregroundColor: ThemeColor.primaryText02(), .font: UIFont.font(ofSize: 15, weight: .regular, scalingWith: .subheadline)])
        searchTextField.keyboardAppearance = AppTheme.keyboardAppearance()
        roundedBackgroundView.backgroundColor = ThemeColor.primaryField01()
        searchIcon.tintColor = ThemeColor.primaryIcon02()
        clearSearchBtn.tintColor = ThemeColor.primaryIcon02()
        showHideArchiveBtn.tintColor = ThemeColor.primaryInteractive01()
    }

    private func updateInfoView() {
        guard let delegate = podcastDelegate, let podcast = delegate.displayedPodcast() else { return }

        // Fork: on the inline Session tab the counts line describes the lineup, and the
        // funnel hides — its filters shape the Episodes list only.
        if delegate.isShowingSession() {
            let count = SessionStore.shared.session(forPodcast: podcast.uuid)
                .map { SessionFeederEngine.storeMemberUuids(for: $0).count } ?? 0
            // An empty tab already says "No episodes" in the list — a "0 episodes"
            // line on top is noise.
            if count > 0 {
                let text = count == 1 ? L10n.podcastEpisodeCountSingular : L10n.podcastEpisodeCountPluralFormat(count.localized())
                episodeInfoLabel?.attributedText = NSAttributedString(string: text, attributes: [.foregroundColor: AppTheme.colorForStyle(.primaryText02)])
            } else {
                episodeInfoLabel?.attributedText = nil
            }
            showHideArchiveBtn?.isHidden = true
            // Sort lives in the ⋯ menu now, not the counts line.
            sortButton.isHidden = true
            return
        }
        showHideArchiveBtn?.isHidden = false
        sortButton.isHidden = true

        let episodeCount = delegate.episodeCount()
        let hasEpisodeLimit = (podcast.autoArchiveEpisodeLimit > 0 && podcast.overrideGlobalArchive)

        let infoText = episodeCount == 1 ? L10n.podcastEpisodeCountSingular : L10n.podcastEpisodeCountPluralFormat(episodeCount.localized())
        let attributedText = NSMutableAttributedString(string: infoText, attributes: [.foregroundColor: AppTheme.colorForStyle(.primaryText02)])
        // Fork: the "• M archived" half is gone. It was the app telling you archived episodes were
        // being withheld — the exact "silently lying" the preset picker's label now makes
        // impossible: whether archived show is a visible, named rule. An episode LIMIT is different
        // (it's an auto-archive setting, not a filter), so that note stays.
        if hasEpisodeLimit {
            attributedText.append(NSAttributedString(string: " • " + L10n.podcastEpisodeLimitCountFormat(podcast.autoArchiveEpisodeLimit.localized()), attributes: [.foregroundColor: AppTheme.colorForStyle(.support08)]))
        }
        let unseenCount = delegate.unseenEpisodeCount()
        if unseenCount > 0 {
            attributedText.append(NSAttributedString(
                string: " • \(L10n.inboxUnseenCountFormat(unseenCount.localized()))",
                attributes: [.foregroundColor: AppTheme.colorForStyle(.primaryText02)]
            ))
        }
        episodeInfoLabel?.attributedText = attributedText

        // Fork: the stock Show/Hide Archived button IS the Filter Preset control now — and it
        // wears the active preset's NAME. That is the safety mechanism: a sticky filter you cannot
        // see is how a list silently lies to you, and an icon (however tinted) does not say what it
        // is filtering by.
        if let showHideBtn = showHideArchiveBtn {
            UIView.performWithoutAnimation {
                FilterPresetPicker.style(showHideBtn)
                showHideBtn.layoutIfNeeded()
            }
        }
        updateSortButton()
    }

    /// The current tab's sort key on the podcast page.
    private var currentSortTab: TriageTabSort.Tab {
        guard let delegate = podcastDelegate else { return .episodes }
        return delegate.isShowingSession() ? .session : .episodes
    }

    /// Fork: the per-tab sort control — accented whenever the shown order isn't the
    /// tab's natural one (Episodes: the stock per-podcast sort, newest first by
    /// default; Session: the custom lineup order; Inbox: newest first).
    private func updateSortButton() {
        guard let podcast = podcastDelegate?.displayedPodcast() else { return }
        let tab = currentSortTab
        let nonDefault: Bool
        if tab == .episodes {
            nonDefault = (podcast.podcastSortOrder ?? .newestToOldest) != .newestToOldest
        } else {
            nonDefault = TriageTabSort.isNonDefault(tab, pageUuid: podcast.uuid)
        }
        UIView.performWithoutAnimation {
            // Button-level symbol config — system buttons override per-image configs,
            // which made the glyph render at different sizes per surface.
            sortButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 16, weight: .medium), forImageIn: .normal)
            sortButton.setImage(UIImage(systemName: "arrow.up.arrow.down"), for: .normal)
            sortButton.tintColor = nonDefault ? ThemeColor.primaryInteractive01() : ThemeColor.primaryIcon02()
            sortButton.layoutIfNeeded()
        }
        sortTrailingToFunnel?.isActive = false
        sortTrailingToEdge?.isActive = false
        if tab == .episodes {
            sortTrailingToFunnel?.isActive = true
        } else {
            sortTrailingToEdge?.isActive = true
        }
    }

    @objc private func sortToggleTapped() {
        guard let podcast = podcastDelegate?.displayedPodcast() else { return }
        let tab = currentSortTab

        // Episodes rides the stock per-podcast sort (full option set); the other
        // tabs get their own per-podcast order picker.
        if tab == .episodes {
            makeSortOptionsPicker()?.present(from: self)
            return
        }

        let picker = OptionsPicker(title: L10n.sortBy.localizedUppercase)
        let current = TriageTabSort.order(tab, pageUuid: podcast.uuid)
        for option in tab.options {
            picker.addAction(action: OptionAction(label: option.title, selected: current == option) { [weak self] in
                TriageTabSort.setOrder(option, tab: tab, pageUuid: podcast.uuid)
                self?.updateSortButton()
                self?.podcastDelegate?.episodesDidChange()
            })
        }
        picker.present(from: self)
    }

    func episodesDidReload() {
        updateInfoView()
    }

    /// Fork: the Filter Preset picker. It replaced the funnel sheet entirely — seen, archived and
    /// session membership are ordinary preset rules now, so there is nothing left for a separate
    /// display-filter sheet to own.
    @IBAction func showHideArchiveTapped(_ sender: Any) {
        guard let controller = podcastDelegate as? UIViewController else { return }
        FilterPresetPicker.present(
            from: controller,
            searchActive: !(searchTextField?.text ?? "").isEmpty,
            onSelect: { [weak self] preset in self?.applyPresetSortAndGroup(preset) }
        ) { [weak self] in
            self?.podcastDelegate?.episodesDidChange()
        }
    }

    @IBAction func overflowTapped(_ sender: Any) {
        guard let delegate = podcastDelegate, let podcast = delegate.displayedPodcast() else { return }

        let optionPicker = OptionsPicker(title: nil)

        if delegate.shouldDisplayPodcastFeedReloadButton() {
            let reloadPodcastFeedAction = OptionAction(label: L10n.podcastFeedReloadButton, icon: "stats_skipping") { [weak self] in
                guard let self else { return }
                self.podcastDelegate?.reloadPodcastFeed(source: .menu)
            }
            optionPicker.addAction(action: reloadPodcastFeedAction)
        }

        let MultiSelectAction = OptionAction(label: L10n.selectEpisodes, icon: "option-multiselect") { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.podcastDelegate?.enableMultiSelect()
        }
        optionPicker.addAction(action: MultiSelectAction)

        let episodeSortOrder = podcast.podcastSortOrder

        let currentSort = episodeSortOrder?.description ?? ""
        let sortAction = OptionAction(label: L10n.sortEpisodes, secondaryLabel: currentSort, icon: "podcastlist_sort") {}
        sortAction.submenu = { [weak self] in self?.makeSortOptionsPicker() }
        optionPicker.addAction(action: sortAction)

        let currentGroup = podcast.podcastGrouping().description
        let groupAction = OptionAction(label: L10n.groupEpisodes, secondaryLabel: currentGroup, icon: "option-group") {}
        groupAction.submenu = { [weak self] in self?.makeGroupOptionsPicker() }
        optionPicker.addAction(action: groupAction)

        let downloadAllAction = OptionAction(label: L10n.downloadAll, icon: "filter_downloaded") {}
        downloadAllAction.submenu = { [weak self] in self?.makeDownloadAllPicker() }
        optionPicker.addAction(action: downloadAllAction)

        let unarchivedQuery = "SELECT COUNT(*) FROM \(DataManager.episodeTableName) WHERE podcast_id = ? AND archived = 0"
        let unarchivedCount = DataManager.sharedManager.count(query: unarchivedQuery, values: [podcast.id])
        if unarchivedCount > 0 {
            let archiveAllAction = OptionAction(label: L10n.podcastArchiveAll, icon: "podcast-archiveall") {}
            archiveAllAction.submenu = { [weak self] in self?.makeArchiveAllPicker(episodeCount: unarchivedCount, playedOnly: false) }
            optionPicker.addAction(action: archiveAllAction)
        } else if !(podcast.autoArchiveEpisodeLimit > 0 && podcast.overrideGlobalArchive) {
            // we only show unarchive all for podcasts that haven't set an episode limit
            let unarchiveAllAction = OptionAction(label: L10n.podcastUnarchiveAll, icon: "list_unarchive") { [weak self] in
                guard let strongSelf = self else { return }

                strongSelf.performUnarchiveAll()
            }
            optionPicker.addAction(action: unarchiveAllAction)
        }

        let playedNotArchivedQuery = "SELECT COUNT(*) FROM \(DataManager.episodeTableName) WHERE podcast_id = ? AND archived = 0 AND playingStatus = \(PlayingStatus.completed.rawValue)"
        let playedNotArchivedCount = DataManager.sharedManager.count(query: playedNotArchivedQuery, values: [podcast.id])
        if playedNotArchivedCount > 0 {
            let archiveAllPlayedAction = OptionAction(label: L10n.podcastArchiveAllPlayed, icon: "podcast-archiveall") {}
            archiveAllPlayedAction.submenu = { [weak self] in self?.makeArchiveAllPicker(episodeCount: playedNotArchivedCount, playedOnly: true) }
            optionPicker.addAction(action: archiveAllPlayedAction)
        }

        optionPicker.present(from: self)
        Analytics.track(.podcastScreenOptionsTapped)
    }

    private func performUnarchiveAll() {
        guard let podcastDelegate else { return }

        podcastDelegate.unarchiveAllTapped()
    }

    private func makeDownloadAllPicker() -> OptionsPicker? {
        guard let delegate = podcastDelegate else { return nil }

        let downloadableCount = delegate.downloadableEpisodeCount(items: nil)
        let downloadLimitExceeded = downloadableCount > Constants.Limits.maxBulkDownloads
        let actualDownloadCount = downloadLimitExceeded ? Constants.Limits.maxBulkDownloads : downloadableCount
        if actualDownloadCount == 0 { return nil }
        let downloadText = L10n.downloadCountPrompt(actualDownloadCount)
        let downloadAction = OptionAction(label: downloadText, icon: nil) {
            delegate.downloadAllTapped()
        }

        let confirmPicker = OptionsPicker(title: nil)
        var warningMessage = downloadLimitExceeded ? L10n.bulkDownloadMax : ""

        if NetworkUtils.shared.isConnectedToUnexpensiveConnection() {
            confirmPicker.addDescriptiveActions(title: L10n.downloadAll, message: warningMessage, icon: "filter_downloaded", actions: [downloadAction])
        } else {
            downloadAction.destructive = true

            let queueAction = OptionAction(label: L10n.queueForLater, icon: nil) {
                delegate.queueAllTapped()
            }
            queueAction.outline = true

            if !Settings.mobileDataAllowed() {
                warningMessage = L10n.downloadDataWarningWithSettingsLink("pktc://settings/storage-and-data") + "\n" + warningMessage
            }
            confirmPicker.addAttributedDescriptiveActions(title: L10n.notOnWifi, message: warningMessage, icon: "option-alert", actions: [downloadAction, queueAction])
        }

        return confirmPicker
    }

    private func makeArchiveAllPicker(episodeCount: Int, playedOnly: Bool) -> OptionsPicker? {
        guard let podcastDelegate else { return nil }

        let archiveAllConfirm = OptionsPicker(title: nil)
        let archiveAllAction = OptionAction(label: episodeCount == 1 ? L10n.podcastArchiveEpisodeCountSingular : L10n.podcastArchiveEpisodesCountPluralFormat(episodeCount.localized()), icon: nil, action: {
            podcastDelegate.archiveAllTapped(playedOnly: playedOnly)
        })
        archiveAllAction.destructive = true
        let title = playedOnly ? L10n.podcastArchiveAllPlayed : L10n.podcastArchiveAll
        archiveAllConfirm.addDescriptiveActions(title: title, message: L10n.podcastArchivePromptMsg, icon: "options-archiveall", actions: [archiveAllAction])

        return archiveAllConfirm
    }

    private func makeSortOptionsPicker() -> OptionsPicker? {
        guard let podcast = podcastDelegate?.displayedPodcast() else { return nil }

        let optionPicker = OptionsPicker(title: L10n.podcastSortOrderTitle)

        let sortOrder = podcast.podcastSortOrder

        PodcastEpisodeSortOrder.allCases.forEach { order in
            let newestToOldestAction = OptionAction(label: order.description, selected: sortOrder == order) { [weak self] in
                self?.setSortSetting(order)
                Analytics.track(.podcastsScreenSortOrderChanged, properties: ["sort_by": order])
            }

            optionPicker.addAction(action: newestToOldestAction)
        }

        return optionPicker
    }

    private func makeGroupOptionsPicker() -> OptionsPicker? {
        guard let podcast = podcastDelegate?.displayedPodcast() else { return nil }

        let optionPicker = OptionsPicker(title: L10n.podcastGroupOptionsTitle)

        let episodeGrouping = podcast.podcastGrouping()

        let noneAction = OptionAction(label: L10n.none, selected: episodeGrouping == PodcastGrouping.none) { [weak self] in
            self?.setGroupingSetting(.none)
            Analytics.track(.podcastsScreenEpisodeGroupingChanged, properties: ["value": PodcastGrouping.none])
        }
        optionPicker.addAction(action: noneAction)

        let downloadedAction = OptionAction(label: L10n.statusDownloaded, selected: episodeGrouping == PodcastGrouping.downloaded) { [weak self] in
            self?.setGroupingSetting(.downloaded)
            Analytics.track(.podcastsScreenEpisodeGroupingChanged, properties: ["value": PodcastGrouping.downloaded])
        }
        optionPicker.addAction(action: downloadedAction)

        let unplayedAction = OptionAction(label: L10n.statusUnplayed, selected: episodeGrouping == PodcastGrouping.unplayed) { [weak self] in
            self?.setGroupingSetting(.unplayed)
            Analytics.track(.podcastsScreenEpisodeGroupingChanged, properties: ["value": PodcastGrouping.unplayed])
        }
        optionPicker.addAction(action: unplayedAction)

        let seasonAction = OptionAction(label: L10n.season, selected: episodeGrouping == PodcastGrouping.season) { [weak self] in
            self?.setGroupingSetting(.season)
            Analytics.track(.podcastsScreenEpisodeGroupingChanged, properties: ["value": PodcastGrouping.season])
        }
        optionPicker.addAction(action: seasonAction)

        let starAction = OptionAction(label: L10n.statusStarred, selected: episodeGrouping == PodcastGrouping.starred) { [weak self] in
            self?.setGroupingSetting(.starred)
            Analytics.track(.podcastsScreenEpisodeGroupingChanged, properties: ["value": PodcastGrouping.starred])
        }
        optionPicker.addAction(action: starAction)

        return optionPicker
    }

    /// "Reset all filters" clears the search term too — the two things that can silently narrow
    /// a list at once. The picker resets the preset; this clears the field.
    @objc private func presetChanged() {
        updateInfoView()
        podcastDelegate?.episodesDidChange()
    }

    @objc func filtersWereReset() {
        guard let field = searchTextField, !(field.text ?? "").isEmpty else { return }
        field.text = ""
        textFieldDidChange()
    }

    func hideKeyboard() {
        searchTextField?.resignFirstResponder()
    }

    func searchDidComplete() {
        DispatchQueue.main.async { [weak self] in
            self?.handleSearchCompleted()
        }
    }

    func searchInProgress() -> Bool {
        searching
    }

    func searchBarActive() -> Bool {
        searchTextField?.isFirstResponder ?? false
    }

    /// Applies a preset's sort when the preset is selected — then the podcast's own sort control
    /// overrides it. The podcast page groups by its own taxonomy (season/status), which the preset's
    /// Group By (none/date/podcast/folder) doesn't map to, so only sort is applied here.
    func applyPresetSortAndGroup(_ preset: FilterPreset) {
        guard let raw = preset.sortOrder, let order = TriageTabSortOrder(rawValue: raw) else { return }
        let mapped: PodcastEpisodeSortOrder? = switch order {
        case .newestToOldest: .newestToOldest
        case .oldestToNewest: .oldestToNewest
        case .shortestToLongest: .shortestToLongest
        case .longestToShortest: .longestToShortest
        case .titleAtoZ: .titleAtoZ
        case .titleZtoA: .titleZtoA
        case .custom: nil
        }
        if let mapped { setSortSetting(mapped) }
    }

    private func setSortSetting(_ setting: PodcastEpisodeSortOrder) {
        guard let podcast = podcastDelegate?.displayedPodcast() else { return }
        podcast.episodeSortOrder = setting.old.rawValue
        DataManager.sharedManager.save(podcast: podcast)
        // Fork: the podcast's session lineup mirrors the page order.
        SessionManager.shared.reseedPodcastSession(for: podcast)

        NotificationCenter.postOnMainThread(notification: Constants.Notifications.podcastUpdated, object: podcast.uuid)
    }

    private func setGroupingSetting(_ setting: PodcastGrouping) {
        guard let podcast = podcastDelegate?.displayedPodcast() else { return }
        podcast.episodeGrouping = setting.rawValue
        DataManager.sharedManager.save(podcast: podcast)
        // Fork: the podcast's session lineup mirrors the page order.
        SessionManager.shared.reseedPodcastSession(for: podcast)

        NotificationCenter.postOnMainThread(notification: Constants.Notifications.podcastUpdated, object: podcast.uuid)
    }
}
