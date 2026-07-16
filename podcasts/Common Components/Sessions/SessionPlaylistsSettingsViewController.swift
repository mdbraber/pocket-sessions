import PocketCastsDataModel
import PocketCastsUtils
import UIKit

/// Fork: Playlists ⋯ → "Session Playlists". Controls which session playlists appear in the
/// Playlists tab: Manual and Smart Playlist sessions are simple on/off; per-podcast sessions show
/// only for the podcast folders selected here (e.g. tick "Series" to surface just those). Replaces
/// the old all-or-nothing "Hide Session Playlists".
class SessionPlaylistsSettingsViewController: PCViewController, UITableViewDataSource, UITableViewDelegate {
    private static let cellId = "SessionPlaylistsCell"

    private enum Row { case manual, smart, folder(Folder) }

    private let onChange: () -> Void
    private let settingsTable = ThemeableTable(frame: .zero, style: .grouped)
    private let folders = DataManager.sharedManager.allFolders(includeDeleted: false)

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var sections: [[Row]] {
        [[.manual, .smart], folders.map { Row.folder($0) }]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.sessionPlaylistsTitle
        settingsTable.dataSource = self
        settingsTable.delegate = self
        settingsTable.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(settingsTable)
        NSLayoutConstraint.activate([
            settingsTable.topAnchor.constraint(equalTo: view.topAnchor),
            settingsTable.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            settingsTable.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            settingsTable.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        settingsTable.reloadData()
    }

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 1 && !folders.isEmpty ? L10n.sessionPlaylistsPodcast : nil
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 1 && !folders.isEmpty ? L10n.sessionPlaylistsPodcastFooter : nil
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = (tableView.dequeueReusableCell(withIdentifier: Self.cellId) as? ThemeableCell)
            ?? ThemeableCell(style: .default, reuseIdentifier: Self.cellId)
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.selectionStyle = .none
        switch sections[indexPath.section][indexPath.row] {
        case .manual:
            cell.textLabel?.text = L10n.sessionPlaylistsManual
            cell.accessoryView = makeToggle(isOn: Settings.showManualSessions(), action: #selector(manualChanged(_:)))
        case .smart:
            cell.textLabel?.text = L10n.sessionPlaylistsSmart
            cell.accessoryView = makeToggle(isOn: Settings.showSmartPlaylistSessions(), action: #selector(smartChanged(_:)))
        case .folder(let folder):
            cell.textLabel?.text = folder.name
            cell.accessoryType = Settings.showPodcastSessionFolders().contains(folder.uuid) ? .checkmark : .none
            cell.selectionStyle = .default
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case .folder(let folder) = sections[indexPath.section][indexPath.row] else { return }
        var set = Settings.showPodcastSessionFolders()
        if set.contains(folder.uuid) { set.remove(folder.uuid) } else { set.insert(folder.uuid) }
        Settings.setShowPodcastSessionFolders(set)
        settingsTable.reloadRows(at: [indexPath], with: .none)
        onChange()
    }

    private func makeToggle(isOn: Bool, action: Selector) -> UISwitch {
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.addTarget(self, action: action, for: .valueChanged)
        return toggle
    }

    @objc private func manualChanged(_ sender: UISwitch) { Settings.setShowManualSessions(sender.isOn); onChange() }
    @objc private func smartChanged(_ sender: UISwitch) { Settings.setShowSmartPlaylistSessions(sender.isOn); onChange() }
}
