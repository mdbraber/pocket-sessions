import PocketCastsDataModel
import PocketCastsServer
import UIKit

class EpisodeCell: ThemeableSwipeCell, MainEpisodeActionViewDelegate {
    private static let playedAlpha: CGFloat = 0.5

    @IBOutlet var episodeImage: PodcastImageView!
    @IBOutlet var episodeTitle: ThemeableLabel! {
        didSet {
            episodeTitle.font = UIFont.font(ofSize: 15, weight: .medium, scalingWith: .subheadline)
        }
    }
    @IBOutlet var statusIndicator: UIImageView!
    @IBOutlet var uploadStatusIndicator: UIImageView!

    @IBOutlet var uploadProgressIndicator: ProgressPieView!
    @IBOutlet var upNextIndicator: UIImageView!

    @IBOutlet var leadingSpacerWidth: NSLayoutConstraint!
    @IBOutlet var selectTickHorizontalOffset: NSLayoutConstraint!
    @IBOutlet var selectCircleHorizontalOffset: NSLayoutConstraint!

    @IBOutlet var downloadingIndicator: UIActivityIndicatorView! {
        didSet {
            downloadingIndicator.transform = CGAffineTransform(scaleX: 0.75, y: 0.75)
        }
    }
    @IBOutlet var bookmarkIcon: UIImageView!

    @IBOutlet var informationLabel: ThemeableLabel! {
        didSet {
            informationLabel.style = .primaryText02
            informationLabel.font = UIFont.font(ofSize: 13, scalingWith: .footnote)
        }
    }

    @IBOutlet var bottomDivider: ThemeDividerView!
    @IBOutlet var bottomDividerHeightConstraint: NSLayoutConstraint! {
        didSet {
            bottomDividerHeightConstraint.constant = 1.0 / UIScreen.main.scale
        }
    }

    /// Fork: when true, `setEditing` leaves `shouldShowSelect` alone — the host drives the select
    /// control explicitly. Needed in the Up Next / session table, which is PERMANENTLY in editing mode
    /// (for drag reorder): UIKit re-calls `setEditing(true)` whenever a cell is re-inserted during a
    /// reorder, which would otherwise flash the select circle even when multi-select is off.
    var managesOwnSelectControl = false

    private var topDivider: ThemeDividerView?

    /// Shows a hairline divider along the top edge of the cell. Used by lists where the
    /// section header is transparent (Liquid Glass plain-style sticky headers) and can't
    /// host the divider itself.
    var showsTopDivider = false {
        didSet {
            guard showsTopDivider != oldValue else { return }
            if showsTopDivider, topDivider == nil {
                let divider = ThemeDividerView()
                divider.translatesAutoresizingMaskIntoConstraints = false
                contentView.addSubview(divider)
                NSLayoutConstraint.activate([
                    divider.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
                    divider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                    divider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                    divider.topAnchor.constraint(equalTo: contentView.topAnchor)
                ])
                topDivider = divider
            }
            topDivider?.isHidden = !showsTopDivider
        }
    }

    @IBOutlet var dayName: ThemeableLabel! {
        didSet {
            dayName.style = .primaryText02
            dayName.font = UIFont.font(ofSize: 11, weight: .semibold, scalingWith: .caption2)
        }
    }

