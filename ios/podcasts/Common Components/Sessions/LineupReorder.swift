import Foundation
import PocketCastsDataModel
import PocketCastsUtils

/// Fork: re-arranging a session lineup.
///
/// A lineup is a *queue*, not a browsed list: there is exactly one saved order, and every surface
/// that shows the lineup shows that order. So "sort" was the wrong verb — nothing here is a lens
/// you can switch off, and there is no "custom" option because hand-ordered IS the base state.
/// Each `apply` is a one-shot re-arrangement written straight into the stored positions and
/// synced, exactly like the session chooser's "Reorder Sessions".
enum LineupReorder {
    /// The orders a lineup can be re-arranged into — the shared vocabulary, minus nothing: every
    /// order is available because each one is a single rewrite rather than a mode to live in.
    static var options: [EpisodeOrder] { EpisodeOrder.menuOrder }

    /// The episode that must stay at position 0: a lineup's head is what's playing, and
    /// re-arranging the rest never displaces it.
    static func pinnedEpisodeUuid(forPlaylistUuid playlistUuid: String) -> String? {
        guard let active = Settings.playbackSession(), active.uuid == playlistUuid,
              PlaybackManager.shared.currentEpisodeIsSessionSourced else { return nil }
        return PlaybackManager.shared.currentEpisode()?.uuid
    }

    /// Rewrites `playlist`'s stored order to `order`, keeping the playing episode first.
    static func apply(_ order: EpisodeOrder, to playlist: EpisodeFilter, episodes: [BaseEpisode]) {
        guard !episodes.isEmpty else { return }

        var ordered = order.sorted(episodes).map { $0.uuid }
        if let pinned = pinnedEpisodeUuid(forPlaylistUuid: playlist.uuid), ordered.contains(pinned) {
            ordered.removeAll { $0 == pinned }
            ordered.insert(pinned, at: 0)
        }

        write(ordered, to: playlist)
    }

    /// The shared order-writing path: lay the uuids down as positions and leave the playlist in
    /// drag-and-drop sort — the only sort a lineup ever has.
    ///
    /// Manual playlists own their positions outright; a smart playlist keeps its lineup in the
    /// custom-order overlay instead.
    static func write(_ orderedUuids: [String], to playlist: EpisodeFilter) {
        guard !orderedUuids.isEmpty else { return }

        if playlist.manual {
            DataManager.sharedManager.applyEpisodeOrder(orderedUuids, for: playlist)
        } else {
            // Clearing the insert anchor keeps a later "add to session" landing where the insert
            // mode says, rather than beside whatever the last insert happened to be before this
            // re-arrange moved it.
            playlist.customOrderLastInsertedUuid = ""
            DataManager.sharedManager.setCustomOrder(episodeUuids: orderedUuids, for: playlist)
        }

        playlist.sortType = PlaylistSort.dragAndDrop.rawValue
        playlist.syncStatus = SyncStatus.notSynced.rawValue
        DataManager.sharedManager.save(playlist: playlist)

        NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged, object: playlist)
    }

    /// Fork: normalise a lineup's playlist so a hand move can land — the lineup is always
    /// drag-and-drop sorted, and a smart playlist's overlay has to be seeded from the order
    /// currently on screen before individual moves mean anything.
    ///
    /// Returns false when there is nothing to write to.
    @discardableResult
    static func prepareForManualMove(_ playlist: EpisodeFilter, currentOrder: @autoclosure () -> [String]) -> Bool {
        var needsSave = false

        if playlist.sortType != PlaylistSort.dragAndDrop.rawValue {
            playlist.sortType = PlaylistSort.dragAndDrop.rawValue
            needsSave = true
        }

        if !playlist.manual, DataManager.sharedManager.positionedEpisodeUuids(for: playlist).isEmpty {
            // Custom order without a seeded lineup: moving an episode would silently no-op against
            // zero position rows. Materialize the order on screen first so the move has something
            // to move within.
            playlist.customOrderLastInsertedUuid = ""
            DataManager.sharedManager.setCustomOrder(episodeUuids: currentOrder(), for: playlist)
        }

        if needsSave {
            playlist.syncStatus = SyncStatus.notSynced.rawValue
            DataManager.sharedManager.save(playlist: playlist)
        }
        return true
    }
}
