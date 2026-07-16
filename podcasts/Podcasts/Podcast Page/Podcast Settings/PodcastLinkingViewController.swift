import PocketCastsDataModel
import PocketCastsUtils
import UIKit

/// Fork: the per-podcast "Session" page. Position in Session is always available (it governs where
/// adds land, global default with a per-podcast override); Auto Add to Session is the on/off plus
/// its global limits; Session Linking (the Up Next ↔ Session mirror overrides) lives under its own
/// heading, revealed by "Custom for This Podcast".
class PodcastLinkingViewController: PCViewController, UITableViewDataSource, UITableViewDelegate {
    private static let cellId = "PodcastSessionCell"

    private enum TableRow { case position, autoAdd, autoAddLimit, customForPodcast, upNextToSession, sessionToUpNext }

    private var podcast: Podcast
    private let settingsTable = ThemeableTable(frame: .zero, style: .grouped)

    init(podcast: Podcast) {
        self.podcast = podcast
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var autoAddOn: Bool {
        SessionStore.shared.session(forPodcast: podcast.uuid)?.autoAdd ?? false
    }

    /// This podcast has an explicit Linking override (isn't following the global setting).
    private var customEnabled: Bool {
        Settings.mirrorOverride(key: Settings.mirrorUpNextToSessionKey, podcastUuid: podcast.uuid) != .followGlobal
            || Settings.mirrorOverride(key: Settings.mirrorSessionToUpNextKey, podcastUuid: podcast.uuid) != .followGlobal
    }

    private var sections: [[TableRow]] {
        // Position (always) + Auto Add (its limits appear when on); Linking behind its Custom toggle.
        let sessionRows: [TableRow] = autoAddOn ? [.position, .autoAdd, .autoAddLimit] : [.position, .autoAdd]
        let linkingRows: [TableRow] = customEnabled ? [.customForPodcast, .upNextToSession, .sessionToUpNext] : [.customForPodcast]
        return [sessionRows, linkingRows]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.playbackSessionTabSession

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

    // MARK: - Values

    private var positionValueLabel: String {
        guard let override = Settings.sessionPositionOverride(podcastUuid: podcast.uuid) else {
            return L10n.sessionPositionFollowGlobal
        }
        return override == .top ? L10n.top : L10n.bottom
    }

    // MARK: - Actions

    private func showPositionPicker() {
        let picker = OptionsPicker(title: L10n.sessionPositionHeading.localizedUppercase)
        let override = Settings.sessionPositionOverride(podcastUuid: podcast.uuid)
        picker.addAction(action: OptionAction(label: L10n.sessionPositionFollowGlobal, icon: nil, selected: override == nil) { [weak self] in
            guard let self else { return }
            Settings.setSessionPositionOverride(nil, podcastUuid: podcast.uuid)
            settingsTable.reloadData()
        })
        for mode in [PlaylistInsertMode.top, .bottom] {
            let label = mode == .top ? L10n.top : L10n.bottom
            picker.addAction(action: OptionAction(label: label, icon: nil, selected: override == mode) { [weak self] in
                guard let self else { return }
                Settings.setSessionPositionOverride(mode, podcastUuid: podcast.uuid)
                settingsTable.reloadData()
            })
        }
        picker.present(from: self)
    }

    @objc private func autoAddChanged(_ sender: UISwitch) {
        if sender.isOn {
            var session = SessionManager.shared.findOrCreateSession(forPodcast: podcast)
            session.autoAdd = true
            SessionStore.shared.upsert(session)
            DispatchQueue.global(qos: .userInitiated).async {
                SessionManager.shared.ingestAutoAdd(session: session)
            }
        } else if var session = SessionStore.shared.session(forPodcast: podcast.uuid) {
            session.autoAdd = false
            SessionStore.shared.upsert(session)
        }
        settingsTable.reloadData()
    }

    @objc private func customToggled(_ sender: UISwitch) {
        if sender.isOn {
            // Seed each direction from the current global setting, so enabling Custom changes nothing
            // until the user flips a direction.
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

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].first == .customForPodcast ? L10n.sessionLinkingHeading : nil
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sections[section].first == .customForPodcast ? L10n.settingsLinkingPodcastMsg : nil
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = sections[indexPath.section][indexPath.row]
        let cell = (tableView.dequeueReusableCell(withIdentifier: Self.cellId) as? ThemeableCell)
            ?? ThemeableCell(style: .value1, reuseIdentifier: Self.cellId)
        cell.accessoryView = nil
        cell.detailTextLabel?.text = nil

        func makeToggle(isOn: Bool, action: Selector) -> UISwitch {
            let toggle = UISwitch()
            toggle.onTintColor = podcast.switchTintColor()
            toggle.isOn = isOn
            toggle.addTarget(self, action: action, for: .valueChanged)
            return toggle
        }

        switch row {
        case .position:
            cell.textLabel?.text = L10n.sessionPositionHeading
            cell.detailTextLabel?.text = positionValueLabel
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case .autoAdd:
            cell.textLabel?.text = L10n.settingsAutoAddToSession
            cell.accessoryView = makeToggle(isOn: autoAddOn, action: #selector(autoAddChanged(_:)))
            cell.accessoryType = .none
            cell.selectionStyle = .none
        case .autoAddLimit:
            cell.textLabel?.text = L10n.settingsGlobalSettings
            cell.detailTextLabel?.text = L10n.settingsEpisodeLimitFormat(Settings.sessionAutoAddLimit().localized())
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case .customForPodcast:
            cell.textLabel?.text = L10n.settingsLinkingCustom
            cell.accessoryView = makeToggle(isOn: customEnabled, action: #selector(customToggled(_:)))
            cell.accessoryType = .none
            cell.selectionStyle = .none
        case .upNextToSession:
            cell.textLabel?.text = L10n.settingsMirrorUpNextToSession
            cell.accessoryView = makeToggle(isOn: Settings.resolvedMirrorUpNextToSession(podcastUuid: podcast.uuid), action: #selector(upNextToSessionToggled(_:)))
            cell.accessoryType = .none
            cell.selectionStyle = .none
        case .sessionToUpNext:
            cell.textLabel?.text = L10n.settingsMirrorSessionToUpNext
            cell.accessoryView = makeToggle(isOn: Settings.resolvedMirrorSessionToUpNext(podcastUuid: podcast.uuid), action: #selector(sessionToUpNextToggled(_:)))
            cell.accessoryType = .none
            cell.selectionStyle = .none
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section][indexPath.row] {
        case .position:
            showPositionPicker()
        case .autoAddLimit:
            navigationController?.pushViewController(AutoAddToSessionViewController(), animated: true)
        default:
            break
        }
    }
}
