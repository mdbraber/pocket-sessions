import SwiftUI

/// Fork: the Inbox tab's closing actions — two pills in exactly the header's
/// Play-as-Session button style: accent Add All, outlined Mark All as Seen. Side by
/// side when the row is wide enough, stacking on narrow screens.
struct InboxActionsFooterView: View {
    @EnvironmentObject var theme: Theme

    let addAll: () -> Void
    let markAllSeen: () -> Void

    static let height: CGFloat = 124

    var body: some View {
        let addAllPill = InboxPillButton(
            icon: Image(systemName: "rectangle.stack.badge.plus"),
            title: L10n.playlistAddAllToLineup,
            color: theme.primaryUi01,
            background: theme.primaryInteractive01,
            stroke: nil,
            action: addAll
        )
        let markSeenPill = InboxPillButton(
            icon: Image(systemName: "eye.slash"),
            title: L10n.inboxClearKeepAll,
            color: theme.primaryText01,
            background: .clear,
            stroke: theme.primaryUi05,
            action: markAllSeen
        )
        // Prefer a single side-by-side row; fall back to stacked when it won't fit.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                addAllPill.frame(maxWidth: .infinity)
                markSeenPill.frame(maxWidth: .infinity)
            }
            VStack(spacing: 12) {
                addAllPill
                markSeenPill
            }
        }
        .padding(16)
    }
}

/// The inbox action pill — the header's Play-as-Session button shape, shared by
/// every inbox surface (podcast/playlist footers and the global Inbox's Clear).
struct InboxPillButton: View {
    var icon: Image?
    let title: String
    let color: Color
    let background: Color
    let stroke: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 8.0) {
                if let icon {
                    icon
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(color)
                        .frame(width: 20, height: 20)
                }
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