    @IBOutlet var starIndicator: UIImageView! {
        didSet {
            starIndicator.image = EpisodeCell.starIndicatorImage(for: Theme.sharedTheme.activeTheme)
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

    private var lastAppliedTheme: Theme.ThemeType?
    private var lastAppliedSizeCategory: UIContentSizeCategory?

    @IBOutlet var videoIndicator: UIImageView!

    /// Fork: the equalizer bars marking the row that's sounding right now. Positioned like the
    /// Up Next now-playing card — trailing side, vertically centered, just before the action
    /// button. Purely a marker: the episode stays in the list (unlike the Up Next tab, which
    /// pulls the playing episode onto a dedicated Now Playing card).
    private lazy var nowPlayingIndicator: NowPlayingIndicatorView = {
        let view = NowPlayingIndicatorView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        return view
    }()

    private func setNowPlaying(_ nowPlaying: Bool) {
        if nowPlaying, nowPlayingIndicator.superview == nil {
            // Match the Up Next now-playing card: the equalizer sits on the trailing side, vertically
            // centered, just before the action button. Inserting it as a MEMBER of the main
            // (center-aligned) stack — rather than floating it — makes the stack reserve its width so
            // the title/info text shrinks to fit instead of running underneath it.
            if let stack = actionButton.superview as? UIStackView,
               let index = stack.arrangedSubviews.firstIndex(of: actionButton) {
                stack.insertArrangedSubview(nowPlayingIndicator, at: index)
                stack.setCustomSpacing(Self.equalizerToButtonGap, after: nowPlayingIndicator)
            } else {
                contentView.addSubview(nowPlayingIndicator)
                NSLayoutConstraint.activate([
                    nowPlayingIndicator.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -Self.equalizerToButtonGap),
                    nowPlayingIndicator.centerYAnchor.constraint(equalTo: actionButton.centerYAnchor)
                ])
            }
        }
        // Gap between the text block and the equalizer — only while the equalizer is shown, so
        // normal rows keep the text flush against the action button.
        if let stack = actionButton.superview as? UIStackView {
            stack.setCustomSpacing(nowPlaying ? 12 : 0, after: contentStackView)
        }
        // Green when the episode plays as part of a session, blue when it plays from Up Next.
        nowPlayingIndicator.color = PlaybackManager.shared.currentEpisodeIsSessionSourced ? ThemeColor.support02() : ThemeColor.support01()
        nowPlayingIndicator.isHidden = !nowPlaying
    }

    /// Fork: the gap between the now-playing equalizer and the trailing play/pause button.
    private static let equalizerToButtonGap: CGFloat = 10

    /// Fork: the rounded accent surface behind the ACTIVE (currently-playing) row — a faint tint
    /// (0.18) plus a solid 1.5pt border, blue in Up Next / green in a session. It replaces the old
    /// big now-playing card: the playing episode is a normal row now, just marked by this surface,
    /// the equalizer, and its action button showing pause. Nil accent = a plain row (no surface).
    private lazy var activeSurfaceView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.cornerRadius = 12
        view.layer.masksToBounds = true
        view.isUserInteractionEnabled = false
        return view
    }()

    /// Fork: the backdrop progress fill inside the active surface — a faint band covering the played
    /// fraction of the row, matching the now-playing card / overview row.
    private lazy var activeProgressView: UIView = {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }()

    private var activeSurfaceAccent: UIColor?
    private var activeProgressFraction: CGFloat = 0

