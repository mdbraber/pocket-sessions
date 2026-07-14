import PocketCastsDataModel
import PocketCastsUtils
import UIKit

/// Fork: per-podcast override of the global Up Next ↔ Session linking. Enable "Custom for This
/// Podcast" to reveal a switch per direction; off follows the global Linking setting. This mirrors
/// the *add action* (a manual add), not Auto Add — same shape as the podcast's Playback Effects page.
class PodcastLinkingViewController: PCViewController, UITableViewDataSource, UITableViewDelegate {
    private static let cellId = "PodcastLinkingCell"

    private enum TableRow { case customForPodcast, upNextToSession, sessionToUpNext }

    private var podcast: Podcast
    private let settingsTable = ThemeableTable(frame: .zero, style: .grouped)

    init(podcast: Podcast) {
        self.podcast = podcast
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// This podcast has an explicit Linking override (isn't following the global setting).
    private var customEnabled: Bool {
        Settings.mirrorOverride(key: Settings.mirrorUpNextToSessionKey, podcastUuid: podcast.uuid) != .followGlobal
            || Settings.mirrorOverride(key: Settings.mirrorSessionToUpNextKey, podcastUuid: podcast.uuid) != .followGlobal
    }

    /// The per-direction switches only exist while Custom is on.
    private var sections: [[TableRow]] {
        customEnabled ? [[.customForPodcast], [.upNextToSession, .sessionToUpNext]] : [[.customForPodcast]]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.settingsLinkingRow

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
        changeNavTint(titleColor: nil, iconsColor: podcast.navIconTintColor(), backgroundColor: podcast.navigationBarTintColor())
        settingsTable.reloadData()
    }

    // MARK: - Toggles

    @objc private func customToggled(_ sender: UISwitch) {
        if sender.isOn {
            // Seed each direction from what the global setting currently resolves to, so enabling
            // Custom changes nothing until the user flips a direction.
            Settings.setMirrorOverride(Settings.mirrorUpNextToSession() ? .on : .off, key: Settings.mirrorUpNextToSessionKey, podcastUuid: podcast.uuid)
            Settings.setMirrorOverride(Settings.mirrorSessionToUpNext() ? .on : .off, key: Settings.mirrorSessionToUpNextKey, podcastUuid: podcast.uuid)
        } else {
            Settings.setMirrorOverride(.followGlobal, key: Settings.mirrorUpNextToSessionKey, podcastUuid: podcast.uuid)
            Settings.setMirrorOverride(.followGlobal, key: Settings.mirrorSessionToUpNextKey, podcastUuid: podcast.uuid)
        }
        settingsTable.reloadData()
    }

    @objc private func upNextToSessionToggled(_ sender: UISwitch) {
        Settings.setMirrorOverride(sender.isOn ? .on : .off, key: Settings.mirrorUpNextToSessionKey, podcastUuid: podcast.uuid)
    }

    @objc private func sessionToUpNextToggled(_ sender: UISwitch) {
        Settings.setMirrorOverride(sender.isOn ? .on : .off, key: Settings.mirrorSessionToUpNextKey, podcastUuid: podcast.uuid)
    }

    // MARK: - Table

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].count }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sections[section].first == .customForPodcast ? L10n.settingsLinkingPodcastMsg : nil
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = (tableView.dequeueReusableCell(withIdentifier: Self.cellId) as? ThemeableCell)
            ?? ThemeableCell(style: .value1, reuseIdentifier: Self.cellId)
        let row = sections[indexPath.section][indexPath.row]

        let toggle = UISwitch()
        toggle.onTintColor = podcast.switchTintColor()
        switch row {
        case .customForPodcast:
            cell.textLabel?.text = L10n.settingsLinkingCustom
            toggle.isOn = customEnabled
            toggle.addTarget(self, action: #selector(customToggled(_:)), for: .valueChanged)
        case .upNextToSession:
            cell.textLabel?.text = L10n.settingsMirrorUpNextToSession
            toggle.isOn = Settings.resolvedMirrorUpNextToSession(podcastUuid: podcast.uuid)
            toggle.addTarget(self, action: #selector(upNextToSessionToggled(_:)), for: .valueChanged)
        case .sessionToUpNext:
            cell.textLabel?.text = L10n.settingsMirrorSessionToUpNext
            toggle.isOn = Settings.resolvedMirrorSessionToUpNext(podcastUuid: podcast.uuid)
            toggle.addTarget(self, action: #selector(sessionToUpNextToggled(_:)), for: .valueChanged)
        }
        cell.detailTextLabel?.text = nil
        cell.accessoryView = toggle
        cell.accessoryType = .none
        cell.selectionStyle = .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
    }
}
