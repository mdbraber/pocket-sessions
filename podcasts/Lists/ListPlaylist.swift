import Foundation
import PocketCastsDataModel

class ListPlaylist: ListItem, Identifiable, Hashable {
    let playlist: EpisodeFilter

    var id: String {
        playlist.uuid
    }

    /// Fork: the position in the unified folders+playlists drag order. Folders override this
    /// with their own `sortPosition` so both kinds share one number space and can interleave.
    var combinedSortPosition: Int32 {
        playlist.sortPosition
    }

    override var differenceIdentifier: String {
        playlist.uuid
    }

    init(playlist: EpisodeFilter) {
        self.playlist = playlist
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ListPlaylist, rhs: ListPlaylist) -> Bool {
        lhs.handleIsEqual(rhs)
    }

    override func isContentEqual(to source: ListItem) -> Bool {
        handleIsEqual(source)
    }

    override func handleIsEqual(_ otherItem: ListItem) -> Bool {
        guard let rhs = otherItem as? ListPlaylist else { return false }

        return playlist.uuid == rhs.playlist.uuid &&
        playlist.playlistUpdateDate == rhs.playlist.playlistUpdateDate
    }
}
