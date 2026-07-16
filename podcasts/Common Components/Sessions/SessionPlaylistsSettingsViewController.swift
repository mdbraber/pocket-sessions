import PocketCastsDataModel
import PocketCastsUtils
import SwiftUI
import UIKit

/// Fork: Playlists ⋯ → "Show Session Playlists". Manual and Smart Playlist sessions are ticks;
/// per-podcast sessions are chosen by ticking folders and/or podcasts — laid out like the
/// smart-playlist "Choose Podcasts" sheet (artwork on the left, square checkbox on the right).
class SessionPlaylistsSettingsViewController: PCViewController, UITableViewDataSource, UITableViewDelegate {
    private static let cellId = "SessionPlaylistsCell"

    private enum Row { case manual, smart, folder(Folder), podcast(Podcast) }

    private let onChange: () -> Void
    private let settingsTable = UITableView(frame: .zero, style: .plain)
    private let folders = DataManager.sharedManager.allFolders(includeDeleted: false)
    private let podcasts = DataManager.sharedManager.allPodcasts(includeUnsubscribed: false)
        .sorted { ($0.title ?? "").localizedCaseInsensitiveCompare($1.title ?? "") == .orderedAscending }

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var sections: [(header: String?, rows: [Row])] {
        var result: [(String?, [Row])] = [(nil, [.manual, .smart])]
        if !folders.isEmpty { result.append((L10n.sessionPlaylistsFolders, folders.map { Row.folder($0) })) }
        result.append((L10n.sessionPlaylistsPodcasts, podcasts.map { Row.podcast($0) }))
        return result.map { (header: $0.0, rows: $0.1) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.sessionPlaylistsShow
        navigationItem.leftBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "chevron.left"), style: .plain, target: self, action: #selector(backTapped))

        settingsTable.dataSource = self
        settingsTable.delegate = self
        settingsTable.backgroundColor = AppTheme.colorForStyle(.primaryUi01)
        settingsTable.separatorColor = AppTheme.colorForStyle(.primaryUi05)
        settingsTable.rowHeight = UITableView.automaticDimension
        settingsTable.estimatedRowHeight = 64
        settingsTable.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(settingsTable)
        NSLayoutConstraint.activate([
            settingsTable.topAnchor.constraint(equalTo: view.topAnchor),
            settingsTable.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            settingsTable.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            settingsTable.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    @objc private func backTapped() { dismiss(animated: true) }

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].header }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellId) ?? UITableViewCell(style: .default, reuseIdentifier: Self.cellId)
        cell.backgroundColor = .clear
        cell.contentView.backgroundColor = .clear
        cell.selectionStyle = .none

        let content: SessionPickerRow
        switch sections[indexPath.section].rows[indexPath.row] {
        case .manual:
            content = SessionPickerRow(label: L10n.sessionPlaylistsManual, selected: Settings.showManualSessions(), artwork: .none)
        case .smart:
            content = SessionPickerRow(label: L10n.sessionPlaylistsSmart, selected: Settings.showSmartPlaylistSessions(), artwork: .none)
        case .folder(let folder):
            content = SessionPickerRow(label: folder.name, selected: Settings.showPodcastSessionFolders().contains(folder.uuid), artwork: .folder(folder.uuid))
        case .podcast(let podcast):
            content = SessionPickerRow(label: podcast.title ?? "", selected: Settings.showPodcastSessionPodcasts().contains(podcast.uuid), artwork: .podcast(podcast.uuid))
        }
        cell.contentConfiguration = UIHostingConfiguration { content }.margins(.vertical, 6)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .manual:
            Settings.setShowManualSessions(!Settings.showManualSessions())
        case .smart:
            Settings.setShowSmartPlaylistSessions(!Settings.showSmartPlaylistSessions())
        case .folder(let folder):
            flip(Settings.showPodcastSessionFolders(), folder.uuid, set: Settings.setShowPodcastSessionFolders)
        case .podcast(let podcast):
            flip(Settings.showPodcastSessionPodcasts(), podcast.uuid, set: Settings.setShowPodcastSessionPodcasts)
        }
        SessionManager.shared.syncFolderScopedPodcastSessions()
        tableView.reloadRows(at: [indexPath], with: .none)
        onChange()
    }

    private func flip(_ current: Set<String>, _ uuid: String, set: (Set<String>) -> Void) {
        var updated = current
        if updated.contains(uuid) { updated.remove(uuid) } else { updated.insert(uuid) }
        set(updated)
    }
}

/// One row of the Show Session Playlists sheet, matching the smart-rule picker: optional artwork,
/// a medium callout label, and the square checkbox with a tick when selected.
private struct SessionPickerRow: View {
    enum Artwork { case none, folder(String), podcast(String) }
    let label: String
    let selected: Bool
    let artwork: Artwork

    var body: some View {
        HStack(spacing: 12) {
            artworkView
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundColor(AppTheme.color(for: .primaryText01, theme: Theme.sharedTheme))
                .lineLimit(1)
            Spacer(minLength: 8)
            checkbox
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }

    @ViewBuilder private var artworkView: some View {
        switch artwork {
        case .none:
            EmptyView()
        case .folder(let uuid):
            SearchFolderPreviewWrapper(uuid: uuid).frame(width: 40, height: 40).cornerRadius(6)
        case .podcast(let uuid):
            PodcastImageViewWrapper(podcastUUID: uuid, size: .list).frame(width: 40, height: 40).cornerRadius(6)
        }
    }

    private var checkbox: some View {
        ZStack {
            Image(selected ? "checkbox-selected" : "checkbox-unselected")
                .renderingMode(.template)
                .foregroundColor(AppTheme.color(for: .primaryInteractive01, theme: Theme.sharedTheme))
            if selected {
                Image("tick")
                    .renderingMode(.template)
                    .foregroundColor(AppTheme.color(for: .primaryInteractive02, theme: Theme.sharedTheme))
            }
        }
        .frame(width: 24, height: 24)
    }
}
