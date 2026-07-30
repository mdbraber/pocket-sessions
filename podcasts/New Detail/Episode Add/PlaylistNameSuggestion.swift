import Foundation
import PocketCastsDataModel

/// Fork: names a new playlist after the route the user took to create it.
///
/// Adding a podcast's Season 2 group offers "Serial - Season 2"; adding from a podcast page offers
/// the podcast's name. It is always a SUGGESTION — the field stays editable and its placeholder is
/// still the generic default, so an empty field falls back exactly as it did before.
enum PlaylistNameSuggestion {
    /// Joins the parts of a route, skipping any that are missing or blank, e.g. podcast + group.
    /// Returns nil when nothing is left, so the caller passes "no suggestion" rather than an
    /// empty name.
    static func joined(_ parts: String?...) -> String? {
        let cleaned = parts
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        return cleaned.joined(separator: " - ")
    }

    /// The name for a single episode's podcast — what "Add to Playlist" from an episode means.
    static func forEpisode(_ episode: BaseEpisode) -> String? {
        joined((episode as? Episode)?.parentPodcast()?.title)
    }

    /// A selection only has a lineage worth borrowing when it all came from ONE podcast. A mixed
    /// selection (from a playlist, a filter, Up Next) has no single name to inherit, and guessing
    /// one from whichever episode happened to be first would be worse than saying nothing.
    static func forEpisodes(_ episodes: [Episode]) -> String? {
        let podcastUuids = Set(episodes.map(\.podcastUuid))
        guard podcastUuids.count == 1, let first = episodes.first else { return nil }
        return forEpisode(first)
    }
}
