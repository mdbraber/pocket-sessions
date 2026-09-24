import AVFoundation
import AVKit
import MediaPlayer
import PocketCastsServer
import PocketCastsUtils
import UIKit

class VideoViewController: SimpleNotificationsViewController, AVPictureInPictureControllerDelegate, UIGestureRecognizerDelegate {
    var willAttachPlayer: (() -> Void)?
    var willDeattachPlayer: (() -> Void)?

    @IBOutlet var routePickerView: PCRoutePickerView! {
        didSet {
            routePickerView.tintColor = ThemeColor.contrast01(for: .extraDark)
            routePickerView.activeTintColor = ThemeColor.primaryIcon01Active(for: .extraDark)
            routePickerView.backgroundColor = UIColor.clear
        }
    }

    @IBOutlet var fillScreenBtn: UIButton!

    @IBOutlet var closeFileStackView: UIStackView!
    @IBOutlet var playPauseBtn: PlayPauseButton! {
        didSet {
            playPauseBtn.backgroundColor = UIColor.clear
            playPauseBtn.circleColor = UIColor.clear
            playPauseBtn.playButtonColor = ThemeColor.contrast01(for: .extraDark)
        }
    }

    @IBOutlet var skipForwardBtn: SkipButton! {
        didSet {
            skipForwardBtn.skipBack = false
            skipForwardBtn.longPressed = { [weak self] in
                self?.skipForwardLongPressed()
            }
        }
    }

    @IBOutlet var skipBackBtn: SkipButton! {
        didSet {
            skipBackBtn.skipBack = true
        }
    }

    @IBOutlet var timeSlider: TimeSlider! {
        didSet {
            timeSlider.delegate = self
            timeSlider.shouldPopupOnDrag = true
            timeSlider.topOffset = 0
            timeSlider.sidePadding = 38 as CGFloat
        }
    }

    @IBOutlet var timeElapsed: ThemeableLabel! {
        didSet {
            timeElapsed.style = .playerContrast02
            timeElapsed.font = UIFont.monospacedDigitSystemFont(ofSize: 14, weight: UIFont.Weight.medium)
        }
    }

    @IBOutlet var timeRemaining: ThemeableLabel! {
        didSet {
            timeRemaining.style = .playerContrast02
            timeRemaining.font = UIFont.monospacedDigitSystemFont(ofSize: 14, weight: UIFont.Weight.medium)
        }
    }

    var controlsDisabled = false
    var showHideTimer: Timer?
    var controlsShowing = true

