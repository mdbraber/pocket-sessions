import SwiftUI

/// Fork: the inbox action pill — the header's Play-as-Session button shape. The
/// per-page Inbox tabs (and their Add All / Mark All footers) are gone; the global
/// Inbox's Clear is the one surface still wearing it.
struct InboxPillButton: View {
    var icon: Image?
    let title: String
    let color: Color
    let background: Color
    let stroke: Color?
    let action: () -> Void

    /// A long press at the call site is invisible to VoiceOver, so any alternative it offers
    /// must also be exposed as a named accessibility action. Both or neither.
    var accessibilityActionName: String?
    var accessibilityAction: (() -> Void)?

    var body: some View {
        button
            .accessibilityLabel(title)
            .conditionalAccessibilityAction(named: accessibilityActionName, accessibilityAction)
    }

    private var button: some View {
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

private extension View {
    /// `accessibilityAction(named:)` has no optional form, so apply it only when the pill was
    /// actually given an alternative to expose.
    @ViewBuilder
    func conditionalAccessibilityAction(named name: String?, _ handler: (() -> Void)?) -> some View {
        if let name, let handler {
            accessibilityAction(named: name) { handler() }
        } else {
            self
        }
    }
}
