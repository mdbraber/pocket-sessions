import UIKit
import PocketCastsDataModel

/// Fork: "Reorder Episodes" mode on a playlist page.
///
/// A lineup is hand-ordered by definition, so dragging is normally live via long-press. This mode
/// exists for the same reason the Files app has one: a long-press drag is invisible until you know
/// it's there, and a row of grips says "this list is yours to arrange" out loud. Entering it puts
/// the table in editing mode with real reorder grips and suspends everything that competes for the
/// touch — tap-to-open, swipe actions and multi-select.
extension PlaylistDetailViewController {
    func enterLineupReorderMode() {
        guard showsLineupReorder, !lineupReorderMode else { return }
        if isMultiSelectEnabled { isMultiSelectEnabled = false }
        if viewModel.isSearching { searchController.searchTextField.resignFirstResponder() }

        lineupReorderMode = true
        // Editing mode otherwise draws the multi-select circles alongside the grips; reorder is the
        // only thing this mode does, so the circles go away for its duration.
        tableView.allowsMultipleSelectionDuringEditing = false
        tableView.setEditing(true, animated: true)
        updateLineupReorderChrome()
        tableView.reloadData()
    }

    @objc func exitLineupReorderMode() {
        guard lineupReorderMode else { return }
        lineupReorderMode = false
        tableView.setEditing(false, animated: true)
        tableView.allowsMultipleSelectionDuringEditing = true
        updateLineupReorderChrome()
        tableView.reloadData()
    }

    /// Done owns the nav bar while reordering; leaving restores whatever was there before.
    private func updateLineupReorderChrome() {
        if lineupReorderMode {
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: L10n.done, style: .done, target: self, action: #selector(exitLineupReorderMode))
        } else {
            navigationItem.rightBarButtonItem = nil
        }
        setEnclosingTabBarHidden(lineupReorderMode, animated: true)
    }

    /// The reorder mode only makes sense while a lineup is on screen — switching tabs, searching or
    /// navigating away leaves it rather than stranding the user in a mode with no grips.
    func exitLineupReorderModeIfNeeded() {
        guard lineupReorderMode, !showsLineupReorder || viewModel.isSearching else { return }
        exitLineupReorderMode()
    }

    // MARK: - Table hooks

    func lineupReorderCanMoveRow(at indexPath: IndexPath) -> Bool {
        // `.episodes` is the lineup section; `.browse` is the browsed list, which has no order to save.
        guard lineupReorderMode, viewModel.section(at: indexPath.section) == .episodes else { return false }
        return viewModel.listEpisode(at: indexPath) != nil
    }

    /// Commits a grip move. Same write path as a long-press drag — one order, one place it's saved.
    func lineupReorderMoveRow(from source: IndexPath, to destination: IndexPath) {
        guard source != destination, source.section == destination.section else { return }
        viewModel.moveLineupElement(from: source.row, to: destination.row)
        viewModel.commitLineupOrder()
        track(.filterManualEpisodesRearranged)
    }

    /// Rows can only be dragged within their own section — a grip must never fling an episode into
    /// the header or archive section.
    func lineupReorderTarget(from source: IndexPath, proposed: IndexPath) -> IndexPath {
        guard proposed.section == source.section else { return source }
        return proposed
    }
}
