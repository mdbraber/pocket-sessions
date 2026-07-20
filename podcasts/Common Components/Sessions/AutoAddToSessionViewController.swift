import PocketCastsDataModel
import UIKit

/// Fork: the global Auto Add to Session settings, mirroring Auto Add to Up Next —
/// the shared episode limit, the chooser, and each auto-add podcast's position.
class AutoAddToSessionViewController: PCViewController, UITableViewDelegate, UITableViewDataSource {
    private let disclosureCellId = "DisclosureCell"
    private let podcastDisclosureCellId = "PodcastDisclosureCell"

    private var autoAddPodcasts = [Podcast]()

    private enum TableRow { case autoAddLimit, selectPodcasts }
    private let topSettingsData: [TableRow] = [.autoAddLimit, .selectPodcasts]

    private let mainTable = ThemeableTable(frame: .zero, style: .grouped)

    override func viewDidLoad() {
        super.viewDidLoad()

        title = L10n.settingsAutoAddSession

        mainTable.register(UINib(nibName: "DisclosureCell", bundle: nil), forCellReuseIdentifier: disclosureCellId)
        mainTable.register(UINib(nibName: "PodcastDisclosureCell", bundle: nil), forCellReuseIdentifier: podcastDisclosureCellId)
        mainTable.rowHeight = UITableView.automaticDimension
        mainTable.estimatedRowHeight = UITableView.automaticDimension
        mainTable.dataSource = self
        mainTable.delegate = self
        mainTable.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mainTable)
        NSLayoutConstraint.activate([
            mainTable.topAnchor.constraint(equalTo: view.topAnchor),
            mainTable.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mainTable.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mainTable.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        reloadAutoAddPodcasts()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadAutoAddPodcasts()
        mainTable.reloadData()
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        2
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? topSettingsData.count : autoAddPodcasts.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let row = topSettingsData[indexPath.row]
            let cell = tableView.dequeueReusableCell(withIdentifier: disclosureCellId, for: indexPath) as! DisclosureCell
            switch row {
            case .autoAddLimit:
                cell.cellLabel.text = L10n.settingsAutoAddLimit
                cell.cellSecondaryLabel.text = Settings.sessionAutoAddLimit().localized()
            case .selectPodcasts:
                let podcastCount = autoAddPodcasts.count
                cell.cellLabel.text = podcastCount == 1 ? L10n.chosenPodcastsSingular : L10n.chosenPodcastsPluralFormat(podcastCount.localized())
                cell.cellSecondaryLabel.text = nil
            }

            return cell
        }

        let cell = tableView.dequeueReusableCell(withIdentifier: podcastDisclosureCellId, for: indexPath) as! PodcastDisclosureCell
        let podcast = autoAddPodcasts[indexPath.row]
        let mode = SessionStore.shared.session(forPodcast: podcast.uuid).flatMap { PlaylistInsertMode(rawValue: $0.insertMode) } ?? .top
        cell.populate(from: podcast, secondaryText: mode.description)

        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        if indexPath.section == 0 {
            let row = topSettingsData[indexPath.row]
            switch row {
            case .autoAddLimit:
                let options = OptionsPicker(title: L10n.settingsAutoAddLimit)
                addAutoAddLimit(amount: 10, to: options)
                addAutoAddLimit(amount: 20, to: options)
                addAutoAddLimit(amount: 50, to: options)
                addAutoAddLimit(amount: 100, to: options)
                addAutoAddLimit(amount: 200, to: options)
                addAutoAddLimit(amount: 500, to: options)
                addAutoAddLimit(amount: 1000, to: options)

                options.present(from: self)
            case .selectPodcasts:
                let podcastSelectViewController = PodcastChooserViewController()
                podcastSelectViewController.analyticsSource = .autoAdd
                podcastSelectViewController.delegate = self
                podcastSelectViewController.selectedUuids = autoAddPodcasts.map(\.uuid)
                navigationController?.pushViewController(podcastSelectViewController, animated: true)
            }
        } else {
            let podcast = autoAddPodcasts[indexPath.row]
            let options = OptionsPicker(title: L10n.sessionPositionHeading.localizedUppercase)
            for mode in PlaylistInsertMode.allCases {
                addActionForPodcast(podcast: podcast, mode: mode, to: options)
            }

            options.present(from: self)
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 || autoAddPodcasts.isEmpty ? nil : L10n.settingsAutoAddPodcasts
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? L10n.settingsSessionAutoAddLimitSubtitle(Settings.sessionAutoAddLimit().localized()) : nil
    }

    func tableView(_ tableView: UITableView, willDisplayFooterView view: UIView, forSection section: Int) {
        ThemeableTable.setHeaderFooterTextColor(on: view)
    }

    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        ThemeableTable.setHeaderFooterTextColor(on: view)
    }

    private func reloadAutoAddPodcasts() {
        autoAddPodcasts = DataManager.sharedManager.allPodcasts(includeUnsubscribed: false)
            .filter { SessionStore.shared.session(forPodcast: $0.uuid)?.autoAdd == true }
    }

    private func setAutoAdd(_ autoAdd: Bool, forPodcast podcast: Podcast) {
        if autoAdd {
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
    }

    private func addActionForPodcast(podcast: Podcast, mode: PlaylistInsertMode, to: OptionsPicker) {
        let currentMode = SessionStore.shared.session(forPodcast: podcast.uuid).flatMap { PlaylistInsertMode(rawValue: $0.insertMode) } ?? .top
        let action = OptionAction(label: mode.description, selected: currentMode == mode) { [weak self] in
            guard var session = SessionStore.shared.session(forPodcast: podcast.uuid) else { return }
            session.insertMode = mode.rawValue
            SessionStore.shared.upsert(session)
            self?.mainTable.reloadData()
        }
        to.addAction(action: action)
    }

    private func addAutoAddLimit(amount: Int, to: OptionsPicker) {
        let selectedSetting = Settings.sessionAutoAddLimit()
        let action = OptionAction(label: L10n.episodeCountPluralFormat(amount.localized()).localizedCapitalized, selected: selectedSetting == amount) { [weak self] in
            Settings.setSessionAutoAddLimit(amount)
            self?.mainTable.reloadData()
        }
        to.addAction(action: action)
    }
}

extension AutoAddToSessionViewController: PodcastSelectionDelegate {
    func bulkSelectionChange(selected: Bool) {
        for podcast in DataManager.sharedManager.allPodcasts(includeUnsubscribed: false) {
            setAutoAdd(selected, forPodcast: podcast)
        }
        reloadAutoAddPodcasts()
        mainTable.reloadData()
    }

    func podcastSelected(podcast: String) {
        guard let podcast = DataManager.sharedManager.findPodcast(uuid: podcast) else { return }
        setAutoAdd(true, forPodcast: podcast)
        reloadAutoAddPodcasts()
        mainTable.reloadData()
    }

    func podcastUnselected(podcast: String) {
        guard let podcast = DataManager.sharedManager.findPodcast(uuid: podcast) else { return }
        setAutoAdd(false, forPodcast: podcast)
        reloadAutoAddPodcasts()
        mainTable.reloadData()
    }

    func didChangePodcasts(numberSelected: Int) {}
}
