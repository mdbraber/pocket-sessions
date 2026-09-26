import Foundation
import PocketCastsDataModel

/// Which list a filter applies to. The Episodes list and the Session lineup keep **independent**
/// active presets — filtering "long unplayed episodes" on the Episodes tab should not also reshape
/// the hand-made Session lineup. Global across pages within a scope, but separate between scopes.
///
/// `sessionEpisodes` is the Episodes list of a *session* (the Queue's Episodes tab, a session or
/// smart playlist page's Episodes tab). It has a session behind it, so it is the one scope that
/// offers contextual presets ("Not in Session") — and it opens on that one, so the list starts out
/// as "what could still be added".
enum FilterScope: String, CaseIterable {
    case episodes, session, sessionEpisodes

    /// Whether lists in this scope have a session behind them — i.e. can resolve `inThisSession`.
    var hasSessionContext: Bool {
        self == .sessionEpisodes
    }

    /// The preset a scope shows until the user picks one.
    var defaultPresetUuid: String {
        hasSessionContext ? FilterPreset.notInThisSession.uuid : FilterPreset.allEpisodes.uuid
    }
}

/// Fork: the live edge of the Filter Preset system — everything that needs the *current* state
/// (which preset is active, which session stores exist) so that `FilterPresetQuery` itself can stay
/// a pure function.
///
/// The active preset is **global and sticky within a scope**: one selection per scope, shared across
/// every page, persisted across launches. That is only safe because the control is **labelled with
/// it** — an invisible sticky filter is how people lose their mail and never find out why. The label
/// is the safety mechanism, not a nicety.
enum FilterPresets {
    /// `singlePodcast`: the list shows one podcast (a podcast page, a podcast's session), so presets
    /// limited to podcasts or folders don't apply there.
    static func active(_ scope: FilterScope = .episodes, singlePodcast: Bool = false) -> FilterPreset {
        FilterPresetStore.shared.activePreset(for: scope, singlePodcast: singlePodcast)
    }

    /// True when the list's active preset narrows anything beyond the default. Drives the accent.
    static func isNarrowing(_ scope: FilterScope = .episodes, singlePodcast: Bool = false) -> Bool {
        !active(scope, singlePodcast: singlePodcast).isDefault
    }

    /// Every session's store playlist — what `inSession` resolves against. Global, not page-relative:
    /// an episode in the podcast's session also reads as "in session" from a smart-playlist page.
    private static var sessionStoreUuids: [String] {
        SessionStore.shared.sessions.compactMap(\.storePlaylistUuid)
    }

    /// The Up Next snapshot a preset needs (now-playing included) — what `inUpNext` resolves
    /// against. Empty unless the preset actually filters on Up Next, so the common case never pays
    /// to load and hydrate the whole queue on every list refresh.
    static func upNextEpisodeUuids(for preset: FilterPreset) -> [String] {
        guard preset.inUpNext != nil else { return [] }
        return PlaybackManager.shared.queue.allEpisodes(includeNowPlaying: true).map(\.uuid)
    }

    /// Resolves a preset's podcast/folder scope to a concrete podcast-uuid list — folders expanded
    /// to their current members. `nil` when the preset has no scope. A non-nil but empty result
    /// means the scope is set but matches no podcasts (e.g. an empty folder).
    static func scopePodcastUuids(for preset: FilterPreset) -> [String]? {
        guard preset.isScoped else { return nil }
        var uuids = preset.podcastUuids
        if !preset.folderUuids.isEmpty {
            let members = DataManager.shared.allPodcasts(includeUnsubscribed: false)
                .filter { preset.folderUuids.contains($0.folderUuid ?? "") }
                .map(\.uuid)
            uuids.formUnion(members)
        }
        return Array(uuids)
    }

    /// Narrows a list that isn't a query — a session lineup, in its saved order — to what `preset`
    /// lets through, keeping the order. One query for the whole list. Non-podcast episodes (Files)
    /// always pass: presets speak about podcast episodes.
    static func filter<T>(_ items: [T], by preset: FilterPreset, thisSessionStoreUuid: String?, singlePodcast: Bool, episode: (T) -> BaseEpisode) -> [T] {
        guard let predicate = FilterPresetQuery.predicate(
            for: preset,
            sessionStoreUuids: sessionStoreUuids,
            thisSessionStoreUuid: thisSessionStoreUuid,
            upNextEpisodeUuids: upNextEpisodeUuids(for: preset),
            scopePodcastUuids: singlePodcast ? nil : scopePodcastUuids(for: preset)
        ) else { return items }
        let uuids = items.compactMap { episode($0) as? Episode }.map(\.uuid)
        guard !uuids.isEmpty else { return items }
        let placeholders = uuids.map { _ in "?" }.joined(separator: ",")
        let matching = Set(DataManager.shared.findEpisodesWhere(customWhere: "uuid IN (\(placeholders)) AND \(predicate.sql)", arguments: uuids + predicate.arguments).map(\.uuid))
        return items.filter { item in
            let candidate = episode(item)
            return !(candidate is Episode) || matching.contains(candidate.uuid)
        }
    }

    /// The active preset as a WHERE fragment. Nil when it constrains nothing.
    ///
    /// `applyScope` is false on single-podcast surfaces (a podcast's own Episodes/Session list),
    /// which ignore the podcast/folder rule — see `FilterPreset.podcastUuids`.
    static func predicate(_ scope: FilterScope = .episodes, columns: FilterPresetQuery.Columns = .unaliased, applyScope: Bool = true) -> (sql: String, arguments: [Any])? {
        let preset = active(scope)
        return FilterPresetQuery.predicate(
            for: preset,
            sessionStoreUuids: sessionStoreUuids,
            upNextEpisodeUuids: upNextEpisodeUuids(for: preset),
            scopePodcastUuids: applyScope ? scopePodcastUuids(for: preset) : nil,
            columns: columns
        )
    }
}
