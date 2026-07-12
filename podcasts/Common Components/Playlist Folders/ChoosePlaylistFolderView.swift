import SwiftUI
import PocketCastsDataModel

/// Fork: move a playlist into a Playlist Folder — the same UX as the podcast page's
/// Choose Folder sheet: a "No Folder" row, folder rows with tick, divider-separated,
/// and a bordered New Folder button that pushes the create form.
struct ChoosePlaylistFolderView: View {
    @EnvironmentObject var theme: Theme

    let playlistUuid: String
    let onDismiss: () -> Void

    @State private var folders: [PlaylistFolder] = []
    @State private var currentFolderUuid: String?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack {
                    ThemedDivider()

                    // "No Folder" first, like the podcast picker's root row.
                    Button {
                        PlaylistFolderManager.shared.setFolder(nil, forPlaylist: playlistUuid)
                        onDismiss()
                    } label: {
                        row(color: nil, name: L10n.folderNoFolder, count: topLevelPlaylistCount, selected: currentFolderUuid == nil)
                    }
                    ThemedDivider()

                    ForEach(folders) { folder in
                        Button {
                            PlaylistFolderManager.shared.setFolder(folder.uuid, forPlaylist: playlistUuid)
                            onDismiss()
                        } label: {
                            row(color: Color(AppTheme.folderColor(colorInt: folder.color)),
                                name: folder.name.isEmpty ? L10n.folderUnnamed : folder.name,
                                count: PlaylistFolderManager.shared.playlistUuids(inFolder: folder.uuid).count,
                                selected: folder.uuid == currentFolderUuid)
                        }
                        ThemedDivider()
                    }

                    HStack {
                        Spacer()
                        NavigationLink(destination: CreatePlaylistFolderView(isInsideNavigation: true, preselectPlaylistUuid: playlistUuid, onDismiss: onDismiss)) {
                            HStack {
                                Image(systemName: "plus")
                                Text(L10n.folderNew)
                                    .fontWeight(.semibold)
                            }
                            .font(.callout)
                            .foregroundColor(ThemeColor.primaryInteractive01(for: theme.activeTheme).color)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(ThemeColor.primaryInteractive01(for: theme.activeTheme).color, lineWidth: 2)
                            )
                        }
                        Spacer()
                    }
                    .padding(.top, 10)
                }
            }
            .padding(.top, 14)
            .navigationTitle(L10n.playlistFolderChoose)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        onDismiss()
                    } label: {
                        Image("close")
                            .foregroundColor(ThemeColor.navBarTint(ThemeColor.secondaryIcon01(for: theme.activeTheme)))
                    }
                    .accessibilityLabel(L10n.close)
                }
            }
            .applyDefaultThemeOptions()
            .onAppear {
                folders = PlaylistFolderManager.shared.allFolders()
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                currentFolderUuid = PlaylistFolderManager.shared.folderUuid(forPlaylist: playlistUuid)
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private var topLevelPlaylistCount: Int {
        DataManager.sharedManager.allPlaylists(includeDeleted: false)
            .filter { PlaylistFolderManager.shared.folderUuid(forPlaylist: $0.uuid) == nil }
            .count
    }

    /// The podcast picker's FolderSelectRow, with playlist counts.
    private func row(color: Color?, name: String, count: Int, selected: Bool) -> some View {
        HStack(spacing: 16) {
            if let color {
                Image("folder-empty")
                    .foregroundColor(color)
            } else {
                Spacer()
                    .frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .textStyle(PrimaryText())
                    .font(.headline)
                    .lineLimit(1)
                Text(count == 1 ? L10n.playlistCountSingular : L10n.playlistCountPluralFormat(count.localized()))
                    .textStyle(SecondaryText())
                    .font(.footnote)
                    .lineLimit(1)
            }
            Spacer()
            if selected {
                Image("small-tick")
                    .foregroundColor(ThemeColor.primaryIcon01(for: theme.activeTheme).color)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
    }
}
