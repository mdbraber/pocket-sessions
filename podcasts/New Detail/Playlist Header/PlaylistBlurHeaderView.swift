import SwiftUI

struct PlaylistBlurHeaderView: View {
    @EnvironmentObject var theme: Theme
    @ObservedObject var viewModel: PlaylistDetailViewModel

    var body: some View {
        // Equatable content: unrelated view-model publishes (tab switches, counts)
        // must not rebuild the blurred images — that reloads them and flashes.
        BlurContent(items: viewModel.images)
            .equatable()
            .accessibilityHidden(true)
    }

    private struct BlurContent: View, Equatable {
        let items: [PlaylistArtworkView.ImageItem]

        var body: some View {
            GeometryReader { proxy in
                HStack {
                    Spacer()
                    PlaylistArtworkView(items: items)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .blur(radius: 60)
                    Spacer()
                }
            }
        }
    }
}
