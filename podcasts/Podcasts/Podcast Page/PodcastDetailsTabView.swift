import SwiftUI
import Combine
import PocketCastsUtils

/// Displays a fake set of tabs that allows the user to open the bookmarks view from the podcast list
struct PodcastDetailsTabView: View {
    @EnvironmentObject var theme: Theme
    @State private var selectedTab: Tab = .episodes

    weak var delegate: PodcastActionsDelegate?

    enum Tab {
        case inbox
        case episodes
        case session
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
    @State private var inboxCount: Int = 0
    /// Fork: auto-add sessions absorb their offers, so there is nothing to triage —
    /// the Inbox tab hides, exactly like the playlist page.
    @State private var inboxHidden = false

    private var sessionTabTitle: String {
        sessionCount > 0 ? "\(L10n.playbackSessionTabSession) · \(sessionCount.localized())" : L10n.playbackSessionTabSession
    }

    private var inboxTabTitle: String {
        inboxCount > 0 ? "\(L10n.inboxTitle) · \(inboxCount.localized())" : L10n.inboxTitle
    }

    private func refreshSessionCount() {
        guard let podcast = delegate?.displayedPodcast() else {
            sessionCount = 0
            inboxCount = 0
            inboxHidden = false
            return
        }
        let session = SessionStore.shared.session(forPodcast: podcast.uuid)
        sessionCount = session.map { SessionFeederEngine.storeMemberUuids(for: $0).count } ?? 0
        let feeder = session ?? Session(uuid: "podcast-inbox-preview", storePlaylistUuid: nil, feeder: .podcast(uuid: podcast.uuid))
        inboxCount = SessionFeederEngine.displayEpisodes(for: feeder, showArchived: false, showPlayed: false, showSeen: false).count
        inboxHidden = session?.autoAdd == true
        if inboxHidden, selectedTab == .inbox {
            openSession()
        }
    }

    private func openSession() {
        selectedTab = .session
        delegate?.showSession()
    }

    private func openInbox() {
        selectedTab = .inbox
        delegate?.showInbox()
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
            // Fork: the Inbox and Session tabs ride the episodes view mode,
            // distinguished by the list-mode flags.
            if viewMode == .episodes, delegate?.isShowingInbox() == true {
                selectedTab = .inbox
            } else if viewMode == .episodes, delegate?.isShowingSession() == true {
                selectedTab = .session
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
        .onAppear(perform: refreshSessionCount)
    }

    @ViewBuilder var tabs: some View {
        HStack(spacing: 12) {
            if !inboxHidden {
                Text(inboxTabTitle)
                    .buttonize {
                        openInbox()
                    } customize: { config in
                        config.label
                            .applyStyle(theme: theme, highlighted: selectedTab == .inbox)
                            .applyButtonEffect(isPressed: config.isPressed)
                    }
            }

            Text(sessionTabTitle)
                .buttonize {
                    openSession()
                } customize: { config in
                    config.label
                        .applyStyle(theme: theme, highlighted: selectedTab == .session)
                        .applyButtonEffect(isPressed: config.isPressed)
                }

            Text(L10n.episodes)
                .buttonize {
                    selectedTab = .episodes
                    delegate?.showEpisodes()
                } customize: { config in
                    config.label
                        .applyStyle(theme: theme, highlighted: selectedTab == .episodes)
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