    func setActiveSurface(accent: UIColor?, progress: CGFloat = 0) {
        activeSurfaceAccent = accent
        activeProgressFraction = max(0, min(1, progress))
        guard let accent else {
            activeSurfaceView.isHidden = true
            return
        }
        if activeSurfaceView.superview == nil {
            contentView.insertSubview(activeSurfaceView, at: 0)
            activeSurfaceView.addSubview(activeProgressView)
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
        // A slightly stronger band of the accent marks the played portion.
        let theme = themeOverride ?? Theme.sharedTheme.activeTheme
        activeProgressView.backgroundColor = theme.isDark ? UIColor.white.withAlphaComponent(0.08) : UIColor.black.withAlphaComponent(0.08)
        setNeedsLayout()
    }

    private func layoutActiveProgress() {
        guard !activeSurfaceView.isHidden, activeProgressView.superview != nil else { return }
        let w = activeSurfaceView.bounds.width * activeProgressFraction
        activeProgressView.frame = CGRect(x: 0, y: 0, width: w, height: activeSurfaceView.bounds.height)
    }
    @IBOutlet var actionButton: MainEpisodeActionView! {
        didSet {
            actionButton.delegate = self
        }
    }

    @IBOutlet var contentStackView: UIStackView!

    @IBOutlet var selectView: UIView!

    @IBOutlet var selectTickImageView: UIImageView! {
        didSet {
            selectTickImageView.backgroundColor = ThemeColor.primaryInteractive01()
            selectTickImageView.tintColor = ThemeColor.primaryInteractive02()
            selectTickImageView.layer.cornerRadius = 12
        }
    }

    @IBOutlet var selectCircleView: UIView! {
        didSet {
            selectCircleView.layer.borderColor = ThemeColor.primaryIcon02().cgColor
            selectCircleView.layer.borderWidth = 2
            selectCircleView.layer.cornerRadius = 12
        }
    }

    @IBOutlet weak var episodeImageLeadConstraint: NSLayoutConstraint!

    var hidesArtwork = false

    var playlist: AutoplayHelper.Playlist?

    /// Fork: when set (session lineup rows), the play button plays the episode AS part of this
    /// session — same as tapping the row — instead of standalone in Up Next.
    var playInSession: Session?

    /// Fork: when set (the Up Next session lineup), the play button routes here instead of the standard
    /// session play — the host moves the episode to the top of the lineup and makes it active.
    var onSessionLineupPlay: ((BaseEpisode) -> Void)?

    /// Fork: hide the play/download action button entirely (session lists play via tap, long-press,
    /// or the detail page, so the button is redundant clutter there).
    var hidesActionButton = false { didSet { setNeedsLayout() } }

    private var inUpNext = false
    private var playlistUuid: String?
    private var podcastUuid: String?
    private var listUuid: String?
    private var mainTintColor: UIColor? {
        didSet {
            actionButton.tintColor = playButtonTintOverride ?? mainTintColor
        }
    }

    /// Fork: forces the play/pause action button to a specific colour (white in the Up Next / session
    /// lineups) without recolouring the date/bookmark, which follow `mainTintColor`.
    var playButtonTintOverride: UIColor? {
        didSet {
            actionButton.tintColor = playButtonTintOverride ?? mainTintColor
        }
    }

    private var episode: BaseEpisode?

    private var isSelectableForMultiSelect: Bool {
        !(episode?.wasDeleted ?? false)
    }

    // MARK: - Setup

    override func awakeFromNib() {
        super.awakeFromNib()

        NotificationCenter.default.addObserver(self, selector: #selector(updateCellFromGenericEvent), name: Constants.Notifications.playbackStarted, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateCellFromGenericEvent), name: Constants.Notifications.playbackEnded, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateCellFromGenericEvent), name: Constants.Notifications.playbackPaused, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateCellFromGenericEvent), name: Constants.Notifications.playbackFailed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateCellFromGenericEvent), name: Constants.Notifications.googleCastStatusChanged, object: nil)

        NotificationCenter.default.addObserver(self, selector: #selector(downloadProgressDidUpdate), name: Constants.Notifications.downloadProgress, object: nil)

        // events that are specific to an episode
        NotificationCenter.default.addObserver(self, selector: #selector(updateCellFromSpecificEvent(_:)), name: Constants.Notifications.episodeDurationChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateCellFromSpecificEvent(_:)), name: Constants.Notifications.episodeStarredChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateCellFromSpecificEvent(_:)), name: Constants.Notifications.episodeDownloadStatusChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateCellFromSpecificEvent(_:)), name: ServerNotifications.episodeTypeOrLengthChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateCellFromSpecificEvent(_:)), name: Constants.Notifications.playbackPositionSaved, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateCellFromSpecificEvent(_:)), name: Constants.Notifications.episodePlayStatusChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateCellFromSpecificEvent(_:)), name: Constants.Notifications.episodeDownloaded, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateCellFromSpecificEvent(_:)), name: ServerNotifications.userEpisodeUploadStatusChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(uploadProgressDidUpdate), name: ServerNotifications.userEpisodeUploadProgress, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reloadArtwork(_:)), name: Constants.Notifications.userEpisodeUpdated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(upNextEpisodeChanged(_:)), name: Constants.Notifications.upNextEpisodeAdded, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(upNextEpisodeChanged(_:)), name: Constants.Notifications.upNextEpisodeRemoved, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(upNextQueueChanged), name: Constants.Notifications.upNextQueueChanged, object: nil)

        updateSize()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func setSelected(_ selected: Bool, animated: Bool) {}

    var isMultiSelectEnabled = false
    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(false, animated: animated)
        isMultiSelectEnabled = editing

        if !managesOwnSelectControl {
            shouldShowSelect = editing
        }
        if editing {
            hideSwipe(animated: true)
        } else {
            showTick = false
        }
        accessibilityLabel = labelForAccessibility(episode: episode)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutActiveProgress()

        // Workaround for iOS issue. When a table transitions to editing mode
        // it takes over hiding/showing views and sometimes the selectivew doesn't
        // appear.
        if selectView.isHidden == isMultiSelectEnabled {
            selectView.isHidden = !isMultiSelectEnabled
            setNeedsLayout()
        }
        let wasDeleted = episode?.wasDeleted ?? false
        let shouldHide = isMultiSelectEnabled || wasDeleted || hidesActionButton

        if actionButton.isHidden != shouldHide {
            actionButton.isHidden = shouldHide
            setNeedsLayout()
        }
    }

    // MARK: - Populate Method

    func populateFrom(episode: BaseEpisode, tintColor: UIColor?, playlistUuid: String? = nil, podcastUuid: String? = nil, listUuid: String? = nil) {
        self.episode = episode
        self.playlistUuid = playlistUuid
        self.podcastUuid = podcastUuid
        self.listUuid = listUuid
        mainTintColor = tintColor ?? ThemeColor.primaryIcon01()

        populate(progressOnly: false)
        updateSize()
    }


    /// Determines whether the bookmark indicator icon should appear
    private var showBookmarksIcon: Bool {
        PaidFeature.bookmarks.isUnlocked && episode?.hasBookmarks == true
    }

    private func populate(progressOnly: Bool) {
        guard let episode else { return }

        if !progressOnly {
            setEpisodeTitle(episode: episode)

            starIndicator.isHidden = !episode.keepEpisode
            // Treat episodes with a usable HLS stream (HLS feature enabled + valid HLS URL) as video, so
            // we show the video indicator without parsing the stream.
            videoIndicator.isHidden = !(episode.videoPodcast() || EpisodeManager.hasHLSStream(episode))
            videoIndicator.tintColor = ThemeColor.support01()
            setNowPlaying(PlaybackManager.shared.isNowPlayingEpisode(episodeUuid: episode.uuid))
            setUpNextIndicator(visible: PlaybackManager.shared.inUpNext(episode: episode), animated: false)
            upNextIndicator.tintColor = ThemeColor.support01()

            var uploadFailed = false
            if let userEpisode = episode as? UserEpisode {
                uploadStatusIndicator.isHidden = !userEpisode.uploaded()
                uploadFailed = userEpisode.uploadFailed()
            } else {
                uploadStatusIndicator.isHidden = true
            }

            // Since this calls out to the DB we'll cache the value here so later calls don't hit it again
            let showBookmarksIcon = self.showBookmarksIcon

            // Setup the bookmarks icon
            bookmarkIcon.image = UIImage(named: "bookmark-icon-episode")
            bookmarkIcon.tintColor = mainTintColor
            bookmarkIcon.isHidden = !showBookmarksIcon

            let hideStatus = !episode.archived && !episode.wasDeleted && !episode.downloaded(pathFinder: DownloadManager.shared) && !episode.downloadFailed() && !uploadFailed && !episode.playbackError()
            if !hideStatus {
                let statusImage: UIImage?
                if episode.downloadFailed() || uploadFailed || episode.playbackError() {
                    statusImage = UIImage(named: "profile-alert")
                } else if episode.downloaded(pathFinder: DownloadManager.shared) {
                    statusImage = UIImage(named: "list_downloaded")
                } else {
                    // To show the archive and bookmark indicator in the correct places we show the bookmark indicator
                    // in the status image, and move the archive icon into the bookmarks place.
                    if showBookmarksIcon {
                        statusImage = UIImage(named: "bookmark-icon-episode")?.tintedImage(mainTintColor ?? ThemeColor.primaryIcon02())
                        bookmarkIcon.image = UIImage(named: "list_archived")?.tintedImage(ThemeColor.primaryIcon02())
                    } else if episode.wasDeleted {
                        statusImage = UIImage(named: "option-cross-circle")?.tintedImage(ThemeColor.primaryIcon02())
                    } else if episode.archived {
                        statusImage = UIImage(named: "list_archived")?.tintedImage(ThemeColor.primaryIcon02())
                    } else {
                        statusImage = nil
                    }
                }
                statusIndicator.image = statusImage
            }
            statusIndicator.isHidden = hideStatus

            if hidesArtwork {
                if !episodeImage.isHidden {
                    episodeImage.isHidden = true
                }
                leadingSpacerWidth.constant = 8
                selectTickHorizontalOffset.constant = 0
                selectCircleHorizontalOffset.constant = 0
            } else {
                leadingSpacerWidth.constant = 12
                selectTickHorizontalOffset.constant = 4
                selectCircleHorizontalOffset.constant = 4

                if let userEpisode = episode as? UserEpisode {
                    episodeImage.setUserEpisode(uuid: userEpisode.uuid, size: .list)
                } else {
                    episodeImage.setPodcast(uuid: episode.parentIdentifier(), size: .list)
                }
            }

            if episode.played() || episode.archived || episode.wasDeleted {
                episodeImage.alpha = EpisodeCell.playedAlpha
                contentStackView.alpha = EpisodeCell.playedAlpha
            } else {
                episodeImage.alpha = 1
                contentStackView.alpha = 1
            }
        }

        inUpNext = PlaybackManager.shared.inUpNext(episode: episode)

        EpisodeDateHelper.setDate(episode: episode, on: dayName, tintColor: mainTintColor)

        if episode.wasDeleted {
            informationLabel.text = L10n.podcastUnavailable + " • " + episode.displayableInfo(includeSize: false)
        }
        else if episode.archived {
            informationLabel.text = L10n.podcastArchived + " • " + episode.displayableInfo(includeSize: false)
        } else if let userEpisode = episode as? UserEpisode {
            informationLabel.text = userEpisode.displayableInfo(includeSize: Settings.primaryRowAction() == .download)
        } else {
            informationLabel.text = episode.displayableInfo(includeSize: Settings.primaryRowAction() == .download)
        }

        if episode.downloading(), !downloadingIndicator.isAnimating {
            downloadingIndicator.startAnimating()
        } else if !episode.downloading(), downloadingIndicator.isAnimating {
            downloadingIndicator.stopAnimating()
        }

        if let userEpisode = episode as? UserEpisode {
            uploadProgressIndicator.isHidden = !(userEpisode.uploading() || userEpisode.uploadWaitingForWifi())
            if userEpisode.uploading() {
                if let progress = UploadManager.shared.progressManager.progressForEpisode(userEpisode.uuid) {
                    uploadProgressIndicator.progress = progress.percentageProgress()
                } else {
                    uploadProgressIndicator.progress = 0.1
                }
                uploadProgressIndicator.alpha = 1
            } else if userEpisode.uploadWaitingForWifi() {
                uploadProgressIndicator.progress = 0
                uploadProgressIndicator.alpha = 0.5
            }
        } else {
            uploadProgressIndicator.isHidden = true
        }

        if episode.wasDeleted {
            actionButton.isHidden = true
        } else {
            actionButton.isHidden = false
            actionButton.populateFrom(episode: episode)
        }

        updateMultiSelectAppearance()

        isAccessibilityElement = true
        accessibilityLabel = labelForAccessibility(episode: episode)
    }

    private func labelForAccessibility(episode: BaseEpisode?) -> String {
        guard let episode else { return "" }
        let heading = dayName.text?.replacingOccurrences(of: "•", with: ",") ?? ""
        let title = episodeTitle.text ?? ""
        let info = episode.accessibilityDisplayableInfo()

        var desc = [heading]

        // add the podcast name in place of the artwork, if it's showing
        if !hidesArtwork {
            desc.append(episode.subTitle())
        }

        desc.append(title)
        desc.append(info)

        if episode.downloaded(pathFinder: DownloadManager.shared) {
            desc.append(L10n.statusDownloaded)
        } else if episode.downloadFailed() {
            desc.append(episode.readableErrorMessage())
        } else if let playbackError = episode.playbackErrorDetails {
            desc.append(playbackError)
        }
        if episode.keepEpisode {
            desc.append(L10n.statusStarred)
        }
        if let userEpisode = episode as? UserEpisode, userEpisode.uploaded() {
            desc.append(L10n.statusUploaded)
        }
        if isMultiSelectEnabled {
            if showTick {
                desc.append(L10n.statusSelected)
            } else {
                desc.append(L10n.statusNotSelected)
            }
        }
        if unseenIndicatorVisible {
            desc.append(L10n.accessibilityInInbox)
        }
        if let sessionDescription = sessionIndicatorState.accessibilityLabel {
            desc.append(sessionDescription)
        }
        return desc.joined(separator: ". ")
    }

    private func setEpisodeTitle(episode: BaseEpisode) {
        guard let title = episode.title else {
            episodeTitle.text = nil

            return
        }

        // if there's no episode numbers make sure we still optimise the title
        if let episode = episode as? Episode, episode.episodeNumber < 1 {
            episodeTitle.text = episode.displayableTitle()

            return
        }

        episodeTitle.text = title
    }

    // MARK: - Event Handling

    @objc private func updateCellFromGenericEvent() {
        guard let episode else { return }

        updateCell(episodeUuid: episode.uuid)
    }

    @objc private func updateCellFromSpecificEvent(_ notification: Notification) {
        guard let episodeUuid = notification.object as? String, episodeUuid == episode?.uuid else {
            return
        }

        updateCell(episodeUuid: episodeUuid)
    }

    private func updateCell(episodeUuid: String) {
        guard let newEpisode = DataManager.sharedManager.findBaseEpisode(uuid: episodeUuid) else { return }

        if Thread.isMainThread {
            populateFrom(episode: newEpisode, tintColor: mainTintColor, playlistUuid: playlistUuid, podcastUuid: podcastUuid)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                self.populateFrom(episode: newEpisode, tintColor: self.mainTintColor, playlistUuid: self.playlistUuid, podcastUuid: self.podcastUuid)
            }
        }
    }

    @objc private func upNextEpisodeChanged(_ notification: Notification) {
        guard let episodeUuid = notification.object as? String, episodeUuid == episode?.uuid else { return }

        updateUpNextIndicator(animated: true)
    }

    @objc private func upNextQueueChanged() {
        // Bulk change with no specific episode, re-evaluate this cell against the queue
        updateUpNextIndicator(animated: true)
    }

    private func updateUpNextIndicator(animated: Bool) {
        guard let episode else { return }

        let isInUpNext = PlaybackManager.shared.inUpNext(episode: episode)
        inUpNext = isInUpNext
        setUpNextIndicator(visible: isInUpNext, animated: animated)
    }

    private func setUpNextIndicator(visible: Bool, animated: Bool) {
        let shouldHide = !visible

        guard animated, window != nil, upNextIndicator.isHidden != shouldHide else {
            upNextIndicator.isHidden = shouldHide
            upNextIndicator.alpha = 1
            upNextIndicator.transform = .identity
            return
        }

        let collapsedTransform = CGAffineTransform(scaleX: 0.1, y: 0.1)
        if visible {
            upNextIndicator.alpha = 0
            upNextIndicator.transform = collapsedTransform
            upNextIndicator.isHidden = false
            UIView.animate(withDuration: Constants.Animation.defaultAnimationTime, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState], animations: {
                self.upNextIndicator.alpha = 1
                self.upNextIndicator.transform = .identity
                self.contentView.layoutIfNeeded()
            })
        } else {
            UIView.animate(withDuration: Constants.Animation.defaultAnimationTime, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState], animations: {
                self.upNextIndicator.alpha = 0
                self.upNextIndicator.transform = collapsedTransform
                self.upNextIndicator.isHidden = true
                self.contentView.layoutIfNeeded()
            }, completion: { _ in
                self.upNextIndicator.alpha = 1
                self.upNextIndicator.transform = .identity
            })
        }
    }

    @objc private func downloadProgressDidUpdate() {
        guard let ourEpisode = episode, let _ = DownloadManager.shared.progressManager.progressForEpisode(ourEpisode.uuid) else { return }

        // if this episode isn't listed as downloading, update it from the DB
        if !ourEpisode.downloading() {
            episode = reloadEpisode()
        }

        populate(progressOnly: true)
    }

    @objc private func uploadProgressDidUpdate() {
        guard let ourEpisode = episode as? UserEpisode, let _ = UploadManager.shared.progressManager.progressForEpisode(ourEpisode.uuid) else { return }

        // if this episode isn't listed as uploading, update it from the DB
        if !ourEpisode.uploading() {
            episode = reloadEpisode()
        }

        if Thread.isMainThread {
            populate(progressOnly: true)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                self.populate(progressOnly: true)
            }
        }
    }

