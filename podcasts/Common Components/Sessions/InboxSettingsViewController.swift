import UIKit

/// Fork: Settings → Inbox — how the triage verbs behave. Currently one choice:
/// where "Add to Session" lands (all matching sessions, the current one, or ask).
class InboxSettingsViewController: PCViewController, UITableViewDataSource, UITableViewDelegate {
    private static let cellId = "InboxSettingsCell"

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

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = (tableView.dequeueReusableCell(withIdentifier: Self.cellId) as? ThemeableCell)
            ?? ThemeableCell(style: .value1, reuseIdentifier: Self.cellId)
        cell.textLabel?.text = L10n.playlistAddToLineup
        cell.detailTextLabel?.text = AddToSessionMode.current.title
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        let modes = AddToSessionMode.allCases
        let selectedIndex = modes.firstIndex(of: .current) ?? 0
        let optionsController = SettingsOptionsViewController(items: modes.map(\.title), selectedValue: selectedIndex) { [weak self] index in
            modes[index].save()
            self?.settingsTable.reloadData()
        }
        optionsController.saveOnChange = true
        optionsController.title = L10n.playlistAddToLineup
        navigationController?.pushViewController(optionsController, animated: true)
    }
}
