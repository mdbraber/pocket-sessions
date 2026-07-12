import Foundation

/// Fork: the in-table "No episodes" row for an empty triage tab — the playlist chrome
/// (header, tabs) stays put; only the episode area reports being empty.
class PlaylistTabEmptyPlaceholder: ListItem {
    override var differenceIdentifier: String {
        "playlistTabEmpty"
    }

    static func == (lhs: PlaylistTabEmptyPlaceholder, rhs: PlaylistTabEmptyPlaceholder) -> Bool {
        lhs.handleIsEqual(rhs)
    }

    override func handleIsEqual(_ otherItem: ListItem) -> Bool {
        otherItem is PlaylistTabEmptyPlaceholder
    }
}
