import SwiftUI
import PocketCastsDataModel

/// Fork: the Playlist Folder creation wizard — the same three steps as the podcast
/// folder flow: pick playlists → name → color with live preview.
class PlaylistFolderCreationModel: ObservableObject {
    @Published var name = ""
    @Published var colorInt = 0
    @Published var selectedPlaylistUuids: [String] = []

    func color(for colorId: Int) -> Color {
        Color(AppTheme.folderColor(colorInt: Int32(colorId)))
    }

    var color: Color {
        color(for: colorInt)
    }

    func createFolder() {
        PlaylistFolderManager.shared.createFolder(name: name, color: Int32(colorInt), playlistUuids: selectedPlaylistUuids)
    }
}

// MARK: - Preview tile (the podcast FolderPreviewView's look, artwork grid included)

/// The 2×2 artwork composite on a folder-colored tile — each slot shows the leading
/// podcast of one of the folder's playlists.
struct PlaylistFolderPreviewTile: View {
    let color: Int32
    let podcastUuids: [String]

    var body: some View {
        GeometryReader { proxy in
            let imageSize = proxy.size.width / 3
            let padding: CGFloat = 4
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(AppTheme.folderColor(colorInt: color)))
                VStack(spacing: padding) {
                    HStack(spacing: padding) {
                        slot(0, size: imageSize)
                        slot(1, size: imageSize)
                    }
                    HStack(spacing: padding) {
                        slot(2, size: imageSize)
                        slot(3, size: imageSize)
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder private func slot(_ index: Int, size: CGFloat) -> some View {
        if let uuid = podcastUuids[safe: index] {
            PodcastImageViewWrapper(podcastUUID: uuid, size: .list)
                .frame(width: size, height: size)
                .cornerRadius(3)
        } else {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.black.opacity(0.1))
                .frame(width: size, height: size)
        }
    }
}

extension PlaylistFolderManager {
    /// The artwork slots for a folder tile: each member playlist contributes its
    /// leading podcast, in list order.
    func previewPodcastUuids(inFolder folderUuid: String) -> [String] {
        previewPodcastUuids(forPlaylistUuids: playlistUuids(inFolder: folderUuid))
    }

    func previewPodcastUuids(forPlaylistUuids uuids: [String]) -> [String] {
        let members = Set(uuids)
        var result = [String]()
        for playlist in DataManager.sharedManager.allPlaylists(includeDeleted: false) where members.contains(playlist.uuid) {
            // Prefer the explicit podcast rule; a manual playlist or a filter-all smart playlist has
            // no rule uuids, so fall back to the first podcast whose episode is actually in it —
            // otherwise the folder tile is blank even though it clearly has a podcast.
            let candidate = playlist.podcastUuids.components(separatedBy: ",").first { !$0.isEmpty && $0 != "none" }
                ?? leadingEpisodePodcast(for: playlist)
            guard let first = candidate, !result.contains(first) else { continue }
            result.append(first)
            if result.count == 4 { break }
        }
        return result
    }

    /// The first podcast with an episode in the playlist — the artwork source when there's no
    /// podcast rule to read. Bounded fetch; only hit for rule-less members.
    private func leadingEpisodePodcast(for playlist: EpisodeFilter) -> String? {
        EpisodesDataManager().playlistEpisodes(for: playlist, limit: 5)
            .lazy.map { $0.episode.podcastUuid }.first { !$0.isEmpty }
    }
}

// MARK: - Step 1: pick playlists

/// Mirrors CreateFolderView: playlist selection with Select All, then an
/// "Add N Playlists" button leading to the name step.
struct CreatePlaylistFolderView: View {
    @EnvironmentObject var theme: Theme
    @StateObject private var model = PlaylistFolderCreationModel()

    /// When pushed from the Choose Folder picker rather than presented standalone.
    var isInsideNavigation: Bool = false
    var preselectPlaylistUuid: String?

    let onDismiss: () -> Void

    private let allPlaylists = DataManager.sharedManager.allPlaylists(includeDeleted: false)

    private var navBarTint: Color? {
        ThemeColor.navBarTint(ThemeColor.secondaryIcon01(for: theme.activeTheme))
    }

    private var addButtonTitle: String {
        let selectedCount = model.selectedPlaylistUuids.count
        return selectedCount == 1 ? L10n.playlistFolderAddSingular : L10n.playlistFolderAddPluralFormat(selectedCount.localized())
    }

    private var hasSelectedAll: Bool {
        model.selectedPlaylistUuids.count == allPlaylists.count
    }

    var body: some View {
        if isInsideNavigation {
            mainBody
        } else {
            navWrappedBody
        }
    }

    private var mainBody: some View {
        VStack {
            ScrollView {
                VStack(spacing: 0) {
                    ThemedDivider()
                    ForEach(allPlaylists, id: \.uuid) { playlist in
                        PlaylistPickerRow(playlist: playlist, selectedUuids: $model.selectedPlaylistUuids)
                        ThemedDivider()
                    }
                }
            }
            NavigationLink(destination: NamePlaylistFolderView(model: model, onDismiss: onDismiss)) {
                Text(addButtonTitle)
                    .textStyle(RoundedButton())
            }
            .padding(.horizontal)
        }
        .navigationTitle(L10n.folderCreate)
        .onAppear {
            if let uuid = preselectPlaylistUuid, !model.selectedPlaylistUuids.contains(uuid) {
                model.selectedPlaylistUuids.append(uuid)
            }
        }
        .applyDefaultThemeOptions()
    }

    private var navWrappedBody: some View {
        NavigationView {
            mainBody
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            onDismiss()
                        } label: {
                            Image("close")
                                .foregroundColor(navBarTint)
                        }
                        .accessibilityLabel(L10n.close)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            model.selectedPlaylistUuids = hasSelectedAll ? [] : allPlaylists.map(\.uuid)
                        } label: {
                            Text(hasSelectedAll ? L10n.deselectAll : L10n.selectAll)
                                .foregroundColor(navBarTint)
                        }
                    }
                }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - Step 2: name (NameFolderView's layout)

struct NamePlaylistFolderView: View {
    @EnvironmentObject var theme: Theme
    @ObservedObject var model: PlaylistFolderCreationModel

    @State private var focusOnTextField = false

    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            Text(L10n.name.localizedUppercase)
                .textStyle(SecondaryText())
                .font(.subheadline)
            TextField(L10n.folderName, text: $model.name)
                .focusMe(state: $focusOnTextField)
                .themedTextField()
            Spacer()
            NavigationLink(destination: ColorPreviewPlaylistFolderView(model: model, onDismiss: onDismiss)) {
                Text(L10n.continue)
                    .textStyle(RoundedButton())
            }
        }
        .padding()
        .navigationTitle(L10n.folderNameTitle)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                focusOnTextField = true
            }
        }
        .applyDefaultThemeOptions()
    }
}

