import Foundation
import PocketCastsDataModel

/// Which list a filter applies to. The Episodes list and the Session lineup keep **independent**
/// active presets — filtering "long unplayed episodes" on the Episodes tab should not also reshape
/// the hand-made Session lineup. Global across pages within a scope, but separate between scopes.
enum FilterScope: String {
    case episodes, session
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
    static func active(_ scope: FilterScope = .episodes) -> FilterPreset {
        FilterPresetStore.shared.activePreset(for: scope)
    }

    /// True when the scope's active preset narrows anything beyond the default. Drives the accent.
    static func isNarrowing(_ scope: FilterScope = .episodes) -> Bool {
        !active(scope).isDefault
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
            let members = DataManager.sharedManager.allPodcasts(includeUnsubscribed: false)
                .filter { preset.folderUuids.contains($0.folderUuid ?? "") }
                .map(\.uuid)
            uuids.formUnion(members)
        }
        return Array(uuids)
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

    /// Filters an **ordered** uuid list through the scope's active preset, preserving its order.
    ///
    /// This is how the Session tab applies a preset: a lineup is a hand-made order, so it can't be
    /// re-queried — but it can be sieved. Going back through the same SQL keeps one source of truth
    /// for what a rule *means*, rather than growing a second, in-memory matcher that drifts from it.
    static func filtering(_ orderedUuids: [String], scope: FilterScope = .session, applyScope: Bool = true) -> [String] {
        guard !orderedUuids.isEmpty, let predicate = predicate(scope, applyScope: applyScope) else { return orderedUuids }

        let placeholders = orderedUuids.map { _ in "?" }.joined(separator: ",")
        let matching = Set(
            DataManager.sharedManager.findEpisodesWhere(
                customWhere: "uuid IN (\(placeholders)) AND \(predicate.sql)",
                arguments: orderedUuids + predicate.arguments
            ).map(\.uuid)
        )
        return orderedUuids.filter { matching.contains($0) }
    }
}
