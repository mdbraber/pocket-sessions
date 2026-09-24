import UIKit
import PocketCastsDataModel

/// Fork: re-arranging the podcast page's Session lineup.
///
/// The lineup has one saved order — it is never sorted over. Two ways to change it: drag the rows
/// (long-press normally, or with real grips in "Reorder Episodes" mode), or arrange the whole thing
/// at once into a date/duration/title order. Both write the same positions.
extension PodcastViewController {
    // MARK: - One-shot re-arrangement

    func reorderSessionLineup(order: EpisodeOrder) {
        guard let podcast,
              let session = SessionStore.shared.session(forPodcast: podcast.uuid),
              let index = episodeInfo.firstIndex(where: { $0.model == "episodes" }) else { return }

        let episodes = episodeInfo[index].elements.compactMap { $0 as? ListEpisode }
        guard episodes.count > 1 else { return }

        var sorted = order.sorted(episodes) { $0.episode }
        // The lineup's head is what's playing; re-arranging the rest never displaces it.
        if let storeUuid = session.storePlaylistUuid,
           let pinned = LineupReorder.pinnedEpisodeUuid(forPlaylistUuid: storeUuid),
           let current = sorted.firstIndex(where: { $0.episode.uuid == pinned }) {
            sorted.insert(sorted.remove(at: current), at: 0)
        }

        SessionManager.shared.setLineupOrder(episodeUuids: sorted.map { $0.episode.uuid }, session: session)
        episodesDidChange()
    }

    // MARK: - Reorder Episodes mode

    /// A long-press drag is invisible until you know it's there; this mode puts a grip on every row
    /// and suspends tap-to-open, swipes and multi-select for its duration.
    func enterLineupReorderMode() {
        guard showingSession, !lineupReorderMode else { return }
        if isMultiSelectEnabled { isMultiSelectEnabled = false }

        lineupReorderMode = true
        // Editing mode otherwise draws the multi-select circles beside the grips.
        episodesTable.allowsMultipleSelectionDuringEditing = false
        episodesTable.setEditing(true, animated: true)
        updateLineupReorderChrome()
        episodesTable.reloadData()
    }

    @objc func exitLineupReorderMode() {
        guard lineupReorderMode else { return }
        lineupReorderMode = false
        episodesTable.setEditing(false, animated: true)
        episodesTable.allowsMultipleSelectionDuringEditing = true
        updateLineupReorderChrome()
        episodesTable.reloadData()
    }

    /// Leaving the Session tab leaves the mode — grips on a browsed episode list would promise a
    /// reorder that has nowhere to be saved.
    func exitLineupReorderModeIfNeeded() {
        guard lineupReorderMode, !showingSession else { return }
        exitLineupReorderMode()
    }

    private func updateLineupReorderChrome() {
        navigationItem.rightBarButtonItem = lineupReorderMode
            ? UIBarButtonItem(title: L10n.done, style: .done, target: self, action: #selector(exitLineupReorderMode))
            : nil
        setEnclosingTabBarHidden(lineupReorderMode, animated: true)
        searchController?.isOverflowButtonEnabled = !lineupReorderMode
    }

    // MARK: - Table hooks

    func lineupReorderCanMoveRow(at indexPath: IndexPath) -> Bool {
        guard lineupReorderMode, showingSession else { return false }
        return episodeAtIndexPath(indexPath) != nil
    }

    /// Commits a grip move — the same write path as a long-press drop.
    func lineupReorderMoveRow(from source: IndexPath, to destination: IndexPath) {
        guard source != destination, source.section == destination.section,
              let podcast,
              let session = SessionStore.shared.session(forPodcast: podcast.uuid),
              var elements = episodeInfo[safe: source.section]?.elements,
              let moved = elements[safe: source.row] else { return }

        elements.remove(at: source.row)
        elements.insert(moved, at: min(destination.row, elements.count))
        episodeInfo[source.section].elements = elements

        let order = elements.compactMap { ($0 as? ListEpisode)?.episode.uuid }
        SessionManager.shared.setLineupOrder(episodeUuids: order, session: session)
    }

    /// Rows stay in their own section — a grip must never fling an episode out of the lineup.
    func lineupReorderTarget(from source: IndexPath, proposed: IndexPath) -> IndexPath {
        proposed.section == source.section ? proposed : source
    }
}
