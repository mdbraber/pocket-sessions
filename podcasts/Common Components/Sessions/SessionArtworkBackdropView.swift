import SwiftUI

/// Fork: the blurred, artwork-derived backdrop for a session lineup — the same treatment the
/// playlist detail uses (`PlaylistBlurHeaderView`): the real podcast artwork of the session's
/// shows, blurred at radius 60 and dissolved into the list with a vertical gradient. Unlike the
/// playlist version it takes its items from a plain observable, so the UIKit host in
/// `UpNextViewController` can swap the browsed session's artwork in place without rebuilding the
/// hosting controller (which would flash the images).
final class SessionArtworkBackdropModel: ObservableObject {
    @Published var items: [PlaylistArtworkView.ImageItem] = []
}

struct SessionArtworkBackdropView: View {
    @EnvironmentObject var theme: Theme
    @ObservedObject var model: SessionArtworkBackdropModel

    var body: some View {
        BlurContent(items: model.items)
            // Equatable so unrelated theme/publish churn never reloads and flashes the images.
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
                PlaylistArtworkView(items: items)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .blur(radius: 60)
            }
        }
    }
}
