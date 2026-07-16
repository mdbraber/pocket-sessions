import PocketCastsDataModel
import PocketCastsUtils
import UIKit

/// Fork: Playlists ⋯ → "Show Session Playlists" (a sheet). Manual and Smart Playlist sessions
/// toggle on/off; per-podcast sessions show for the folders and podcasts ticked here (square
/// checkboxes, like the smart-playlist rule picker). Replaces the old "Hide Session Playlists".
class SessionPlaylistsSettingsViewController: PCViewController, UITableViewDataSource, UITableViewDelegate {
    private static let cellId = "SessionPlaylistsCell"

    private enum Row { case manual, smart, folder(Folder), podcast(Podcast) }

    private let onChange: () -> Void
    private let settingsTable = ThemeableTable(frame: .zero, style: .grouped)
    private let folders = DataManager.sharedManager.allFolders(includeDeleted: false)
    private let podcasts = DataManager.sharedManager.allPodcasts(includeUnsubscribed: false)
        .sorted { ($0.title ?? "").localizedCaseInsensitiveCompare($1.title ?? "") == .orderedAscending }

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// One toggles section, then a Podcast Sessions section: folders first, then podcasts.
    private var sections: [[Row]] {
        var podcastSection: [Row] = folders.map { Row.folder($0) }
        podcastSection += podcasts.map { Row.podcast($0) }
        return [[.manual, .smart], podcastSection]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.sessionPlaylistsShow
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(doneTapped))
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

    @objc private func doneTapped() { dismiss(animated: true) }

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 1 ? L10n.sessionPlaylistsPodcast : nil
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 1 ? L10n.sessionPlaylistsPodcastFooter : nil
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = (tableView.dequeueReusableCell(withIdentifier: Self.cellId) as? ThemeableCell)
            ?? ThemeableCell(style: .default, reuseIdentifier: Self.cellId)
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.selectionStyle = .none
        cell.imageView?.image = nil

        switch sections[indexPath.section][indexPath.row] {
        case .manual:
            cell.textLabel?.text = L10n.sessionPlaylistsManual
            cell.accessoryView = makeToggle(isOn: Settings.showManualSessions(), action: #selector(manualChanged(_:)))
        case .smart:
            cell.textLabel?.text = L10n.sessionPlaylistsSmart
            cell.accessoryView = makeToggle(isOn: Settings.showSmartPlaylistSessions(), action: #selector(smartChanged(_:)))
        case .folder(let folder):
            cell.textLabel?.text = folder.name
            cell.imageView?.image = UIImage(systemName: "folder.fill")?.withTintColor(AppTheme.folderColor(colorInt: folder.color), renderingMode: .alwaysOriginal)
            cell.accessoryView = checkbox(selected: Settings.showPodcastSessionFolders().contains(folder.uuid))
            cell.selectionStyle = .default
        case .podcast(let podcast):
            cell.textLabel?.text = podcast.title
            cell.accessoryView = checkbox(selected: Settings.showPodcastSessionPodcasts().contains(podcast.uuid))
            cell.selectionStyle = .default
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section][indexPath.row] {
        case .folder(let folder):
            toggle(Settings.showPodcastSessionFolders(), folder.uuid, set: Settings.setShowPodcastSessionFolders)
        case .podcast(let podcast):
            toggle(Settings.showPodcastSessionPodcasts(), podcast.uuid, set: Settings.setShowPodcastSessionPodcasts)
        default:
            return
        }
        SessionManager.shared.syncFolderScopedPodcastSessions()
        settingsTable.reloadRows(at: [indexPath], with: .none)
        onChange()
    }

    // MARK: - Helpers

    private func toggle(_ current: Set<String>, _ uuid: String, set: (Set<String>) -> Void) {
        var updated = current
        if updated.contains(uuid) { updated.remove(uuid) } else { updated.insert(uuid) }
        set(updated)
    }

    private func checkbox(selected: Bool) -> UIImageView {
        UIImageView(image: UIImage(named: selected ? "checkbox-selected" : "checkbox-unselected"))
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
