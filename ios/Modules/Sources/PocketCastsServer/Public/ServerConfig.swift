import Foundation
import PocketCastsDataModel

public class ServerConfig {
    public static let shared = ServerConfig()

    private var backgroundSessionHandler: (() -> Void)?

    // MARK: - App values required for Server communication

    public var syncDelegate: ServerSyncDelegate?
    public var playbackDelegate: ServerPlaybackDelegate?

    /// Error logger for reporting sync errors to crash reporting services (e.g., Sentry)
    public var errorLogger: ErrorLogger?

    /// Fork: injected by the app at launch (same pattern as `PlaybackSession.episodeSource`).
    ///
    /// Given a set of episode uuids the playlist sync is about to (re-)add to the Inbox
    /// (`DataManager.inboxPlaylistUuid`), returns the subset the app's seen-ledger says were
    /// deliberately removed. Playlist sync is last-writer-wins over the whole membership set
    /// with no tombstones, so without this filter a lagging device's stale upload resurrects
    /// episodes the user already triaged away. Only ever consulted for the Inbox playlist.
    public var inboxSeenFilter: ((Set<String>) -> Set<String>)?

    public func setBackgroundSessionCompletionHandler(handler: (() -> Void)?) {
        backgroundSessionHandler = handler
    }

    public func backgroundSessionCompletionHandler() -> (() -> Void)? {
        backgroundSessionHandler
    }
}
