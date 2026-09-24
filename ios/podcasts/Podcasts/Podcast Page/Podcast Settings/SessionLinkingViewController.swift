import PocketCastsDataModel
import UIKit

/// Fork: the per-podcast Session Linking detail page — an explicit override of the global
/// Up Next ↔ Session mirror. Reached from the Linking row in podcast settings, styled like
/// the Auto Archive detail page.
class SessionLinkingViewController: PCViewController, UITableViewDataSource, UITableViewDelegate {
    private enum Row { case custom, mirrorUpNextToSession, mirrorSessionToUpNext }

    private static let switchCellId = "SwitchCell"

    private let podcast: Podcast

    private let linkingTable = ThemeableTable(frame: .zero, style: .grouped)

    init(podcast: Podcast) {
        self.podcast = podcast
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        changeNavTint(titleColor: nil, iconsColor: podcast.navIconTintColor(), backgroundColor: podcast.navigationBarTintColor())
        title = L10n.sessionLinkingHeading

        linkingTable.translatesAutoresizingMaskIntoConstraints = false
        linkingTable.rowHeight = UITableView.automaticDimension
        linkingTable.dataSource = self
        linkingTable.delegate = self
        linkingTable.register(UINib(nibName: "SwitchCell", bundle: nil), forCellReuseIdentifier: Self.switchCellId)
        view.addSubview(linkingTable)
        NSLayoutConstraint.activate([
            linkingTable.topAnchor.constraint(equalTo: view.topAnchor),
            linkingTable.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            linkingTable.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            linkingTable.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    override func handleThemeChanged() {
        changeNavTint(titleColor: nil, iconsColor: podcast.navIconTintColor(), backgroundColor: podcast.navigationBarTintColor())
        linkingTable.reloadData()
    }

    // MARK: - State

    /// This podcast has an explicit Linking override (isn't following the global setting).
    private var customEnabled: Bool {
        Settings.mirrorOverride(key: Settings.mirrorUpNextToSessionKey, podcastUuid: podcast.uuid) != .followGlobal
            || Settings.mirrorOverride(key: Settings.mirrorSessionToUpNextKey, podcastUuid: podcast.uuid) != .followGlobal
    }

    private var rows: [Row] {
        customEnabled ? [.custom, .mirrorUpNextToSession, .mirrorSessionToUpNext] : [.custom]
    }

    // MARK: - UITableViewDataSource

    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.switchCellId, for: indexPath) as! SwitchCell
        cell.cellSwitch.onTintColor = podcast.switchTintColor()
        cell.setNoImage()

        switch rows[indexPath.row] {
        case .custom:
            cell.cellLabel.text = L10n.settingsLinkingCustom
            cell.cellSwitch.isOn = customEnabled
            cell.cellSwitch.removeTarget(self, action: nil, for: .valueChanged)
            cell.cellSwitch.addTarget(self, action: #selector(customChanged(_:)), for: .valueChanged)
        case .mirrorUpNextToSession:
            cell.cellLabel.text = L10n.settingsMirrorUpNextToSession
            cell.cellSwitch.isOn = Settings.resolvedMirrorUpNextToSession(podcastUuid: podcast.uuid)
            cell.cellSwitch.removeTarget(self, action: nil, for: .valueChanged)
            cell.cellSwitch.addTarget(self, action: #selector(mirrorUpNextToSessionChanged(_:)), for: .valueChanged)
        case .mirrorSessionToUpNext:
            cell.cellLabel.text = L10n.settingsMirrorSessionToUpNext
            cell.cellSwitch.isOn = Settings.resolvedMirrorSessionToUpNext(podcastUuid: podcast.uuid)
            cell.cellSwitch.removeTarget(self, action: nil, for: .valueChanged)
            cell.cellSwitch.addTarget(self, action: #selector(mirrorSessionToUpNextChanged(_:)), for: .valueChanged)
        }

        return cell
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        L10n.settingsLinkingPodcastMsg
    }

    func tableView(_ tableView: UITableView, willDisplayFooterView view: UIView, forSection section: Int) {
        ThemeableTable.setHeaderFooterTextColor(on: view)
    }

    // MARK: - Switch handlers

    @objc private func customChanged(_ sender: UISwitch) {
        if sender.isOn {
            // Seed each direction from the current global setting, so enabling Custom changes nothing
            // until the user flips a direction.
            Settings.setMirrorOverride(Settings.mirrorUpNextToSession() ? .on : .off, key: Settings.mirrorUpNextToSessionKey, podcastUuid: podcast.uuid)
            Settings.setMirrorOverride(Settings.mirrorSessionToUpNext() ? .on : .off, key: Settings.mirrorSessionToUpNextKey, podcastUuid: podcast.uuid)
        } else {
            Settings.setMirrorOverride(.followGlobal, key: Settings.mirrorUpNextToSessionKey, podcastUuid: podcast.uuid)
            Settings.setMirrorOverride(.followGlobal, key: Settings.mirrorSessionToUpNextKey, podcastUuid: podcast.uuid)
        }
        linkingTable.reloadData()
    }

    @objc private func mirrorUpNextToSessionChanged(_ sender: UISwitch) {
        Settings.setMirrorOverride(sender.isOn ? .on : .off, key: Settings.mirrorUpNextToSessionKey, podcastUuid: podcast.uuid)
    }

    @objc private func mirrorSessionToUpNextChanged(_ sender: UISwitch) {
        Settings.setMirrorOverride(sender.isOn ? .on : .off, key: Settings.mirrorSessionToUpNextKey, podcastUuid: podcast.uuid)
    }
}
