import PocketCastsDataModel
import SwiftUI

/// Fork: the podcast/folder scope picker for a Filter Preset.
///
/// Multi-select over folders and podcasts. Empty selection = all podcasts (the default), which is
/// why the summary reads "All Podcasts" when nothing is chosen. Folders and podcasts are stored
/// separately on the preset (a folder resolves to its *current* members at query time, so adding a
/// show to a folder later widens the preset for free).
struct FilterPresetScopePicker: View {
    @EnvironmentObject var theme: Theme
    @ObservedObject var model: FilterPresetEditorModel

    private let folders = DataManager.sharedManager.allFolders(includeDeleted: false).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    private let podcasts = DataManager.sharedManager.allPodcasts(includeUnsubscribed: false).sorted { ($0.title ?? "").localizedCaseInsensitiveCompare($1.title ?? "") == .orderedAscending }

    var body: some View {
        List {
            if !folders.isEmpty {
                Section(header: Text(L10n.folders)) {
                    ForEach(folders, id: \.uuid) { folder in
                        row(folder.name, selected: model.preset.folderUuids.contains(folder.uuid)) {
                            toggle(folder.uuid, in: \.folderUuids)
                        }
                    }
                }
            }
            Section(header: Text(L10n.podcastsPlural)) {
                ForEach(podcasts, id: \.uuid) { podcast in
                    row(podcast.title ?? "", selected: model.preset.podcastUuids.contains(podcast.uuid)) {
                        toggle(podcast.uuid, in: \.podcastUuids)
                    }
                }
            }
        }
        .navigationTitle(L10n.filterPresetRuleScope)
    }

    private func row(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).foregroundStyle(theme.primaryText01)
                Spacer()
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(theme.primaryInteractive01)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ uuid: String, in keyPath: WritableKeyPath<FilterPreset, Set<String>>) {
        if model.preset[keyPath: keyPath].contains(uuid) {
            model.preset[keyPath: keyPath].remove(uuid)
        } else {
            model.preset[keyPath: keyPath].insert(uuid)
        }
    }
}

extension FilterPreset {
    /// A short human summary of the scope, for the editor row: "All Podcasts", or a count.
    var scopeSummary: String {
        guard isScoped else { return L10n.filterPresetScopeAll }
        return L10n.filterPresetScopeCount((podcastUuids.count + folderUuids.count).localized())
    }
}
