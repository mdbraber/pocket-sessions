import SwiftUI
import Combine
import PocketCastsUtils

/// Displays a fake set of tabs that allows the user to open the bookmarks view from the podcast list
struct PodcastDetailsTabView: View {
    @EnvironmentObject var theme: Theme
    @State private var selectedTab: Tab = .episodes

    weak var delegate: PodcastActionsDelegate?

    enum Tab {
        case episodes
        case session
        case playlists
        case bookmarks
        case youMightLike

        init(from viewMode: PodcastViewController.ViewMode) {
            switch viewMode {
            case .episodes:
                self = .episodes
            case .bookmarks:
                self = .bookmarks
            case .youMightLike:
                self = .youMightLike
            }
        }
    }

    @State private var sessionCount: Int = 0
    @State private var playlistCount: Int = 0

    /// Fork: the Playlists tab counts the LISTS this podcast appears in, not episodes — "this
    /// podcast is in 3 of your playlists".
    private var playlistsTabTitle: String {
        playlistCount > 0 ? "\(L10n.podcastPlaylistsTab) · \(playlistCount.localized())" : L10n.podcastPlaylistsTab
    }

    private var sessionTabTitle: String {
        sessionCount > 0 ? "\(L10n.playbackSessionTabSession) · \(sessionCount.localized())" : L10n.playbackSessionTabSession
    }

    /// Sessions exist only for subscribed podcasts — no Session tab on a page that has
    /// no session and could not create one.
    @State private var sessionTabAvailable = false

    private func refreshSessionCount() {
        guard let podcast = delegate?.displayedPodcast() else {
            sessionCount = 0
            sessionTabAvailable = false
            return
        }
        let session = SessionStore.shared.session(forPodcast: podcast.uuid)
        sessionTabAvailable = session != nil || podcast.isSubscribed()
        sessionCount = session.map { SessionFeederEngine.storeMemberUuids(for: $0).count } ?? 0
        refreshPlaylistCount(podcastUuid: podcast.uuid)
    }

    /// Counting reads every playlist's episodes (a smart playlist's membership is a query, not a
    /// table), so it runs off the main thread and publishes back.
    private func refreshPlaylistCount(podcastUuid: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let count = PodcastPlaylistRows.current(forPodcast: podcastUuid).count
            DispatchQueue.main.async { playlistCount = count }
        }
    }

    private func openPlaylists() {
        selectedTab = .playlists
        delegate?.showPodcastPlaylists()
    }

    private func openSession() {
        selectedTab = .session
        delegate?.showSession()
    }

    var body: some View {
        Group {
            if FeatureFlag.recommendations.enabled {
                ScrollView(.horizontal, showsIndicators: false) { tabs }
            } else {
                tabs
            }
        }
        .onReceive(delegate?.currentViewModePublisher ?? Just(.episodes).eraseToAnyPublisher()) { viewMode in
            // Fork: the Session tab rides the episodes view mode, distinguished by the list-mode flag.
            if viewMode == .episodes, delegate?.isShowingSession() == true {
                selectedTab = .session
            } else if viewMode == .episodes, delegate?.isShowingPodcastPlaylists() == true {
                selectedTab = .playlists
            } else {
                selectedTab = Tab(from: viewMode)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: SessionStore.changed)) { _ in
            refreshSessionCount()
        }
        .onReceive(NotificationCenter.default.publisher(for: Constants.Notifications.episodePlayStatusChanged)) { _ in
            refreshSessionCount()
        }
        .onReceive(NotificationCenter.default.publisher(for: Constants.Notifications.episodeArchiveStatusChanged)) { _ in
            refreshSessionCount()
        }
        // Bulk archive / mark played post manyEpisodesChanged; the sweep then posts
        // playlistChanged. Refresh on both so the tab count never lags the lineup.
        .onReceive(NotificationCenter.default.publisher(for: Constants.Notifications.manyEpisodesChanged)) { _ in
            refreshSessionCount()
        }
        .onReceive(NotificationCenter.default.publisher(for: Constants.Notifications.playlistChanged)) { _ in
            refreshSessionCount()
        }
        .onAppear(perform: refreshSessionCount)
    }

    @ViewBuilder var tabs: some View {
        HStack(spacing: 12) {
            Text(L10n.episodes)
                .buttonize {
                    selectedTab = .episodes
                    delegate?.showEpisodes()
                } customize: { config in
                    config.label
                        .applyStyle(theme: theme, highlighted: selectedTab == .episodes)
                        .applyButtonEffect(isPressed: config.isPressed)
                }

            if sessionTabAvailable {
                Text(sessionTabTitle)
                    .buttonize {
                        openSession()
                    } customize: { config in
                        config.label
                            .applyStyle(theme: theme, highlighted: selectedTab == .session)
                            .applyButtonEffect(isPressed: config.isPressed)
                    }
            }

            Text(playlistsTabTitle)
                .buttonize {
                    openPlaylists()
                } customize: { config in
                    config.label
                        .applyStyle(theme: theme, highlighted: selectedTab == .playlists)
                        .applyButtonEffect(isPressed: config.isPressed)
                }

            Text(L10n.bookmarks)
                .buttonize {
                    selectedTab = .bookmarks
                    delegate?.showBookmarks()
                } customize: { config in
                    config.label
                        .applyStyle(theme: theme, highlighted: selectedTab == .bookmarks)
                        .applyButtonEffect(isPressed: config.isPressed)
                }

            Text(L10n.youMightLike)
                .buttonize {
                    selectedTab = .youMightLike
                    delegate?.showYouMightLike()
                } customize: { config in
                    config.label
                        .applyStyle(theme: theme, highlighted: selectedTab == .youMightLike)
                        .applyButtonEffect(isPressed: config.isPressed)
                }

            Spacer()
        }
        .font(.subheadline.weight(.medium))
    }
}

// MARK: - View Extension

private extension View {
    func applyStyle(theme: Theme, highlighted: Bool = false) -> some View {
        self
            .contentShape(Rectangle())
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .foregroundColor(highlighted ? theme.primaryUi01 : theme.primaryText02)
            .background(tabBackground(theme: theme, highlighted: highlighted))
    }

    @ViewBuilder
    func tabBackground(theme: Theme, highlighted: Bool) -> some View {
        if highlighted {
            if LiquidGlass.isEnabled {
                // Render the selected tab as a proper pill to match the player controls.
                Capsule().fill(theme.primaryText01)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(theme.primaryText01)
            }
        }
    }
}

// MARK: - Previews

struct PodcastDetailsTabView_Previews: PreviewProvider {
    static var previews: some View {
        PodcastDetailsTabView()
            .setupDefaultEnvironment()
    }
}
