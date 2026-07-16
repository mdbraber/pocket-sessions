import SwiftUI
import PocketCastsDataModel

/// Fork: one entry in the Playlists grid — either a folder tile or a playlist tile —
/// so both kinds share a single ordered list and drag order can interleave them.
enum PlaylistGridItem: Identifiable {
    case folder(PlaylistFolder)
    case playlist(EpisodeFilter)

    var id: String {
        switch self {
        case .folder(let folder): return "playlist-folder-\(folder.uuid)"
        case .playlist(let playlist): return playlist.uuid
        }
    }

    var sortPosition: Int32 {
        switch self {
        case .folder(let folder): return folder.sortPosition
        case .playlist(let playlist): return playlist.sortPosition
        }
    }
}

/// Fork: the Playlists overview's grid layouts — the podcast page's Large/Small Grid,
/// with folder tiles (colored, 2×2 artwork) and playlist tiles (artwork composite),
/// names captioned beneath.
struct PlaylistsGridView: View {
    @EnvironmentObject var theme: Theme

    let columns: Int
    let onFolderTapped: (PlaylistFolder) -> Void
    let onPlaylistTapped: (EpisodeFilter) -> Void

    /// Fork: folders and playlists share one ordered list so a folder can sit anywhere
    /// among the playlists (drag order), not pinned to the top.
    let items: [PlaylistGridItem]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: columns), spacing: 16) {
                ForEach(items) { item in
                    switch item {
                    case .folder(let folder):
                        Button {
                            onFolderTapped(folder)
                        } label: {
                            VStack(spacing: 6) {
                                PlaylistFolderPreviewTile(color: folder.color,
                                                          podcastUuids: PlaylistFolderManager.shared.previewPodcastUuids(inFolder: folder.uuid))
                                caption(folder.name)
                            }
                        }
                        .buttonStyle(.plain)
                    case .playlist(let playlist):
                        Button {
                            onPlaylistTapped(playlist)
                        } label: {
                            VStack(spacing: 6) {
                                PlaylistGridTile(playlist: playlist)
                                caption(playlist.playlistName)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

/// A playlist's grid tile: the 2×2 composite of its podcast rule (single artwork when
/// the rule names one podcast; a placeholder when it names none).
struct PlaylistGridTile: View {
    let playlist: EpisodeFilter

    private var podcastUuids: [String] {
        playlist.podcastUuids.components(separatedBy: ",").filter { !$0.isEmpty && $0 != "none" }
    }

    var body: some View {
        GeometryReader { proxy in
            let uuids = podcastUuids
            if uuids.count >= 2 {
                let imageSize = (proxy.size.width - 4) / 2
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        slot(uuids[safe: 0], size: imageSize)
                        slot(uuids[safe: 1], size: imageSize)
                    }
                    HStack(spacing: 4) {
                        slot(uuids[safe: 2], size: imageSize)
                        slot(uuids[safe: 3], size: imageSize)
                    }
                }
            } else if let first = uuids.first {
                PodcastImageViewWrapper(podcastUUID: first, size: .grid)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .cornerRadius(8)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.1))
                    Image("filter_list")
                        .renderingMode(.template)
                        .foregroundColor(.secondary)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .shadow(radius: 2, x: 0, y: 1)
    }

    @ViewBuilder private func slot(_ uuid: String?, size: CGFloat) -> some View {
        if let uuid {
            PodcastImageViewWrapper(podcastUUID: uuid, size: .list)
                .frame(width: size, height: size)
                .cornerRadius(4)
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.black.opacity(0.1))
                .frame(width: size, height: size)
        }
    }
}
