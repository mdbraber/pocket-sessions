import Foundation
import PocketCastsDataModel

/// Fork: a Playlist Folder's row in the Playlists list — rides the same diffing
/// pipeline as playlist rows via a sentinel filter.
class ListPlaylistFolder: ListPlaylist {
    let folder: PlaylistFolder
    let count: Int

    init(folder: PlaylistFolder, count: Int) {
        self.folder = folder
        self.count = count
        let sentinel = EpisodeFilter()
        sentinel.uuid = "playlist-folder-\(folder.uuid)"
        sentinel.playlistName = folder.name
        super.init(playlist: sentinel)
    }

    override var differenceIdentifier: String {
        "playlist-folder-\(folder.uuid)"
    }

    override var combinedSortPosition: Int32 {
        folder.sortPosition
    }

    override func handleIsEqual(_ otherItem: ListItem) -> Bool {
        guard let rhs = otherItem as? ListPlaylistFolder else { return false }
        return folder == rhs.folder && count == rhs.count
    }
}
