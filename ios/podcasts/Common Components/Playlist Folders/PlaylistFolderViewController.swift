import UIKit
import SwiftUI
import PocketCastsDataModel

/// Fork: a Playlist Folder's page — its playlists in the same rows as the Playlists
/// tab, with an Edit button for the folder itself (name, color, members, delete).
class PlaylistFolderViewController: PCViewController, UITableViewDataSource, UITableViewDelegate, FilterCreatedDelegate {
    private let folderUuid: String
    private let table = ThemeableTable()
    private var playlists: [EpisodeFilter] = []

    var presentingPlaylistDetail = false

    init(folderUuid: String) {
        self.folderUuid = folderUuid
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = AppTheme.viewBackgroundColor()
        table.register(NewPlaylistCell.self, forCellReuseIdentifier: NewPlaylistCell.reuseIdentifier)
        table.dataSource = self
        table.delegate = self
        table.separatorStyle = .none
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = NewPlaylistCell.cellHeight
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        insetAdjuster.setupInsetAdjustmentsForMiniPlayer(scrollView: table)

        customRightBtn = UIBarButtonItem(image: UIImage(named: "more"), style: .plain, target: self, action: #selector(folderOptionsTapped))
        customRightBtn?.accessibilityLabel = L10n.accessibilityMoreActions

        NotificationCenter.default.addObserver(self, selector: #selector(reloadData), name: PlaylistFolderManager.foldersChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reloadData), name: Constants.Notifications.playlistChanged, object: nil)
        reloadData()
    }

    @objc private func reloadData() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let folder = PlaylistFolderManager.shared.folder(uuid: self.folderUuid) else {
                // Folder deleted from the edit sheet — nothing left to show.
                self.navigationController?.popViewController(animated: true)
                return
            }
            self.title = folder.name
            // The Playlists world's Session Playlists preferences apply inside folders too — one
            // shared filter drives both this list and the count under the folder row.
            var playlists = PlaylistFolderManager.shared.visiblePlaylists(inFolder: self.folderUuid)
            if LibrarySort(rawValue: Int32(UserDefaults.standard.integer(forKey: "SJPlaylistsSortOrder"))) == .titleAtoZ {
                playlists.sort { $0.playlistName.localizedCaseInsensitiveCompare($1.playlistName) == .orderedAscending }
            }
            self.playlists = playlists
            self.table.reloadData()
        }
    }

    /// The folder page's options: the Playlists world's base options first, then the
    /// folder-specific ones (Edit Folder, Add or Remove Playlists).
    @objc private func folderOptionsTapped() {
        let optionsPicker = OptionsPicker(title: nil)

        // Same as the Playlists main screen: which session playlists appear (Manual / Smart /
        // per-folder-or-podcast). Replaces the old, illogical per-folder "Hide Session Playlists".
        optionsPicker.addAction(action: OptionAction(label: L10n.sessionPlaylistsShow, icon: "option-multiselect") { [weak self] in
            DispatchQueue.main.async {
                let settings = SessionPlaylistsSettingsViewController { [weak self] in self?.reloadData() }
                self?.navigationController?.pushViewController(settings, animated: true)
            }
        })

        let currentSort = LibrarySort(rawValue: Int32(UserDefaults.standard.integer(forKey: "SJPlaylistsSortOrder"))) ?? .custom
        let sortAction = OptionAction(label: L10n.sortBy, secondaryLabel: currentSort.description, icon: "podcast-sort") {}
        sortAction.submenu = { [weak self] in
            let picker = OptionsPicker(title: L10n.sortBy.localizedUppercase)
            for option in [LibrarySort.custom, .titleAtoZ] {
                picker.addAction(action: OptionAction(label: option.description, selected: currentSort == option) {
                    UserDefaults.standard.set(Int(option.rawValue), forKey: "SJPlaylistsSortOrder")
                    self?.reloadData()
                })
            }
            return picker
        }
        optionsPicker.addAction(action: sortAction)

        optionsPicker.addAction(action: OptionAction(label: L10n.folderEdit, icon: "folder-edit") { [weak self] in
            guard let self, let folder = PlaylistFolderManager.shared.folder(uuid: self.folderUuid) else { return }
            let editView = PlaylistFolderEditView(folder: folder) { [weak self] in
                self?.dismiss(animated: true)
            }
            let host = PCHostingController(rootView: editView.environmentObject(Theme.sharedTheme))
            self.present(host, animated: true)
        })

        optionsPicker.addAction(action: OptionAction(label: L10n.playlistFolderAddRemove, icon: "folder-podcasts") { [weak self] in
            guard let self else { return }
            let membersView = EditPlaylistFolderPlaylistsView(folderUuid: self.folderUuid) { [weak self] in
                self?.dismiss(animated: true)
            }
            let host = PCHostingController(rootView: membersView.environmentObject(Theme.sharedTheme))
            self.present(host, animated: true)
        })

        optionsPicker.present(from: self)
    }

    // MARK: - Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        playlists.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = (tableView.dequeueReusableCell(withIdentifier: NewPlaylistCell.reuseIdentifier) as? NewPlaylistCell)
            ?? NewPlaylistCell(style: .default, reuseIdentifier: NewPlaylistCell.reuseIdentifier)
        if cell.tag != indexPath.row { cell.reset() }
        cell.tag = indexPath.row
        if let playlist = playlists[safe: indexPath.row] {
            cell.set(playlistName: playlist.playlistName, isManualPlaylist: playlist.manual)
            cell.setSessionSubtitle(SessionStore.shared.session(forStore: playlist.uuid)?.displaySubtitle)
            cell.loadMetadata(for: playlist)
            cell.hideSeparator(indexPath.row == playlists.count - 1)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let playlist = playlists[safe: indexPath.row] else { return }
        let viewController = PlaylistDetailViewController(playlist: playlist, delegate: self)
        navigationController?.pushViewController(viewController, animated: true)
        UserDefaults.standard.set(playlist.uuid, forKey: Constants.UserDefaults.lastFilterShown)
    }

    // MARK: - FilterCreatedDelegate

    func filterCreated(newFilter: EpisodeFilter) {}
}
