import PocketCastsDataModel
import PocketCastsUtils
import UIKit

class UpNextNowPlayingCell: ThemeableSwipeCell {
    override var themeOverride: Theme.ThemeType? {
        didSet {
            super.updateColor()
            episodeTitle.themeOverride = themeOverride
            dateLabel.themeOverride = themeOverride
            timeRemainingLabel.themeOverride = themeOverride
            roundedBackgroundView.themeOverride = themeOverride
            sessionInfoLabel?.themeOverride = themeOverride
        }
    }

    /// Fork: an optional metadata line rendered UNDER the card, matching the info line a normal
    /// session row shows (season/episode · duration). Only the fork's session surfaces use it; the
    /// Up Next tab never calls `setSessionInfoLine`, so the card there is unchanged.
    private var sessionInfoLabel: ThemeableLabel?

    /// Fork: the now-playing equalizer accent — green in the Session world, blue in Up Next.
    /// The title text keeps its regular colour (no accent).
    private var worldAccent: UIColor?
    func setNowPlayingAccent(_ color: UIColor) {
        worldAccent = color
        playingAnimationView.setFillColor(color)
        applyCardSurfaceColor()
        updatePlayPauseButton()
    }

    /// Fork: the card's background is tinted like the chooser cards — faint blue in the Up Next
    /// lineup, faint green in a session lineup (the world accent at 0.18, matching SessionListCell).
    /// Falls back to the neutral themed surface when no world accent is set (stock Up Next tab).
    private func applyCardSurfaceColor() {
        if let worldAccent {
            roundedBackgroundView.backgroundColor = worldAccent.withAlphaComponent(0.18)
            // A solid accent border round the active card — green (session) / blue (Up Next).
            roundedBackgroundView.layer.borderColor = worldAccent.cgColor
            roundedBackgroundView.layer.borderWidth = 1.5
            return
        }
        roundedBackgroundView.layer.borderWidth = 0
        let activeTheme = themeOverride ?? Theme.sharedTheme.activeTheme
        if activeTheme.isDark {
            roundedBackgroundView.style = .playerContrast06
        } else {
            roundedBackgroundView.style = activeTheme == .contrastLight ? .primaryUi05 : .primaryUi02
        }
    }

