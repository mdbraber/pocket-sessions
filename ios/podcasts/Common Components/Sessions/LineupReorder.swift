import Foundation
import PocketCastsDataModel
import PocketCastsServer
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
        guard let active = Settings.playbackSession, active.uuid == playlistUuid,
              PlaybackManager.shared.currentEpisodeIsSessionSourced else { return nil }
        return PlaybackManager.shared.currentEpisode?.uuid
    }

    /// Rewrites `playlist`'s stored order to `order`, keeping the playing episode first.
    static func apply(_ order: EpisodeOrder, to playlist: EpisodeFilter, episodes: [BaseEpisode]) {
        guard !episodes.isEmpty else { return }
        write(arranged(episodes, in: order, pinning: pinnedEpisodeUuid(forPlaylistUuid: playlist.uuid)), to: playlist)
    }

    /// A hand reorder of a FILTERED lineup, written back without losing what the filter hid: the
    /// visible episodes take the slots visible episodes held, in their new order; hidden ones keep
    /// theirs. (Writing just the visible list would drop the hidden members from the session.) Pure.
    static func mergingVisibleOrder(_ reorderedVisible: [String], into full: [String]) -> [String] {
        let visible = Set(reorderedVisible)
        var next = reorderedVisible.makeIterator()
        let merged = full.map { uuid in visible.contains(uuid) ? (next.next() ?? uuid) : uuid }
        // Anything visible the full order didn't know goes on the end.
        let known = Set(full)
        return merged + reorderedVisible.filter { !known.contains($0) }
    }

    /// The whole saved order of `session`'s store, for `mergingVisibleOrder`.
    static func storedOrder(of session: Session) -> [String] {
        guard let uuid = session.storePlaylistUuid, let store = DataManager.shared.findPlaylist(uuid: uuid) else { return [] }
        return DataManager.shared.positionedEpisodeUuids(for: store)
    }

    /// `episodes` in `order`, with `pinned` (the playing episode) moved to the front. Pure.
    static func arranged(_ episodes: [BaseEpisode], in order: EpisodeOrder, pinning pinned: String?) -> [String] {
        var ordered = order.sorted(episodes).map { $0.uuid }
        if let pinned, ordered.contains(pinned) {
            ordered.removeAll { $0 == pinned }
            ordered.insert(pinned, at: 0)
        }
        return ordered
    }

    /// The shared order-writing path: lay the uuids down as positions and leave the playlist in
    /// drag-and-drop sort — the only sort a lineup ever has.
    ///
    /// Manual playlists own their positions outright; a smart playlist keeps its lineup in the
    /// custom-order overlay instead.
    static func write(_ orderedUuids: [String], to playlist: EpisodeFilter) {
        guard !orderedUuids.isEmpty else { return }

        if playlist.manual {
            DataManager.shared.applyEpisodeOrder(orderedUuids, for: playlist)
        } else {
            // Clearing the insert anchor keeps a later "add to session" landing where the insert
            // mode says, rather than beside whatever the last insert happened to be before this
            // re-arrange moved it.
            playlist.customOrderLastInsertedUuid = ""
            DataManager.shared.setCustomOrder(episodeUuids: orderedUuids, for: playlist)
        }

        playlist.sortType = PlaylistSort.dragAndDrop.rawValue
        playlist.syncStatus = SyncStatus.notSynced.rawValue
        DataManager.shared.save(playlist: playlist)

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

        if !playlist.manual, DataManager.shared.positionedEpisodeUuids(for: playlist).isEmpty {
            // Custom order without a seeded lineup: moving an episode would silently no-op against
            // zero position rows. Materialize the order on screen first so the move has something
            // to move within.
            playlist.customOrderLastInsertedUuid = ""
            DataManager.shared.setCustomOrder(episodeUuids: currentOrder(), for: playlist)
        }

        if needsSave {
            playlist.syncStatus = SyncStatus.notSynced.rawValue
            DataManager.shared.save(playlist: playlist)
        }
        return true
    }
}

