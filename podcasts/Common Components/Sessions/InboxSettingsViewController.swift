import PocketCastsServer
import PocketCastsUtils
import UIKit

/// Fork: Settings → Up Next & Session — where "Add to Session" lands (all matching
/// sessions, the current one, or ask) plus the Auto Add pages for both worlds.
class InboxSettingsViewController: PCViewController, UITableViewDataSource, UITableViewDelegate {
    private static let cellId = "InboxSettingsCell"

    private enum TableRow: CaseIterable { case addToSessionMode, autoAddToUpNext, autoAddToSession, mirrorUpNextToSession, mirrorSessionToUpNext }

    /// Grouped: the Add to Session routing stands apart from the Auto Add pages and
    /// the linked-adds switches. With sessions off only stock Up Next remains.
    private var sections: [[TableRow]] {
        FeatureFlag.sessions.enabled
            ? [[.addToSessionMode], [.autoAddToUpNext, .autoAddToSession], [.mirrorUpNextToSession, .mirrorSessionToUpNext]]
            : [[.autoAddToUpNext]]
    }

    private let settingsTable = ThemeableTable(frame: .zero, style: .grouped)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.settingsUpNextAndSession

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

    @objc private func mirrorUpNextToSessionChanged(_ sender: UISwitch) {
        Settings.setMirrorUpNextToSession(sender.isOn)
    }

    @objc private func mirrorSessionToUpNextChanged(_ sender: UISwitch) {
        Settings.setMirrorSessionToUpNext(sender.isOn)
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].first == .mirrorUpNextToSession ? L10n.settingsLinking : nil
    }

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = (tableView.dequeueReusableCell(withIdentifier: Self.cellId) as? ThemeableCell)
            ?? ThemeableCell(style: .value1, reuseIdentifier: Self.cellId)
        switch sections[indexPath.section][indexPath.row] {
        case .addToSessionMode:
            cell.textLabel?.text = L10n.playlistAddToLineup
            cell.detailTextLabel?.text = AddToSessionMode.current.title
        case .autoAddToUpNext:
            cell.textLabel?.text = L10n.settingsAutoAdd
            cell.detailTextLabel?.text = L10n.settingsEpisodeLimitFormat(ServerSettings.autoAddToUpNextLimit().localized())
        case .autoAddToSession:
            cell.textLabel?.text = L10n.settingsAutoAddSession
            cell.detailTextLabel?.text = L10n.settingsEpisodeLimitFormat(Settings.sessionAutoAddLimit().localized())
        case .mirrorUpNextToSession, .mirrorSessionToUpNext:
            let isUpNextToSession = sections[indexPath.section][indexPath.row] == .mirrorUpNextToSession
            cell.textLabel?.text = isUpNextToSession ? L10n.settingsMirrorUpNextToSession : L10n.settingsMirrorSessionToUpNext
            cell.detailTextLabel?.text = nil
            let toggle = UISwitch()
            toggle.isOn = isUpNextToSession ? Settings.mirrorUpNextToSession() : Settings.mirrorSessionToUpNext()
            toggle.addTarget(self, action: isUpNextToSession ? #selector(mirrorUpNextToSessionChanged(_:)) : #selector(mirrorSessionToUpNextChanged(_:)), for: .valueChanged)
            cell.accessoryView = toggle
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        }
        cell.accessoryView = nil
        cell.selectionStyle = .default
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        switch sections[indexPath.section][indexPath.row] {
        case .addToSessionMode:
            let modes = AddToSessionMode.allCases
            let selectedIndex = modes.firstIndex(of: .current) ?? 0
            let optionsController = SettingsOptionsViewController(items: modes.map(\.title), selectedValue: selectedIndex) { [weak self] index in
                modes[index].save()
                self?.settingsTable.reloadData()
            }
            optionsController.saveOnChange = true
            optionsController.title = L10n.playlistAddToLineup
            navigationController?.pushViewController(optionsController, animated: true)
        case .autoAddToUpNext:
            navigationController?.pushViewController(AutoAddToUpNextViewController(), animated: true)
        case .autoAddToSession:
            navigationController?.pushViewController(AutoAddToSessionViewController(), animated: true)
        case .mirrorUpNextToSession, .mirrorSessionToUpNext:
            break
        }
    }
}
