import PocketCastsDataModel
import SwipeCellKit
import UIKit

class PlayerCell: ThemeableSwipeCell {
    override var themeOverride: Theme.ThemeType? {
        didSet {
            super.updateColor()
            episodeTitle.themeOverride = themeOverride
            episodeInfo.themeOverride = themeOverride
            dayName.themeOverride = themeOverride
            dividerView.themeOverride = themeOverride
            starIndicator?.image = PlayerCell.starIndicatorImage(for: themeOverride ?? Theme.sharedTheme.activeTheme)
        }
    }

    @IBOutlet var podcastImage: PodcastImageView!
    @IBOutlet var episodeTitle: ThemeableLabel! {
        didSet {
            episodeTitle.style = .primaryText01
            episodeTitle.font = UIFont.font(ofSize: 15, weight: .medium, scalingWith: .subheadline)
        }
    }

    @IBOutlet var episodeInfo: ThemeableLabel! {
        didSet {
            episodeInfo.style = .primaryText02
            episodeInfo.font = UIFont.font(ofSize: 13, scalingWith: .footnote)
        }
    }

    @IBOutlet var downloadedIndicator: UIImageView!

    @IBOutlet var starIndicator: UIImageView! {
        didSet {
            starIndicator.image = PlayerCell.starIndicatorImage(for: themeOverride ?? Theme.sharedTheme.activeTheme)
        }
    }

    private static var starIndicatorImageCache: [Theme.ThemeType: UIImage] = [:]

    private static func starIndicatorImage(for theme: Theme.ThemeType) -> UIImage? {
        if let cached = starIndicatorImageCache[theme] {
            return cached
        }
        let image = UIImage(named: "list_starred")?.tintedImage(ThemeColor.support10(for: theme))
        starIndicatorImageCache[theme] = image
        return image
    }

    @IBOutlet var dayName: ThemeableLabel! {
        didSet {
            dayName.style = .primaryText02
            dayName.font = UIFont.font(ofSize: 11, weight: .semibold, scalingWith: .caption2)
        }
    }

    @IBOutlet var downloadingIndicator: UIActivityIndicatorView! {
        didSet {
            downloadingIndicator.transform = CGAffineTransform(scaleX: 0.75, y: 0.75)
        }
    }

    @IBOutlet var selectView: UIView! {
        didSet {
            selectView.layer.borderWidth = 0
            selectView.layer.cornerRadius = 12
        }
    }

    @IBOutlet var dividerView: ThemeableView! {
        didSet {
            dividerView.style = .primaryUi05
        }
    }

    @IBOutlet var bottomDividerHeightConstraint: NSLayoutConstraint! {
        didSet {
            bottomDividerHeightConstraint.constant = 1.0 / UIScreen.main.scale
        }
    }

    @IBOutlet var podcastImageToSelectViewConstraint: NSLayoutConstraint!
    @IBOutlet var selectViewLeadingConstraint: NSLayoutConstraint!
    @IBOutlet var selectTickImageView: UIImageView!

    var showTick = false {
        didSet {
            selectTickImageView.isHidden = !showTick
            selectView.backgroundColor = showTick ? AppTheme.colorForStyle(.primaryInteractive01, themeOverride: themeOverride) : AppTheme.colorForStyle(.primaryUi04, themeOverride: themeOverride)
            selectView.layer.borderWidth = showTick ? 0 : 2
            selectTickImageView.tintColor = AppTheme.colorForStyle(.primaryInteractive02, themeOverride: themeOverride)

            selectView.accessibilityLabel = showTick ? L10n.accessibilityDeselectEpisode : L10n.accessibilitySelectEpisode
        }
    }

    private var episode: BaseEpisode?

