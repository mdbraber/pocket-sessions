import Foundation
import PocketCastsDataModel

/// Fork: the live edge of the Filter Preset system — everything that needs the *current* state
/// (which preset is active, which session stores exist) so that `FilterPresetQuery` itself can stay
/// a pure function.
///
/// The active preset is **global and sticky**: one selection, shared across every episode list,
/// persisted across launches. That is only safe because the control is **labelled with it** — an
/// invisible sticky filter is how people lose their mail and never find out why. The label is the
/// safety mechanism, not a nicety.
enum FilterPresets {
    static var active: FilterPreset {
        FilterPresetStore.shared.activePreset
    }

    /// True when the active preset narrows anything beyond the default. Drives the control's accent.
    static var isNarrowing: Bool {
        !active.isDefault
    }

    /// Every session's store playlist — what `inSession` resolves against. Global, not page-relative:
    /// an episode in the podcast's session also reads as "in session" from a smart-playlist page.
    private static var sessionStoreUuids: [String] {
        SessionStore.shared.sessions.compactMap(\.storePlaylistUuid)
    }

    /// The active preset as a WHERE fragment. Nil when it constrains nothing.
    static func predicate(columns: FilterPresetQuery.Columns = .unaliased) -> (sql: String, arguments: [Any])? {
        FilterPresetQuery.predicate(for: active, sessionStoreUuids: sessionStoreUuids, columns: columns)
    }

    /// Filters an **ordered** uuid list through the active preset, preserving its order.
    ///
    /// This is how the Session tab applies a preset: a lineup is a hand-made order, so it can't be
    /// re-queried — but it can be sieved. Going back through the same SQL keeps one source of truth
    /// for what a rule *means*, rather than growing a second, in-memory matcher that drifts from it.
    static func filtering(_ orderedUuids: [String]) -> [String] {
        guard !orderedUuids.isEmpty, let predicate = predicate() else { return orderedUuids }

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
