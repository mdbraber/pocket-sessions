import Foundation
import PocketCastsDataModel
import PocketCastsUtils

/// Fork: linked adds — a user-initiated add to one world can mirror into the other.
/// One hop, never cascading: mirrors call the primitives directly and only explicit
/// user verbs call these entry points (never auto-add pipelines, playback
/// bookkeeping, or reseeds). Positions reuse the existing settings — the session's
/// insert mode on one side, the podcast's Up Next position on the other. Removals
/// are never mirrored.
enum SessionLinking {
    /// After a user-initiated Up Next add: mirror the episodes into their podcasts'
    /// sessions (created on demand), at each session's insert position.
    static func mirrorQueueAdd(episodes: [BaseEpisode]) {
        guard FeatureFlag.sessions.enabled else { return }
        let grouped = Dictionary(grouping: episodes.compactMap { $0 as? Episode }, by: \.podcastUuid)
        for (podcastUuid, podcastEpisodes) in grouped {
            guard Settings.resolvedMirrorUpNextToSession(podcastUuid: podcastUuid),
                  let podcast = DataManager.sharedManager.findPodcast(uuid: podcastUuid, includeUnsubscribed: true) else { continue }
            let session = SessionManager.shared.findOrCreateSession(forPodcast: podcast)
            let members = Set(SessionFeederEngine.storeMemberUuids(for: session))
            let toAdd = podcastEpisodes.map(\.uuid).filter { !members.contains($0) }
            guard !toAdd.isEmpty else { continue }
            SessionManager.shared.addToLineup(episodeUuids: toAdd, session: session)
        }
    }

    /// After a user-initiated session add: mirror the episodes into Up Next at the
    /// podcast's queue position (bottom unless the podcast prefers top).
    static func mirrorSessionAdd(episodeUuids: [String]) {
        guard FeatureFlag.sessions.enabled else { return }
        for uuid in episodeUuids {
            guard let episode = DataManager.sharedManager.findEpisode(uuid: uuid),
                  Settings.resolvedMirrorSessionToUpNext(podcastUuid: episode.podcastUuid),
                  !PlaybackManager.shared.inUpNext(episode: episode),
                  !PlaybackManager.shared.isNowPlayingEpisode(episodeUuid: uuid) else { continue }
            let toTop = DataManager.sharedManager.findPodcast(uuid: episode.podcastUuid, includeUnsubscribed: true)?
                .autoAddToUpNextSetting() == .addFirst
            PlaybackManager.shared.addToUpNext(episode: episode, ignoringQueueLimit: true, toTop: toTop, userInitiated: false)
        }
    }
}
