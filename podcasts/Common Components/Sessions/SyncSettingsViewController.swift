import PocketCastsServer
import PocketCastsUtils
import UIKit

/// Fork: Settings → Synchronization — how Sessions data syncs. Three modes: the user's own
/// Pocket Casts Sessions (PCS) server, iCloud, or this device only. Deliberately separate from (and
/// explained against) the Pocket Casts account, which always keeps syncing podcasts,
/// progress, playlists and Up Next regardless of what's chosen here.
class SyncSettingsViewController: PCViewController, UITableViewDataSource, UITableViewDelegate {
    private static let cellId = "SyncSettingsCell"

    private enum TableRow { case modeServer, modeICloud, modeLocal, serverURL, account, followPlayback, syncNow, pushWins, pullWins }

    /// The server-detail and manual-sync sections only show while the server mode is selected.
    private var sections: [[TableRow]] {
        var sections: [[TableRow]] = [[.modeServer, .modeICloud, .modeLocal]]
        if Settings.sessionSyncMode() == .server {
            sections.append([.serverURL, .account, .followPlayback])
            sections.append([.syncNow, .pushWins, .pullWins])
        }
        return sections
    }

    private let settingsTable = ThemeableTable(frame: .zero, style: .grouped)

    /// Last-known PC link state on the server, refreshed on appear.
    ///
    /// Deliberately NOT an email. Enrollment approves the pairing code with this device's own
    /// Pocket Casts session (`SessionServerSync.enroll`), so the linked account is always the
    /// account the app signed in with — printing it back tells the user nothing they didn't
    /// already know, and goes stale the moment the two diverge.
    /// The Pocket Casts account the SERVER is linked to. Shown rather than hidden: seeing the
    /// wrong address is exactly how you discover a stale link, and Unlink is right beside it.
    private var pcLinkEmail: String?
    private var pcLinked = false

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
        SessionServerSync.shared?.pcLinkStatus { [weak self] linked, email in
            self?.pcLinked = linked
            self?.pcLinkEmail = linked ? (email ?? "") : nil
            self?.settingsTable.reloadData()
        }
    }

    // MARK: - Table

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section].first {
        case .modeServer: return L10n.sessionSyncModeHeader
        case .serverURL: return L10n.sessionSyncModeServer
        case .syncNow: return L10n.sessionSyncActionsHeader
        default: return nil
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch sections[section].first {
        case .modeServer: return L10n.sessionSyncFooter
        case .serverURL: return L10n.sessionSyncServerFooter
        case .syncNow: return L10n.sessionSyncActionsFooter
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
        case .account:
            // Everything credential-shaped collapses into one status row: the URL
            // save enrolls automatically, so this only ever shows the outcome.
            cell.textLabel?.text = L10n.sessionSyncAccount
            cell.detailTextLabel?.text = pcLinkEmail.map { $0.isEmpty ? L10n.sessionSyncLinked : $0 } ?? L10n.sessionSyncNotLinked
            cell.accessoryType = .disclosureIndicator
        case .followPlayback:
            cell.textLabel?.text = L10n.sessionSyncFollowPlayback
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .none
            cell.selectionStyle = .none
            let toggle = UISwitch()
            toggle.isOn = Settings.sessionSyncPlayback()
            toggle.addTarget(self, action: #selector(followPlaybackToggled(_:)), for: .valueChanged)
            cell.accessoryView = toggle
        case .syncNow:
            cell.textLabel?.text = L10n.sessionSyncNow
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .none
        case .pushWins:
            cell.textLabel?.text = L10n.sessionSyncPushWins
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .none
        case .pullWins:
            cell.textLabel?.text = L10n.sessionSyncPullWins
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .none
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
        case .account:
            showAccountOptions()
        case .followPlayback:
            break // the switch handles it
        case .syncNow:
            withActiveSync { $0.syncNow { ok in Toast.show(ok ? L10n.sessionSyncNowDone : L10n.sessionSyncFailed) } }
        case .pushWins:
            confirm(title: L10n.sessionSyncPushWins, message: L10n.sessionSyncPushConfirm) { [weak self] in
                self?.withActiveSync { $0.pushReplacingServer { ok in Toast.show(ok ? L10n.sessionSyncNowDone : L10n.sessionSyncFailed) } }
            }
        case .pullWins:
            confirm(title: L10n.sessionSyncPullWins, message: L10n.sessionSyncPullConfirm) { [weak self] in
                self?.withActiveSync { $0.pullReplacingLocal { ok in Toast.show(ok ? L10n.sessionSyncNowDone : L10n.sessionSyncFailed) } }
            }
        }
    }

    /// The engine only exists when server mode was active at launch — a just-switched
    /// mode needs a relaunch first, and the toast says so instead of failing silently.
    private func withActiveSync(_ block: (SessionServerSync) -> Void) {
        guard let sync = SessionServerSync.shared else {
            Toast.show(L10n.sessionSyncRestartNeeded)
            return
        }
        block(sync)
    }

    private func confirm(title: String, message: String, onConfirm: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: title, style: .destructive) { _ in onConfirm() })
        present(alert, animated: true)
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
            // Entering the server is the only manual step: enrollment (PC link +
            // this device's own PCS token) runs automatically from here.
            if !raw.isEmpty, SyncManager.isUserLoggedIn() {
                self?.linkPCAccount()
            }
        })
        present(alert, animated: true)
    }

    /// PC-identity enrollment: the server gets a pairing code from Pocket Casts,
    /// this device approves it with its own session, and the server redeems it for
    /// a renewable lineage — issuing this device its own PCS API token in return.
    /// No password or token ever leaves this device, and no bootstrap token is
    /// needed. Engine-free, so it works right after the URL is saved (no relaunch).
    private func linkPCAccount() {
        guard SyncManager.isUserLoggedIn() else {
            Toast.show(L10n.sessionSyncPcLinkNoToken)
            return
        }
        Toast.show(L10n.sessionSyncPcLinking)
        SessionServerSync.enroll { [weak self] email in
            if let email {
                self?.pcLinked = true
                self?.pcLinkEmail = email
                self?.settingsTable.reloadData()
                Toast.show(L10n.sessionSyncPcLinkDone(email.isEmpty ? L10n.sessionSyncLinked : email))
            } else {
                Toast.show(L10n.sessionSyncFailed)
            }
        }
    }

    @objc private func followPlaybackToggled(_ toggle: UISwitch) {
        Settings.setSessionSyncPlayback(toggle.isOn)
    }

    /// The Account row's sheet: link (or re-link), and unlink when there is a link to drop.
    ///
    /// Manual token entry used to hide here. It's gone: saving the server URL issues this device
    /// its own token automatically, so hand-typing one could only ever disagree with the one the
    /// server actually knows.
    private func showAccountOptions() {
        let alert = UIAlertController(title: L10n.sessionSyncAccount, message: L10n.sessionSyncPcLinkMessage, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.sessionSyncPcLink, style: .default) { [weak self] _ in
            self?.linkPCAccount()
        })
        if pcLinked {
            alert.addAction(UIAlertAction(title: L10n.sessionSyncPcUnlink, style: .destructive) { [weak self] _ in
                self?.confirmUnlink()
            })
        }
        alert.addAction(UIAlertAction(title: L10n.cancel, style: .cancel))
        present(alert, animated: true)
    }

    private func confirmUnlink() {
        confirm(title: L10n.sessionSyncPcUnlink, message: L10n.sessionSyncPcUnlinkConfirm) { [weak self] in
            SessionServerSync.shared?.pcUnlink { ok in
                if ok {
                    self?.pcLinked = false
                    self?.pcLinkEmail = nil
                    self?.settingsTable.reloadData()
                }
                Toast.show(ok ? L10n.sessionSyncPcUnlinkDone : L10n.sessionSyncFailed)
            }
        }
    }
}
