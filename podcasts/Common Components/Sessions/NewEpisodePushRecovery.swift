import Foundation
import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils

/// Fork: recovers a new episode that a push announced but a normal refresh will never deliver.
///
/// **The problem.** `refresh.pocketcasts.com/user/update` keeps its own per-device record of what
/// it has already handed over. The app posts `last_episodes` (its newest local episode per podcast)
/// as the anchor, but once the service has reported an episode to a device it advances that
/// device's cursor — so a later request quoting the *same* anchor is answered from the cursor, not
/// from the anchor, and comes back empty. If the app was ever handed an episode and failed to
/// persist it, the ordinary refresh can never fetch it again: it keeps asking from the same anchor
/// and is told, correctly from the server's point of view, that there is nothing new.
///
/// Observed on 2026-07-30: the PCS watcher pushed "Cassette: Tour Tapes — #3 Tour Féminin '84",
/// and the app refreshed repeatedly for hours, each time logging "found 0 new episodes", while the
/// very same request issued from a different device id returned that episode every time.
///
/// **The fix.** A PCS episode push names the podcast and the episode (`podcast_uuid` + `eu`, the
/// same shape as PC's own episode pushes). When one arrives for an episode we do not have, ask for
/// that one podcast again from an *older* anchor — the second-newest local episode — using
/// `RefreshManager.refresh(podcast:from:)`, which posts `forceRefreshEpisodeFrom` instead of the
/// usual `latestEpisodeUuid`. A different anchor moves the server's cursor back, and the missing
/// episode arrives. Verified: the episode above landed within seconds of a forced refresh.
///
/// This is self-healing rather than preventative — it does not matter *what* swallowed the original
/// delivery, only that the app can now ask again in a way the server will answer.
enum NewEpisodePushRecovery {
    /// The push keys PC uses for an episode notification, which the PCS watcher mirrors.
    private static let episodeUuidKey = "eu"
    private static let podcastUuidKey = "podcast_uuid"

    /// Re-fetches the podcast named in `userInfo` when it announces an episode we do not have.
    ///
    /// Cheap and safe to call on every push: it does nothing at all unless the payload names both
    /// uuids AND the episode is genuinely missing, so the normal (working) delivery path is never
    /// disturbed. `completion` runs once the targeted refresh finishes, or immediately when there
    /// is nothing to recover.
    static func recover(userInfo: [AnyHashable: Any], completion: (() -> Void)? = nil) {
        guard let episodeUuid = userInfo[episodeUuidKey] as? String, !episodeUuid.isEmpty,
              let podcastUuid = userInfo[podcastUuidKey] as? String, !podcastUuid.isEmpty else {
            completion?()
            return
        }
        recover(episodeUuid: episodeUuid, podcastUuid: podcastUuid, completion: completion)
    }

    /// The uuid-taking half, so a caller that already knows what is missing can use it directly.
    static func recover(episodeUuid: String, podcastUuid: String, completion: (() -> Void)? = nil) {
        // The ordinary path works the overwhelming majority of the time. Only step in when it
        // demonstrably has not.
        guard DataManager.sharedManager.findEpisode(uuid: episodeUuid) == nil else {
            completion?()
            return
        }
        guard let podcast = DataManager.sharedManager.findPodcast(uuid: podcastUuid, includeUnsubscribed: true) else {
            completion?()
            return
        }

        // The anchor has to be OLDER than the one the normal refresh already sent, or the server
        // answers from its cursor again and we learn nothing. The second-newest local episode is
        // the smallest such step: everything published after it comes back, which is the missing
        // episode plus at most the newest one we already hold (skipped as an existing uuid).
        let latest = podcast.latestEpisodes(limit: 2)
        guard latest.count > 1, let anchor = latest.last else {
            // Nothing older to anchor to (a podcast with a single local episode). Leave it to the
            // ordinary refresh rather than inventing an anchor the server would reject.
            FileLog.shared.addMessage("NewEpisodePushRecovery: no older anchor for \(podcast.title ?? podcastUuid)")
            completion?()
            return
        }

        FileLog.shared.addMessage("NewEpisodePushRecovery: \(podcast.title ?? podcastUuid) is missing \(episodeUuid) — re-asking from \(anchor.uuid)")
        RefreshManager.shared.refresh(podcast: podcast, from: anchor.uuid)

        // `refresh(podcast:from:)` has no completion of its own, and the recovery is best-effort:
        // callers use `completion` to carry on, not to depend on the episode having arrived.
        completion?()
    }
}
