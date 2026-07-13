import UIKit

class UnplayedBadge: UIView {
    var unplayedCount = 0 {
        didSet {
            unplayedLabel.text = "\(unplayedCount)"
        }
    }

    var showsNumber = true {
        didSet {
            unplayedLabel.isHidden = !showsNumber
            // Counts size to their text (capsule); the dot is a square circle.
            dotWidthConstraint?.isActive = !showsNumber
            layer.cornerRadius = bounds.height / 2
        }
    }

    private var unplayedLabel: UILabel!
    private var dotWidthConstraint: NSLayoutConstraint?

    override func awakeFromNib() {
        super.awakeFromNib()

        clipsToBounds = true
        layer.cornerRadius = bounds.height / 2

        // Fork: the XIB pins width == height (the old circle badge). The playlist-
        // style count sizes to its text instead, so the square lock only applies in
        // dot mode — and the badge must hug tightly or the row stack stretches it
        // and the number floats away from the trailing edge.
        constraints.filter { $0.firstAttribute == .width }.forEach { removeConstraint($0) }
        dotWidthConstraint = widthAnchor.constraint(equalTo: heightAnchor)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        unplayedLabel = UILabel(frame: bounds)
        addSubview(unplayedLabel)
        unplayedLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            unplayedLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            unplayedLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            unplayedLabel.topAnchor.constraint(equalTo: topAnchor),
            unplayedLabel.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        unplayedLabel.font = UIFont.font(ofSize: 14, weight: .regular, scalingWith: .footnote)
        unplayedLabel.adjustsFontForContentSizeCategory = true
        unplayedLabel.textAlignment = .center

        updateColors()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    func updateColors() {
        // Counts are just the number, playlist-row style; only the presence dot
        // draws anything (the accent circle).
        backgroundColor = showsNumber ? .clear : ThemeColor.primaryInteractive01()
        unplayedLabel.textColor = ThemeColor.primaryText02()
    }
}
