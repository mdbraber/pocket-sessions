import UIKit

/// Fork: a row in the session list — artwork, three lines (name · next episode · info), a neutral
/// background progress fill (the same one the Up Next now-playing card uses), an episode-style
/// equalizer while it sounds, and a play/pause button. Tapping the row opens the lane's page; the
/// button plays/pauses it. Up Next and the current session are two SEPARATE tinted cards (faint blue
/// / faint green); the rest are a flat pool. All cells are left-aligned.
class SessionListCell: ThemeableSwipeCell {
    static let reuseIdentifier = "SessionListCell"

    /// Which kind of row this is. Up Next and the current session each get their own rounded, tinted
    /// card; pool rows are flat.
    enum Placement { case upNext, current, pool }

    /// Tapped the play/pause button — play, resume, or pause this lane.
    var onPlayTapped: (() -> Void)?

    /// Long-pressed the play button — make this session current, inheriting the current play state.
    var onPlayLongPressed: (() -> Void)?

    // MARK: - Subviews

    /// The row's card (Up Next / current) or a flat clear backing (pool). Clips the progress fill to
    /// its rounded corners.
    private let surfaceView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.masksToBounds = true
        return view
    }()

    /// Neutral background progress fill from the leading edge, width = progress — identical treatment
    /// to `UpNextNowPlayingCell.progressView` (playerContrast06 @ 10% on dark, black @ 10% on light).
    private let progressView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private lazy var artworkView: PodcastImageView = {
        let view = PodcastImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        // No manual corner radius: PodcastImageView applies the same 4pt radius + subtle shadow the
        // episode rows (EpisodeCell) on a podcast/playlist page use (via the .list thumbnail below).
        return view
    }()

    /// Green sparkles glyph AFTER the name for smart-playlist-fed sessions.
    private lazy var smartIcon: UIImageView = {
        let config = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let view = UIImageView(image: UIImage(systemName: "sparkles", withConfiguration: config)?.withRenderingMode(.alwaysTemplate))
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        view.isHidden = true
        return view
    }()

    private lazy var nameLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .font(ofSize: 16, weight: .semibold, scalingWith: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private lazy var nameRow: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [nameLabel, smartIcon])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        return stack
    }()

    private lazy var nextLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .font(ofSize: 13, weight: .regular, scalingWith: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private lazy var infoLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Self.tabularFont(ofSize: 12, scalingWith: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private lazy var textStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [nameRow, nextLabel, infoLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 2
        return stack
    }()

    private lazy var playButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        // Fork: long-pressing the play button makes the session current and INHERITS the play state
        // (paused stays paused), as opposed to a tap, which makes it current and plays.
        button.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(playLongPressed(_:))))
        return button
    }()

    /// The equalizer bars marking the lane that's sounding — the SAME view and intrinsic size as an
    /// episode-list row's now-playing indicator. Green for a session, blue for Up Next.
    private lazy var nowPlayingIndicator: NowPlayingIndicatorView = {
        let view = NowPlayingIndicatorView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        view.isHidden = true
        return view
    }()

    /// The trailing controls: the equalizer (when sounding) sits just before the play/pause button,
    /// matching an episode row. A stack so a hidden member collapses without leaving a gap.
    private lazy var trailingStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [nowPlayingIndicator, playButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        return stack
    }()

    /// A hairline between pool rows.
    private lazy var divider: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    // MARK: - Layout state (rewritten per populate)

    private var placement: Placement = .pool
    private var ownsCard = false
    private var isUpNextLane = false
    private var progress: Double = 0

    private var surfaceTop: NSLayoutConstraint?
    private var surfaceBottom: NSLayoutConstraint?
    private var artworkTop: NSLayoutConstraint?
    private var artworkBottom: NSLayoutConstraint?
    private var progressWidth: NSLayoutConstraint?
    private var trailingStackTrailing: NSLayoutConstraint?
    private var surfaceTrailing: NSLayoutConstraint?

    /// A hair of horizontal inset applied to EVERY row so all content aligns.
    private static let sideInset: CGFloat = 8
    private static let innerPad: CGFloat = 12

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(false, animated: animated)
    }

    // MARK: - Init

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        accessoryType = .none
        selectionStyle = .none
        self.style = .primaryUi02
        iconStyle = .primaryIcon02
        backgroundColor = .clear

        surfaceView.addSubview(progressView)
        contentView.addSubview(surfaceView)
        contentView.addSubview(artworkView)
        contentView.addSubview(textStack)
        contentView.addSubview(trailingStack)
        surfaceView.addSubview(divider)

        let sTop = surfaceView.topAnchor.constraint(equalTo: contentView.topAnchor)
        let sBottom = surfaceView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        surfaceTop = sTop; surfaceBottom = sBottom
        let pWidth = progressView.widthAnchor.constraint(equalToConstant: 0)
        progressWidth = pWidth
        // Trailing controls sit at the surface edge (aligning the play button with the EpisodeCell
        // rows on the details screens, whose action button hugs the same edge); in reorder mode they
        // shift left to clear the drag handle the table draws at the trailing edge.
        let tTrailing = trailingStack.trailingAnchor.constraint(equalTo: surfaceView.trailingAnchor, constant: 0)
        trailingStackTrailing = tTrailing
        // In reorder mode the card stretches to the trailing edge so the drag handle sits ON the
        // background rather than out in the margin.
        let sTrailing = surfaceView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Self.sideInset)
        surfaceTrailing = sTrailing
        let aTop = artworkView.topAnchor.constraint(equalTo: surfaceView.topAnchor, constant: Self.innerPad)
        let aBottom = artworkView.bottomAnchor.constraint(equalTo: surfaceView.bottomAnchor, constant: -Self.innerPad)
        artworkTop = aTop; artworkBottom = aBottom

        NSLayoutConstraint.activate([
            surfaceView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Self.sideInset),
            sTrailing,
            sTop, sBottom,

            progressView.leadingAnchor.constraint(equalTo: surfaceView.leadingAnchor),
            progressView.topAnchor.constraint(equalTo: surfaceView.topAnchor),
            progressView.bottomAnchor.constraint(equalTo: surfaceView.bottomAnchor),
            pWidth,

            artworkView.leadingAnchor.constraint(equalTo: surfaceView.leadingAnchor, constant: Self.innerPad),
            aTop,
            aBottom,
            artworkView.widthAnchor.constraint(equalToConstant: 56),
            artworkView.heightAnchor.constraint(equalToConstant: 56),

            textStack.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: trailingStack.leadingAnchor, constant: -6),
            textStack.centerYAnchor.constraint(equalTo: artworkView.centerYAnchor),

            playButton.widthAnchor.constraint(equalToConstant: 36),
            playButton.heightAnchor.constraint(equalToConstant: 36),

            trailingStack.centerYAnchor.constraint(equalTo: artworkView.centerYAnchor),
            tTrailing,

            divider.leadingAnchor.constraint(equalTo: textStack.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: surfaceView.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: surfaceView.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale)
        ])

        isAccessibilityElement = true
        for view in [artworkView, smartIcon, nameLabel, nextLabel, infoLabel, divider] {
            view.isAccessibilityElement = false
        }

        updateColor()
    }

    @MainActor required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Populate

    func populate(from row: SessionListRow, placement: Placement, reordering: Bool) {
        self.placement = placement
        self.ownsCard = row.ownsCard
        self.isUpNextLane = row.isUpNext
        if let podcastUuid = row.nextEpisodePodcastUuid {
            artworkView.setPodcast(uuid: podcastUuid, size: .list)
        } else {
            artworkView.clearArtwork()
        }

        nameLabel.text = row.name
        smartIcon.isHidden = !row.isSmartPlaylist

        let isEmpty = row.nextEpisodeTitle == nil
        nextLabel.isHidden = isEmpty
        // Season/episode shorthand (e.g. "S4 E2") before the title when available.
        if let title = row.nextEpisodeTitle {
            nextLabel.text = [row.nextEpisodeSeasonEpisode, title].compactMap { $0 }.joined(separator: " · ")
        }
        infoLabel.text = isEmpty ? L10n.sessionRowNoEpisodes : Self.infoText(for: row)

        artworkView.alpha = isEmpty ? 0.45 : 1
        nameStyle = isEmpty ? .primaryText02 : .primaryText01

        // Only the active (playing) row shows its background progress fill; the rest are plain. A drag
        // drops it too (see refreshProgressFill).
        rowProgress = row.progress
        refreshProgressFill()

        // The lane that owns the card shows the equalizer — animated while playing, frozen while
        // paused (NowPlayingIndicatorView manages that itself). Blue for the queue, green for a session.
        nowPlayingIndicator.isHidden = !row.ownsCard
        nowPlayingIndicator.color = laneAccent(isUpNext: row.isUpNext)

        // Play when idle/paused, pause when this lane is sounding. Outline (not filled) glyphs.
        let symbol = row.isPlaying ? "pause.circle" : "play.circle"
        let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        playButton.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)
        playButton.accessibilityLabel = row.isPlaying ? L10n.pause : L10n.play
        // Normally every row shows its play button; in Reorder Items mode the pool rows show the
        // table's trailing drag handle instead, so hide the button and clear space for the handle.
        // (A host that wires no play handler — the Switch Session sheet — also shows no button.)
        playButton.isHidden = reordering || onPlayTapped == nil
        trailingStackTrailing?.constant = reordering ? -40 : -(Self.innerPad - 4)
        surfaceTrailing?.constant = reordering ? 0 : -Self.sideInset

        accessibilityLabel = Self.accessibilityLabel(for: row)

        applyPlacement()
        updateColor()
        setNeedsLayout()
    }

    /// Line 3 — episode count + time left across the lineup.
    private static func infoText(for row: SessionListRow) -> String {
        var parts: [String] = []
        if row.episodeCount > 0 {
            parts.append(row.episodeCount == 1
                ? L10n.podcastEpisodeCountSingular
                : L10n.episodeCountPluralFormat(row.episodeCount.localized()))
        }
        if let timeLeft = row.timeLeft { parts.append(timeLeft) }
        return parts.joined(separator: " · ")
    }

    private static func accessibilityLabel(for row: SessionListRow) -> String {
        guard let title = row.nextEpisodeTitle else {
            return "\(row.name), \(L10n.sessionRowNoEpisodes)"
        }
        let name = row.isPlaying ? L10n.sessionRowPlayingAccessibility(row.name) : row.name
        var next = title
        if let podcast = row.nextEpisodePodcast { next += ", \(podcast)" }
        let count = row.episodeCount == 1
            ? L10n.podcastEpisodeCountSingular
            : L10n.episodeCountPluralFormat(row.episodeCount.localized())
        var tail = count
        if let timeLeft = row.timeLeft { tail += ", \(L10n.queueUpNextHeaderTimeLeft(timeLeft))" }
        return "\(name). \(next). \(tail)"
    }

    private var nameStyle: ThemeStyle = .primaryText01

    /// Blue for the queue lane, green for a session — the accent for the equalizer.
    private func laneAccent(isUpNext: Bool) -> UIColor {
        let theme = themeOverride ?? Theme.sharedTheme.activeTheme
        return isUpNext ? ThemeColor.support01(for: theme) : ThemeColor.support02(for: theme)
    }

    // MARK: - Placement

    private func applyPlacement() {
        // Fork: the session list (current + pool) is a uniform flat list — hairline dividers, only
        // the ACTIVE (playing) row boxed. Up Next is the exception: it's a separate pinned row that
        // ALWAYS keeps its accent box (blue), matching its own screen. So a row is boxed when it's Up
        // Next OR the active one.
        let boxed = showsAccentBox
        surfaceTop?.constant = boxed ? 2 : 0
        // Boxed rows leave more space beneath them than a flat row; the top session leaves the most, to
        // set it apart from the pool below it. (Content is inset within the surface, so this just grows
        // the row — no clipping.)
        surfaceBottom?.constant = isTopSession ? -18 : (boxed ? -8 : 0)
        // Pool rows get comfortable vertical padding so the sessions sit apart like playlist rows.
        let vPad: CGFloat = boxed ? Self.innerPad : 11
        artworkTop?.constant = vPad
        artworkBottom?.constant = -vPad
        surfaceView.layer.cornerRadius = boxed ? 12 : 0
        surfaceView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        // A boxed row carries its own outline, so it drops the row divider; flat rows keep one.
        divider.isHidden = boxed
    }

    /// When true, the Up Next row is a normal session row (no pinned accent box) — the "In Session
    /// List" position option. Set by the host before `populate`.
    var upNextInSessionList = false

    /// The top session (position 0 of the session list). It always keeps its accent background — the
    /// "active position" — even when the queue, not a session, is what's playing. Set before `populate`.
    var isTopSession = false

    /// Shows the accent background when: Up Next is pinned at the top, the row is the top session, or
    /// the row is the actively-playing lane. A drag suppresses the top-session / active background.
    private var showsAccentBox: Bool {
        (isUpNextLane && !upNextInSessionList) || ((isTopSession || ownsCard) && !suppressActiveBoxForDrag)
    }

    /// While any row is being dragged, the active session drops its box so the list reads uniform.
    private var suppressActiveBoxForDrag = false

    func setActiveBoxSuppressed(_ suppressed: Bool) {
        guard suppressActiveBoxForDrag != suppressed else { return }
        suppressActiveBoxForDrag = suppressed
        applyPlacement()
        updateColor()
        refreshProgressFill()
    }

    /// The backdrop progress fill shows only on the active row, and drops while a drag suppresses
    /// the active styling.
    private var rowProgress: CGFloat = 0
    private func refreshProgressFill() {
        progress = (ownsCard && !suppressActiveBoxForDrag) ? rowProgress : 0
    }

    /// Monospaced digits so the counts line doesn't jitter as its time ticks down.
    private static func tabularFont(ofSize size: CGFloat, scalingWith style: UIFont.TextStyle) -> UIFont {
        let settings: [[UIFontDescriptor.FeatureKey: Int]] = [[
            .type: kNumberSpacingType,
            .selector: kMonospacedNumbersSelector
        ]]
        let descriptor = UIFont.systemFont(ofSize: size).fontDescriptor.addingAttributes([.featureSettings: settings])
        let metrics = UIFontMetrics(forTextStyle: style)
        let maxPointSize = metrics.scaledValue(for: size, compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge))
        return metrics.scaledFont(for: UIFont(descriptor: descriptor, size: size), maximumPointSize: maxPointSize)
    }

    @objc private func playTapped() {
        onPlayTapped?()
    }

    @objc private func playLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        onPlayLongPressed?()
    }

    /// True when `point` (in this cell's coordinate space) lands on the play button — the table's
    /// drag delegate uses this to refuse a row drag that begins on the play button, so a long-press
    /// there is the "make current" gesture, not a lift.
    func pointHitsPlayButton(_ point: CGPoint) -> Bool {
        guard !playButton.isHidden else { return false }
        let local = convert(point, to: playButton)
        return playButton.bounds.insetBy(dx: -8, dy: -8).contains(local)
    }

    // MARK: - Theming

    override func handleThemeDidChange() {
        backgroundColor = .clear
        nameLabel.textColor = AppTheme.colorForStyle(nameStyle, themeOverride: themeOverride)
        // Line 2 and line 3 are dimmed.
        nextLabel.textColor = AppTheme.colorForStyle(.primaryText02, themeOverride: themeOverride)
        infoLabel.textColor = AppTheme.colorForStyle(.primaryText02, themeOverride: themeOverride)
        smartIcon.tintColor = ThemeColor.support02(for: themeOverride) // green sparkle
        divider.backgroundColor = AppTheme.colorForStyle(.primaryUi05, themeOverride: themeOverride)

        // Fork: uniform list — only the ACTIVE (playing) row is styled. Its accent is blue when it's
        // the Up Next lane, green when it's a session; every other row is a flat, white-play-button
        // list row (matching the lineup, where only the playing episode gets the accent box).
        let theme = themeOverride ?? Theme.sharedTheme.activeTheme
        let accent = laneAccent(isUpNext: isUpNextLane)
        if showsAccentBox {
            playButton.tintColor = accent
            surfaceView.backgroundColor = accent.withAlphaComponent(0.18)
        } else {
            playButton.tintColor = AppTheme.colorForStyle(.primaryText01, themeOverride: themeOverride)
            surfaceView.backgroundColor = .clear
        }
        // The border marks the actually-active LANE: Up Next when the queue is playing, otherwise the
        // active session. The top session keeps its background but takes no border unless it's the one
        // playing. A drag suppresses the active border too.
        let bordered = ownsCard && !suppressActiveBoxForDrag
        surfaceView.layer.borderColor = accent.cgColor
        surfaceView.layer.borderWidth = bordered ? 1.5 : 0

        // The neutral progress fill — identical to UpNextNowPlayingCell.progressView.
        if theme == .rosé {
            progressView.backgroundColor = AppTheme.colorForStyle(.primaryIcon02Selected, themeOverride: themeOverride).withAlphaComponent(0.1)
        } else if theme.isDark {
            progressView.backgroundColor = AppTheme.colorForStyle(.playerContrast06, themeOverride: themeOverride).withAlphaComponent(0.1)
        } else {
            progressView.backgroundColor = .black.withAlphaComponent(0.1)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressWidth?.constant = surfaceView.bounds.width * CGFloat(min(1, max(0, progress)))
        CATransaction.commit()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        artworkView.alpha = 1
        artworkView.clearArtwork()
        progress = 0
        ownsCard = false
        suppressActiveBoxForDrag = false
        isTopSession = false
        smartIcon.isHidden = true
        nowPlayingIndicator.isHidden = true
        playButton.isHidden = false
        onPlayTapped = nil
        onPlayLongPressed = nil
    }
}
