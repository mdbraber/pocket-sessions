import PocketCastsDataModel
import UIKit
import Combine

class ShortcutManager: CustomObserver {

    private var cancelable: Cancellable?

    func listenForShortcutChanges() {
        //Cleans up existing observers
        stopListeningForShortcutChanges()

        let notifications: [NSNotification.Name] = [Constants.Notifications.playbackStarted,
                                                    Constants.Notifications.playbackPaused,
                                                    Constants.Notifications.playbackEnded,
                                                    // Fork: the playback SOURCE flipping (session ⇄ Up Next) re-orders the shortcuts.
                                                    Constants.Notifications.playbackTrackChanged,
                                                    Constants.Notifications.playlistChanged,
                                                    Constants.Notifications.podcastAdded,
                                                    Constants.Notifications.episodePlayStatusChanged,
                                                    Constants.Notifications.episodeArchiveStatusChanged,
                                                    Constants.Notifications.episodeStarredChanged,
                                                    Constants.Notifications.episodeDownloadStatusChanged,
                                                    Constants.Notifications.manyEpisodesChanged]

        let mergedNotifications = notifications
            .map { NotificationCenter.default.publisher(for: $0) }
            .reduce(Empty<Notification, Never>().eraseToAnyPublisher()) { acc, pub in
                acc.merge(with: pub).eraseToAnyPublisher()
            }
            .debounce(for: .seconds(3), scheduler: RunLoop.main)

        cancelable = mergedNotifications.sink { [weak self] _ in
            self?.shortcutsRequireUpdate()
        }

        shortcutsRequireUpdate()
    }

    func stopListeningForShortcutChanges() {
        cancelable?.cancel()
        cancelable = nil
    }

    @objc private func shortcutsRequireUpdate() {
        DispatchQueue.global().async { [weak self] () in
            guard let strongSelf = self else { return }

            strongSelf.updateShortcuts()
        }
    }

    private func updateShortcuts() {
        var shortcutItems = [UIMutableApplicationShortcutItem]()

        // Fork: two play options — Up Next and the active session, each captioned with
        // the episode that would play there.
        let session = Settings.playbackSession()

        let upNextEpisode: BaseEpisode? = session == nil
            ? (PlaybackManager.shared.currentEpisode() ?? PlaybackManager.shared.queue.allEpisodes(includeNowPlaying: false).first)
            : PlaybackManager.shared.queue.allEpisodes(includeNowPlaying: false).first
        let upNextItem: UIMutableApplicationShortcutItem? = upNextEpisode.map { episode in
            UIMutableApplicationShortcutItem(
                type: "au.com.shiftyjelly.podcasts",
                localizedTitle: L10n.upNext,
                localizedSubtitle: episode.displayableTitle(),
                icon: UIApplicationShortcutIcon(type: .play),
                userInfo: ["url": "pktc://shortcuts/play-upnext" as NSSecureCoding]
            )
        }

        var sessionItem: UIMutableApplicationShortcutItem?
        if let session {
            let sessionName: String?
            switch session.type {
            case .podcast:
                sessionName = DataManager.sharedManager.findPodcast(uuid: session.uuid, includeUnsubscribed: true)?.title
            case .playlist, .smartPlaylist:
                sessionName = DataManager.sharedManager.findPlaylist(uuid: session.uuid)?.playlistName
            }
            let sessionEpisode = PlaybackManager.shared.currentEpisode() ?? session.nextEpisode(after: nil)
            if let sessionName {
                sessionItem = UIMutableApplicationShortcutItem(
                    type: "au.com.shiftyjelly.podcasts",
                    localizedTitle: sessionName,
                    localizedSubtitle: sessionEpisode?.displayableTitle(),
                    icon: UIApplicationShortcutIcon(type: .play),
                    userInfo: ["url": "pktc://shortcuts/play-session" as NSSecureCoding]
                )
            }
        }

        // Lead with whichever world is the current playback SOURCE, so a right-press → first option
        // resumes what's actually sounding: the session while it's the source, otherwise Up Next.
        if PlaybackManager.shared.currentEpisodeIsSessionSourced {
            shortcutItems.append(contentsOf: [sessionItem, upNextItem].compactMap { $0 })
        } else {
            shortcutItems.append(contentsOf: [upNextItem, sessionItem].compactMap { $0 })
        }

        if shortcutItems.isEmpty {
            shortcutItems.append(
                UIMutableApplicationShortcutItem(
                    type: "au.com.shiftyjelly.podcasts",
                    localizedTitle: "Find New Podcasts",
                    localizedSubtitle: nil,
                    icon: UIApplicationShortcutIcon(type: .search),
                    userInfo: ["url": "pktc://shortcuts/discover" as NSSecureCoding]
                )
            )
        }

        DispatchQueue.main.async {
            UIApplication.shared.shortcutItems = shortcutItems
        }
    }
}
