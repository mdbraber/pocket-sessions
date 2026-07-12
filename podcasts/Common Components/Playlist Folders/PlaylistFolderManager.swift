import Foundation
import PocketCastsDataModel

/// Fork: a Playlist Folder — groups playlists the way podcast folders group podcasts.
/// Device-local: the server has no such concept, so folders and memberships live in
/// UserDefaults keyed by playlist uuid (which survives full-sync playlist rebuilds).
struct PlaylistFolder: Codable, Equatable, Identifiable {
    let uuid: String
    var name: String
    var color: Int32
    var sortPosition: Int32

    var id: String { uuid }
}

class PlaylistFolderManager {
    static let shared = PlaylistFolderManager()

    static let foldersChanged = NSNotification.Name(rawValue: "SJPlaylistFoldersChanged")

    private static let foldersKey = "SJPlaylistFolders"
    private static let membershipKey = "SJPlaylistFolderMembership" // playlistUuid -> folderUuid

    // MARK: - Folders

    func allFolders() -> [PlaylistFolder] {
        guard let data = UserDefaults.standard.data(forKey: Self.foldersKey),
              let folders = try? JSONDecoder().decode([PlaylistFolder].self, from: data) else { return [] }
        return folders.sorted { $0.sortPosition < $1.sortPosition }
    }

    func folder(uuid: String) -> PlaylistFolder? {
        allFolders().first { $0.uuid == uuid }
    }

    @discardableResult
    func createFolder(name: String, color: Int32, playlistUuids: [String]) -> PlaylistFolder {
        let folder = PlaylistFolder(uuid: UUID().uuidString, name: name, color: color,
                                    sortPosition: (allFolders().map(\.sortPosition).max() ?? -1) + 1)
        persist(folders: allFolders() + [folder])
        var membership = membershipMap()
        for playlistUuid in playlistUuids {
            membership[playlistUuid] = folder.uuid
        }
        persist(membership: membership)
        notifyChanged()
        return folder
    }

    func save(folder: PlaylistFolder) {
        var folders = allFolders()
        if let index = folders.firstIndex(where: { $0.uuid == folder.uuid }) {
            folders[index] = folder
        } else {
            folders.append(folder)
        }
        persist(folders: folders)
        notifyChanged()
    }

    /// Deleting a folder releases its playlists back to the top level.
    func delete(folderUuid: String) {
        persist(folders: allFolders().filter { $0.uuid != folderUuid })
        persist(membership: membershipMap().filter { $0.value != folderUuid })
        notifyChanged()
    }

    // MARK: - Membership

    func folderUuid(forPlaylist playlistUuid: String) -> String? {
        let uuid = membershipMap()[playlistUuid]
        // A membership pointing at a deleted folder means top level.
        return uuid.flatMap { folder(uuid: $0) != nil ? $0 : nil }
    }

    func setFolder(_ folderUuid: String?, forPlaylist playlistUuid: String) {
        var membership = membershipMap()
        membership[playlistUuid] = folderUuid
        persist(membership: membership)
        notifyChanged()
    }

    /// Replaces a folder's entire membership with the given playlists.
    func setPlaylists(_ playlistUuids: [String], inFolder folderUuid: String) {
        var membership = membershipMap().filter { $0.value != folderUuid }
        for playlistUuid in playlistUuids {
            membership[playlistUuid] = folderUuid
        }
        persist(membership: membership)
        notifyChanged()
    }

    func playlistUuids(inFolder folderUuid: String) -> [String] {
        membershipMap().filter { $0.value == folderUuid }.map(\.key)
    }

    /// The folder's playlists, in the playlists page's own order.
    func playlists(inFolder folderUuid: String) -> [EpisodeFilter] {
        let members = Set(playlistUuids(inFolder: folderUuid))
        return DataManager.sharedManager.allPlaylists(includeDeleted: false).filter { members.contains($0.uuid) }
    }

    // MARK: - Storage

    private func membershipMap() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: Self.membershipKey) as? [String: String] ?? [:]
    }

    private func persist(folders: [PlaylistFolder]) {
        if let data = try? JSONEncoder().encode(folders) {
            UserDefaults.standard.set(data, forKey: Self.foldersKey)
        }
    }

    private func persist(membership: [String: String]) {
        UserDefaults.standard.set(membership, forKey: Self.membershipKey)
    }

    private func notifyChanged() {
        NotificationCenter.postOnMainThread(notification: Self.foldersChanged)
    }
}
