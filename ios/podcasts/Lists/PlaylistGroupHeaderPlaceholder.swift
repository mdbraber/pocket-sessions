import Foundation

/// Fork: a Group By heading row inside a playlist's episode list — rendered with the
/// podcast page's HeadingCell so grouping looks identical everywhere.
class PlaylistGroupHeaderPlaceholder: ListItem {
    let title: String
    /// Fork: where a small right-side chevron on the header navigates to — the grouped-by
    /// podcast or folder. Nil for groupings with no single destination (dates, "No Folder", …).
    let target: GroupNavTarget?

    /// Fork: the destination behind a Group By header's chevron.
    enum GroupNavTarget: Equatable {
        case podcast(uuid: String)
        case folder(uuid: String)
    }

    init(title: String, target: GroupNavTarget? = nil) {
        self.title = title
        self.target = target
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
        return title == rhs.title && target == rhs.target
    }
}
