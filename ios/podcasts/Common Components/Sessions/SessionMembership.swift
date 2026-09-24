import Foundation
import PocketCastsDataModel
import PocketCastsServer

/// Fork: an in-memory cache of "which episodes are in any session".
///
/// The source of truth is the session stores (synced manual playlists); this only **memoizes** the
/// union so the "in a session" badge and Group-By-Session don't re-run the (indexed, but still
/// repeated) membership query on every list reload. It is never persisted and never synced — it is
/// invalidated whenever membership can change, then lazily rebuilt on next read. Worst case it is
/// stale for one runloop until the notification lands; there is nothing to reconcile because it owns
/// no data.
final class SessionMembership {
    static let shared = SessionMembership()

    private let lock = NSLock()
    private var cache: Set<String>?

    private init() {
        let center = NotificationCenter.default
        // Any of these can change which episodes sit in a session store.
        for name in [Constants.Notifications.playlistChanged,
                     Constants.Notifications.manyEpisodesChanged,
                     ServerNotifications.syncCompleted] {
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.invalidate()
            }
        }
    }

    /// Every episode uuid that belongs to any session's store. O(1) after the first build.
    var inAnySession: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        if let cache { return cache }
        let stores = SessionStore.shared.sessions.compactMap(\.storePlaylistUuid)
        let set = stores.isEmpty ? [] : DataManager.sharedManager.playlistEpisodeUuids(forPlaylistUuids: stores)
        cache = set
        return set
    }

    /// Drop the cache; the next `inAnySession` read rebuilds it from the stores.
    func invalidate() {
        lock.lock()
        cache = nil
        lock.unlock()
    }
}
