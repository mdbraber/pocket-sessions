import Combine
import PocketCastsDataModel
import PocketCastsUtils
import SwiftUI

/// Fork: backs the "Sessions" tab on the episode card and the full-screen player —
/// the sessions whose lineup currently holds the episode, most specific feeder first.
class EpisodeSessionsViewModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let sessionUuid: String
        let storeUuid: String
        let name: String
        let artwork: [PlaylistArtworkView.ImageItem]
        let episodeCount: Int

        var id: String { sessionUuid }
    }

    @Published private(set) var rows: [Row] = []

    var episodeUuid: String? {
        didSet { reload() }
    }

    /// The host decides how to reach the playlist — the episode card dismisses itself
    /// first, the player routes through NavigationManager (which closes it).
    var onOpenSession: ((Row) -> Void)?

    /// Invokes the standard add-to-session flow for the episode; the host presents any
    /// "which session?" picker. The trailing "Add to Session" row only shows when set.
    var onAddToSession: (() -> Void)?

    private var cancellables = Set<AnyCancellable>()

    init(episodeUuid: String? = nil) {
        self.episodeUuid = episodeUuid

        // Lineup edits post playlistChanged, session create/delete posts SessionStore.changed,
        // and bulk archive/mark-played sweeps post manyEpisodesChanged.
        let signals = [SessionStore.changed, Constants.Notifications.playlistChanged, Constants.Notifications.manyEpisodesChanged]
        for name in signals {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.reload() }
                .store(in: &cancellables)
        }

        reload()
    }

    func reload() {
        guard let episodeUuid else {
            rows = []
            return
        }

        rows = SessionManager.shared.sessionsHolding(episodeUuids: [episodeUuid])
            .compactMap { session -> (row: Row, feederCount: Int)? in
                guard let store = SessionManager.shared.store(for: session), !store.playlistName.isEmpty else { return nil }
                let row = Row(sessionUuid: session.uuid,
                              storeUuid: store.uuid,
                              name: store.playlistName,
                              artwork: Self.artworkItems(for: session),
                              episodeCount: SessionFeederEngine.storeMemberUuids(for: session).count)
                return (row, SessionManager.shared.feederPodcastCount(session.feeder))
            }
            .sorted { $0.feederCount < $1.feederCount }
            .map(\.row)
    }

    /// The same tiles the Playlists tab shows for this session's store: the feeder's stable
    /// podcasts, falling back to the lineup's podcasts (4-up grid, or a single tile under 4).
    private static func artworkItems(for session: Session) -> [PlaylistArtworkView.ImageItem] {
        var uuids = session.artworkPodcastUuids
        if uuids.isEmpty {
            for episodeUuid in SessionFeederEngine.storeMemberUuids(for: session) {
                guard let podcastUuid = DataManager.sharedManager.findEpisode(uuid: episodeUuid)?.podcastUuid else { continue }
                if !uuids.contains(podcastUuid) { uuids.append(podcastUuid) }
                if uuids.count == 4 { break }
            }
        }
        var tiles = Array(uuids.prefix(4))
        if tiles.count < 4 { tiles = Array(tiles.prefix(1)) }
        return tiles.map { PlaylistArtworkView.ImageItem(id: $0, url: ImageManager.sharedManager.podcastUrl(imageSize: .grid, uuid: $0)) }
    }
}

struct EpisodeSessionsListView: View {
    /// Matches the surface it's embedded in: the themed episode card vs the dark player.
    enum Style {
        case episodeCard, player
    }

    @EnvironmentObject var theme: Theme
    @ObservedObject var viewModel: EpisodeSessionsViewModel
    let style: Style

    private var primaryColor: Color {
        style == .player ? theme.playerContrast01 : theme.primaryText01
    }

    private var secondaryColor: Color {
        style == .player ? theme.playerContrast02 : theme.primaryText02
    }

    private var dividerColor: Color {
        style == .player ? theme.playerContrast05 : theme.primaryUi05
    }

    private var accentColor: Color {
        style == .player ? theme.playerHighlight01 : theme.primaryInteractive01
    }

    /// The combined children read as "name, <bare number>", so spell the count out instead.
    private func accessibilityLabel(for row: EpisodeSessionsViewModel.Row) -> String {
        let count = row.episodeCount == 1 ? L10n.podcastEpisodeCountSingular : L10n.episodeCountPluralFormat(row.episodeCount.localized())
        return "\(row.name), \(count)"
    }

    var body: some View {
        if viewModel.rows.isEmpty {
            VStack {
                Spacer()
                Text(L10n.episodeSessionsNone)
                    .font(.subheadline)
                    .foregroundColor(secondaryColor)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                if viewModel.onAddToSession != nil {
                    addToSessionRow
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.rows) { row in
                        Button {
                            viewModel.onOpenSession?(row)
                        } label: {
                            HStack(spacing: 12) {
                                PlaylistArtworkView(items: row.artwork)
                                    .frame(width: 48, height: 48)
                                    .accessibilityHidden(true)

                                Text(row.name)
                                    .font(.body.weight(.medium))
                                    .foregroundColor(primaryColor)
                                    .lineLimit(1)

                                Spacer()

                                Text(row.episodeCount.localized())
                                    .font(.subheadline)
                                    .foregroundColor(secondaryColor)

                                Image(systemName: "chevron.forward")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundColor(secondaryColor)
                                    .accessibilityHidden(true)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(accessibilityLabel(for: row))

                        if row.id != viewModel.rows.last?.id {
                            Rectangle()
                                .fill(dividerColor)
                                .frame(height: 0.5)
                                .padding(.leading, 76)
                        }
                    }

                    if viewModel.onAddToSession != nil {
                        Rectangle()
                            .fill(dividerColor)
                            .frame(height: 0.5)
                            .padding(.leading, 76)

                        addToSessionRow
                    }
                }
            }
        }
    }

    /// The trailing "Add to Session" row — also shown when the episode is already in
    /// sessions, so it can be added to another one.
    private var addToSessionRow: some View {
        Button {
            viewModel.onAddToSession?()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 24))
                    .foregroundColor(accentColor)
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)

                Text(L10n.playlistAddToLineup)
                    .font(.body.weight(.medium))
                    .foregroundColor(accentColor)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.playlistAddToLineup)
    }
}