    override func awakeFromNib() {
        super.awakeFromNib()

        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: PlayerCell, _) in
            view.updateSize()
        }

        NotificationCenter.default.addObserver(self, selector: #selector(updateCellForDownloadProgressChange), name: Constants.Notifications.downloadProgress, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateCellForDownloadStatusChange(_:)), name: Constants.Notifications.episodeDownloaded, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateCellForDownloadStatusChange(_:)), name: Constants.Notifications.episodeDownloadStatusChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateCellForStarredChange(_:)), name: Constants.Notifications.episodeStarredChanged, object: nil)

        installPlayButton()
        updateSize()
    }

    override func addSubview(_ view: UIView) {
        super.addSubview(view)

        // The handle view (`UITableViewCellReorderControl`) is a subclass of UIControl
        // Add a gesture on it to detect when we're about to reorder
        guard (view as? UIControl) != nil, view.gestureRecognizers == nil else {
            return
        }

        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(didTouchHandle))
        gesture.minimumPressDuration = 0.1
        gesture.cancelsTouchesInView = false

        view.addGestureRecognizer(gesture)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func populateFrom(episode: BaseEpisode) {
        self.episode = episode

        episodeTitle.text = episode.displayableTitle()
        if let episode = episode as? Episode {
            podcastImage.setPodcast(uuid: episode.podcastUuid, size: .list)
        } else if let episode = episode as? UserEpisode {
            podcastImage.setUserEpisode(uuid: episode.uuid, size: .list)
        }
        updateDownloadStatus()
        updateStarStatus()

        EpisodeDateHelper.setDate(episode: episode, on: dayName, tintColor: ThemeColor.primaryText01(for: themeOverride))
        accessibilityLabel = labelForAccessibility(episode: episode)
        updatePlayButton()
    }

    private func updateStarStatus() {
        starIndicator.isHidden = !(episode?.keepEpisode ?? false)
    }

    private func labelForAccessibility(episode: BaseEpisode?) -> String {
        guard let episode else { return "" }
        let heading = dayName.text?.replacingOccurrences(of: "•", with: ",") ?? ""
        let title = episodeTitle.text ?? ""
        let subtitle = episode.subTitle()
        let info = episodeInfo.text ?? ""

        var desc = [heading, subtitle, title, info]
        if episode.keepEpisode {
            desc.append(L10n.statusStarred)
        }
        if episode.downloaded(pathFinder: DownloadManager.shared) {
            desc.append(L10n.statusDownloaded)
        } else if let playbackError = episode.playbackErrorDetails {
            desc.append(playbackError)
        }
        if upNextIndicatorVisible {
            desc.append(L10n.upNext)
        }
        if let sessionDescription = sessionIndicatorState.accessibilityLabel {
            desc.append(sessionDescription)
        }

        return desc.joined(separator: ". ")
    }

    @objc private func updateCellForDownloadProgressChange() {
        guard let ourEpisode = episode, let _ = DownloadManager.shared.progressManager.progressForEpisode(ourEpisode.uuid) else { return }

        if !ourEpisode.downloading() {
            episode = DataManager.sharedManager.findBaseEpisode(uuid: ourEpisode.uuid)
        }

        updateDownloadStatus()
    }

    @objc private func updateCellForDownloadStatusChange(_ notification: Notification) {
        // make sure this event is related to our episode
        guard let ourEpisode = episode, let uuid = notification.object as? String, ourEpisode.uuid == uuid else { return }

        // if it is, reload our episode so we get the latest status for it
        episode = DataManager.sharedManager.findBaseEpisode(uuid: ourEpisode.uuid)

        updateDownloadStatus()
    }

    @objc private func updateCellForStarredChange(_ notification: Notification) {
        // make sure this event is related to our episode
        guard let ourEpisode = episode, let uuid = notification.object as? String, ourEpisode.uuid == uuid else { return }

        // reload our episode so we get the latest starred status for it
        episode = DataManager.sharedManager.findBaseEpisode(uuid: ourEpisode.uuid)

        updateStarStatus()
    }

    func updateDownloadStatus() {
        guard let episode else {
            downloadingIndicator.isHidden = true
            downloadedIndicator.isHidden = true
            return
        }

        if let episode = episode as? UserEpisode, episode.uploadStatus == UploadStatus.missing.rawValue {
            episodeInfo.text = L10n.downloadErrorNotUploaded
            downloadingIndicator.isHidden = true
            downloadedIndicator.isHidden = true

            return
        }

        if episode.queued() {
            downloadingIndicator.stopAnimating()
            downloadingIndicator.isHidden = true
            downloadedIndicator.isHidden = true
            episodeInfo.text = episode.displayableInfo(includeSize: Settings.primaryRowAction() == .download)
        } else if episode.downloading() {
            if !downloadingIndicator.isAnimating {
                downloadingIndicator.startAnimating()
                downloadingIndicator.isHidden = false
                downloadedIndicator.isHidden = true
            }
            episodeInfo.text = episode.displayableInfo(includeSize: Settings.primaryRowAction() == .download)
        } else if episode.downloaded(pathFinder: DownloadManager.shared) {
            downloadingIndicator.stopAnimating()
            downloadingIndicator.isHidden = true
            downloadedIndicator.isHidden = false
            episodeInfo.text = episode.displayableTimeLeft()
        } else {
            downloadingIndicator.isHidden = true
            downloadedIndicator.isHidden = true
            episodeInfo.text = episode.displayableTimeLeft()
        }
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        // Show the reordering control but not the native selection view (editControl)
        // In iOS13+ the tableView is in editing mode but the cell is not
        super.setEditing(false, animated: animated)
    }

    /// Fork: mini indicator — this queued episode is also in a session's lineup.
    /// Green, wearing the session glyph, next to the download indicator.
    private lazy var sessionIndicator: UIImageView = {
        let imageView = UIImageView(image: UIImage(systemName: "rectangle.stack.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)))
        imageView.tintColor = ThemeColor.support02()
        imageView.setContentHuggingPriority(.required, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        return imageView
    }()

    /// Fork: the reverse indicator — this session row is also queued in Up Next.
    /// Stock orange queued glyph, same slot.
    private lazy var upNextMiniIndicator: UIImageView = {
        let imageView = UIImageView(image: UIImage(named: "list_upnext"))
        imageView.tintColor = ThemeColor.support01()
        imageView.setContentHuggingPriority(.required, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        return imageView
    }()

    /// Tracked so labelForAccessibility can speak the queued mark; VoiceOver can't see the glyph.
    private var upNextIndicatorVisible = false

    func setUpNextIndicator(visible: Bool) {
        if visible, upNextMiniIndicator.superview == nil {
            if let stack = downloadedIndicator.superview as? UIStackView, let index = stack.arrangedSubviews.firstIndex(of: downloadedIndicator) {
                stack.insertArrangedSubview(upNextMiniIndicator, at: index)
            } else if let superview = downloadedIndicator.superview {
                superview.addSubview(upNextMiniIndicator)
                upNextMiniIndicator.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    upNextMiniIndicator.trailingAnchor.constraint(equalTo: downloadedIndicator.leadingAnchor, constant: -4),
                    upNextMiniIndicator.centerYAnchor.constraint(equalTo: downloadedIndicator.centerYAnchor)
                ])
            }
        }
        upNextMiniIndicator.tintColor = ThemeColor.support01()
        upNextMiniIndicator.isHidden = !visible

        upNextIndicatorVisible = visible
        accessibilityLabel = labelForAccessibility(episode: episode)
    }

    /// Fork: the equalizer bars + accent title for the row that's sounding right now.
    private lazy var nowPlayingIndicator: NowPlayingIndicatorView = {
        let view = NowPlayingIndicatorView()
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        return view
    }()

    func setNowPlaying(_ nowPlaying: Bool) {
        if nowPlaying, nowPlayingIndicator.superview == nil {
            if let stack = downloadedIndicator.superview as? UIStackView, let index = stack.arrangedSubviews.firstIndex(of: downloadedIndicator) {
                stack.insertArrangedSubview(nowPlayingIndicator, at: index)
            } else if let superview = downloadedIndicator.superview {
                superview.addSubview(nowPlayingIndicator)
                nowPlayingIndicator.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    nowPlayingIndicator.trailingAnchor.constraint(equalTo: downloadedIndicator.leadingAnchor, constant: -4),
                    nowPlayingIndicator.centerYAnchor.constraint(equalTo: downloadedIndicator.centerYAnchor)
                ])
            }
        }
        // Green when the episode plays as part of a session, blue when it plays from Up Next.
        nowPlayingIndicator.color = PlaybackManager.shared.currentEpisodeIsSessionSourced
            ? ThemeColor.support02(for: themeOverride)
            : ThemeColor.support01(for: themeOverride)
        nowPlayingIndicator.isHidden = !nowPlaying
        // The title keeps its regular colour — only the equalizer marks the playing row.
        episodeTitle.style = .primaryText01
    }

    /// Fork: colour just the now-playing equalizer by the world the row is shown in (green Session /
    /// blue Up Next) — used by the Up Next world's session head row. The title stays unaccented.
    func setNowPlayingAccent(_ color: UIColor) {
        nowPlayingIndicator.color = color
    }

    // MARK: - Fork: action button + active surface (matches the session lineup rows)

    /// Fork: the SAME episode action control the session lineup rows use (play / pause / download),
    /// so the queue rows read identically. Sits at the trailing edge of the glyph stack.
    private lazy var actionButton: MainEpisodeActionView = {
        let view = MainEpisodeActionView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.delegate = self
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        // A disabled marker recognizer so `addSubview(_:)` below doesn't mistake this for the reorder
        // control (which it tags any gesture-less UIControl as).
        let marker = UITapGestureRecognizer()
        marker.isEnabled = false
        view.addGestureRecognizer(marker)
        return view
    }()

    /// Fork: the rounded accent surface behind the now-playing (active) row — tint + border, matching
    /// the session lineup's active row. Nil accent = a plain row.
    private lazy var activeSurfaceView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.cornerRadius = 12
        view.isUserInteractionEnabled = false
        return view
    }()

    private func installPlayButton() {
        guard actionButton.superview == nil, let stack = downloadedIndicator.superview as? UIStackView else { return }
        let size: CGFloat = max(44, UIFontMetrics(forTextStyle: .body).scaledValue(for: 44))
        actionButton.updateSizeConstraints(to: size)
        actionButton.enlargementScale = size / 44
        stack.addArrangedSubview(actionButton)
        stack.setCustomSpacing(8, after: downloadedIndicator)
    }

    /// Refreshes the action control from the current episode/playback state.
    func updatePlayButton() {
        guard let episode else { return }
        actionButton.tintColor = AppTheme.colorForStyle(.primaryIcon01, themeOverride: themeOverride)
        actionButton.populateFrom(episode: episode)
    }

    /// Styles the row as active (now-playing): rounded accent box + accent-tinted action button. Nil
    /// clears it back to a plain row with the standard action-button colour.
    func setActiveSurface(accent: UIColor?) {
        if let accent {
            if activeSurfaceView.superview == nil {
                contentView.insertSubview(activeSurfaceView, at: 0)
                NSLayoutConstraint.activate([
                    activeSurfaceView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
                    activeSurfaceView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
                    activeSurfaceView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
                    activeSurfaceView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2)
                ])
            }
            activeSurfaceView.isHidden = false
            activeSurfaceView.backgroundColor = accent.withAlphaComponent(0.18)
            activeSurfaceView.layer.borderColor = accent.cgColor
            activeSurfaceView.layer.borderWidth = 1.5
        } else {
            activeSurfaceView.isHidden = true
        }
    }

    /// Tracked so labelForAccessibility can speak the session badge; VoiceOver can't see the glyph.
    private var sessionIndicatorState: SessionIndicatorState = .none

    func setSessionIndicator(_ state: SessionIndicatorState) {
        if state.isVisible, sessionIndicator.superview == nil {
            if let stack = downloadedIndicator.superview as? UIStackView, let index = stack.arrangedSubviews.firstIndex(of: downloadedIndicator) {
                stack.insertArrangedSubview(sessionIndicator, at: index)
            } else if let superview = downloadedIndicator.superview {
                superview.addSubview(sessionIndicator)
                sessionIndicator.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    sessionIndicator.trailingAnchor.constraint(equalTo: downloadedIndicator.leadingAnchor, constant: -4),
                    sessionIndicator.centerYAnchor.constraint(equalTo: downloadedIndicator.centerYAnchor)
                ])
            }
        }
        if let image = state.indicatorImage {
            sessionIndicator.image = image
        }
        sessionIndicator.tintColor = state.tint ?? ThemeColor.support02()
        sessionIndicator.isHidden = !state.isVisible

        sessionIndicatorState = state
        accessibilityLabel = labelForAccessibility(episode: episode)
    }

    override func prepareForReuse() {
        super.prepareForReuse()

        sessionIndicator.isHidden = true
        sessionIndicatorState = .none
        upNextMiniIndicator.isHidden = true
        upNextIndicatorVisible = false
        nowPlayingIndicator.isHidden = true
        episodeTitle.style = .primaryText01
        showTick = false
        setActiveSurface(accent: nil)
        actionButton.isHidden = false
        setSelected(false, animated: false)
    }

    private func updateBgColor(_ color: UIColor) {
        contentView.backgroundColor = color
        backgroundColor = color
        accessoryView?.backgroundColor = color
    }

    func shouldShowSelect(show: Bool, animate: Bool) {
        // The action button gives way to the multi-select tick.
        actionButton.isHidden = show
        if animate {
            if show {
                selectView.layer.borderWidth = 2
                hideSwipe(animated: true)
            }
            contentView.layoutIfNeeded()
            UIView.animate(withDuration: Constants.Animation.defaultAnimationTime, animations: {
                self.selectViewLeadingConstraint.constant = show ? 16 : -24
                self.contentView.layoutIfNeeded()
            }, completion: { _ in
                if !show {
                    self.showTick = false
                    self.selectView.layer.borderWidth = 0
                    self.setHighlightedState(false)
                }
            })
        } else {
            selectViewLeadingConstraint.constant = show ? 16 : -24
            showTick = false
            selectView.layer.borderWidth = show ? 2 : 0
            if !show {
                setHighlightedState(false)
            }
        }
    }

    override func handleThemeDidChange() {
        selectView.layer.borderColor = AppTheme.colorForStyle(.primaryIcon02, themeOverride: themeOverride).cgColor
        selectView.backgroundColor = showTick ? AppTheme.colorForStyle(.primaryInteractive01, themeOverride: themeOverride) : AppTheme.colorForStyle(.primaryUi04, themeOverride: themeOverride)
        selectView.layer.borderWidth = showTick ? 0 : 2
        selectTickImageView.tintColor = AppTheme.colorForStyle(.primaryInteractive02, themeOverride: themeOverride)
        downloadingIndicator.color = AppTheme.colorForStyle(.primaryIcon01, themeOverride: themeOverride)
        // Update the reorder control color
        let activeTheme = themeOverride ?? Theme.sharedTheme.activeTheme
        starIndicator.image = PlayerCell.starIndicatorImage(for: activeTheme)
        overrideUserInterfaceStyle = activeTheme.isDark ? .dark : .light
    }

    private func updateSize() {
        let metric = UIFontMetrics(forTextStyle: .largeTitle)
        let imageSize = max(56, metric.scaledValue(for: 56))
        podcastImage.updateSizeConstraints(to: imageSize)

        let iconSize = max(16, metric.scaledValue(for: 16))
        downloadedIndicator.updateSizeConstraints(to: iconSize)
        downloadingIndicator.updateSizeConstraints(to: iconSize)
        starIndicator.updateSizeConstraints(to: iconSize)

        let tickSize = max(24, metric.scaledValue(for: 24))
        selectTickImageView.updateSizeConstraints(to: tickSize)
        selectTickImageView.layer.cornerRadius = tickSize / 2

        episodeTitle.updateNumberOfLines(regular: 2, accessibility: 3)
        dayName.updateNumberOfLines(regular: 1, accessibility: 2)
    }
}

