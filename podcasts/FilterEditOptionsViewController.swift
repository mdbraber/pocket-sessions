
import PocketCastsDataModel
import PocketCastsUtils
import UIKit

class FilterEditOptionsViewController: PCViewController, UITableViewDelegate, UITableViewDataSource, UITextFieldDelegate {
    var filterToEdit: EpisodeFilter!
    @IBOutlet var tableView: UITableView! {
        didSet {
            tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: Constants.Values.miniPlayerOffset, right: 0)
        }
    }

    private let nameCellId = "EditFilterNameId"
    private let switchCellId = "SwitchCell"
    private let disclosureCellId = "DisclosureCell"
    private let buttonCellId = "ButtonCell"
    private let settingsCellId = "SettingsCell"
    private let deleteCellId = "DettingsCell"
    private enum TableRow: Int { case filterName, autodownload, autoDownloadLimit, siriShortcut, isSessionPlaylist, sessionFillMode, backfillSession, deletePlaylist }
    private static let tableDataAutoDownloadDisabled: [[TableRow]] = {
        return [[.filterName], [.autodownload]]
    }()
    private static let tableDataAutoDownloadEnabled: [[TableRow]] = {
        return [[.filterName], [.autodownload, .autoDownloadLimit]]
    }()
    private var filterNameTextField: UITextField!
    private var existingShortcut: Any!

    /* Analytics Helpers */
    private var didChangeAutoDownload = false
    private var didChangeEpisodeCount = false
    private var isViewingShortcuts = false
    private var didChangeName: Bool {
        filterToEdit.playlistName != filterNameTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = L10n.playlistOptions

        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped(_:)))
        tapRecognizer.cancelsTouchesInView = false
        tableView.addGestureRecognizer(tapRecognizer)

        tableView.register(UINib(nibName: "EditFilterNameCell", bundle: nil), forCellReuseIdentifier: nameCellId)
        tableView.register(UINib(nibName: "SwitchCell", bundle: nil), forCellReuseIdentifier: switchCellId)
        tableView.register(UINib(nibName: "DisclosureCell", bundle: nil), forCellReuseIdentifier: disclosureCellId)
        tableView.register(UINib(nibName: "ButtonCell", bundle: nil), forCellReuseIdentifier: buttonCellId)
        tableView.register(UINib(nibName: "TopLevelSettingsCell", bundle: nil), forCellReuseIdentifier: settingsCellId)
        tableView.register(UINib(nibName: "AccountActionCell", bundle: nil), forCellReuseIdentifier: deleteCellId)
        updateExistingSortcutData()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        let didChangeName = filterToEdit.playlistName != filterNameTextField.text

        if didChangeName {
            track(.filterNameUpdated)
        }

        filterToEdit.setTitle(filterNameTextField.text, defaultTitle: L10n.filtersDefaultNewFilter.localizedCapitalized)
        filterToEdit.syncStatus = SyncStatus.notSynced.rawValue
        DataManager.sharedManager.save(playlist: filterToEdit)
        NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged, object: filterToEdit)

        if isViewingShortcuts == false {
            let properties = ["did_change_name": didChangeName,
                              "did_change_auto_download": didChangeAutoDownload,
                              "did_change_episode_count": didChangeEpisodeCount]
            track(.filterEditDismissed, properties: properties)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        isViewingShortcuts = false
    }

    @objc func backgroundTapped(_ sender: UITapGestureRecognizer) {
        if let nameTextField = filterNameTextField {
            if nameTextField.isFirstResponder {
                nameTextField.resignFirstResponder()
            }
        }
    }

    // MARL:- TableView Data Source
    func numberOfSections(in tableView: UITableView) -> Int {
        tableData().count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        tableData()[section].count
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        indexPath.section == 1 ? 79 : 64
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let tableRow = tableData()[indexPath.section][indexPath.row]
        switch tableRow {
        case .filterName:
            let cell = tableView.dequeueReusableCell(withIdentifier: nameCellId) as! EditFilterNameCell
            cell.nameTextField.text = filterToEdit.playlistName
            filterNameTextField = cell.nameTextField
            cell.nameTextField.delegate = self
            return cell
        case .autodownload:
            let cell = tableView.dequeueReusableCell(withIdentifier: switchCellId) as! SwitchCell
            cell.cellSwitch.onStyle = .primaryIcon01

            cell.cellLabel.text = L10n.settingsAutoDownload
            cell.cellLabel.font.withSize(16)
            cell.setImage(imageName: "filter_downloaded")
            cell.cellSwitch.setOn(filterToEdit.autoDownloadEpisodes, animated: true)

            cell.cellSwitch.removeTarget(self, action: nil, for: UIControl.Event.valueChanged)
            cell.cellSwitch.addTarget(self, action: #selector(switchChanged(_:)), for: .valueChanged)
            return cell
        case .autoDownloadLimit:
            let cell = tableView.dequeueReusableCell(withIdentifier: disclosureCellId) as! DisclosureCell
            cell.cellLabel.text = L10n.autoDownloadPromptFirst
            cell.cellSecondaryLabel.text = L10n.episodeCountPluralFormat(filterToEdit.maxAutoDownloadEpisodes().localized())

            return cell
        case .siriShortcut:
            let cell = tableView.dequeueReusableCell(withIdentifier: settingsCellId) as! TopLevelSettingsCell
            cell.settingsLabel.text = L10n.settingsSiriShortcuts
            cell.settingsImage.image = UIImage(named: "settings_shortcuts")
            cell.settingsImage.tintColor = AppTheme.colorForStyle(.primaryIcon01)
            return cell
        case .isSessionPlaylist:
            let cell = tableView.dequeueReusableCell(withIdentifier: switchCellId) as! SwitchCell
            cell.cellSwitch.onStyle = .primaryIcon01

            cell.cellLabel.text = L10n.playlistIsSession
            cell.cellLabel.font.withSize(16)
            cell.setImage(image: UIImage(systemName: "rectangle.stack"))
            cell.cellSwitch.setOn(!Settings.playlistOptedOutOfSession(uuid: filterToEdit.uuid), animated: true)

            cell.cellSwitch.removeTarget(self, action: nil, for: UIControl.Event.valueChanged)
            cell.cellSwitch.addTarget(self, action: #selector(isSessionPlaylistChanged(_:)), for: .valueChanged)
            return cell
        case .sessionFillMode:
            let cell = tableView.dequeueReusableCell(withIdentifier: disclosureCellId) as! DisclosureCell
            cell.cellLabel.text = L10n.sessionFillMode
            cell.cellSecondaryLabel.text = sessionAutoFill ? L10n.sessionFillAuto : L10n.sessionFillManual

            return cell
        case .backfillSession:
            let cell = tableView.dequeueReusableCell(withIdentifier: deleteCellId, for: indexPath) as! AccountActionCell
            cell.cellLabel.text = L10n.sessionBackfillPlaylist
            cell.cellImage.image = UIImage(systemName: "rectangle.stack")
            cell.iconStyle = .primaryIcon01
            cell.counterView.isHidden = true
            cell.showsDisclosureIndicator = false
            return cell
        case .deletePlaylist:
            let cell = tableView.dequeueReusableCell(withIdentifier: deleteCellId, for: indexPath) as! AccountActionCell
            cell.cellLabel.text = L10n.playlistsDelete
            cell.cellImage.image = UIImage(named: "delete")
            cell.iconStyle = .support05
            cell.counterView.isHidden = true
            cell.showsDisclosureIndicator = false
            return cell
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let tableRow = tableData()[indexPath.section][indexPath.row]

        switch tableRow {
        case .autoDownloadLimit:

            tableView.deselectRow(at: indexPath, animated: true)

            let options = OptionsPicker(title: L10n.autoDownloadFirst)
            let currentLimit = filterToEdit.maxAutoDownloadEpisodes()
            addAutoLimitOption(optionPicker: options, limit: 5, currentLimit: currentLimit)
            addAutoLimitOption(optionPicker: options, limit: 10, currentLimit: currentLimit)
            addAutoLimitOption(optionPicker: options, limit: 20, currentLimit: currentLimit)
            addAutoLimitOption(optionPicker: options, limit: 40, currentLimit: currentLimit)
            addAutoLimitOption(optionPicker: options, limit: 100, currentLimit: currentLimit)

            options.present(from: self)
        case .siriShortcut:
            isViewingShortcuts = true
            let singleFilterVC = PlaylistShortcutsViewController(playlist: filterToEdit)
            navigationController?.pushViewController(singleFilterVC, animated: true)
            tableView.deselectRow(at: indexPath, animated: false)
        case .sessionFillMode:
            tableView.deselectRow(at: indexPath, animated: true)

            let current = sessionAutoFill
            let options = OptionsPicker(title: L10n.sessionFillMode.localizedUppercase)
            options.addAction(action: OptionAction(label: L10n.sessionFillAuto, selected: current) { [weak self] in
                self?.setSessionAutoFill(true)
            })
            options.addAction(action: OptionAction(label: L10n.sessionFillManual, selected: !current) { [weak self] in
                self?.setSessionAutoFill(false)
            })
            options.present(from: self)
        case .backfillSession:
            tableView.deselectRow(at: indexPath, animated: true)
            guard let playlist = filterToEdit else { return }

            // Full-domain query + store writes — off the main thread, or the whole screen
            // (including the back button) freezes for the duration on big playlists.
            DispatchQueue.global(qos: .userInitiated).async {
                let added = SessionManager.shared.backfillSession(forSmartPlaylist: playlist)
                DispatchQueue.main.async {
                    Toast.show(added > 0 ? L10n.sessionBackfillDone(added.localized()) : L10n.sessionBackfillNone)
                }
            }
        case .deletePlaylist:
            showDeleteConfirmationDialog(for: filterToEdit)

            tableView.deselectRow(at: indexPath, animated: true)
        default:
            tableView.deselectRow(at: indexPath, animated: false)
            return
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        let autoDownloadSection = 1
        if section == autoDownloadSection {
            return filterToEdit.autoDownloadEpisodes ? L10n.episodeCountPluralFormat(filterToEdit.maxAutoDownloadEpisodes().localized()) : L10n.playlistsAutoDownloadOffSubtitle
        }
        // Fork: explain what turning the playlist into (or out of) a session playlist means,
        // then the fill modes and what backfilling does — the row names alone don't carry it.
        if tableData()[section].contains(.isSessionPlaylist) {
            guard tableData()[section].contains(.sessionFillMode) else { return L10n.playlistIsSessionFooter }
            return "\(L10n.playlistIsSessionFooter)\n\n\(L10n.sessionFillFooter)\n\n\(L10n.sessionBackfillPlaylistMsg)"
        }
        if tableData()[section].contains(.sessionFillMode) {
            return "\(L10n.sessionFillFooter)\n\n\(L10n.sessionBackfillPlaylistMsg)"
        }
        if tableData()[section].contains(.backfillSession) {
            return L10n.sessionBackfillPlaylistMsg
        }
        return nil
    }

    func tableView(_ tableView: UITableView, willDisplayFooterView view: UIView, forSection section: Int) {
        ThemeableTable.setHeaderFooterTextColor(on: view)
    }

    // MARK: Actions

    @objc private func switchChanged(_ sender: UISwitch) {
        track(.filterAutoDownloadUpdated, properties: ["enabled": sender.isOn, "source": AnalyticsSource.filters])
        filterToEdit.autoDownloadEpisodes = sender.isOn
        didChangeAutoDownload = true
        tableView.reloadData()
    }

    /// Fork: "Session Playlist" — ON means this smart playlist can back a session (the default).
    /// Turning it OFF hides the fill/backfill rows here, and the Session tab, Play Session button
    /// and chooser/CarPlay row elsewhere. Any existing session keeps its lineup, frozen, so
    /// turning it back on restores everything.
    @objc private func isSessionPlaylistChanged(_ sender: UISwitch) {
        Settings.setPlaylistOptedOutOfSession(!sender.isOn, uuid: filterToEdit.uuid)
        tableView.reloadData()
        NotificationCenter.postOnMainThread(notification: SessionStore.changed)
        NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged, object: filterToEdit)
    }

    // MARK: - TextFieldDelegate

    func textFieldDidBeginEditing(_ textField: UITextField) {
        NotificationCenter.postOnMainThread(notification: Constants.Notifications.textEditingDidStart)
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        if didChangeName {
            track(.filterNameUpdated)
        }

        NotificationCenter.postOnMainThread(notification: Constants.Notifications.textEditingDidEnd)
        filterToEdit.setTitle(filterNameTextField.text, defaultTitle: L10n.filtersDefaultNewFilter.localizedCapitalized)
        textField.resignFirstResponder()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()

        return true
    }

    func textFieldShouldClear(_ textField: UITextField) -> Bool {
        true
    }

    // MARK: - Theme changes

    override func handleThemeChanged() {
        tableView.reloadData()
    }

    // MARK: - Table Data

    private func tableData() -> [[FilterEditOptionsViewController.TableRow]] {
        var data = filterToEdit.autoDownloadEpisodes ? FilterEditOptionsViewController.tableDataAutoDownloadEnabled : FilterEditOptionsViewController.tableDataAutoDownloadDisabled

        data.append([.siriShortcut])

        // Fork: smart playlists only — a manual playlist has no feeder to fill or backfill from.
        // The opt-out switch itself always shows for a smart playlist; the fill/backfill rows
        // only make sense while it IS a session playlist.
        if !filterToEdit.manual {
            var sessionRows: [TableRow] = [.isSessionPlaylist]
            if !Settings.playlistOptedOutOfSession(uuid: filterToEdit.uuid) {
                sessionRows.append(contentsOf: [.sessionFillMode, .backfillSession])
            }
            data.append(sessionRows)
        }

        data.append([.deletePlaylist])

        return data
    }

    // MARK: - Private Helper Methods

    private func addAutoLimitOption(optionPicker: OptionsPicker, limit: Int32, currentLimit: Int32) {
        let action = OptionAction(label: L10n.episodeCountPluralFormat(limit.localized()), selected: currentLimit == limit) { [weak self] in
            self?.track(.filterAutoDownloadLimitUpdated, properties: ["limit": limit])
            self?.didChangeEpisodeCount = true
            self?.filterToEdit.autoDownloadLimit = limit
            self?.tableView.reloadData()
        }
        optionPicker.addAction(action: action)
    }

    /// Fork: the playlist session's fill mode — Automatic when no session exists yet
    /// (new sessions default to autoFill).
    private var sessionAutoFill: Bool {
        SessionStore.shared.session(forSmartPlaylistFeeder: filterToEdit.uuid)?.autoFill ?? true
    }

    private func setSessionAutoFill(_ autoFill: Bool) {
        guard let session = SessionManager.shared.findOrCreateSession(forSmartPlaylist: filterToEdit) else { return }
        SessionStore.shared.setAutoFill(autoFill, for: session.uuid)
        tableView.reloadData()
    }

    private func updateExistingSortcutData() {
        SiriShortcutsManager.shared.voiceShortcutForFilter(filter: filterToEdit, completion: { voiceShortcut in
            self.existingShortcut = voiceShortcut
            DispatchQueue.main.async {
                self.tableView.reloadData()
            }
        })
    }
}

extension FilterEditOptionsViewController: PlaylistTypeTrackerProvider {
    var analyticsSourceType: String {
        filterToEdit.manual ? "manual" : "smart"
    }
}

// MARK: - Delete

extension FilterEditOptionsViewController {
    fileprivate func showDeleteConfirmationDialog(for playlist: EpisodeFilter) {
        let playlistType = playlist.manual ? "manual" : "smart"
        let analyticsProperties = ["filter_type": playlistType]
        Analytics.track(.filterDeleteTriggered, properties: analyticsProperties)

        let alert = UIAlertController(
            title: L10n.playlistsDeleteAlertTitle,
            message: L10n.playlistsDeleteAlertMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.cancel, style: .cancel) { _ in
            Analytics.track(.filterDeleteDismissed, properties: analyticsProperties)
        })
        alert.addAction(UIAlertAction(title: L10n.delete, style: .destructive) { [weak self] _ in
            self?.delete(playlist: playlist)
        })
        present(alert, animated: true)
    }

    fileprivate func delete(playlist: EpisodeFilter) {
        PlaylistManager.delete(playlist: playlist, fireEvent: true)

        var properties: [String: Sendable] = [:]
        properties["filter_type"] = playlist.manual ? "manual" : "smart"
        Analytics.track(.filterDeleted, properties: properties)
        navigationController?.popToRootViewController(animated: true)
    }
}
