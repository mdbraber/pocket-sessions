import UIKit

/// Fork: a row in the session CHOOSER — artwork, the session's name, and the episode it
/// would play next. Registered programmatically (no XIB); self-sizing.
class SessionListCell: ThemeableCell {
    static let reuseIdentifier = "SessionListCell"

    // MARK: - Subviews

    /// The next episode's podcast art — the very same `PodcastImageView`, at the very same
    /// 56pt, that an Up Next row uses (see PlayerCell). A session row promises one episode,
    /// so it should look like that episode's row.
    private lazy var artworkView: PodcastImageView = {
        let view = PodcastImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private lazy var nameLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .font(ofSize: 18, weight: .semibold, scalingWith: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    private lazy var playingBadge: UILabel = {
        let label = PaddedLabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .font(ofSize: 10, weight: .semibold, scalingWith: .caption2)
        label.adjustsFontForContentSizeCategory = true
        label.text = L10n.nowPlayingShortTitle.localizedUppercase
        label.numberOfLines = 1
        label.layer.cornerRadius = 5
        label.layer.masksToBounds = true
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }()

    private lazy var titleRow: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [nameLabel, playingBadge, UIView()])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        return stack
    }()

    private lazy var episodeLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .font(ofSize: 14, weight: .regular, scalingWith: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private lazy var metaLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Self.tabularFont(ofSize: 12, scalingWith: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    /// The table draws no separators (Up Next rows carry their own), so the chooser does too —
    /// without one, names run together down the list.
    private lazy var divider: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    /// A slim bar under the detail column, rather than a wash across the row background.
    private lazy var progressTrack: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.cornerRadius = 1
        view.layer.masksToBounds = true
        return view
    }()

    private lazy var progressFill: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    /// The detail column beside the artwork: what you'd hear, then how much there is.
    private lazy var textStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [episodeLabel, metaLabel, progressTrack])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 2
        stack.setCustomSpacing(6, after: metaLabel)
        return stack
    }()

    /// Width of the background fill, as a fraction of the row; rewritten on layout.
    private var progressWidth: NSLayoutConstraint?
    private var progress: Double = 0

    // MARK: - Init

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        accessoryType = .none
        selectionStyle = .default
        self.style = .primaryUi02
        iconStyle = .primaryIcon02

        contentView.addSubview(titleRow)
        contentView.addSubview(artworkView)
        contentView.addSubview(textStack)
        contentView.addSubview(divider)
        progressTrack.addSubview(progressFill)

        let width = progressFill.widthAnchor.constraint(equalToConstant: 0)
        progressWidth = width

        NSLayoutConstraint.activate([
            // The name owns its own line at the row's leading edge, so names scan straight
            // down the list instead of competing with the detail beside the artwork.
            titleRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            titleRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            titleRow.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),

            artworkView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            artworkView.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 8),
            artworkView.widthAnchor.constraint(equalToConstant: 56),
            artworkView.heightAnchor.constraint(equalToConstant: 56),
            artworkView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),

            textStack.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            textStack.centerYAnchor.constraint(equalTo: artworkView.centerYAnchor),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: artworkView.topAnchor),

            divider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            divider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            progressTrack.heightAnchor.constraint(equalToConstant: 2),
            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
            width
        ])

        isAccessibilityElement = true
        for view in [artworkView, nameLabel, playingBadge, episodeLabel, metaLabel, progressTrack, divider] {
            view.isAccessibilityElement = false
        }

        updateColor()
    }

    @MainActor required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Populate

    func populate(from row: SessionListRow) {
        if let podcastUuid = row.nextEpisodePodcastUuid {
            artworkView.setPodcast(uuid: podcastUuid, size: .list)
        } else {
            // Nothing left to play — no episode, so no episode art.
            artworkView.clearArtwork()
        }

        nameLabel.text = row.name
        playingBadge.isHidden = !row.isPlaying

        let isEmpty = row.nextEpisodeTitle == nil
        episodeLabel.isHidden = isEmpty
        episodeLabel.text = row.nextEpisodeTitle

        metaLabel.text = isEmpty ? L10n.sessionRowNoEpisodes : Self.metaText(for: row)

        // An empty session recedes — dimmed name and artwork, no episode line.
        artworkView.alpha = isEmpty ? 0.45 : 1
        nameStyle = isEmpty ? .primaryText02 : .primaryText01

        progress = row.progress
        progressTrack.isHidden = row.progress <= 0

        accessibilityLabel = Self.accessibilityLabel(for: row)

        updateColor()
        setNeedsLayout()
    }

    /// "<duration> · <count> episodes · <timeLeft>", skipping whatever is missing. The podcast
    /// name is deliberately absent — the artwork beside it already says which show this is.
    private static func metaText(for row: SessionListRow) -> String {
        var parts: [String] = []
        if let duration = row.nextEpisodeDuration { parts.append(duration) }
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
        if let duration = row.nextEpisodeDuration { next += ", \(duration)" }

        let count = row.episodeCount == 1
            ? L10n.podcastEpisodeCountSingular
            : L10n.episodeCountPluralFormat(row.episodeCount.localized())
        var tail = count
        if let timeLeft = row.timeLeft { tail += ", \(L10n.queueUpNextHeaderTimeLeft(timeLeft))" }

        return "\(name). \(next). \(tail)"
    }

    private var nameStyle: ThemeStyle = .primaryText01

    /// Monospaced digits at `size`, scaling with `style` — the counts line shouldn't
    /// jitter as its times tick down.
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

    // MARK: - Theming

    override func handleThemeDidChange() {
        nameLabel.textColor = AppTheme.colorForStyle(nameStyle, themeOverride: themeOverride)
        episodeLabel.textColor = AppTheme.colorForStyle(.primaryText01, themeOverride: themeOverride)
        metaLabel.textColor = AppTheme.colorForStyle(.primaryText02, themeOverride: themeOverride)

        let support = ThemeColor.support02(for: themeOverride ?? Theme.sharedTheme.activeTheme)
        playingBadge.textColor = support
        playingBadge.backgroundColor = support.withAlphaComponent(0.16)

        divider.backgroundColor = AppTheme.colorForStyle(.primaryUi05, themeOverride: themeOverride)

        progressTrack.backgroundColor = AppTheme.colorForStyle(.primaryUi05, themeOverride: themeOverride)
        progressFill.backgroundColor = AppTheme.colorForStyle(.primaryInteractive01, themeOverride: themeOverride)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        progressWidth?.constant = progressTrack.bounds.width * CGFloat(min(1, max(0, progress)))
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        artworkView.alpha = 1
        artworkView.clearArtwork()
        progress = 0
        progressTrack.isHidden = true
    }
}

// MARK: - Playing badge

/// A label with room around its text — the "Playing" pill.
private final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 2, left: 5, bottom: 2, right: 5)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right,
                      height: size.height + insets.top + insets.bottom)
    }
}
