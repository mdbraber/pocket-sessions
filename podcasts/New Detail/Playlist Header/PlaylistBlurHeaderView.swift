import SwiftUI

struct PlaylistBlurHeaderView: View {
    @EnvironmentObject var theme: Theme
    @ObservedObject var viewModel: PlaylistDetailViewModel

    var body: some View {
        // Equatable content: unrelated view-model publishes (tab switches, counts)
        // must not rebuild the blurred images — that reloads them and flashes.
        BlurContent(items: viewModel.images)
            .equatable()
            // Dissolve into the list background instead of ending on a hard edge.
            .mask(
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.6),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            )
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
