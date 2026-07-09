import UIKit
import SwiftUI
import PocketCastsDataModel

class PlaylistDetailCustomOrderViewController: PCViewController {
    /// Fork: rows are episodes plus, for custom-ordered smart playlists, the draggable
    /// insert-marker row.
    private enum Row {
        case marker
        case episode(ListEpisode)

        var listEpisode: ListEpisode? {
            if case .episode(let episode) = self { return episode }
            return nil
        }
    }

    private weak var viewModel: PlaylistDetailViewModel?
    private var rows: [Row] = []

    private(set) var tableView: ThemeableTable! {
        didSet {
            tableView.themeStyle = .primaryUi02
            tableView.sectionHeaderTopPadding = 0
            tableView.estimatedRowHeight = 80
            tableView.rowHeight = UITableView.automaticDimension
            tableView.translatesAutoresizingMaskIntoConstraints = false
            tableView.delegate = self
            tableView.dataSource = self
            tableView.separatorStyle = .none
            tableView.isEditing = true
            registerCells()
        }
    }

    init(viewModel: PlaylistDetailViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = AppTheme.viewBackgroundColor()

        setupNavBar()
        setupContent()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        tableView.reloadData()
    }

    private func setupNavBar() {
        let backgroundColor = AppTheme.viewBackgroundColor()
        changeNavTint(titleColor: AppTheme.colorForStyle(.primaryText01), iconsColor: AppTheme.colorForStyle(.primaryIcon03), backgroundColor: backgroundColor)

        title = L10n.playlistManualEpisodesOrderOption
        navigationController?.navigationBar.prefersLargeTitles = false
        navigationItem.largeTitleDisplayMode = .never

        if !LiquidGlass.isEnabled {
            let appearance = UINavigationBarAppearance()
            appearance.backgroundColor = AppTheme.colorForStyle(.primaryUi01)
            appearance.titleTextAttributes = [
                NSAttributedString.Key.foregroundColor: AppTheme.colorForStyle(.primaryText01)
            ]
            navigationController?.navigationBar.scrollEdgeAppearance = appearance
            navigationController?.navigationBar.standardAppearance = appearance
            navigationController?.navigationBar.sizeToFit()
        }
    }

    private func setupContent() {
        if let viewModel, viewModel.usesCustomOrderOverlay {
            // Smart playlist overlay: the editor rearranges the Lineup (inbox episodes are
            // triaged from the detail screen), with the insert marker as a draggable row.
            let lineup = viewModel.lineupEpisodes
            rows = lineup.map { .episode($0) }
            let markerIndex = viewModel.playlist.insertMarkerIndex(inLineup: lineup.map { $0.episode.uuid })
            rows.insert(.marker, at: min(markerIndex, rows.count))
        } else {
            rows = (viewModel?.episodes ?? []).map { .episode($0) }
        }

        tableView = ThemeableTable()
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 0),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: 0),
            tableView.topAnchor.constraint(equalTo: view.topAnchor, constant: 0),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: 0)
        ])

        view.layoutSubviews()

        insetAdjuster.setupInsetAdjustmentsForMiniPlayer(scrollView: tableView)
    }

    private func registerCells() {
        tableView.register(PlaylistEpisodePreviewCell.self, forCellReuseIdentifier: PlaylistEpisodePreviewCell.reuseIdentifier)
        tableView.register(PlaylistInsertMarkerCell.self, forCellReuseIdentifier: PlaylistInsertMarkerCell.reuseIdentifier)
    }
}

extension PlaylistDetailCustomOrderViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch rows[indexPath.row] {
        case .marker:
            return tableView.dequeueReusableCell(withIdentifier: PlaylistInsertMarkerCell.reuseIdentifier, for: indexPath) as! PlaylistInsertMarkerCell
        case .episode(let listEpisode):
            let cell = tableView.dequeueReusableCell(withIdentifier: PlaylistEpisodePreviewCell.reuseIdentifier, for: indexPath) as! PlaylistEpisodePreviewCell
            cell.set(episode: listEpisode.episode)
            return cell
        }
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if case .marker = rows[indexPath.row] {
            return PlaylistInsertMarkerCell.height
        }
        return UITableView.automaticDimension
    }

    // MARK: - Editing

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        true
    }

    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        if case .marker = rows[indexPath.row] {
            return .none
        }
        return .delete
    }

    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        false
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete, let episode = rows[safe: indexPath.row]?.listEpisode {
            // For a smart playlist this removes the position row only — the episode goes
            // back to the New (inbox) section, not out of the playlist.
            viewModel?.delete(episodes: [episode.episode.uuid])

            rows.remove(at: indexPath.row)
            tableView.beginUpdates()
            tableView.deleteRows(at: [indexPath], with: .top)
            tableView.endUpdates()

            if let viewModel {
                track(episode: episode.episode, added: false, to: viewModel.playlist, source: "playlist_rearrange")
            }
        }
    }

    // MARK: - Cell reordering

    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        if sourceIndexPath == destinationIndexPath { return }

        let movedRow = rows[sourceIndexPath.row]
        rows.remove(at: sourceIndexPath.row)
        rows.insert(movedRow, at: destinationIndexPath.row)

        let lineupUuids = rows.compactMap { $0.listEpisode?.episode.uuid }

        switch movedRow {
        case .marker:
            // Episode rows before the marker's new spot = its lineup index.
            let markerLineupIndex = rows.prefix(destinationIndexPath.row).compactMap { $0.listEpisode }.count
            viewModel?.updateInsertMarker(toLineupIndex: markerLineupIndex, lineupUuids: lineupUuids)
        case .episode(let movedObject):
            viewModel?.updatePlaylist(sortType: .dragAndDrop)
            let lineupIndex = rows.prefix(destinationIndexPath.row).compactMap { $0.listEpisode }.count
            viewModel?.move(episode: movedObject, toIndex: lineupIndex)
            track(.filterManualEpisodesRearranged)
        }
    }
}

extension PlaylistDetailCustomOrderViewController: PlaylistTypeTrackerProvider {
    var analyticsSourceType: String {
        viewModel?.isManualPlaylist == true ? "manual" : "smart"
    }
}
