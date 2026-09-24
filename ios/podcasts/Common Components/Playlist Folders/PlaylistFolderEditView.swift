import SwiftUI
import PocketCastsDataModel

/// Fork: edit a Playlist Folder — the podcast EditFolderView's exact layout: name,
/// color row, delete. Changes save when the sheet closes.
struct PlaylistFolderEditView: View {
    @EnvironmentObject var theme: Theme
    @StateObject private var model: PlaylistFolderCreationModel

    private let folder: PlaylistFolder
    private let onDismiss: () -> Void

    @State private var showingDeleteConfirmation = false

    init(folder: PlaylistFolder, onDismiss: @escaping () -> Void) {
        self.folder = folder
        self.onDismiss = onDismiss
        let model = PlaylistFolderCreationModel()
        model.name = folder.name
        model.colorInt = Int(folder.color)
        _model = StateObject(wrappedValue: model)
    }

    private var navBarTint: Color? {
        ThemeColor.navBarTint(ThemeColor.secondaryIcon01(for: theme.activeTheme))
    }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading) {
                Group {
                    Text(L10n.name.localizedUppercase)
                        .textStyle(SecondaryText())
                        .font(.subheadline)
                        .padding(.bottom, -8)
                        .padding(.top, 30)
                    TextField("", text: $model.name)
                        .themedTextField()
                }
                .padding(.bottom, 10)
                .padding([.leading, .trailing], 16)
                VStack(alignment: .leading, spacing: 20) {
                    Text(L10n.color.localizedUppercase)
                        .textStyle(SecondaryText())
                        .font(.subheadline)
                        .padding(.bottom, -14)
                        .padding([.leading, .trailing], 16)
                    ThemedDivider()
                    PlaylistFolderColorSelectRow(model: model)
                        .padding([.leading, .trailing], 16)
                }
                .padding(.vertical, 10)
                ThemedDivider()
                    .padding(.bottom, 16)
                VStack(alignment: .leading, spacing: 15) {
                    ThemedDivider()
                    Button {
                        showingDeleteConfirmation = true
                    } label: {
                        Group {
                            Image("delete")
                            Text(L10n.folderDelete)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .foregroundColor(ThemeColor.support05(for: theme.activeTheme).color)
                        .padding(.leading, 16)
                    }
                    .alert(isPresented: $showingDeleteConfirmation) {
                        Alert(
                            title: Text(L10n.folderDeletePromptTitle),
                            message: Text(L10n.playlistFolderDeleteMessage),
                            primaryButton: .destructive(Text(L10n.delete)) {
                                PlaylistFolderManager.shared.delete(folderUuid: folder.uuid)
                                onDismiss()
                            },
                            secondaryButton: .cancel()
                        )
                    }
                    ThemedDivider()
                }
                .padding(.top, 10)
                Spacer()
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        saveChanges()
                        onDismiss()
                    } label: {
                        Image("close")
                            .foregroundColor(navBarTint)
                    }
                    .accessibilityLabel(L10n.close)
                }
            }
            .applyDefaultThemeOptions()
            .navigationTitle(L10n.folderEdit)
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func saveChanges() {
        var updated = folder
        let trimmed = model.name.trimmingCharacters(in: .whitespaces)
        updated.name = trimmed.isEmpty ? folder.name : trimmed
        updated.color = Int32(model.colorInt)
        guard updated != folder else { return }
        PlaylistFolderManager.shared.save(folder: updated)
    }
}

/// Fork: Add or Remove Playlists — the podcast EditFolderPodcastsView's shape: the
/// picker list in its own sheet, membership applied on close.
struct EditPlaylistFolderPlaylistsView: View {
    @EnvironmentObject var theme: Theme

    let folderUuid: String
    let onDismiss: () -> Void

    @State private var selectedUuids: [String] = []

    private let allPlaylists = DataManager.sharedManager.allPlaylists(includeDeleted: false)

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 0) {
                    ThemedDivider()
                    ForEach(allPlaylists, id: \.uuid) { playlist in
                        PlaylistPickerRow(playlist: playlist, selectedUuids: $selectedUuids)
                        ThemedDivider()
                    }
                }
            }
            .navigationTitle(L10n.playlistFolderChoosePlaylists)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        PlaylistFolderManager.shared.setPlaylists(selectedUuids, inFolder: folderUuid)
                        onDismiss()
                    } label: {
                        Image("close")
                            .foregroundColor(ThemeColor.secondaryIcon01(for: theme.activeTheme).color)
                    }
                    .accessibilityLabel(L10n.close)
                }
            }
            .applyDefaultThemeOptions()
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear {
            selectedUuids = PlaylistFolderManager.shared.playlistUuids(inFolder: folderUuid)
        }
    }
}

/// The podcast PodcastPickerRow's layout for playlists: 56pt artwork, name, and the
/// rounded-square checkbox.
struct PlaylistPickerRow: View {
    @EnvironmentObject var theme: Theme

    let playlist: EpisodeFilter
    @Binding var selectedUuids: [String]

    private var leadingPodcastUuid: String? {
        playlist.podcastUuids.components(separatedBy: ",").first { !$0.isEmpty && $0 != "none" }
    }

    var body: some View {
        Button {
            if selectedUuids.contains(playlist.uuid) {
                selectedUuids.removeAll { $0 == playlist.uuid }
            } else {
                selectedUuids.append(playlist.uuid)
            }
        } label: {
            HStack {
                Group {
                    if let uuid = leadingPodcastUuid {
                        PodcastImageViewWrapper(podcastUUID: uuid, size: .list)
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.black.opacity(0.1))
                    }
                }
                .frame(width: 56, height: 56)
                .cornerRadius(4)
                .shadow(radius: 2, x: 0, y: 1)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.playlistName)
                        .textStyle(PrimaryText())
                        .font(.callout)
                        .lineLimit(2)
                }
                .padding(.leading, 2)
                Spacer()
                ZStack {
                    if selectedUuids.contains(playlist.uuid) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(ThemeColor.primaryInteractive01(for: theme.activeTheme).color)
                            .frame(width: 24, height: 24)
                        Image("small-tick")
                            .foregroundColor(ThemeColor.primaryInteractive02(for: theme.activeTheme).color)
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(ThemeColor.primaryInteractive01(for: theme.activeTheme).color, lineWidth: 2)
                            .frame(width: 24, height: 24)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}
