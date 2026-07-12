import SwiftUI
import PocketCastsUtils

struct PlaylistHeaderView: View {
    @EnvironmentObject var theme: Theme
    @ObservedObject var viewModel: PlaylistDetailViewModel

    @ScaledMetric(relativeTo: .largeTitle) private var iconSize = CGFloat(18)

    // The podcast header's exact spacing metrics (collapsed state), so switching
    // between a podcast page and a playlist page keeps everything pinned in place.
    @ScaledMetric(relativeTo: .body) private var titleBottomMargin = 16
    @ScaledMetric(relativeTo: .largeTitle) private var itemMargin = 24

    private var topMarginForTitle: CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .title2)
        let adjustment = font.lineHeight - font.capHeight + font.descender
        return 26 - adjustment
    }

    private var bottomMarginAdjustmentForTitle: CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .title2)
        return -font.descender
    }

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
                Spacer().frame(height: titleBottomMargin)
                HStack(spacing: 0) {
                    Spacer()
                    HeaderArtwork(items: viewModel.images)
                        .equatable()
                    Spacer()
                }
                Spacer().frame(height: topMarginForTitle)

                // The counts line lives under the search bar, so the title stands
                // alone. Font and margins mirror the podcast header's title exactly.
                Text(viewModel.playlistName)
                    .font(.title2).bold()
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(theme.primaryText01)
                    .multilineTextAlignment(.center)
                Spacer().frame(height: titleBottomMargin - bottomMarginAdjustmentForTitle)
                // (The podcast page's stars row sits here, collapsed to zero height.)
                Spacer().frame(height: titleBottomMargin)

                // Fork: podcast-page action rows — bare icon buttons (smart rules /
                // Playlist Folder / playlist options), then the Play pill beneath.
                HStack(spacing: 0) {
                    Spacer()
                    iconButton(
                        type: viewModel.isManualPlaylist ? .addEpisodes : .smartRules,
                        image: Image(viewModel.isManualPlaylist ? "filter_new_episode" : "cs-sparkle-black"),
                        title: viewModel.isManualPlaylist ? L10n.playlistManualAddEpisodes : L10n.playlistSmartRulesTitle)
                    iconButton(
                        type: .playlistFolder,
                        image: Image(PlaylistFolderManager.shared.folderUuid(forPlaylist: viewModel.playlist.uuid) == nil ? "folder-empty" : "folder-check"),
                        title: L10n.folder)
                    iconButton(
                        type: .playlistSettings,
                        image: Image("podcast-settings"),
                        title: L10n.playlistOptions)
                    Spacer()
                }
                Spacer().frame(height: 12)

                HStack(spacing: 0) {
                    Spacer()
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
                .animation(.easeInOut(duration: 0.2), value: viewModel.isSearching)
                Spacer().frame(height: itemMargin)

                if viewModel.usesTriageTabs, !viewModel.isSearching {
                    triageTabs
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
                .frame(width: PodcastHeaderView.Constants.smallImageSize, height: PodcastHeaderView.Constants.smallImageSize)
                .shadow(color: .black.opacity(0.2), radius: 30, x: 0, y: 2)
        }
    }

    /// Fork: the Inbox | Session | Episodes selector, exactly the podcast page's tab
    /// strip. Inbox and Episodes (the feeder's views) need a feeder; Session always
    /// shows. Inbox and Session carry counts; Episodes doesn't.
    @ViewBuilder private var triageTabs: some View {
        let hasInboxTab = viewModel.hasInboxTab
        HStack(spacing: 12) {
            if hasInboxTab {
                Text(viewModel.triageNewCount > 0 ? "\(L10n.inboxTitle) · \(viewModel.triageNewCount.localized())" : L10n.inboxTitle)
                    .buttonize {
                        viewModel.selectTriageTab(.new)
                    } customize: { config in
                        config.label
                            .applyTriageTabStyle(theme: theme, highlighted: viewModel.selectedTriageTab == .new)
                            .applyButtonEffect(isPressed: config.isPressed)
                    }
            }

            Text("\(L10n.playbackSessionTabSession) · \(viewModel.triageLineupCount.localized())")
                .buttonize {
                    viewModel.selectTriageTab(.lineup)
                } customize: { config in
                    config.label
                        .applyTriageTabStyle(theme: theme, highlighted: viewModel.selectedTriageTab == .lineup || (!hasInboxTab && viewModel.selectedTriageTab == .new))
                        .applyButtonEffect(isPressed: config.isPressed)
                }

            if hasInboxTab {
                Text(L10n.episodes)
                    .buttonize {
                        viewModel.selectTriageTab(.browse)
                    } customize: { config in
                        config.label
                            .applyTriageTabStyle(theme: theme, highlighted: viewModel.selectedTriageTab == .browse)
                            .applyButtonEffect(isPressed: config.isPressed)
                    }
            }

            Spacer()
        }
        .font(.subheadline.weight(.medium))
    }

    /// A bare padded template icon, exactly the podcast header's action-button style.
    private func iconButton(
        type: PlaylistDetailViewModel.ButtonTag,
        image: Image,
        title: String
    ) -> some View {
        Button {
            viewModel.onButtonTapped(type)
        } label: {
            image
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
                .padding(8)
                .foregroundStyle(theme.primaryIcon03)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
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
                    .frame(width: 20, height: 20)
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