// MARK: - Handle Tap Detection
private extension PlayerCell {
    @objc func didTouchHandle(gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            NotificationCenter.default.post(name: .tableViewReorderWillBegin, object: nil)
        case .ended, .cancelled:
            NotificationCenter.default.post(name: .tableViewReorderDidEnd, object: nil)
        default: break
        }
    }
}

// MARK: - Fork: the queue row's episode action button (play / pause / download)

extension PlayerCell: MainEpisodeActionViewDelegate {
    func downloadTapped() {
        guard let uuid = episode?.uuid else { return }
        PlaybackActionHelper.download(episodeUuid: uuid)
    }

    func stopDownloadTapped() {
        guard let uuid = episode?.uuid else { return }
        PlaybackActionHelper.stopDownload(episodeUuid: uuid)
    }

    func playTapped() {
        guard let episode else { return }
        // The queue plays standalone (unlike a session lineup row, which joins its session).
        AnalyticsPlaybackHelper.shared.currentSource = .upNext
        PlaybackActionHelper.play(episode: episode)
    }

    func pauseTapped() {
        PlaybackActionHelper.pause()
    }

    func errorTapped() {
        guard let episode else { return }
        let picker = OptionsPicker(title: nil)
        let isPlayback = episode.playbackError()
        let retry = OptionAction(label: L10n.retry, icon: nil) { [weak self] in
            isPlayback ? self?.playTapped() : self?.downloadTapped()
        }
        picker.addDescriptiveActions(title: isPlayback ? L10n.playbackFailed : L10n.downloadFailed,
                                     message: isPlayback ? episode.playbackErrorDetails : episode.readableErrorMessage(),
                                     icon: "option-alert", actions: [retry])
        picker.present()
    }

    func waitingForWifiTapped() {
        guard let uuid = episode?.uuid else { return }
        PlaybackActionHelper.overrideWaitingForWifi(episodeUuid: uuid, autoDownloadStatus: .autoDownloaded)
    }
}