/// Fork: a session lineup's arrangement — its Sort By and Group By, the sticky counterparts to
/// `LineupReorder`'s one-shot arrange.
///
/// Both are saved once, on the `Session` (synced), and nowhere else: the playlist page, the Queue
/// and the podcast page all read and write those values, which is what keeps the old two-states bug
/// (a per-page sort silently disabling dragging elsewhere) from coming back.
///
/// They set the PLAY order, not just the display — a session's list is what plays next, and showing
/// one order while playing another would be worse than either. The order the player follows is the
/// store's positions, so while the lineup is arranged this keeps the positions arranged: whenever it
/// changes (episodes added by hand, auto-add, a sync) it is laid out again — grouped, then sorted
/// within each group. New episodes therefore land where the arrangement says; the "Position in
/// Session" insert mode only matters under Manual. The playing episode stays first.
///
/// Manual is not lost by arranging: the hand-made order is saved when the lineup leaves Manual and
/// restored when the user picks Manual again (new episodes go where the insert mode says). Placing
/// an episode by hand (a drag, a grip move, Move to Top/Bottom) is different — the user is making a
/// new hand order from what's on screen, so the lineup goes to Manual as it stands and the saved one
/// is dropped. Playing an episode changes nothing: play-moves-to-top is bookkeeping, and the
/// arrangement puts things back around the new head.
enum LineupSort {
    /// The session's current values, read fresh from the store.
    private static func fresh(_ session: Session) -> Session {
        SessionStore.shared.session(uuid: session.uuid) ?? session
    }

    /// The session's sort (nil = Manual within whatever grouping applies).
    static func order(of session: Session) -> EpisodeOrder? { fresh(session).lineupSortOrder }
    static func grouping(of session: Session) -> EpisodeGroupBy { fresh(session).lineupGrouping }
    static func groupsReversed(of session: Session) -> Bool { fresh(session).lineupGroupReversed }

    /// Sets (nil = Manual) the sort, from the menu.
    static func set(_ order: EpisodeOrder?, for session: Session) {
        update(session) { $0.lineupSort = order?.rawValue }
    }

    /// Sets (`.none` = ungrouped) the grouping, from the menu.
    static func setGrouping(_ groupBy: EpisodeGroupBy, for session: Session) {
        update(session) { $0.lineupGroupBy = groupBy == .none ? nil : groupBy.rawValue }
    }

    static func setGroupsReversed(_ reversed: Bool, for session: Session) {
        update(session) { $0.lineupGroupReversed = reversed }
    }

    /// A hand placement: from here the lineup is Manual, exactly as it stands (the saved hand order
    /// is dropped — the user is making a new one). Call BEFORE writing the new positions, so the
    /// write isn't arranged straight back.
    static func switchToManual(_ session: Session?) {
        guard let session, !fresh(session).lineupIsManual else { return }
        SessionStore.shared.mutateSession(session) {
            $0.lineupSort = nil
            $0.lineupGroupBy = nil
            $0.manualLineupOrder = []
        }
        // The sort or grouping the user picked just went away as a side effect of a drag — say so,
        // or the menu silently reads Manual next time with no hint why.
        DispatchQueue.main.async { Toast.show(L10n.lineupSwitchedToManual) }
    }

    /// A menu change: saves the hand order on leaving Manual, restores it on returning, and lays the
    /// lineup out in whatever arrangement results.
    private static func update(_ session: Session, _ transform: @escaping (inout Session) -> Void) {
        let before = fresh(session)
        let store = before.storePlaylistUuid.flatMap { DataManager.shared.findPlaylist(uuid: $0) }
        let current = store.map { DataManager.shared.positionedEpisodeUuids(for: $0) } ?? []

        var after = before
        transform(&after)
        let leavingManual = before.lineupIsManual && !after.lineupIsManual
        let returningToManual = !before.lineupIsManual && after.lineupIsManual
        let savedHandOrder = before.manualLineupOrder

        SessionStore.shared.mutateSession(session) { session in
            transform(&session)
            if leavingManual { session.manualLineupOrder = current }
            if returningToManual { session.manualLineupOrder = [] }
        }

        if returningToManual, let store, !savedHandOrder.isEmpty {
            let pinned = LineupReorder.pinnedEpisodeUuid(forPlaylistUuid: store.uuid)
            let restored = restoredOrder(saved: savedHandOrder, current: current, insertMode: after.insertMode, pinning: pinned)
            if restored != current { LineupReorder.write(restored, to: store) }
        } else {
            keepArranged(fresh(session))
        }
    }

    /// The saved hand order, re-applied to today's members: episodes that left are dropped, and ones
    /// that joined while the lineup was arranged go where the insert mode says (the bottom for
    /// Bottom, otherwise the top), in the order they're in now. The playing episode stays first. Pure.
    static func restoredOrder(saved: [String], current: [String], insertMode: Int32, pinning pinned: String?) -> [String] {
        let members = Set(current)
        let kept = saved.filter(members.contains)
        let keptSet = Set(kept)
        let joined = current.filter { !keptSet.contains($0) }
        var order = insertMode == PlaylistInsertMode.bottom.rawValue ? kept + joined : joined + kept
        if let pinned, let index = order.firstIndex(of: pinned) {
            order.remove(at: index)
            order.insert(pinned, at: 0)
        }
        return order
    }

