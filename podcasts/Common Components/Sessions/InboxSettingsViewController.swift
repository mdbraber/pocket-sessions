import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils
import UIKit

/// Fork: Settings → Up Next & Session — where "Add to Session" lands (all matching
/// sessions, the current one, or ask) plus the Auto Add pages for both worlds.
class InboxSettingsViewController: PCViewController, UITableViewDataSource, UITableViewDelegate {
    private static let cellId = "InboxSettingsCell"

    private enum TableRow: CaseIterable { case globalPosition, addToSessionMode, removeFromSessionMode, autoAddToUpNext, autoAddToSession, mirrorUpNextToSession, mirrorSessionToUpNext }

    /// Four blocks: Position (the global default), Add & Remove routing, Auto Add limits, and the
    /// linked-adds (Linking) switches.
    private var sections: [[TableRow]] {
        [[.globalPosition], [.addToSessionMode, .removeFromSessionMode], [.autoAddToUpNext, .autoAddToSession], [.mirrorUpNextToSession, .mirrorSessionToUpNext]]
    }

    private let settingsTable = ThemeableTable(frame: .zero, style: .grouped)

    /// A plain, non-accented button pinned to the bottom of the screen (the table footer).
    private lazy var backfillButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle(L10n.sessionBackfillNow, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        button.addTarget(self, action: #selector(backfillTapped), for: .touchUpInside)
        return button
    }()

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

        let footer = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 64))
        backfillButton.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(backfillButton)
        NSLayoutConstraint.activate([
            backfillButton.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            backfillButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
        settingsTable.tableFooterView = footer
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Non-accented: a neutral text colour, not the interactive/accent tint.
        backfillButton.setTitleColor(AppTheme.colorForStyle(.primaryText01), for: .normal)
        settingsTable.reloadData()
    }

    @objc private func backfillTapped() {
        let count = SessionManager.shared.backfillSessions()
        Toast.show(count > 0 ? L10n.sessionBackfillDone(count.localized()) : L10n.sessionBackfillNone)
    }

    @objc private func mirrorUpNextToSessionChanged(_ sender: UISwitch) {
        Settings.setMirrorUpNextToSession(sender.isOn)
    }


    @objc private func mirrorSessionToUpNextChanged(_ sender: UISwitch) {
        Settings.setMirrorSessionToUpNext(sender.isOn)
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section].first {
        case .globalPosition: return L10n.sessionPositionHeading
        case .addToSessionMode: return L10n.sessionAddRemoveHeading
        case .autoAddToUpNext: return L10n.sessionAutoAddLimitsHeading
        case .mirrorUpNextToSession: return L10n.settingsLinking
        default: return nil
        }
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
        case .globalPosition:
            cell.textLabel?.text = L10n.sessionPositionHeading
            cell.detailTextLabel?.text = Settings.sessionInsertPosition() == .top ? L10n.top : L10n.bottom
        case .addToSessionMode:
            cell.textLabel?.text = L10n.playlistAddToLineup
            cell.detailTextLabel?.text = AddToSessionMode.current.title
        case .removeFromSessionMode:
            cell.textLabel?.text = L10n.sessionRemoveFrom
            cell.detailTextLabel?.text = RemoveFromSessionMode.current.title
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
        case .globalPosition:
            let picker = OptionsPicker(title: L10n.sessionPositionHeading.localizedUppercase)
            let current = Settings.sessionInsertPosition()
            for mode in [PlaylistInsertMode.top, .bottom] {
                let label = mode == .top ? L10n.top : L10n.bottom
                picker.addAction(action: OptionAction(label: label, icon: nil, selected: current == mode) { [weak self] in
                    Settings.setSessionInsertPosition(mode)
                    self?.settingsTable.reloadData()
                })
            }
            picker.present(from: self)
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
        case .autoAddToUpNext:
            navigationController?.pushViewController(AutoAddToUpNextViewController(), animated: true)
        case .autoAddToSession:
            navigationController?.pushViewController(AutoAddToSessionViewController(), animated: true)
        case .mirrorUpNextToSession, .mirrorSessionToUpNext:
            break
        }
    }
}