    @objc func reloadArtwork(_ notification: Notification) {
        guard let episodeUuid = notification.object as? String,
              episodeUuid == episode?.uuid,
              let userEpisode = episode as? UserEpisode else { return }
        episodeImage.setUserEpisode(uuid: userEpisode.uuid, size: .list)
    }

    // MARK: - MainEpisodeActionViewDelegate

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

        // if the user tapped play from a featured list, record that. We just want the first play, if they are unpausing it, that's not relevant (hence the last check below)
        if let podcastUuid, let listUuid, !PlaybackManager.shared.isNowPlayingEpisode(episodeUuid: episode.uuid) {
            AnalyticsHelper.podcastEpisodePlayedFromList(listId: listUuid, podcastUuid: podcastUuid)
        }

        // Fork: the Up Next session lineup routes play through the host so the episode moves to the
        // top and becomes the active (styled) item — matching how the queue pins its now-playing.
        if let onSessionLineupPlay {
            onSessionLineupPlay(episode)
            return
        }

        // Fork: on a session's lineup the play button joins the session rather than starting
        // standalone queue playback.
        if let playInSession {
            SessionManager.shared.play(episode: episode, in: playInSession)
            return
        }

        PlaybackActionHelper.play(episode: episode, playlistUuid: playlistUuid, podcastUuid: podcastUuid, playlist: playlist)
    }

    func pauseTapped() {
        PlaybackActionHelper.pause()
    }

    func errorTapped() {
        guard let episode else { return }

        if episode.playbackError() {
            let optionsPicker = OptionsPicker(title: nil)
            let retryAction = OptionAction(label: L10n.retry, icon: nil, action: { [weak self] in
                self?.playTapped()
            })

            optionsPicker.addDescriptiveActions(title: L10n.playbackFailed, message: episode.playbackErrorDetails, icon: "option-alert", actions: [retryAction])
            optionsPicker.present()
        } else {
            let downloadError = episode.readableErrorMessage()
            let optionsPicker = OptionsPicker(title: nil)
            let retryAction = OptionAction(label: L10n.retry, icon: nil, action: { [weak self] in
                self?.downloadTapped()
            })
            optionsPicker.addDescriptiveActions(title: L10n.downloadFailed, message: downloadError, icon: "option-alert", actions: [retryAction])
            optionsPicker.present()
        }
    }

    func waitingForWifiTapped() {
        guard let uuid = episode?.uuid else { return }

        PlaybackActionHelper.overrideWaitingForWifi(episodeUuid: uuid, autoDownloadStatus: .autoDownloaded)
    }

    override func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        false
    }

    private func reloadEpisode() -> BaseEpisode? {
        if let episode = episode as? Episode {
            return DataManager.sharedManager.findEpisode(uuid: episode.uuid)
        } else if let episode = episode as? UserEpisode {
            return DataManager.sharedManager.findUserEpisode(uuid: episode.uuid)
        }

        return nil
    }

    /// Fork: mini indicator — this episode is in the session of the page being viewed.
    /// Green, wearing the session glyph; lives next to the Up Next indicator.
    private lazy var sessionIndicator: UIImageView = {
        let imageView = UIImageView(image: UIImage(systemName: "rectangle.stack.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)))
        imageView.tintColor = ThemeColor.support02()
        imageView.setContentHuggingPriority(.required, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        return imageView
    }()

    /// Tracked so labelForAccessibility can speak the session badge; VoiceOver can't see the glyph.
    private var sessionIndicatorState: SessionIndicatorState = .none

    func setSessionIndicator(_ state: SessionIndicatorState) {
        if state.isVisible, sessionIndicator.superview == nil {
            if let stack = upNextIndicator.superview as? UIStackView, let index = stack.arrangedSubviews.firstIndex(of: upNextIndicator) {
                stack.insertArrangedSubview(sessionIndicator, at: index)
            } else if let superview = upNextIndicator.superview {
                superview.addSubview(sessionIndicator)
                sessionIndicator.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    sessionIndicator.trailingAnchor.constraint(equalTo: upNextIndicator.leadingAnchor, constant: -4),
                    sessionIndicator.centerYAnchor.constraint(equalTo: upNextIndicator.centerYAnchor)
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

    /// Fork: the unread dot — this episode is in the Inbox, i.e. you haven't looked at it yet.
    /// Accent-coloured, because a presence dot is the one badge that is allowed to be accent.
    private lazy var unseenIndicator: UIView = {
        let dot = UIView()
        dot.backgroundColor = ThemeColor.primaryInteractive01()
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8)
        ])
        dot.setContentHuggingPriority(.required, for: .horizontal)
        dot.setContentCompressionResistancePriority(.required, for: .horizontal)
        return dot
    }()

    /// Tracked so labelForAccessibility can speak the Inbox dot; VoiceOver can't see it.
    private var unseenIndicatorVisible = false

    /// Membership of the Inbox playlist is what this reflects — so callers must pass a value
    /// read from a Set fetched ONCE per list load. Never query membership per row.
    func setUnseenIndicator(visible: Bool) {
        if visible, unseenIndicator.superview == nil {
            if let stack = upNextIndicator.superview as? UIStackView, let index = stack.arrangedSubviews.firstIndex(of: upNextIndicator) {
                stack.insertArrangedSubview(unseenIndicator, at: index)
            } else if let superview = upNextIndicator.superview {
                superview.addSubview(unseenIndicator)
                NSLayoutConstraint.activate([
                    unseenIndicator.trailingAnchor.constraint(equalTo: upNextIndicator.leadingAnchor, constant: -4),
                    unseenIndicator.centerYAnchor.constraint(equalTo: upNextIndicator.centerYAnchor)
                ])
            }
        }
        unseenIndicator.backgroundColor = ThemeColor.primaryInteractive01()
        unseenIndicator.isHidden = !visible

        unseenIndicatorVisible = visible
        accessibilityLabel = labelForAccessibility(episode: episode)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        setNowPlaying(false)
        setActiveSurface(accent: nil)
        onSessionLineupPlay = nil
        playButtonTintOverride = nil

        unseenIndicator.isHidden = true
        unseenIndicatorVisible = false
        sessionIndicator.isHidden = true
        sessionIndicatorState = .none
        starIndicator.isHidden = true
        upNextIndicator.layer.removeAllAnimations()
        upNextIndicator.isHidden = true
        upNextIndicator.alpha = 1
        upNextIndicator.transform = .identity
        statusIndicator.isHidden = true
        uploadProgressIndicator.isHidden = true
        uploadStatusIndicator.isHidden = true
        playlistUuid = nil
        podcastUuid = nil
        showTick = false
        shouldShowSelect = false
        actionButton.isHidden = false

        updateSize()
    }

    // MARK: - Multi Select icons

    var shouldShowSelect = false {
        didSet {
            updateMultiSelectAppearance()
        }
    }

    var showTick = false {
        didSet {
            guard isSelectableForMultiSelect else {
                selectTickImageView.isHidden = true
                selectCircleView.layer.borderWidth = 2
                return
            }

            selectTickImageView.isHidden = !showTick
            selectCircleView.layer.borderWidth = showTick ? 0 : 2
            selectView.accessibilityLabel = showTick ? L10n.accessibilityDeselectEpisode : L10n.accessibilitySelectEpisode
            accessibilityLabel = labelForAccessibility(episode: episode)
            style = showTick ? .primaryUi02Selected : .primaryUi02
            updateColor()
        }
    }

    private func updateMultiSelectAppearance() {
        let isSelectable = isSelectableForMultiSelect
        selectView.isHidden = !shouldShowSelect || !isSelectable
        if isSelectable {
            actionButton.isHidden = shouldShowSelect || hidesActionButton
        }
    }

    // Handle theme change
    override func handleThemeDidChange() {
        let theme = themeOverride ?? Theme.sharedTheme.activeTheme
        guard lastAppliedTheme != theme else { return }
        lastAppliedTheme = theme

        selectCircleView.layer.borderColor = ThemeColor.primaryIcon02(for: theme).cgColor
        selectTickImageView.backgroundColor = ThemeColor.primaryInteractive01(for: theme)
        selectTickImageView.tintColor = ThemeColor.primaryInteractive02(for: theme)
        starIndicator.image = EpisodeCell.starIndicatorImage(for: theme)
    }

    private func updateSize() {
        let sizeCategory = traitCollection.preferredContentSizeCategory

        guard lastAppliedSizeCategory != sizeCategory else { return }
        lastAppliedSizeCategory = sizeCategory

        let metric = UIFontMetrics(forTextStyle: .largeTitle)
        let imageSize = max(56, metric.scaledValue(for: 56))
        episodeImage.updateSizeConstraints(to: imageSize)

        let buttonSize = max(44, metric.scaledValue(for: 44))
        actionButton.updateSizeConstraints(to: buttonSize)
        actionButton.enlargementScale = buttonSize / 44
        selectView.updateSizeConstraints(to: buttonSize)

        let iconSize = max(16, metric.scaledValue(for: 16))
        statusIndicator.updateSizeConstraints(to: iconSize)
        uploadStatusIndicator.updateSizeConstraints(to: iconSize)
        upNextIndicator.updateSizeConstraints(to: iconSize)
        bookmarkIcon.updateSizeConstraints(to: iconSize)
        starIndicator.updateSizeConstraints(to: iconSize)
        downloadingIndicator.updateSizeConstraints(to: iconSize)
        videoIndicator.updateSizeConstraints(to: iconSize)

        let tickSize = max(24, metric.scaledValue(for: 24))
        selectTickImageView.updateSizeConstraints(to: tickSize)
        selectCircleView.updateSizeConstraints(to: tickSize)
        selectTickImageView.layer.cornerRadius = tickSize / 2
        selectCircleView.layer.cornerRadius = tickSize / 2

        episodeTitle.updateNumberOfLines(regular: 2, accessibility: 3)
        dayName.updateNumberOfLines(regular: 1, accessibility: 3)
        informationLabel.updateNumberOfLines(regular: 1, accessibility: 3)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.preferredContentSizeCategory != previousTraitCollection?.preferredContentSizeCategory else { return }
        updateSize()
    }
}
