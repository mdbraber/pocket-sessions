import SwiftUI
import PocketCastsDataModel

/// Fork: the session's dismissed episodes — the recoverable "no" pile. Restoring an
/// episode deletes its dismissal so the feeder offers it again.
struct DismissedEpisodesView: View {
    @EnvironmentObject var theme: Theme

    let sessionUuid: String
    let onDismiss: () -> Void

    @State private var episodes: [Episode] = []

    var body: some View {
        NavigationView {
            Group {
                if episodes.isEmpty {
                    Text(L10n.sessionDismissedEmpty)
                        .font(.subheadline)
                        .foregroundColor(AppTheme.color(for: .primaryText02, theme: theme))
                        .padding()
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ThemedDivider()
                            ForEach(episodes, id: \.uuid) { episode in
                                row(episode)
                                ThemedDivider()
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.sessionDismissedTitle)
            .navigationBarTitleDisplayMode(.inline)
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
            .onAppear(perform: reload)
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func row(_ episode: Episode) -> some View {
        HStack(spacing: 12) {
            PodcastImageViewWrapper(podcastUUID: episode.podcastUuid, size: .list)
                .frame(width: 48, height: 48)
                .cornerRadius(4)
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.displayableTitle())
                    .textStyle(PrimaryText())
                    .font(.callout)
                    .lineLimit(2)
                Text(episode.parentPodcast()?.title ?? "")
                    .textStyle(SecondaryText())
                    .font(.footnote)
                    .lineLimit(1)
            }
            Spacer()
            Button(L10n.sessionDismissedRestore) {
                SessionStore.shared.setDismissed(false, episodeUuid: episode.uuid, sessionUuid: sessionUuid)
                reload()
            }
            .font(.callout.weight(.semibold))
            .foregroundColor(ThemeColor.primaryInteractive01(for: theme.activeTheme).color)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func reload() {
        episodes = SessionStore.shared.dismissedUuids(sessionUuid: sessionUuid)
            .compactMap { DataManager.sharedManager.findEpisode(uuid: $0) }
            .sorted { ($0.publishedDate ?? .distantPast) > ($1.publishedDate ?? .distantPast) }
    }
}