// MARK: - Step 3: color + preview (ColorPreviewFolderView's layout)

struct ColorPreviewPlaylistFolderView: View {
    @EnvironmentObject var theme: Theme
    @ObservedObject var model: PlaylistFolderCreationModel

    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group {
                Text(L10n.color.localizedUppercase)
                    .textStyle(SecondaryText())
                    .font(.subheadline)
                    .padding(.bottom, -8)
                ThemedDivider()
                PlaylistFolderColorSelectRow(model: model)
                ThemedDivider()
                Text(L10n.folderColorDetail)
                    .font(.footnote)
                    .textStyle(SecondaryText())
                    .padding(.top, -8)
            }
            Group {
                Text(L10n.preview.localizedUppercase)
                    .textStyle(SecondaryText())
                    .font(.subheadline)
                    .padding(.bottom, -8)
                    .padding(.top, 10)
                ThemedDivider()
                HStack {
                    PlaylistFolderPreviewTile(color: Int32(model.colorInt),
                                              podcastUuids: PlaylistFolderManager.shared.previewPodcastUuids(forPlaylistUuids: model.selectedPlaylistUuids))
                        .frame(width: 60, height: 60)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.name)
                            .textStyle(PrimaryText())
                            .font(.subheadline)
                        Text(model.selectedPlaylistUuids.count == 1 ? L10n.playlistCountSingular : L10n.playlistCountPluralFormat(model.selectedPlaylistUuids.count.localized()))
                            .textStyle(SecondaryText())
                            .font(.subheadline)
                    }
                    Spacer()
                }
                ThemedDivider()
            }
            Spacer()
            Button {
                model.createFolder()
                onDismiss()
            } label: {
                Text(L10n.folderSaveFolder)
                    .textStyle(RoundedButton())
            }
        }
        .padding()
        .navigationTitle(L10n.folderChooseColor)
        .applyDefaultThemeOptions()
    }
}

/// ColorSelectRow's layout, driven by the playlist folder model.
struct PlaylistFolderColorSelectRow: View {
    @EnvironmentObject var theme: Theme
    @ObservedObject var model: PlaylistFolderCreationModel

    let availableColors = [0, 6, 2, 1, 3, 9, 7, 4, 10, 8, 5, 11]
    let spacing: CGFloat = 12
    let circleWidth: CGFloat = 40

    var body: some View {
        GeometryReader { geometry in
            LazyVGrid(columns: getColumns(gridWidth: geometry.size.width), alignment: .leading, spacing: spacing) {
                ForEach(availableColors, id: \.self) { colorId in
                    Button {
                        model.colorInt = colorId
                    } label: {
                        ZStack {
                            Circle()
                                .fill(model.color(for: colorId))
                                .frame(width: circleWidth, height: circleWidth)
                            if model.colorInt == colorId {
                                Image("small-tick")
                                    .resizable()
                                    .frame(width: 28, height: 28)
                                    .foregroundColor(ThemeColor.primaryInteractive02(for: theme.activeTheme).color)
                            }
                        }
                    }
                    .accessibilityLabel("\(L10n.color) \(colorId + 1)")
                }
            }
        }
        .frame(height: circleWidth * 2 + spacing)
    }

    private func getColumns(gridWidth: CGFloat) -> [GridItem] {
        var columns = [GridItem]()
        let sizing = circleWidth + spacing
        for _ in 0 ... Int(gridWidth / sizing) {
            columns.append(GridItem(.fixed(circleWidth)))
        }
        return columns
    }
}