    func setSessionInfoLine(_ text: String?) {
        guard let text, !text.isEmpty else {
            sessionInfoLabel?.text = nil
            sessionInfoLabel?.isHidden = true
            return
        }

        if sessionInfoLabel == nil {
            let label = ThemeableLabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.style = .primaryText02
            label.font = UIFont.font(ofSize: 13, scalingWith: .footnote)
            label.numberOfLines = 1
            label.themeOverride = themeOverride
            contentView.addSubview(label)
            sessionInfoLabel = label

            // The card is pinned to the content view's bottom; break that so the card keeps its
            // intrinsic height and the cell grows to fit the info line beneath it.
            for constraint in contentView.constraints where
                (constraint.firstItem as? UIView) === contentView
                && constraint.firstAttribute == .bottom
                && (constraint.secondItem as? UIView) === roundedBackgroundView
                && constraint.secondAttribute == .bottom {
                constraint.isActive = false
            }

            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: roundedBackgroundView.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(lessThanOrEqualTo: roundedBackgroundView.trailingAnchor),
                label.topAnchor.constraint(equalTo: roundedBackgroundView.bottomAnchor, constant: 6),
                contentView.bottomAnchor.constraint(equalTo: label.bottomAnchor, constant: 10)
            ])
        }

        sessionInfoLabel?.text = text
        sessionInfoLabel?.isHidden = false
    }

    @IBOutlet var roundedBackgroundView: ThemeableView!

    @IBOutlet var progressView: UIView!

    @IBOutlet var podcastImage: PodcastImageView!
    @IBOutlet var dateLabel: ThemeableLabel! {
        didSet {
            dateLabel.style = .primaryText02
            dateLabel.font = UIFont.font(ofSize: 12, weight: .semibold, scalingWith: .caption1)
        }
    }

    @IBOutlet var downloadedIndicator: UIImageView!
    @IBOutlet var downloadingIndicator: UIActivityIndicatorView! {
        didSet {
            downloadingIndicator.transform = CGAffineTransform(scaleX: 0.75, y: 0.75)
        }
    }

    @IBOutlet var timeRemainingLabel: ThemeableLabel! {
        didSet {
            timeRemainingLabel.style = .primaryText02
            timeRemainingLabel.font = UIFont.font(ofSize: 13, scalingWith: .footnote)
        }
    }

    @IBOutlet var episodeTitle: ThemeableLabel! {
        didSet {
            episodeTitle.style = .primaryText01
            episodeTitle.font = UIFont.font(ofSize: 15, weight: .medium, scalingWith: .subheadline)
        }
    }

    @IBOutlet var disclosureImageView: UIImageView!

    @IBOutlet var playingAnimationView: NowPlayingAnimationView!

    @IBOutlet var progressViewWidthConstraint: NSLayoutConstraint!

    private var episode: BaseEpisode? = nil

    /// Fork: an explicit play/pause button on the now-playing card, sitting in front of the drag
    /// handle (the card is a reorderable row like the others). Replaces the plain disclosure chevron.
    private lazy var playPauseButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        return button
    }()

    override func awakeFromNib() {
        super.awakeFromNib()
        style = .primaryUi04

        // The card carries a real play/pause button (in place of the disclosure chevron); the drag
        // handle draws to its right when the row is reorderable.
        disclosureImageView.isHidden = true
        contentView.addSubview(playPauseButton)
        NSLayoutConstraint.activate([
            playPauseButton.trailingAnchor.constraint(equalTo: roundedBackgroundView.trailingAnchor, constant: -12),
            playPauseButton.centerYAnchor.constraint(equalTo: roundedBackgroundView.centerYAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 36),
            playPauseButton.heightAnchor.constraint(equalToConstant: 36)
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(progressUpdated), name: Constants.Notifications.playbackProgress, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updatePlayingAnimation), name: Constants.Notifications.playbackPaused, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updatePlayingAnimation), name: Constants.Notifications.playbackStarted, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateCellForDownloadProgressChange), name: Constants.Notifications.downloadProgress, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateCellForDownloadStatusChange(_:)), name: Constants.Notifications.episodeDownloaded, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateCellForDownloadStatusChange(_:)), name: Constants.Notifications.episodeDownloadStatusChanged, object: nil)

        updateSize()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// The world accent (green Session / blue Up Next) when the host sets one, else source-based.
    private var playingEqualizerColor: UIColor {
        if let worldAccent { return worldAccent }
        return PlaybackManager.shared.currentEpisodeIsSessionSourced
            ? ThemeColor.support02(for: themeOverride)
            : ThemeColor.support01(for: themeOverride)
    }

    func populateFrom(episode: BaseEpisode) {
        self.episode = DataManager.sharedManager.findBaseEpisode(uuid: episode.uuid) // this is a bit hacky, but we're likely to be passed the cached version here from the player, so reload it from the database to get the latest version with the correct download stats

        episodeTitle.text = episode.displayableTitle()

        if let episode = episode as? Episode {
            podcastImage.setPodcast(uuid: episode.podcastUuid, size: .list)
        } else if let episode = episode as? UserEpisode {
            podcastImage.setUserEpisode(uuid: episode.uuid, size: .list)
        }

        EpisodeDateHelper.setDate(episode: episode, on: dateLabel, tintColor: ThemeColor.primaryText02(for: themeOverride))

        if let dateText = dateLabel.text {
            dateLabel.accessibilityLabel = L10n.queueNowPlayingAccessibility(dateText)
        }
        progressUpdated(animated: false)
        updateDownloadStatus()
        // Green when the episode plays as part of a session, blue when it plays from Up Next.
        playingAnimationView.setFillColor(playingEqualizerColor)
    }

    @objc func progressUpdated(animated: Bool = true) {
        layoutIfNeeded()

        let duration: Double
        let currentTime: TimeInterval

        if let episode {
            duration = episode.duration
            currentTime = PlaybackManager.shared.currentTime()
        }
        else {
            duration = 1
            currentTime = 1
        }

        guard duration > 0, currentTime.isFinite else { return }

        let remaining = duration - currentTime
        timeRemainingLabel.text = L10n.queueTimeRemaining(TimeFormatter.shared.multipleUnitFormattedShortTime(time: remaining))

        let percentageLapsed = CGFloat(currentTime / duration)
        progressViewWidthConstraint.constant = percentageLapsed * roundedBackgroundView.frame.width

        // The equalizer only shows while actually playing — hidden (not just frozen) when paused/idle.
        playingAnimationView.animating = PlaybackManager.shared.playing()
        playingAnimationView.isHidden = !PlaybackManager.shared.playing()
        updatePlayPauseButton()

        updateDownloadStatus()

        if animated {
            UIView.animate(withDuration: 0.95) {
                self.layoutIfNeeded()
            }
        } else { layoutIfNeeded() }
    }

    @objc func updatePlayingAnimation() {
        playingAnimationView.animating = PlaybackManager.shared.playing()
        playingAnimationView.isHidden = !PlaybackManager.shared.playing()
        updatePlayPauseButton()
    }

    @objc private func playPauseTapped() {
        if PlaybackManager.shared.playing() {
            PlaybackManager.shared.pause()
        } else {
            PlaybackManager.shared.play()
        }
    }

    private func updatePlayPauseButton() {
        let playing = PlaybackManager.shared.playing()
        let config = UIImage.SymbolConfiguration(pointSize: 30, weight: .regular)
        playPauseButton.setImage(UIImage(systemName: playing ? "pause.circle" : "play.circle", withConfiguration: config), for: .normal)
        playPauseButton.tintColor = worldAccent ?? playingEqualizerColor
        playPauseButton.accessibilityLabel = playing ? L10n.pause : L10n.play
    }

    override func prepareForReuse() {
        progressViewWidthConstraint.constant = 0
        playingAnimationView.animating = false
    }

    override func handleThemeDidChange() {
        super.handleThemeDidChange()

        let activeTheme = themeOverride ?? Theme.sharedTheme.activeTheme

        // Rounded background — tinted with the world accent (chooser-card look) when one is set.
        applyCardSurfaceColor()

        // Progress view
        if activeTheme == .rosé {
            progressView.backgroundColor = AppTheme.colorForStyle(.primaryIcon02Selected, themeOverride: themeOverride).withAlphaComponent(0.1)
        } else if activeTheme.isDark {
            progressView.backgroundColor = AppTheme.colorForStyle(.playerContrast06, themeOverride: themeOverride).withAlphaComponent(0.1)
        } else {
            progressView.backgroundColor = .black.withAlphaComponent(0.1)
        }

        // Disclosure icon
        switch activeTheme {
        case .dark:
            disclosureImageView.backgroundColor = AppTheme.colorForStyle(.primaryInteractive02)
            disclosureImageView.tintColor = nil

        case .contrastLight, .contrastDark:
            disclosureImageView.backgroundColor = AppTheme.colorForStyle(.primaryInteractive01, themeOverride: themeOverride)
            disclosureImageView.tintColor = AppTheme.colorForStyle(.primaryInteractive02, themeOverride: themeOverride)

        default:
            disclosureImageView.backgroundColor = AppTheme.colorForStyle(.primaryUi05, themeOverride: themeOverride)
            disclosureImageView.tintColor = AppTheme.colorForStyle(.primaryInteractive01, themeOverride: themeOverride)
        }
        downloadingIndicator.color = AppTheme.colorForStyle(.primaryIcon01, themeOverride: themeOverride)
        playingAnimationView.setFillColor(playingEqualizerColor)
    }

    func updateDownloadStatus() {
        defer {
            setNeedsUpdateConstraints()
        }
        guard let episode else {
            downloadingIndicator.isHidden = true
            downloadedIndicator.isHidden = true
            return
        }
        if let episode = episode as? UserEpisode, episode.uploadStatus == UploadStatus.missing.rawValue {
            downloadingIndicator.isHidden = true
            downloadedIndicator.isHidden = true

            return
        }

        if episode.queued() {
            downloadingIndicator.stopAnimating()
            downloadingIndicator.isHidden = true
            downloadedIndicator.isHidden = true
        } else if episode.downloading() {
            if !downloadingIndicator.isAnimating {
                downloadingIndicator.startAnimating()
                downloadingIndicator.isHidden = false
                downloadedIndicator.isHidden = true
            }
        } else if episode.downloaded(pathFinder: DownloadManager.shared) {
            downloadingIndicator.stopAnimating()
            downloadingIndicator.isHidden = true
            downloadedIndicator.isHidden = false
        } else {
            downloadingIndicator.isHidden = true
            downloadedIndicator.isHidden = true
        }
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

    // MARK: - Dynamic Type Support

    private func updateSize() {
        let metric = UIFontMetrics(forTextStyle: .largeTitle)
        let imageSize = max(48, metric.scaledValue(for: 48))
        podcastImage.updateSizeConstraints(to: imageSize)

        let iconSize = max(16, metric.scaledValue(for: 16))
        downloadedIndicator.updateSizeConstraints(to: iconSize)
        downloadingIndicator.updateSizeConstraints(to: iconSize)

        let buttonSize = max(24, metric.scaledValue(for: 24))
        disclosureImageView.updateSizeConstraints(to: buttonSize)
        disclosureImageView.layer.cornerRadius = buttonSize / 2

        playingAnimationView.updateSizeConstraints(to: buttonSize)

        updateDownloadStatus()

        episodeTitle.updateNumberOfLines(regular: 1, accessibility: 3)
        dateLabel.updateNumberOfLines(regular: 1, accessibility: 2)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.preferredContentSizeCategory != previousTraitCollection?.preferredContentSizeCategory else { return }
        updateSize()
    }
}
