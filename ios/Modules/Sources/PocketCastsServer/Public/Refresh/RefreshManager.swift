import Foundation
import PocketCastsDataModel
import PocketCastsUtils
import UIKit
#if os(watchOS)
    import WatchKit
#endif

public class RefreshManager {
    public static let shared = RefreshManager()

    lazy var refreshQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1

        return queue
    }()

    // the watch has less resources than a phone, so be a bit more aggressive about not refreshing constantly
    #if os(watchOS)
        private static let minTimeBetweenRefreshes = 1.minute
    #else
        private static let minTimeBetweenRefreshes = 15.seconds
    #endif

    /// Fork: sends pending local episode changes soon, without a full refresh.
    ///
    /// Position and star each have a single-episode endpoint, so they leave the device the moment
    /// they happen. Archive and played have none — `Api_UpdateEpisodeRequest` carries only uuid,
    /// podcast, position, status, duration and stats — so they travel solely as records in the
    /// batched `/user/sync/update`. Without a nudge that batch waits for whatever comes first:
    /// foregrounding after five minutes away, a background refresh iOS schedules no sooner than
    /// every 30 minutes and often skips, or a push. Archiving could stay invisible to other devices
    /// for a long time.
    ///
    /// Deliberately NOT `refreshPodcasts`. That re-fetches every podcast and drags Up Next, history,
    /// settings and subscription tasks along with it — far more than sending one flag, and it can
    /// start auto-downloads as a side effect. This queues the sync alone: the same operation the
    /// change was already going to travel in, just sooner.
    ///
    /// Debounced, because the batch is still a network round trip and archiving a screenful one tap
    /// at a time (or any bulk action) would otherwise fire one per episode. Calls inside the window
    /// collapse into a single sync, so callers can nudge freely.
    public func syncLocalChangesSoon() {
        guard SyncManager.isUserLoggedIn() else { return }

        localChangeSyncQueue.async { [weak self] in
            guard let self else { return }
            self.pendingLocalChangeSync?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, SyncManager.isUserLoggedIn() else { return }
                // maxConcurrentOperationCount is 1, so this serialises behind any refresh already
                // running rather than racing it.
                self.refreshQueue.addOperation(SyncTask())
            }
            self.pendingLocalChangeSync = work
            self.localChangeSyncQueue.asyncAfter(deadline: .now() + RefreshManager.localChangeSyncDebounce, execute: work)
        }
    }

    /// Long enough to absorb a burst of taps, short enough to feel immediate elsewhere. Matches the
    /// spirit of `PlaybackQueue`'s own Up Next debounce.
    private static let localChangeSyncDebounce: TimeInterval = 3
    private let localChangeSyncQueue = DispatchQueue(label: "au.com.shiftyjelly.podcasts.localChangeSync")
    private var pendingLocalChangeSync: DispatchWorkItem?

    public func syncUpNext() {
        if !SyncManager.isUserLoggedIn() { return }

        // if the user has an active subscription, there might be custom episodes in their Up Next, so grab those first
        if SubscriptionHelper.hasActiveSubscription() {
            refreshQueue.addOperation(RetrieveCustomFilesTask())
        }
        refreshQueue.addOperation(UpNextSyncTask())
    }


    /// Updates a podcast and all the associated information.
    ///
    /// Note that this will force all the episodes to be updated.
    /// - Parameter podcast: a `Podcast` object
    public func refresh(podcast: Podcast, from episodeUuid: String) {
        podcast.forceRefreshEpisodeFrom = episodeUuid
        refresh(podcasts: [podcast]) {
            if SyncManager.isUserLoggedIn() {
                guard let episodes = ApiServerHandler.shared.retrieveEpisodeTaskSynchronouusly(podcastUuid: podcast.uuid) else { return }

                DataManager.sharedManager.saveBulkEpisodeSyncInfo(episodes: DataConverter.convert(syncInfoEpisodes: episodes))
                podcast.forceRefreshEpisodeFrom = nil
            }
        }
    }

    public func refresh(podcast: Podcast, from episodeUuid: String) async {
        podcast.forceRefreshEpisodeFrom = episodeUuid
        await withCheckedContinuation { continuation in
            refresh(podcasts: [podcast]) {
                if SyncManager.isUserLoggedIn() {
                    guard let episodes = ApiServerHandler.shared.retrieveEpisodeTaskSynchronouusly(podcastUuid: podcast.uuid) else { return }

                    DataManager.sharedManager.saveBulkEpisodeSyncInfo(episodes: DataConverter.convert(syncInfoEpisodes: episodes))
                    podcast.forceRefreshEpisodeFrom = nil
                }
                continuation.resume()
            }
        }
    }

    public func refreshPodcasts(forceEvenIfRefreshedRecently: Bool = false) {
        if !forceEvenIfRefreshedRecently {
            if let lastRefreshStartTime = ServerSettings.lastRefreshStartTime(), fabs(lastRefreshStartTime.timeIntervalSinceNow) < RefreshManager.minTimeBetweenRefreshes {
                // if it's been less than minTimeBetweenRefreshes since our last refresh, don't do another one. Effectively throttling user refreshes a little bit
                FileLog.shared.addMessage("Refresh - Throttled")
                DispatchQueue.global().async {
                    Thread.sleep(forTimeInterval: 1.second)
                    ServerNotificationsHelper.shared.firePodcastsUpdated()
                    NotificationCenter.default.post(name: ServerNotifications.podcastRefreshThrottled, object: nil)
                }

                return
            }
        }

        refresh(podcasts: DataManager.sharedManager.allPodcasts(includeUnsubscribed: false))
    }

    #if !os(watchOS)
    private func refresh(podcasts: [Podcast], completion: (() -> Void)? = nil) {
        UserDefaults.standard.set(Date(), forKey: ServerConstants.UserDefaults.lastRefreshStartTime)

        DispatchQueue.global().async {
            MainServerHandler.shared.refresh(podcasts: podcasts) { [weak self] refreshResponse in
                guard let self else { return }

                self.processPodcastRefreshResponse(refreshResponse) { _ in
                    completion?()
                }
            }
        }
    }
    #endif

    #if os(watchOS)
    // Watch OS 10 has a very very very weird issue that happened after using Xcode 16:
    // if the refresh call uses a [weak self] the system kills the app.
    // I'm not entirely sure why that happens but removing the weak part fixes the issue.
    // We can safely remove this method once we remove support to watchOS 10.
    private func refresh(podcasts: [Podcast], completion: (() -> Void)? = nil) {
        UserDefaults.standard.set(Date(), forKey: ServerConstants.UserDefaults.lastRefreshStartTime)

        DispatchQueue.global().async {
            let watchOsMajorVersion = WKInterfaceDevice.current().systemVersion.split(separator: ".")[safe: 0]

            if watchOsMajorVersion == "10" {
                // Let's not use [weak self] so the app is not killed
                MainServerHandler.shared.refresh(podcasts: podcasts) { refreshResponse in
                    self.processPodcastRefreshResponse(refreshResponse) { _ in
                        completion?()
                    }
                }

                return
            }

            MainServerHandler.shared.refresh(podcasts: podcasts) { [weak self] refreshResponse in
                guard let self else { return }

                self.processPodcastRefreshResponse(refreshResponse) { _ in
                    completion?()
                }
            }
        }
    }
    #endif

    public func refreshPodcasts(completion: @escaping (RefreshFetchResult) -> Void) {
        DispatchQueue.global().async {
            let podcasts = DataManager.sharedManager.allPodcasts(includeUnsubscribed: false)
            MainServerHandler.shared.refresh(podcasts: podcasts) { [weak self] refreshResponse in
                guard let self else { return }

                self.processPodcastRefreshResponse(refreshResponse, completion: completion)
            }
        }
    }

    public func cancelAllRefreshes() {
        refreshQueue.cancelAllOperations()
    }

    private func processPodcastRefreshResponse(_ refreshResponse: PodcastRefreshResponse?, completion: ((RefreshFetchResult) -> Void)?) {
        guard let response = refreshResponse, response.success() else {
            FileLog.shared.addMessage("Podcast refresh failed with message: \(refreshResponse?.message ?? "none"). See previous log for more details.")
            ServerNotificationsHelper.shared.firePodcastRefreshFailed()
            completion?(.failed)

            return
        }

        if let result = response.result {
            let refreshOperation = RefreshOperation(result: result, completionHandler: completion)
            refreshQueue.addOperation(refreshOperation)
        }
    }
}
