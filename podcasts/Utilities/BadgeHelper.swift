import Foundation
import PocketCastsDataModel
import PocketCastsServer
import Combine

class BadgeHelper {
    deinit {
        teardown()
    }

    private var cancelable: Cancellable?

    func setup() {
        let notifications: [NSNotification.Name] = [Constants.Notifications.playlistChanged,
                                                    Constants.Notifications.episodePlayStatusChanged,
                                                    Constants.Notifications.episodeArchiveStatusChanged,
                                                    Constants.Notifications.episodeStarredChanged,
                                                    Constants.Notifications.episodeDownloadStatusChanged,
                                                    Constants.Notifications.manyEpisodesChanged,
                                                    ServerNotifications.podcastsRefreshed,
                                                    Constants.Notifications.opmlImportCompleted,
                                                    Constants.Notifications.episodeDownloaded,
                                                    Constants.Notifications.playbackTrackChanged,
                                                    Constants.Notifications.playbackEnded,
                                                    Constants.Notifications.playbackStarted,
                                                    // Fork: the Inbox Count badge moves with triage state and the queue.
                                                    SessionStore.changed,
                                                    Constants.Notifications.upNextQueueChanged]

        let mergedNotifications = notifications
            .map { NotificationCenter.default.publisher(for: $0) }
            .reduce(Empty<Notification, Never>().eraseToAnyPublisher()) { acc, pub in
                acc.merge(with: pub).eraseToAnyPublisher()
            }
            .debounce(for: .seconds(3), scheduler: RunLoop.main)

        cancelable = mergedNotifications.sink { [weak self] _ in
            self?.updateBadge()
        }
    }

    func teardown() {
        cancelable?.cancel()
        cancelable = nil
    }

    @objc func updateBadge() {
        guard let badgeSetting = Settings.appBadge else { return }

        // Fork: the badge is independent of New Episodes push notifications — it
        // renders under its own (badge-only) authorization.
        if badgeSetting == .off {
            // clearBadge no-ops at zero, so an off setting never triggers a
            // permission prompt.
            clearBadge(clearNotificationsToo: false)
        } else if badgeSetting == .totalUnplayed {
            let unplayedCount = DataManager.sharedManager.count(query: "SELECT COUNT(e.id) FROM SJEpisode e LEFT JOIN SJPodcast p ON p.id = e.podcast_id WHERE p.subscribed = 1 AND e.playingStatus == 1 AND e.archived = 0", values: nil)
            setBadgeTo(unplayedCount)
        } else if badgeSetting == .newSinceLastOpened {
            guard let lastClosedDate = UserDefaults.standard.object(forKey: Constants.UserDefaults.lastAppCloseDate) as? Date else {
                clearBadge(clearNotificationsToo: false)

                return
            }

            let newCount = DataManager.sharedManager.count(query: "SELECT COUNT(e.id) FROM SJEpisode e LEFT JOIN SJPodcast p ON p.id = e.podcast_id WHERE p.subscribed = 1 AND e.playingStatus == 1 AND e.archived = 0 AND e.addedDate > ?", values: [lastClosedDate])
            setBadgeTo(newCount)
        } else if badgeSetting == .inboxCount {
            // Fork: the global Inbox count — the same number the Inbox tab wears.
            // The sweep reads every unarchived episode, so it stays off the main thread.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let global = SessionStore.shared.globalInbox
                let count = SessionFeederEngine.inboxEpisodes(for: global).filter { global.showSeen || !$0.isSeen }.count
                self?.setBadgeTo(count)
            }
        } else if badgeSetting == .filterCount {
            guard let playlistId = Settings.appBadgeFilterUuid else {
                Settings.appBadge = .off

                return
            }

            guard let playlist = DataManager.sharedManager.findPlaylist(uuid: playlistId) else {
                Settings.appBadge = .off

                return
            }

            let episodeCount = DataManager.sharedManager.episodeCount(for: playlist, episodeUuidToAdd: playlist.episodeUuidToAddToQueries())
            setBadgeTo(episodeCount)
        }
    }

    func clearNotifications() {
        clearBadge(clearNotificationsToo: true)
        updateBadge()
    }

    private func clearBadge(clearNotificationsToo: Bool) {
        DispatchQueue.main.async {
            let currentBadgeValue = UIApplication.shared.applicationIconBadgeNumber
            if clearNotificationsToo, currentBadgeValue == 0 {
                // if the badge is already 0, set it to 1 to clear out things like notifications, setting a badge that's 0 to 0 won't do that
                UIApplication.shared.applicationIconBadgeNumber = 1
            }
            if !clearNotificationsToo, currentBadgeValue == 0 { return }

            UIApplication.shared.applicationIconBadgeNumber = 0
        }
    }

    private func setBadgeTo(_ badgeNumber: Int) {
        DispatchQueue.main.async {
            UIApplication.shared.applicationIconBadgeNumber = badgeNumber
        }
    }
}
