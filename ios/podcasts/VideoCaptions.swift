import AVFoundation
import PocketCastsServer
import PocketCastsUtils
import UIKit

/// Fork: captions for the video player, from two sources.
///
/// - Caption tracks carried by the video. `AVPlayerLayer` draws a selected track itself, in the
///   user's system caption style, so this only chooses the track.
/// - The episode transcript, drawn here as a caption line over the video. Most podcast videos carry
///   no caption track, but many episodes have a transcript.
///
/// The choice is remembered across episodes (`Settings.videoCaptionChoice`) and applied to each new
/// episode by `DefaultPlayer`. Choosing a caption track when the video has none falls back to the
/// transcript, so "captions on" shows whatever the episode has.
@MainActor
final class VideoCaptions {
    /// Called whenever what the captions menu offers, or what it has selected, changes.
    var stateChanged: (() -> Void)?

    private weak var playerView: VideoPlayerView?

    private var captionItem: AVPlayerItem?
    private var captionGroup: AVMediaSelectionGroup?
    /// Whether the current item's caption tracks have finished loading. Until they have, an
    /// embedded choice can't fall back to the transcript: the video may yet turn out to have tracks.
    private var captionTracksLoaded = false

    #if !APPCLIP
    private var transcript: TranscriptModel?
    /// Generated transcripts are timed against the episode without dynamic ads, so they need the
    /// fingerprint mapping to line up. Publisher transcripts use the playback time as is.
    private var transcriptIsGenerated = false
    private var transcriptEpisodeUuid: String?
    private var transcriptTask: Task<Void, Never>?
    private var cachedCueIndex = 0
    private var displayLink: CADisplayLink?
    #endif

