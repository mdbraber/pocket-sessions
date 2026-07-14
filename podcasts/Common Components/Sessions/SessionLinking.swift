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

    /// A user-initiated Remove from Up Next: an episode that also sits in a session
    /// lineup prompts for whether the session keeps it; otherwise the queue removal
    /// happens straight away. `completion` runs after the removal (never when the
    /// prompt is dismissed without choosing).
    static func removeFromUpNextAskingSession(episode: BaseEpisode, completion: (() -> Void)? = nil) {
        let removeFromQueue = {
            PlaybackManager.shared.removeIfPlayingOrQueued(episode: episode, fireNotification: true, userInitiated: true)
        }

        let containing = SessionStore.shared.sessions.filter { SessionFeederEngine.storeMemberUuids(for: $0).contains(episode.uuid) }
        guard !containing.isEmpty else {
            removeFromQueue()
            completion?()
            return
        }

        let picker = OptionsPicker(title: L10n.sessionQueueRemoveTitle.localizedUppercase)
        picker.addAction(action: OptionAction(label: L10n.sessionQueueRemoveKeep, icon: nil) {
            removeFromQueue()
            completion?()
        })
        let removeBoth = OptionAction(label: L10n.sessionQueueRemoveAlso, icon: nil) {
            removeFromQueue()
            for session in containing {
                SessionManager.shared.removeFromLineup(episodeUuids: [episode.uuid], session: session)
            }
            completion?()
        }
        removeBoth.destructive = true
        picker.addAction(action: removeBoth)
        // The remove verb can itself be chosen from another OptionsPicker (e.g. the
        // episode detail add sheet), whose dismissal is still in flight — defer a
        // runloop so this sheet presents from a settled top-most controller.
        DispatchQueue.main.async { picker.present() }
    }

    /// Bulk Remove from Up Next: if any of the selected episodes also sit in a session
    /// lineup, prompt once for whether the sessions keep them; the choice applies to
    /// the whole selection. `completion` runs after the removal.
    static func removeFromUpNextAskingSession(episodeUuids: [String], completion: (() -> Void)? = nil) {
        let removeFromQueue = {
            PlaybackManager.shared.bulkRemoveQueued(uuids: episodeUuids)
        }

        // sessionUuid -> the selected episodes it holds.
        var membership = [String: [String]]()
        let selected = Set(episodeUuids)
        for session in SessionStore.shared.sessions {
            let held = SessionFeederEngine.storeMemberUuids(for: session).filter { selected.contains($0) }
            if !held.isEmpty { membership[session.uuid] = held }
        }
        guard !membership.isEmpty else {
            removeFromQueue()
            completion?()
            return
        }

        let picker = OptionsPicker(title: L10n.sessionQueueRemoveTitle.localizedUppercase)
        picker.addAction(action: OptionAction(label: L10n.sessionQueueRemoveKeep, icon: nil) {
            removeFromQueue()
            completion?()
        })
        let removeBoth = OptionAction(label: L10n.sessionQueueRemoveAlso, icon: nil) {
            removeFromQueue()
            for (sessionUuid, held) in membership {
                guard let session = SessionStore.shared.session(uuid: sessionUuid) else { continue }
                SessionManager.shared.removeFromLineup(episodeUuids: held, session: session)
            }
            completion?()
        }
        removeBoth.destructive = true
        picker.addAction(action: removeBoth)
        // The remove verb can itself be chosen from another OptionsPicker (e.g. the
        // episode detail add sheet), whose dismissal is still in flight — defer a
        // runloop so this sheet presents from a settled top-most controller.
        DispatchQueue.main.async { picker.present() }
    }

    /// After a user-initiated session add: mirror the episodes into Up Next at the
    /// podcast's queue position (bottom unless the podcast prefers top).
    static func mirrorSessionAdd(episodeUuids: [String]) {
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