    @IBOutlet var videoPlayerView: VideoPlayerView! {
        didSet {
            let doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(videoViewDoubleTapped))
            doubleTapGesture.numberOfTapsRequired = 2

            let tapGesture = UITapGestureRecognizer(target: self, action: #selector(videoViewTapped))
            tapGesture.numberOfTapsRequired = 1
            tapGesture.require(toFail: doubleTapGesture)

            let panGesture = UIPanGestureRecognizer(target: self, action: #selector(panGestureRecognizerHandler(_:)))
            panGesture.delegate = self
            videoPlayerView.addGestureRecognizer(doubleTapGesture)
            videoPlayerView.addGestureRecognizer(tapGesture)
            videoPlayerView.addGestureRecognizer(panGesture)
        }
    }

    @IBOutlet var pipButton: UIButton!

    @IBOutlet var airplayButton: UIButton!

    #if APPCLIP
    @IBOutlet var castButton: UIButton!
    #else
    @IBOutlet var castButton: PCGoogleCastButton!
    #endif

    private var pipController: AVPictureInPictureController?
    @IBOutlet var controlsOverlay: UIView! {
        didSet {
            let panGesture = UIPanGestureRecognizer(target: self, action: #selector(panGestureRecognizerHandler(_:)))
            panGesture.delegate = self
            controlsOverlay.addGestureRecognizer(panGesture)

            let tapGesture = UITapGestureRecognizer(target: self, action: #selector(videoViewTapped))
            controlsOverlay.addGestureRecognizer(tapGesture)
        }
    }

    /// Fork: while casting there is nothing to render locally — `GoogleCastPlayer` has no local
    /// player, so `attachPlayer()` sets `videoPlayerView.player = nil` and the surface is solid
    /// black. Unexplained, that reads as a broken screen. This chip sits over it and says where the
    /// video actually went.
    ///
    /// Deliberately a sibling of `controlsOverlay` rather than a child of it: the controls fade out
    /// after 3 seconds (see VideoViewController+Controls), and a black screen needs explaining most
    /// once the controls are gone.
    private lazy var castInfoView: UIView = {
        let container = UIStackView()
        container.axis = .horizontal
        container.alignment = .center
        container.spacing = 8
        container.isUserInteractionEnabled = false // taps belong to the video surface below
        container.translatesAutoresizingMaskIntoConstraints = false

        let icon = UIImageView(image: UIImage(named: "nav_cast_on")?.withRenderingMode(.alwaysTemplate))
        icon.tintColor = ThemeColor.contrast01(for: .extraDark)
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)

        container.addArrangedSubview(icon)
        container.addArrangedSubview(castInfoLabel)
        return container
    }()

    private lazy var castInfoLabel: UILabel = {
        let label = UILabel()
        // Matches the player's error banner: 14pt medium on the extra-dark contrast colour.
        label.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = ThemeColor.contrast01(for: .extraDark)
        label.textAlignment = .center
        label.numberOfLines = 2
        return label
    }()

    // MARK: - Chapters

    /// Fork: chapter title + "N of M" + previous/next, sitting above the scrubber inside
    /// `controlsOverlay` so it fades with the rest of the controls.
    ///
    /// The transport's skip buttons are left alone: chapters are an additional way to move, not a
    /// replacement, which is also how the Now Playing player treats them.
    private lazy var chapterBar: UIStackView = {
        let titleStack = UIStackView(arrangedSubviews: [chapterTitleLabel, chapterCounterLabel])
        titleStack.axis = .vertical
        titleStack.alignment = .center
        titleStack.spacing = 2

        let bar = UIStackView(arrangedSubviews: [chapterPrevButton, titleStack, chapterNextButton])
        bar.axis = .horizontal
        bar.alignment = .center
        bar.spacing = 16
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.isHidden = true
        return bar
    }()

    private lazy var chapterTitleLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = ThemeColor.contrast01(for: .extraDark)
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private lazy var chapterCounterLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        label.textColor = ThemeColor.contrast02(for: .extraDark)
        label.textAlignment = .center
        return label
    }()

    private lazy var chapterPrevButton = makeChapterButton(imageName: "chapter-skipbackwards", action: #selector(chapterPrevTapped))
    private lazy var chapterNextButton = makeChapterButton(imageName: "chapter-skipforward", action: #selector(chapterNextTapped))

    private func makeChapterButton(imageName: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(named: imageName)?.withRenderingMode(.alwaysTemplate), for: .normal)
        button.tintColor = ThemeColor.contrast01(for: .extraDark)
        button.addTarget(self, action: action, for: .touchUpInside)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }

    deinit {
        teardownPictureInPicturePlayback()
    }

    override var prefersStatusBarHidden: Bool {
        true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .black

        let skipBackAmount = Settings.skipBackTime
        skipBackBtn.skipAmount = skipBackAmount

        let skipFwdAmount = Settings.skipForwardTime
        skipForwardBtn.skipAmount = skipFwdAmount

        setupCastInfoView()
        setupChapterBar()
    }

    private func setupChapterBar() {
        controlsOverlay.addSubview(chapterBar)
        NSLayoutConstraint.activate([
            chapterBar.centerXAnchor.constraint(equalTo: timeSlider.centerXAnchor),
            chapterBar.bottomAnchor.constraint(equalTo: timeSlider.topAnchor, constant: -8),
            chapterBar.leadingAnchor.constraint(greaterThanOrEqualTo: controlsOverlay.leadingAnchor, constant: 24),
            chapterBar.trailingAnchor.constraint(lessThanOrEqualTo: controlsOverlay.trailingAnchor, constant: -24)
        ])
    }

    /// Mirrors the Now Playing player: the bar only exists when the episode actually has chapters,
    /// and the arrows are disabled at the ends rather than wrapping.
    private func updateChapterBar() {
        let chapterCount = PlaybackManager.shared.chapterCount()
        guard chapterCount > 0, let visible = PlaybackManager.shared.currentChapters().visibleChapter else {
            chapterBar.isHidden = true
            return
        }
        chapterBar.isHidden = false
        let title = PlaybackManager.shared.currentChapters().title
        chapterTitleLabel.text = title.isEmpty ? PlaybackManager.shared.currentEpisode()?.displayableTitle() : title
        chapterCounterLabel.text = L10n.playerChapterCount((visible.index + 1).localized(), chapterCount.localized())
        chapterPrevButton.isEnabled = !visible.isFirst
        chapterNextButton.isEnabled = !visible.isLast
        chapterPrevButton.alpha = visible.isFirst ? 0.4 : 1
        chapterNextButton.alpha = visible.isLast ? 0.4 : 1
    }

    @objc private func chapterPrevTapped() {
        if PlaybackManager.shared.playing() { startHideControlsTimer() }
        PlaybackManager.shared.trackChapterEvent(.playerPreviousChapterTapped)

        #if !APPCLIP
        // Generated chapters carry reference-timeline starts that dynamic ads have shifted, so
        // resolve the real position by fingerprinting first — the same route the Now Playing
        // player and the chapters list take. Seeking to the raw start would land in the wrong place.
        if GeneratedChapterSeeker.isEnabled, let previous = PlaybackManager.shared.previousPlayableChapter() {
            PlaybackManager.shared.trackChapterSkippedIfNeeded(to: previous)
            GeneratedChapterSeeker.seek(to: previous, startPlayback: false)
            return
        }
        #endif

        PlaybackManager.shared.skipToPreviousChapter()
    }

    @objc private func chapterNextTapped() {
        if PlaybackManager.shared.playing() { startHideControlsTimer() }
        PlaybackManager.shared.trackChapterEvent(.playerNextChapterTapped)

        #if !APPCLIP
        if GeneratedChapterSeeker.isEnabled {
            guard let next = PlaybackManager.shared.nextPlayableChapter() else {
                // No next chapter — respect the producer's end of the last one, as
                // `skipToNextChapter` does. Not a chapter start, so nothing to resolve.
                PlaybackManager.shared.skipToEndOfLastChapter()
                return
            }
            PlaybackManager.shared.trackChapterSkippedIfNeeded(to: next)
            GeneratedChapterSeeker.seek(to: next, startPlayback: false)
            return
        }
        #endif

        PlaybackManager.shared.skipToNextChapter()
    }

    /// Adds the casting chip ABOVE `controlsOverlay`, so hiding the controls leaves it in place.
    private func setupCastInfoView() {
        view.addSubview(castInfoView)
        view.bringSubviewToFront(castInfoView)
        NSLayoutConstraint.activate([
            castInfoView.centerXAnchor.constraint(equalTo: videoPlayerView.centerXAnchor),
            castInfoView.centerYAnchor.constraint(equalTo: videoPlayerView.centerYAnchor),
            castInfoView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            castInfoView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
        updateCastInfoView()
    }

    /// Casting is the only state where the local surface is black on purpose, so the chip's
    /// visibility tracks it exactly. Refreshed from `update()` (which the googleCastStatusChanged
    /// observer drives) and from `attachPlayer()`, the two moments the surface can change.
    private func updateCastInfoView() {
        let casting = GoogleCastManager.sharedManager.connectedOrConnectingToDevice()
        castInfoView.isHidden = !casting
        guard casting else { return }
        let device = GoogleCastManager.sharedManager.connectedDevice()?.friendlyName ?? L10n.chromecastUnnamedDevice
        castInfoLabel.text = L10n.videoPlayingOnDevice(device)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        attachPlayer()

        update()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        addUiNotificationObservers()
        if PlaybackManager.shared.playing() {
            startHideControlsTimer()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        willDeattachPlayer?()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        videoPlayerView.player = nil
        removeAllCustomObservers()
    }

    // MARK: - Actions

    @IBAction func closeTapped(_ sender: Any) {
        dismiss(animated: true, completion: nil)
    }

    @IBAction func fillScreenTapped(_ sender: Any) {
        toggleFillScreen()
    }

    @IBAction func skipBackTapped(_ sender: Any) {
        if PlaybackManager.shared.playing() { startHideControlsTimer() }

        PlaybackManager.shared.skipBack()
    }

    @IBAction func playPauseTapped(_ sender: Any) {
        let currentlyPlaying = PlaybackManager.shared.playing()
        HapticsHelper.triggerPlayPauseHaptic()
        if currentlyPlaying {
            PlaybackManager.shared.pause()
            stopHideControlsTimer()
        } else {
            PlaybackManager.shared.play()
            startHideControlsTimer()
        }
    }

    @IBAction func skipForwardTapped(_ sender: Any) {
        if PlaybackManager.shared.playing() { startHideControlsTimer() }
        PlaybackManager.shared.skipForward()
    }

    private func skipForwardLongPressed() {
        guard let episode = PlaybackManager.shared.currentEpisode() else { return }

        let options = OptionsPicker(title: nil, themeOverride: .dark)

        let markPlayedOption = OptionAction(label: L10n.markPlayedShort, icon: nil) {
            AnalyticsEpisodeHelper.shared.currentSource = .videoPlayerSkipForwardLongPress
            EpisodeManager.markAsPlayed(episode: episode, fireNotification: true)
        }
        options.addAction(action: markPlayedOption)

        if PlaybackManager.shared.queue.upNextCount() > 0 {
            let skipToNextAction = OptionAction(label: L10n.nextEpisode, icon: nil) {
                let currentlyPlayingEpisode = PlaybackManager.shared.currentEpisode()
                PlaybackManager.shared.removeIfPlayingOrQueued(episode: currentlyPlayingEpisode, fireNotification: true, userInitiated: true)
            }
            options.addAction(action: skipToNextAction)
        }

        options.present(from: self)
    }

    // MARK: - Picture In Picture

    @IBAction func pictureInPictureTapped(_ sender: Any) {
        guard let pipController else { return }

        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else {
            pipController.startPictureInPicture()
        }
    }

    private func setupPictureInPicturePlayback() {
        if let videoPlayerView, AVPictureInPictureController.isPictureInPictureSupported() {
            pipController = AVPictureInPictureController(playerLayer: videoPlayerView.playerLayer)
            pipController?.delegate = self
            pipButton.isHidden = false
        } else {
            pipButton.isHidden = true
        }
    }

    private func teardownPictureInPicturePlayback() {
        if let pipController {
            pipController.delegate = nil
        }

        pipController = nil
    }

    // MARK: - AVPictureInPictureControllerDelegate

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        disableControls()
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        enableControls()
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        print("PiP Did Fail")
    }

    // MARK: - Event Handling

    private func addUiNotificationObservers() {
        addCustomObserver(Constants.Notifications.playbackProgress, selector: #selector(progressUpdated))
        addCustomObserver(Constants.Notifications.playbackStarted, selector: #selector(update))
        addCustomObserver(Constants.Notifications.videoPlaybackEngineSwitched, selector: #selector(videoPlaybackEngineSwitched))
        addCustomObserver(Constants.Notifications.playbackPaused, selector: #selector(update))
        addCustomObserver(Constants.Notifications.playbackEnded, selector: #selector(playbackFinished))
        addCustomObserver(Constants.Notifications.playbackTrackChanged, selector: #selector(trackChanged))
        addCustomObserver(Constants.Notifications.googleCastStatusChanged, selector: #selector(update))
        // Chapters arrive asynchronously (file parse + remote fetch) and change as playback moves.
        addCustomObserver(Constants.Notifications.podcastChaptersDidUpdate, selector: #selector(update))
        addCustomObserver(Constants.Notifications.podcastChapterChanged, selector: #selector(update))
    }

    private func removeUiNotificationObservers() {
        removeAllCustomObservers()
    }

    @objc private func playbackFinished() {
        dismiss(animated: true, completion: nil)
    }

    @objc private func progressUpdated() {
        if timeSlider.isScrubbing() || PlaybackManager.shared.isSeeking() { return }

        updateUpTo(upTo: PlaybackManager.shared.currentTime(), duration: PlaybackManager.shared.duration(), moveSlider: true)
    }

    @objc private func trackChanged() {
        guard PlaybackManager.shared.currentEpisode() != nil, PlaybackManager.shared.isCurrentEpisodeVideo() else {
            dismiss(animated: true, completion: nil)
            return
        }

        // if we're on a different video we need to attach the new player, the old will most likely have been replaced in the transition
        attachPlayer()
        update()
    }

    @objc private func videoPlaybackEngineSwitched() {
        // grab the new player and attach it
        attachPlayer()
        update()
    }

    // MARK: - Updates

    @objc private func update() {
        updatePlayPauseButton()
        progressUpdated()
        updateFillScreenBtn()
        updateCastInfoView()
        updateChapterBar()
    }

    private func updateFillScreenBtn() {
        let imageName = videoPlayerView.gravity == .resizeAspect ? "video-expand" : "video-collapse"
        fillScreenBtn.setImage(UIImage(named: imageName), for: .normal)
    }

    private func updatePlayPauseButton() {
        playPauseBtn.isPlaying = PlaybackManager.shared.playing()
    }

    func updateUpTo(upTo: TimeInterval, duration: TimeInterval, moveSlider: Bool) {
        let remaining = max(0, duration - upTo)
        updateTimeLabels(upTo: upTo, remaining: remaining)

        if moveSlider {
            timeSlider.totalDuration = duration
            timeSlider.currentTime = upTo
        }
    }

    private func attachPlayer() {
        willAttachPlayer?()
        videoPlayerView.player = PlaybackManager.shared.internalPlayerForVideoPlayback()
        setupPictureInPicturePlayback()
        // A nil player here IS the black surface — keep the explanation in step with it.
        updateCastInfoView()
    }

    private func updateTimeLabels(upTo: TimeInterval, remaining: TimeInterval) {
        timeElapsed.text = TimeFormatter.shared.playTimeFormat(time: upTo)
        timeRemaining.text = "-\(TimeFormatter.shared.playTimeFormat(time: remaining))"
    }

    func toggleFillScreen() {
        videoPlayerView.gravity = videoPlayerView.gravity == .resizeAspect ? .resizeAspectFill : .resizeAspect
        updateFillScreenBtn()
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        true
    }

    // MARK: - Orientation

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .allButUpsideDown
    }

    // MARK: - Swipe to close

    // The closeOverlay and controlOverlay are anchored to the safe area
    // when we move the view the overlays flicker
    // To prevent this, anchor to the view instead of the safe area
    var initialTouchPoint = CGPoint.zero

    private static let pullDownThreshold: CGFloat = 100

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if timeSlider.isScrubbing() { return false }

        guard let recognizer = gestureRecognizer as? UIPanGestureRecognizer else { return true }

        let velocity = recognizer.velocity(in: view)
        let vertical = abs(velocity.y) > abs(velocity.x)

        if !vertical { return false }

        return velocity.y > 0 // we are only looking for swipe down gestures
    }

    @IBOutlet var closeToViewTopConstraint: NSLayoutConstraint!
    @IBOutlet var closeToSafeTopConstraint: NSLayoutConstraint!

    @IBAction func panGestureRecognizerHandler(_ sender: UIPanGestureRecognizer) {
        let touchPoint = sender.location(in: view?.window)

        if sender.state == UIGestureRecognizer.State.began {
            initialTouchPoint = touchPoint

            closeToViewTopConstraint.constant = closeFileStackView.frame.minY
            closeToSafeTopConstraint.isActive = false
            closeToViewTopConstraint.isActive = true
        } else if sender.state == UIGestureRecognizer.State.changed {
            if touchPoint.y - initialTouchPoint.y > 0 {
                view.frame = CGRect(x: 0, y: touchPoint.y - initialTouchPoint.y, width: view.frame.size.width, height: view.frame.size.height)
            }
        } else if sender.state == UIGestureRecognizer.State.ended || sender.state == UIGestureRecognizer.State.cancelled {
            if touchPoint.y - initialTouchPoint.y > VideoViewController.pullDownThreshold {
                videoPlayerView.isHidden = true
                dismiss(animated: true, completion: nil)
            } else {
                UIView.animate(withDuration: 0.3, animations: {
                    self.view.frame = CGRect(x: 0, y: 0, width: self.view.frame.size.width, height: self.view.frame.size.height)
                }, completion: { (_: Bool) in
                    self.view.frame = CGRect(x: 0, y: 0, width: self.view.frame.size.width, height: self.view.frame.size.height)
                    self.closeToSafeTopConstraint.isActive = true
                    self.closeToViewTopConstraint.isActive = false
                })
            }
        }
    }
}
