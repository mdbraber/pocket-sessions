import PocketCastsUtils
import UIKit

/// Fork: Settings → Synchronization — how Sessions data syncs. Three modes: the user's own
/// Pocket Sessions server, iCloud, or this device only. Deliberately separate from (and
/// explained against) the Pocket Casts account, which always keeps syncing podcasts,
/// progress, playlists and Up Next regardless of what's chosen here.
class SyncSettingsViewController: PCViewController, UITableViewDataSource, UITableViewDelegate {
    private static let cellId = "SyncSettingsCell"

    private enum TableRow { case modeServer, modeICloud, modeLocal, serverURL, serverToken }

    /// The server-detail section only shows while the server mode is selected.
    private var sections: [[TableRow]] {
        var sections: [[TableRow]] = [[.modeServer, .modeICloud, .modeLocal]]
        if Settings.sessionSyncMode() == .server {
            sections.append([.serverURL, .serverToken])
        }
        return sections
    }

    private let settingsTable = ThemeableTable(frame: .zero, style: .grouped)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.settingsSync

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

    // MARK: - Table

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section].first {
        case .modeServer: return L10n.sessionSyncModeHeader
        case .serverURL: return L10n.sessionSyncModeServer
        default: return nil
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch sections[section].first {
        case .modeServer: return L10n.sessionSyncFooter
        case .serverURL: return L10n.sessionSyncServerFooter
        default: return nil
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = (tableView.dequeueReusableCell(withIdentifier: Self.cellId) as? ThemeableCell)
            ?? ThemeableCell(style: .value1, reuseIdentifier: Self.cellId)
        cell.accessoryView = nil
        cell.selectionStyle = .default

        let mode = Settings.sessionSyncMode()
        switch sections[indexPath.section][indexPath.row] {
        case .modeServer:
            cell.textLabel?.text = L10n.sessionSyncModeServer
            cell.detailTextLabel?.text = nil
            cell.accessoryType = mode == .server ? .checkmark : .none
        case .modeICloud:
            cell.textLabel?.text = L10n.sessionSyncModeIcloud
            cell.detailTextLabel?.text = nil
            cell.accessoryType = mode == .icloud ? .checkmark : .none
        case .modeLocal:
            cell.textLabel?.text = L10n.sessionSyncModeLocal
            cell.detailTextLabel?.text = nil
            cell.accessoryType = mode == .local ? .checkmark : .none
        case .serverURL:
            cell.textLabel?.text = L10n.sessionSyncServerUrl
            cell.detailTextLabel?.text = Settings.sessionServerURL()?.absoluteString ?? L10n.sessionSyncNotSet
            cell.accessoryType = .disclosureIndicator
        case .serverToken:
            cell.textLabel?.text = L10n.sessionSyncServerToken
            cell.detailTextLabel?.text = Settings.sessionServerToken() == nil ? L10n.sessionSyncNotSet : "••••••"
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        switch sections[indexPath.section][indexPath.row] {
        case .modeServer:
            select(mode: .server)
            // A server mode with no URL can't sync — take the user straight to entering one.
            if Settings.sessionServerURL() == nil { promptForServerURL() }
        case .modeICloud:
            select(mode: .icloud)
        case .modeLocal:
            select(mode: .local)
        case .serverURL:
            promptForServerURL()
        case .serverToken:
            promptForToken()
        }
    }

    private func select(mode: Settings.SessionSyncMode) {
        guard mode != Settings.sessionSyncMode() else { return }
        Settings.setSessionSyncMode(mode)
        // The engines hook the stores at launch; switching applies on next launch (the
        // footer says so). Reload so the checkmark and the server section follow.
        settingsTable.reloadData()
    }

    private func promptForServerURL() {
        let alert = UIAlertController(title: L10n.sessionSyncServerUrl, message: L10n.sessionSyncServerUrlMessage, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = Settings.sessionServerURL()?.absoluteString
            field.placeholder = "https://sessions.example.com"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: L10n.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.fileUploadSave, style: .default) { [weak self, weak alert] _ in
            let raw = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Settings.setSessionServerURL(raw.isEmpty ? nil : raw)
            self?.settingsTable.reloadData()
        })
        present(alert, animated: true)
    }

    private func promptForToken() {
        let alert = UIAlertController(title: L10n.sessionSyncServerToken, message: L10n.sessionSyncServerTokenMessage, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = Settings.sessionServerToken()
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: L10n.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.fileUploadSave, style: .default) { [weak self, weak alert] _ in
            let raw = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Settings.setSessionServerToken(raw.isEmpty ? nil : raw)
            self?.settingsTable.reloadData()
        })
        present(alert, animated: true)
    }
}
