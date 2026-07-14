import PocketCastsServer
import PocketCastsUtils
import UIKit

/// Fork: Settings → Up Next & Session — where "Add to Session" lands (all matching
/// sessions, the current one, or ask) plus the Auto Add pages for both worlds.
class InboxSettingsViewController: PCViewController, UITableViewDataSource, UITableViewDelegate {
    private static let cellId = "InboxSettingsCell"

    private enum TableRow: CaseIterable { case addToSessionMode, removeFromSessionMode, backfillSessions, autoAddToUpNext, autoAddToSession, mirrorUpNextToSession, mirrorSessionToUpNext }

    /// Grouped: the Add/Remove routing and the backfill catch-up stand apart from the Auto Add pages
    /// and the linked-adds switches. With sessions off only stock Up Next remains.
    private var sections: [[TableRow]] {
        [[.addToSessionMode, .removeFromSessionMode, .backfillSessions], [.autoAddToUpNext, .autoAddToSession], [.mirrorUpNextToSession, .mirrorSessionToUpNext]]
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

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sections[section].first == .addToSessionMode ? L10n.sessionBackfillMsg : nil
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
        case .removeFromSessionMode:
            cell.textLabel?.text = L10n.sessionRemoveFrom
            cell.detailTextLabel?.text = RemoveFromSessionMode.current.title
        case .backfillSessions:
            cell.textLabel?.text = L10n.sessionBackfillNow
            cell.detailTextLabel?.text = nil
            cell.accessoryView = nil
            cell.accessoryType = .none
            cell.selectionStyle = .default
            return cell
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
        case .removeFromSessionMode:
            let modes = RemoveFromSessionMode.allCases
            let selectedIndex = modes.firstIndex(of: .current) ?? 0
            let optionsController = SettingsOptionsViewController(items: modes.map(\.title), selectedValue: selectedIndex) { [weak self] index in
                modes[index].save()
                self?.settingsTable.reloadData()
            }
            optionsController.saveOnChange = true
            optionsController.title = L10n.sessionRemoveFrom
            navigationController?.pushViewController(optionsController, animated: true)
        case .backfillSessions:
            let count = SessionManager.shared.backfillSessions()
            Toast.show(count > 0 ? L10n.sessionBackfillDone(count.localized()) : L10n.sessionBackfillNone)
        case .autoAddToUpNext:
            navigationController?.pushViewController(AutoAddToUpNextViewController(), animated: true)
        case .autoAddToSession:
            navigationController?.pushViewController(AutoAddToSessionViewController(), animated: true)
        case .mirrorUpNextToSession, .mirrorSessionToUpNext:
            break
        }
    }
}
