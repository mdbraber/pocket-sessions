import UIKit

/// Fork: Settings → Inbox — how the triage verbs behave: where "Add to Session"
/// lands (all matching sessions, the current one, or ask), and the global Auto Add
/// to Session settings.
class InboxSettingsViewController: PCViewController, UITableViewDataSource, UITableViewDelegate {
    private static let cellId = "InboxSettingsCell"

    private enum TableRow: CaseIterable { case addToSessionMode, autoAddToSession }

    private let settingsTable = ThemeableTable(frame: .zero, style: .grouped)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.inboxTitle

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

    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { TableRow.allCases.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = (tableView.dequeueReusableCell(withIdentifier: Self.cellId) as? ThemeableCell)
            ?? ThemeableCell(style: .value1, reuseIdentifier: Self.cellId)
        switch TableRow.allCases[indexPath.row] {
        case .addToSessionMode:
            cell.textLabel?.text = L10n.playlistAddToLineup
            cell.detailTextLabel?.text = AddToSessionMode.current.title
        case .autoAddToSession:
            cell.textLabel?.text = L10n.settingsAutoAddSession
            cell.detailTextLabel?.text = L10n.settingsEpisodeLimitFormat(Settings.sessionAutoAddLimit().localized())
        }
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        switch TableRow.allCases[indexPath.row] {
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
        case .autoAddToSession:
            navigationController?.pushViewController(AutoAddToSessionViewController(), animated: true)
        }
    }
}