    /// Sits over the video, below the controls. Hidden whenever there's no line to show.
    private(set) lazy var transcriptCaptionView: UIView = {
        let container = UIView()
        container.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        container.layer.cornerRadius = 6
        container.isUserInteractionEnabled = false // taps belong to the video surface below
        container.isHidden = true
        container.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(transcriptCaptionLabel)
        NSLayoutConstraint.activate([
            transcriptCaptionLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            transcriptCaptionLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            transcriptCaptionLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            transcriptCaptionLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10)
        ])
        return container
    }()

    private lazy var transcriptCaptionLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 3
        label.lineBreakMode = .byTruncatingHead // a long cue keeps its newest words
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    init(playerView: VideoPlayerView) {
        self.playerView = playerView
    }

    deinit {
        #if !APPCLIP
        displayLink?.invalidate()
        transcriptTask?.cancel()
        #endif
    }

    // MARK: - Menu

    /// Whether there is anything to choose between.
    var hasCaptions: Bool {
        !captionTracks.isEmpty || hasTranscriptCaptions
    }

    /// Whether captions of either kind are showing, for the button's on state.
    var isShowingCaptions: Bool {
        selectedTrack != nil || showsTranscript
    }

    func makeMenu() -> UIMenu {
        let selected = selectedTrack
        let showingTranscript = showsTranscript

        var actions = [UIAction(title: L10n.off, state: selected == nil && !showingTranscript ? .on : .off) { [weak self] _ in
            self?.choose(.off)
        }]
        for option in captionTracks {
            actions.append(UIAction(title: option.displayName, state: option == selected ? .on : .off) { [weak self] _ in
                self?.choose(.embedded(languageTag: option.extendedLanguageTag))
            })
        }
        if hasTranscriptCaptions {
            actions.append(UIAction(title: L10n.videoCaptionsFromTranscript, state: showingTranscript ? .on : .off) { [weak self] _ in
                self?.choose(.transcript)
            })
        }
        return UIMenu(title: L10n.videoCaptions, options: .singleSelection, children: actions)
    }

    private func choose(_ choice: VideoCaptionChoice) {
        Settings.videoCaptionChoice = choice
        if let captionItem, let captionGroup {
            captionItem.select(DefaultPlayer.captionOption(for: choice, in: captionGroup), in: captionGroup)
        }
        transcriptChoiceChanged()
        stateChanged?()
    }

    // MARK: - Loading

    /// Picks up the current player item and episode. Call whenever the attached player may have
    /// changed; it does nothing when neither did.
    func reload() {
        loadCaptionTracks()
        #if !APPCLIP
        loadTranscript()
        #endif
    }

    private func loadCaptionTracks() {
        let item = playerView?.player?.currentItem
        guard item !== captionItem else { return }

        captionItem = item
        captionGroup = nil
        captionTracksLoaded = false
        transcriptChoiceChanged()
        stateChanged?()

        guard let item else { return }
        Task { [weak self] in
            let group = try? await item.asset.loadMediaSelectionGroup(for: .legible)
            guard let self, self.captionItem === item else { return }
            self.captionGroup = group
            self.captionTracksLoaded = true
            self.transcriptChoiceChanged()
            self.stateChanged?()
        }
    }

    private var captionTracks: [AVMediaSelectionOption] {
        captionGroup.map(DefaultPlayer.captionOptions(in:)) ?? []
    }

    private var selectedTrack: AVMediaSelectionOption? {
        guard let captionItem, let captionGroup else { return nil }
        return captionItem.currentMediaSelection.selectedMediaOption(in: captionGroup)
    }

    // MARK: - Transcript captions

    #if APPCLIP
    private var hasTranscriptCaptions: Bool { false }
    private var showsTranscript: Bool { false }
    private func transcriptChoiceChanged() {}
    func updateTranscriptCaption() {}
    #else
    private var hasTranscriptCaptions: Bool {
        transcript != nil
    }

    private var showsTranscript: Bool {
        guard hasTranscriptCaptions else { return false }
        switch Settings.effectiveVideoCaptionChoice {
        case .off:
            return false
        case .transcript:
            return true
        case .embedded:
            return captionTracksLoaded && captionTracks.isEmpty
        }
    }

    /// Generated transcripts are a paid feature and only line up through the fingerprint mapping,
    /// so they're offered on the same terms as the synced transcript view.
    private static var canUseGeneratedTranscript: Bool {
        guard FeatureFlag.syncedTranscripts.enabled else { return false }
        let needsUpgrade = FeatureFlag.generatedTranscripts.enabled && (!SubscriptionHelper.hasActiveSubscription() || !SyncManager.isUserLoggedIn())
        return !needsUpgrade
    }

    private func loadTranscript() {
        guard let episode = PlaybackManager.shared.currentEpisode else { return }
        guard episode.uuid != transcriptEpisodeUuid else { return }

        let episodeUuid = episode.uuid
        transcriptEpisodeUuid = episodeUuid
        transcript = nil
        cachedCueIndex = 0
        transcriptTask?.cancel()
        transcriptChoiceChanged()
        stateChanged?()

        let manager = TranscriptManager(episodeUUID: episodeUuid, podcastUUID: episode.parentIdentifier())
        transcriptTask = Task { [weak self] in
            guard let model = try? await manager.loadTranscript(), !model.cues.isEmpty else { return }
            let isGenerated = manager.isDisplayingGeneratedTranscript
            guard let self, !Task.isCancelled, self.transcriptEpisodeUuid == episodeUuid else { return }
            guard !isGenerated || Self.canUseGeneratedTranscript else { return }

            self.transcript = model
            self.transcriptIsGenerated = isGenerated
            self.transcriptChoiceChanged()
            self.stateChanged?()
        }
    }

    /// Starts or stops drawing the transcript line to match the current choice.
    private func transcriptChoiceChanged() {
        guard showsTranscript else {
            displayLink?.invalidate()
            displayLink = nil
            transcriptCaptionView.isHidden = true
            return
        }

        if transcriptIsGenerated, case .idle = FingerprintTimingManager.shared.state {
            FingerprintTimingManager.shared.prepareForCurrentEpisode()
        }
        if displayLink == nil {
            let link = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.tick))
            // Cue boundaries only need tenth-of-a-second precision.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 10)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        updateTranscriptCaption()
    }

    /// Shows the cue at the current playback position, or nothing between cues. Also called after
    /// seeks and pauses, when the position jumps.
    func updateTranscriptCaption() {
        guard showsTranscript, let transcript, let position = transcriptPosition(),
              let cue = cue(at: position, in: transcript.cues) else {
            transcriptCaptionView.isHidden = true
            return
        }

        let text = (transcript.attributedText.string as NSString).substring(with: cue.characterRange).trimmingCharacters(in: .whitespacesAndNewlines)
        if transcriptCaptionLabel.text != text {
            transcriptCaptionLabel.text = text
        }
        transcriptCaptionView.isHidden = text.isEmpty
    }

    /// The position on the transcript's timeline. For a generated transcript that's only known on
    /// content the fingerprint has matched, so nothing shows over dynamic ads.
    private func transcriptPosition() -> Double? {
        let playbackTime = PlaybackManager.shared.currentTime()
        guard transcriptIsGenerated else { return playbackTime }
        guard case .active = FingerprintTimingManager.shared.state else { return nil }
        return FingerprintTimingManager.shared.matchedReferenceTime(forPlaybackTime: playbackTime)
    }

    /// Normal playback stays on the cached cue or moves to the next one; only seeks scan.
    private func cue(at position: Double, in cues: [TranscriptCue]) -> TranscriptCue? {
        for index in [cachedCueIndex, cachedCueIndex + 1] where cues.indices.contains(index) {
            if cues[index].contains(timeInSeconds: position) {
                cachedCueIndex = index
                return cues[index]
            }
        }
        guard let index = cues.firstIndex(where: { $0.contains(timeInSeconds: position) }) else { return nil }
        cachedCueIndex = index
        return cues[index]
    }

    /// `CADisplayLink` retains its target, which would keep `VideoCaptions` alive forever.
    private final class DisplayLinkTarget: NSObject {
        private weak var captions: VideoCaptions?

        init(_ captions: VideoCaptions) {
            self.captions = captions
            super.init()
        }

        @objc func tick() {
            MainActor.assumeIsolated {
                captions?.updateTranscriptCaption()
            }
        }
    }
    #endif
}
