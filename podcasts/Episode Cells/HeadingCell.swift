import UIKit

class HeadingCell: ThemeableCell {
    @IBOutlet var heading: UILabel! {
        didSet {
            heading.font = UIFont.font(ofSize: 22, weight: .medium, scalingWith: .title2)
            heading.adjustsFontForContentSizeCategory = true
        }
    }
    @IBOutlet var button: UIButton!

    var action: (() -> Void)?

    override func setSelected(_ selected: Bool, animated: Bool) {}
    override func setHighlighted(_ highlighted: Bool, animated: Bool) {}

    @IBAction func buttonTapped(_ sender: UIButton) {
        action?()
    }

    /// Fork: renders the group title, optionally preceded by a collapse chevron
    /// (right = collapsed, down = expanded). The chevron is an inline text attachment
    /// so it needs no XIB constraint surgery.
    func configure(title: String, collapsible: Bool, collapsed: Bool) {
        guard collapsible else {
            heading.attributedText = nil
            heading.text = title
            return
        }
        let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let symbol = UIImage(systemName: collapsed ? "chevron.right" : "chevron.down", withConfiguration: config)?
            .withTintColor(AppTheme.colorForStyle(.primaryText01), renderingMode: .alwaysOriginal)
        let attachment = NSTextAttachment()
        attachment.image = symbol
        if let symbol {
            attachment.bounds = CGRect(x: 0, y: (heading.font.capHeight - symbol.size.height) / 2,
                                       width: symbol.size.width, height: symbol.size.height)
        }
        let result = NSMutableAttributedString(attachment: attachment)
        result.append(NSAttributedString(string: "  " + title))
        heading.attributedText = result
    }

    /// Fork: the title with a small chevron directly AFTER the text (a "tap to open" affordance for
    /// Group By Podcast / Folder headers) — inline, not pinned to the far right.
    func configureWithTrailingChevron(title: String) {
        let config = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        guard let symbol = UIImage(systemName: "chevron.right", withConfiguration: config)?
            .withTintColor(AppTheme.colorForStyle(.primaryIcon02), renderingMode: .alwaysOriginal) else {
            heading.text = title
            return
        }
        let attachment = NSTextAttachment()
        attachment.image = symbol
        attachment.bounds = CGRect(x: 0, y: (heading.font.capHeight - symbol.size.height) / 2,
                                   width: symbol.size.width, height: symbol.size.height)
        let result = NSMutableAttributedString(string: title + "  ")
        result.append(NSAttributedString(attachment: attachment))
        heading.attributedText = result
    }
}
