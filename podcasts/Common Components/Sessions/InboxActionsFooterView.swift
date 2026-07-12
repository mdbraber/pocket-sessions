import SwiftUI

/// Fork: the Inbox tab's closing actions — two pills in exactly the header's
/// Play-as-Session button style: accent Add All, outlined Mark All as Seen.
struct InboxActionsFooterView: View {
    @EnvironmentObject var theme: Theme

    let addAll: () -> Void
    let markAllSeen: () -> Void

    static let height: CGFloat = 124

    var body: some View {
        VStack(spacing: 12) {
            pill(
                icon: Image(systemName: "rectangle.stack.badge.plus"),
                title: L10n.playlistAddAllToLineup,
                color: theme.primaryUi01,
                background: theme.primaryInteractive01,
                stroke: nil,
                action: addAll
            )
            pill(
                icon: Image(systemName: "eye.slash"),
                title: L10n.inboxClearKeepAll,
                color: theme.primaryText01,
                background: .clear,
                stroke: theme.primaryUi05,
                action: markAllSeen
            )
        }
        .padding(16)
    }

    private func pill(icon: Image, title: String, color: Color, background: Color, stroke: Color?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 8.0) {
                icon
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(color)
                    .frame(width: 20, height: 20)
                Text(title)
                    .font(style: .subheadline, weight: .medium)
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16.0)
            .padding(.vertical, 10.0)
            .frame(minWidth: 152, minHeight: 40.0)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(background)
            )
            .overlay {
                if let stroke {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(stroke, lineWidth: 1)
                }
            }
        }
    }
}
