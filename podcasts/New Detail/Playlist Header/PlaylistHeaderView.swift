import SwiftUI
import PocketCastsUtils

struct PlaylistHeaderView: View {
    @EnvironmentObject var theme: Theme
    @ObservedObject var viewModel: PlaylistDetailViewModel

    @ScaledMetric(relativeTo: .largeTitle) private var iconSize = CGFloat(18)

    var description: String {
        let duration = viewModel.totalDuration()
        switch viewModel.playlistEpisodesCount {
        case let count where count > 1:
            if let duration {
                return L10n.playlistDetailDescription(count, duration)
            }
            return L10n.playlistEpisodesCount(count)
        case 1:
            if let duration {
                return L10n.playlistDetailDescriptionOneEpisode(duration)
            }
            return L10n.podcastEpisodeCountSingular
        default:
            return L10n.playlistEpisodesCount(viewModel.playlistEpisodesCount)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Spacer()
                    HeaderArtwork(items: viewModel.images)
                        .equatable()
                    Spacer()
                }

                VStack(spacing: 0.0) {
                    Text(viewModel.playlistName)
                        .font(style: .title2, weight: .bold)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(theme.primaryText01)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 10.0)
                    Text(viewModel.usesCustomOrderOverlay ? " " : description)
                        .font(style: .footnote, weight: .regular)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(theme.primaryText02)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 15.0)
                .padding(.bottom, 16.0)

                HStack(spacing: 8.0) {
                    Spacer()
                    actionButton(
                        type: viewModel.isManualPlaylist ? .addEpisodes : .smartRules,
                        color: theme.primaryText01,
                        image: Image(viewModel.isManualPlaylist ? "filter_new_episode" : "cs-sparkle-black"),
                        title: viewModel.isManualPlaylist ? L10n.playlistManualAddEpisodes : L10n.playlistSmartRulesTitle,
                        background: .clear,
                        stroke: theme.primaryUi05) { type in
                            viewModel.onButtonTapped(type)
                    }
                    actionButton(
                        type: .playAll,
                        color: viewModel.isSearching ? theme.primaryText01 : theme.primaryUi01,
                        image: Image("filter_play"),
                        title: FeatureFlag.playbackSessions.enabled ? L10n.playlistPlayAsSession : L10n.playlistsPlayAll,
                        background: viewModel.isSearching ? .clear : theme.primaryInteractive01,
                        stroke: viewModel.isSearching ? theme.primaryUi05 : nil) { type in
                            viewModel.onButtonTapped(type)
                    }
                    Spacer()
                }
                .padding(.bottom, 10.0)
                .animation(.easeInOut(duration: 0.2), value: viewModel.isSearching)

                if viewModel.usesCustomOrderOverlay, !viewModel.isSearching, !viewModel.playlist.newEpisodesAutoAdd {
                    // Same button-to-tabs gap as the podcast page (itemMargin 24;
                    // the buttons row already pads 10).
                    triageTabs
                        .padding(.top, 14.0)
                        .padding(.horizontal, 16.0)
                }

                Spacer()
            }
        }
        .background(.clear)
    }

    /// The artwork as equatable content: tab switches and count updates re-render the
    /// header, but must not rebuild (and flash) the artwork images.
    private struct HeaderArtwork: View, Equatable {
        let items: [PlaylistArtworkView.ImageItem]

        var body: some View {
            PlaylistArtworkView(items: items, cornerRadius: 8)
                .frame(width: 192.0, height: 192.0)
                .padding(.top, LiquidGlass.isEnabled ? 0 : 15.0)
                .shadow(color: .black.opacity(0.2), radius: 30, x: 0, y: 2)
        }
    }

    /// Fork: the New | Lineup selector, styled and placed like the podcast page's tabs.
    @ViewBuilder private var triageTabs: some View {
        HStack(spacing: 12) {
            Text(L10n.playlistInboxSectionHeader(viewModel.triageNewCount.localized()))
                .buttonize {
                    viewModel.selectTriageTab(.new)
                } customize: { config in
                    config.label
                        .applyTriageTabStyle(theme: theme, highlighted: viewModel.selectedTriageTab == .new)
                        .applyButtonEffect(isPressed: config.isPressed)
                }

            Text("\(L10n.playlistLineupSectionHeader) · \(viewModel.triageLineupCount.localized())")
                .buttonize {
                    viewModel.selectTriageTab(.lineup)
                } customize: { config in
                    config.label
                        .applyTriageTabStyle(theme: theme, highlighted: viewModel.selectedTriageTab == .lineup)
                        .applyButtonEffect(isPressed: config.isPressed)
                }

            Spacer()
        }
        .font(.subheadline.weight(.medium))
    }

    private func actionButton(
        type: PlaylistDetailViewModel.ButtonTag,
        color: Color,
        image: Image,
        title: String,
        background: Color,
        stroke: Color? = nil,
        action: @escaping (PlaylistDetailViewModel.ButtonTag) -> Void
    ) -> some View {
        Button {
            action(type)
        } label: {
            HStack(alignment: .center, spacing: 8.0) {
                image
                    .renderingMode(.template)
                    .resizable()
                    .foregroundStyle(color)
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                Text(title)
                    .font(style: .subheadline, weight: .medium)
                    .foregroundStyle(color)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16.0)
            .padding(.vertical, 10.0)
            .frame(minWidth: 152, minHeight: 40.0)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(stroke ?? background, lineWidth: 2)
            )
        }
    }
}


// MARK: - Fork: triage tab styling (mirrors the podcast page's tab style)

private extension View {
    func applyTriageTabStyle(theme: Theme, highlighted: Bool = false) -> some View {
        self
            .contentShape(Rectangle())
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .foregroundColor(highlighted ? theme.primaryUi01 : theme.primaryText02)
            .background(triageTabBackground(theme: theme, highlighted: highlighted))
    }

    @ViewBuilder
    func triageTabBackground(theme: Theme, highlighted: Bool) -> some View {
        if highlighted {
            if LiquidGlass.isEnabled {
                Capsule().fill(theme.primaryText01)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(theme.primaryText01)
            }
        }
    }
}
