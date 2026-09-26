import UIKit
import PocketCastsDataModel

/// Fork: ordering the podcast page's Session lineup.
///
/// The lineup has one saved order, which is also its play order. Two ways to change it: drag the
/// rows (long-press normally, or with real grips in "Reorder Episodes" mode), which makes it Manual;
/// or give the session a Sort By / Group By (saved on the session — see `LineupSort`).
extension PodcastViewController {
    // MARK: - Arrangement

    /// The podcast's session, whose lineup the Session tab shows.
    var lineupSession: Session? {
        podcast.flatMap { SessionStore.shared.session(forPodcast: $0.uuid) }
    }

    /// Sets the lineup's sticky Sort By (nil = Manual) — see `LineupSort`.
    func setSessionLineupSort(_ order: EpisodeOrder?) {
        guard let session = lineupSession else { return }
        LineupSort.set(order, for: session)
        episodesDidChange()
    }

    func reorderSessionLineup(order: EpisodeOrder) {
        setSessionLineupSort(order)
    }

    // MARK: - Reorder Episodes mode

    /// A long-press drag is invisible until you know it's there; this mode puts a grip on every row
    /// and suspends tap-to-open, swipes and multi-select for its duration.
    func enterLineupReorderMode() {
        guard showingSession, !lineupReorderMode else { return }
        if isMultiSelectEnabled { isMultiSelectEnabled = false }
        // Grips need a flat list: hand-ordering a grouped lineup makes it Manual as it stands.
        if let session = lineupSession, LineupSort.grouping(of: session) != .none {
            LineupSort.switchToManual(session)
            episodesDidChange()
        }

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

        var order = elements.compactMap { ($0 as? ListEpisode)?.episode.uuid }
        LineupSort.switchToManual(session)
        // A filtered Session tab shows a subset: keep what the filter hid where it was.
        if FilterPresets.isNarrowing(.session, singlePodcast: true) {
            order = LineupReorder.mergingVisibleOrder(order, into: LineupReorder.storedOrder(of: session))
        }
        SessionManager.shared.setLineupOrder(episodeUuids: order, session: session)
    }

    /// Rows stay in their own section — a grip must never fling an episode out of the lineup.
    func lineupReorderTarget(from source: IndexPath, proposed: IndexPath) -> IndexPath {
        proposed.section == source.section ? proposed : source
    }
}
