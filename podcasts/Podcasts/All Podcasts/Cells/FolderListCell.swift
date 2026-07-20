import PocketCastsDataModel
import UIKit

class FolderListCell: ThemeableCollectionCell {
    @IBOutlet var folderPreview: FolderPreviewView! {
        didSet {
            folderPreview.showFolderName = false
        }
    }

    @IBOutlet var folderName: ThemeableLabel! {
        didSet {
            folderName.font = UIFont.font(ofSize: 16, weight: .medium, scalingWith: .callout)
            folderName.adjustsFontForContentSizeCategory = true
        }
    }

    @IBOutlet var folderInfo: ThemeableLabel! {
        didSet {
            folderInfo.style = .primaryText02
            folderInfo.font = UIFont.font(ofSize: 14, weight: .regular, scalingWith: .footnote)
            folderInfo.adjustsFontForContentSizeCategory = true
        }
    }

    @IBOutlet var unplayedBadge: UnplayedBadge!
    @IBOutlet var unplayedHeight: NSLayoutConstraint!

    private var badgeType: BadgeType = .off

    override func awakeFromNib() {
        super.awakeFromNib()
        isAccessibilityElement = true
        addFlexSpacer()
        updateSize()
    }

    /// The row's slack lives in this invisible flex view, so the badge and chevron
    /// pin hard against the trailing edge instead of Auto Layout breaking an
    /// arbitrary constraint to resolve the over-constrained stack.
    private func addFlexSpacer() {
        guard let stack = unplayedBadge.superview as? UIStackView,
              let badgeIndex = stack.arrangedSubviews.firstIndex(of: unplayedBadge) else { return }
        let flex = UIView()
        flex.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        flex.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)
        stack.insertArrangedSubview(flex, at: badgeIndex)
    }

    func populateFrom(folder: Folder, badgeType: BadgeType) {
        self.badgeType = badgeType
        folderName.text = folder.name
        folderPreview.populateFromAsync(folder: folder)
        folderPreview.backgroundColor = AppTheme.folderColor(colorInt: folder.color)

        accessibilityLabel = [folderPreview.accessibilityLabel, badgeType.accessibilityDescription(count: folder.cachedUnreadCount)].compactMap { $0 }.joined(separator: ", ")

        let count = DataManager.sharedManager.countOfPodcastsInFolder(folder: folder)
        folderInfo.text = L10n.podcastCount(count)

        if badgeType.showsCount {
            let metric = UIFontMetrics(forTextStyle: .largeTitle)
            unplayedHeight.constant = max(22, metric.scaledValue(for: 22))
            unplayedBadge.layoutIfNeeded()

            unplayedBadge.showsNumber = true
            unplayedBadge.unplayedCount = folder.cachedUnreadCount > 99 ? 99 : folder.cachedUnreadCount
            unplayedBadge.isHidden = folder.cachedUnreadCount == 0
        } else if badgeType.showsDot {
            let metric = UIFontMetrics(forTextStyle: .largeTitle)
            unplayedHeight.constant = max(10, metric.scaledValue(for: 10))
            unplayedBadge.layoutIfNeeded()

            unplayedBadge.showsNumber = false
            unplayedBadge.isHidden = folder.cachedUnreadCount == 0
        } else {
            unplayedBadge.isHidden = true
        }

        unplayedBadge.updateColors()

        // Fork: folders navigate into a page — the chevron says so (podcast rows
        // don't get one, matching the playlist rows' pattern).
        addChevronIfNeeded()
        chevron?.tintColor = ThemeColor.primaryIcon02()
    }

    private var chevron: UIImageView?

    private func addChevronIfNeeded() {
        guard chevron == nil, let stack = unplayedBadge.superview as? UIStackView else { return }
        let imageView = UIImageView(image: UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)))
        imageView.contentMode = .center
        // Fixed and tightly hugging — otherwise the stack stretches the image view
        // and the glyph floats away from the trailing edge.
        imageView.setContentHuggingPriority(.required, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        imageView.widthAnchor.constraint(equalToConstant: 14).isActive = true
        stack.addArrangedSubview(imageView)
        chevron = imageView
    }

    private func updateSize() {
        let metric = UIFontMetrics(forTextStyle: .largeTitle)
        let imageSize = max(56, metric.scaledValue(for: 56))
        folderPreview.updateSizeConstraints(to: imageSize)

        let badgeMetric = UIFontMetrics(forTextStyle: .largeTitle)
        if badgeType.showsCount {
            unplayedHeight.constant = max(22, badgeMetric.scaledValue(for: 22))
        } else if badgeType.showsDot {
            unplayedHeight.constant = max(10, badgeMetric.scaledValue(for: 10))
        }
        unplayedBadge.layoutIfNeeded()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.preferredContentSizeCategory != previousTraitCollection?.preferredContentSizeCategory else { return }
        updateSize()
    }
}
