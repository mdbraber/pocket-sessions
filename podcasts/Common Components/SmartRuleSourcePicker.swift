import PocketCastsDataModel
import SwiftUI
import UIKit

/// Multi-select picker for the fork's folder / manual-playlist smart rules, with an
/// include/exclude toggle. Mirrors the podcast rule picker's save semantics: writes the
/// selection to the filter, marks the transient applied flag, saves and posts
/// `playlistChanged`, then pops.
enum SmartRuleSourcePicker {
    enum Kind {
        case folders
        case manualPlaylists

        var title: String {
            switch self {
            case .folders: return L10n.smartRuleChooseFolders
            case .manualPlaylists: return L10n.smartRuleChoosePlaylists
            }
        }
    }

    static func makeController(kind: Kind, filter: EpisodeFilter) -> UIViewController {
        let controller = ThemedHostingController(rootView: SmartRuleSourcePickerView(kind: kind, filter: filter))
        controller.title = kind.title
        return controller
    }
}

struct SmartRuleSourcePickerView: View {
    struct Item: Identifiable {
        let uuid: String
        let name: String
        var id: String { uuid }
    }

    let kind: SmartRuleSourcePicker.Kind
    let filter: EpisodeFilter

    @EnvironmentObject private var theme: Theme
    @Environment(\.dismiss) private var dismiss

    @State private var selectedUuids: Set<String>
    @State private var excluded: Bool
    private let items: [Item]

    init(kind: SmartRuleSourcePicker.Kind, filter: EpisodeFilter) {
        self.kind = kind
        self.filter = filter

        switch kind {
        case .folders:
            items = DataManager.sharedManager.allFolders()
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { Item(uuid: $0.uuid, name: $0.name) }
            _selectedUuids = State(initialValue: Set(filter.folderUuids.components(separatedBy: ",").filter { !$0.isEmpty }))
            _excluded = State(initialValue: filter.foldersExcluded)
        case .manualPlaylists:
            items = DataManager.sharedManager.allManualPlaylists(includeDeleted: false)
                .filter { $0.uuid != filter.uuid }
                .map { Item(uuid: $0.uuid, name: $0.playlistName) }
            _selectedUuids = State(initialValue: Set(filter.manualPlaylistUuids.components(separatedBy: ",").filter { !$0.isEmpty }))
            _excluded = State(initialValue: filter.manualPlaylistsExcluded)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    Toggle(isOn: $excluded) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.smartRuleExcludeTitle)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))
                            Text(excluded ? L10n.smartRuleExcludeSubtitleOn : L10n.smartRuleExcludeSubtitleOff)
                                .font(.footnote)
                                .foregroundColor(AppTheme.color(for: .primaryText02, theme: theme))
                        }
                    }
                    .tint(AppTheme.color(for: .primaryInteractive01, theme: theme))
                    .listRowBackground(AppTheme.color(for: .primaryUi01, theme: theme))
                }

                Section {
                    ForEach(items) { item in
                        Button {
                            if selectedUuids.contains(item.uuid) {
                                selectedUuids.remove(item.uuid)
                            } else {
                                selectedUuids.insert(item.uuid)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                // The same checkbox the podcast rule picker's cells use
                                ZStack {
                                    Image(selectedUuids.contains(item.uuid) ? "checkbox-selected" : "checkbox-unselected")
                                        .renderingMode(.template)
                                        .foregroundColor(AppTheme.color(for: .primaryInteractive01, theme: theme))
                                    if selectedUuids.contains(item.uuid) {
                                        Image("tick")
                                            .renderingMode(.template)
                                            .foregroundColor(AppTheme.color(for: .primaryInteractive02, theme: theme))
                                    }
                                }
                                .frame(width: 24, height: 24)

                                Text(item.name)
                                    .font(.callout.weight(.medium))
                                    .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))
                                Spacer()
                            }
                        }
                        .listRowBackground(AppTheme.color(for: .primaryUi01, theme: theme))
                    }
                }
            }
            .scrollContentBackground(.hidden)

            Button(action: save) {
                Text(L10n.playlistSmartRuleSaveButton)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppTheme.color(for: .primaryInteractive01, theme: theme))
                    .foregroundColor(AppTheme.color(for: .primaryInteractive02, theme: theme))
                    .cornerRadius(12)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(AppTheme.color(for: .primaryUi04, theme: theme))
    }

    private func save() {
        let joined = selectedUuids.isEmpty ? "" : items.map(\.uuid).filter { selectedUuids.contains($0) }.joined(separator: ",")

        switch kind {
        case .folders:
            filter.folderUuids = joined
            filter.foldersExcluded = joined.isEmpty ? false : excluded
            filter.folderSmartRuleApplied = true
        case .manualPlaylists:
            filter.manualPlaylistUuids = joined
            filter.manualPlaylistsExcluded = joined.isEmpty ? false : excluded
            filter.manualPlaylistSmartRuleApplied = true
        }

        filter.syncStatus = SyncStatus.notSynced.rawValue
        DataManager.sharedManager.save(playlist: filter)
        NotificationCenter.postOnMainThread(notification: Constants.Notifications.playlistChanged, object: filter)
        dismiss()
    }
}
