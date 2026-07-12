import Foundation

/// Fork: a Group By heading row inside a playlist's episode list — rendered with the
/// podcast page's HeadingCell so grouping looks identical everywhere.
class PlaylistGroupHeaderPlaceholder: ListItem {
    let title: String

    init(title: String) {
        self.title = title
        super.init()
    }

    override var differenceIdentifier: String {
        "group-\(title)"
    }

    static func == (lhs: PlaylistGroupHeaderPlaceholder, rhs: PlaylistGroupHeaderPlaceholder) -> Bool {
        lhs.handleIsEqual(rhs)
    }

    override func handleIsEqual(_ otherItem: ListItem) -> Bool {
        guard let rhs = otherItem as? PlaylistGroupHeaderPlaceholder else { return false }
        return title == rhs.title
    }
}
