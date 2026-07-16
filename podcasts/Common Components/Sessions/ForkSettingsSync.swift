import Foundation
import PocketCastsUtils
import UIKit

/// Fork: syncs the fork's settings through iCloud's key-value store — small scalar
/// keys where last-writer-wins is the right semantic (mirror switches, filters,
/// badges, per-tab sorts, and the active playback-session pointer, which other
/// devices adopt without auto-playing, exactly like stock's Up Next). Without the
/// iCloud entitlement the KV store just never propagates; the app stays local-only.
final class ForkSettingsSync {
    static let shared = ForkSettingsSync()

    /// Exact keys that sync verbatim.
    private static let exactKeys: [String] = [
        "SJEpisodesFilterOn",
        Settings.mirrorUpNextToSessionKey,
        Settings.mirrorSessionToUpNextKey,
        Settings.sessionAutoAddLimitKey,
        Settings.playlistsBadgeKey,
        Settings.badgeKey,
        "SJInboxAddToSessionMode",
        "SJRemoveFromSessionMode",
        "SJPlaylistsHideSessions",
        Settings.showManualSessionsKey,
        Settings.showSmartPlaylistSessionsKey,
        Settings.showPodcastSessionFoldersKey,
        Settings.showPodcastSessionPodcastsKey,
        "SJPlaylistsSortOrder",
        "SJPlaylistsLibraryType",
        "SJInboxGroupBy",
        "SJInboxGroupLimit",
        "SJGlobalInboxOptOutPodcasts",
        "SJInboxConditionalPodcasts",
        Settings.playbackSessionTypeKey,
        Settings.playbackSessionUuidKey,
        Settings.sessionInsertPositionKey,
        // Playlist folders are fork-only (upstream has no such concept), so they have no
        // other sync channel. Both are plist values — a JSON blob of folders and a
        // playlistUuid->folderUuid map — and low-churn, so KV last-writer-wins fits.
        "SJPlaylistFolders",
        "SJPlaylistFolderMembership"
    ]

    /// The active playback-session pointer. Synced so idle devices adopt the framing, but never
    /// applied over a device that's actively playing that session (see `pull`).
    private static let pointerKeys: Set<String> = [
        Settings.playbackSessionTypeKey,
        Settings.playbackSessionUuidKey
    ]

    /// Key families (per podcast / per page) that sync by prefix.
    private static let prefixes: [String] = [
        "\(Settings.mirrorUpNextToSessionKey)-",
        "\(Settings.mirrorSessionToUpNextKey)-",
        "SJTabSort-",
        "SJSessionPosition-"
    ]

    private let store = NSUbiquitousKeyValueStore.default
    private let debounce = Debounce(delay: 2)
    private var applyingRemote = false

    func start() {
        NotificationCenter.default.addObserver(self, selector: #selector(storeChangedExternally(_:)),
                                               name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                               object: store)
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged),
                                               name: UserDefaults.didChangeNotification, object: nil)
        store.synchronize()
        pull(keys: Array(store.dictionaryRepresentation.keys))
        pushAll()
    }

    // MARK: - Local → cloud

    @objc private func defaultsChanged() {
        guard !applyingRemote else { return }
        debounce.call { [weak self] in
            self?.pushAll()
        }
    }

    private func pushAll() {
        let defaults = UserDefaults.standard.dictionaryRepresentation()
        var changed = false
        for key in Self.exactKeys {
            changed = push(key: key, value: defaults[key]) || changed
        }
        for (key, value) in defaults where Self.prefixes.contains(where: { key.hasPrefix($0) }) {
            changed = push(key: key, value: value) || changed
        }
        if changed {
            // NSUbiquitousKeyValueStore uploads lazily — without this nudge a change made while the
            // app stays foreground (e.g. starting a playback session) may not reach other devices
            // until the app next backgrounds, which reads as "the pointer never syncs".
            store.synchronize()
        }
    }

    @discardableResult
    private func push(key: String, value: Any?) -> Bool {
        let current = store.object(forKey: key)
        guard !valuesEqual(current, value) else { return false }
        if let value {
            store.set(value, forKey: key)
        } else if current != nil {
            store.removeObject(forKey: key)
        }
        if Self.pointerKeys.contains(key) {
            FileLog.shared.addMessage("ForkSettingsSync: pushed session pointer \(key)=\(String(describing: value))")
        }
        return true
    }

    // MARK: - Cloud → local

    @objc private func storeChangedExternally(_ notification: Notification) {
        let changed = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            ?? Array(store.dictionaryRepresentation.keys)
        pull(keys: changed)
    }

    private func pull(keys: [String]) {
        let synced = keys.filter { key in
            Self.exactKeys.contains(key) || Self.prefixes.contains(where: { key.hasPrefix($0) })
        }
        guard !synced.isEmpty else { return }

        applyingRemote = true
        var applied = false
        var foldersChanged = false
        for key in synced {
            // The device actively playing a session owns its now-playing framing: don't let a
            // remote pointer change — another device that merely adopted the session, or cleared
            // it — clobber it and flip live session playback into Up Next. Idle devices still adopt.
            if Self.pointerKeys.contains(key), PlaybackManager.shared.isPlayingSessionEpisode {
                FileLog.shared.addMessage("ForkSettingsSync: skipped adopting pointer \(key) (this device is playing a session)")
                continue
            }
            let remote = store.object(forKey: key)
            let local = UserDefaults.standard.object(forKey: key)
            guard !valuesEqual(remote, local) else { continue }
            if Self.pointerKeys.contains(key) {
                FileLog.shared.addMessage("ForkSettingsSync: adopting session pointer \(key)=\(String(describing: remote))")
            }
            if let remote {
                UserDefaults.standard.set(remote, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
            applied = true
            if key == "SJPlaylistFolders" || key == "SJPlaylistFolderMembership" { foldersChanged = true }
        }
        applyingRemote = false

        guard applied else { return }
        // One broad refresh covers every synced setting's UI; the playback-session
        // pointer additionally announces itself (adopt, never auto-play).
        NotificationCenter.postOnMainThread(notification: SessionStore.changed)
        NotificationCenter.postOnMainThread(notification: Constants.Notifications.playbackSessionChanged)
        // Folder membership shapes the Playlists grid — rebuild it so a synced folder shows
        // without waiting for the next navigation.
        if foldersChanged {
            NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged)
        }
    }

    private func valuesEqual(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil):
            return true
        case (let a?, let b?):
            return (a as? NSObject) == (b as? NSObject)
        default:
            return false
        }
    }
}