    /// `episodes` in the session's arrangement: grouped (groups in their fixed order, reversed if
    /// asked), each group sorted — or, with no sort, kept in its current order — and the playing
    /// episode first. Pure.
    static func arranged(_ episodes: [BaseEpisode], sort: EpisodeOrder?, groupBy: EpisodeGroupBy, groupsReversed: Bool, pinning pinned: String?) -> [String] {
        var items = sort.map { $0.sorted(episodes) } ?? episodes
        if groupBy != .none {
            items = EpisodeGrouper.group(items, by: groupBy, limit: 0, reversed: groupsReversed) { $0 }.flatMap(\.items)
        }
        var ordered = items.map(\.uuid)
        if let pinned, let index = ordered.firstIndex(of: pinned) {
            ordered.remove(at: index)
            ordered.insert(pinned, at: 0)
        }
        return ordered
    }

    /// A preset picked for a Session tab seeds the session's arrangement, as it seeds a browsed
    /// list's sort and grouping — but only with what it actually specifies: an empty sort or
    /// grouping leaves the session's alone. Manual and None are real choices (Manual brings back
    /// the saved hand order once nothing else arranges the lineup).
    static func applySeeds(of preset: FilterPreset, to session: Session) {
        switch preset.sortSeed {
        case .manual: set(nil, for: session)
        case .order(let order): set(order, for: session)
        case nil: break
        }
        if let groupBy = preset.groupSeed {
            setGrouping(groupBy, for: session)
            if groupBy != .none { setGroupsReversed(preset.groupReversed, for: session) }
        }
    }

    // MARK: - Keeping arranged lineups arranged

    private static var started = false
    private static var pendingSessionUuids = Set<String>()
    private static var flushScheduled = false

    /// Watches everything that can change a lineup's membership. Idempotent.
    static func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(forName: Constants.Notifications.playlistChanged, object: nil, queue: .main) { note in
            if let playlist = note.object as? EpisodeFilter {
                if let session = SessionStore.shared.session(forStore: playlist.uuid) { schedule([session]) }
            } else {
                scheduleAllArranged()
            }
        }
        // Sync imports write positions without a playlistChanged; an arrangement set on another
        // device arrives as a session change.
        center.addObserver(forName: ServerNotifications.syncCompleted, object: nil, queue: .main) { _ in scheduleAllArranged() }
        center.addObserver(forName: SessionStore.changed, object: nil, queue: .main) { _ in scheduleAllArranged() }
        scheduleAllArranged()
    }

    private static func scheduleAllArranged() {
        schedule(SessionStore.shared.sessions)
    }

    /// Coalesced onto the next main-loop turn: one add fires several notifications.
    private static func schedule(_ sessions: [Session]) {
        let arranged = sessions.filter { !$0.lineupIsManual }
        guard !arranged.isEmpty else { return }
        pendingSessionUuids.formUnion(arranged.map(\.uuid))
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async {
            flushScheduled = false
            let uuids = pendingSessionUuids
            pendingSessionUuids.removeAll()
            for uuid in uuids {
                if let session = SessionStore.shared.session(uuid: uuid) { keepArranged(session) }
            }
        }
    }

    /// Lays an arranged session's store out in its arrangement, if it isn't already. A no-op for
    /// Manual — and when the order already holds, which is what stops its own write from looping.
    static func keepArranged(_ session: Session) {
        guard !session.lineupIsManual,
              let storeUuid = session.storePlaylistUuid,
              let store = DataManager.shared.findPlaylist(uuid: storeUuid) else { return }
        let current = DataManager.shared.positionedEpisodeUuids(for: store)
        let episodes = current.compactMap { DataManager.shared.findBaseEpisode(uuid: $0) }
        guard episodes.count > 1 else { return }
        let ordered = arranged(episodes, sort: session.lineupSortOrder, groupBy: session.lineupGrouping,
                               groupsReversed: session.lineupGroupReversed,
                               pinning: LineupReorder.pinnedEpisodeUuid(forPlaylistUuid: storeUuid))
        // Compare against the rows we could arrange: an unresolvable row keeps its place at the end.
        let found = Set(ordered)
        guard ordered != current.filter(found.contains) else { return }
        LineupReorder.write(ordered, to: store)
    }
}
