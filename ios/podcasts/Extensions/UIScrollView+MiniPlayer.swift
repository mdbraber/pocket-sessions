import Foundation

extension UIScrollView {
    /// Fork: under Liquid Glass the now-playing pill is a `UITabAccessory` meant to ride the bottom
    /// safe area, but on some screens it overhangs the scroll view and covers the last row — measure
    /// how far the pill dips past the safe area into the scroll view so the last row can clear it.
    /// Returns 0 when not under Liquid Glass, when there is no pill, or when the safe area already
    /// covers it (so it never double-pads).
    func miniPlayerOverlapClearance() -> CGFloat {
        guard LiquidGlass.isEnabled,
              let pill = UIApplication.shared.appDelegate()?.miniPlayer()?.view, pill.window != nil,
              let container = superview else { return 0 }
        let pillFrame = container.convert(pill.bounds, from: pill)
        let overlap = frame.maxY - pillFrame.minY - safeAreaInsets.bottom
        guard overlap > 0 else { return 0 }
        // Clear the pill fully (plus a little breathing room) so the last row isn't tucked under it.
        // Bound by the pill's own height + margin so a stale or cross-hierarchy frame can't report a
        // runaway overlap and let the list scroll far past the pill. (The old cap at the smaller
        // `miniPlayerOffset` left the last row slightly obscured when the pill is taller than that.)
        let margin: CGFloat = 8
        return min(overlap, pillFrame.height) + margin
    }

    func applyInsetForMiniPlayer(additionalBottomInset: CGFloat = 0) {
        guard !LiquidGlass.isEnabled else {return }

        let existingInset = contentInset
        contentInset = UIEdgeInsets(top: existingInset.top, left: existingInset.left, bottom: existingInset.bottom + Constants.Values.miniPlayerOffset + additionalBottomInset, right: existingInset.right)

        let existingScrollIndicatorInset = verticalScrollIndicatorInsets
        verticalScrollIndicatorInsets = UIEdgeInsets(top: existingScrollIndicatorInset.top, left: existingScrollIndicatorInset.left, bottom: existingScrollIndicatorInset.bottom + Constants.Values.miniPlayerOffset + additionalBottomInset, right: existingScrollIndicatorInset.right)
    }

    func updateContentInset(multiSelectEnabled: Bool, ignoreMiniPlayer: Bool = false, extraBottom: CGFloat = 0) {
        if LiquidGlass.isEnabled {
            let multiSelectFooterOffset: CGFloat = multiSelectEnabled ? 60 : 0
            // The tab-accessory safe area doesn't always cover the pill on every screen — top up
            // the measured overhang so the last row clears it.
            let pillClearance = ignoreMiniPlayer ? 0 : miniPlayerOverlapClearance()
            contentInset.bottom = multiSelectFooterOffset + pillClearance + extraBottom
            verticalScrollIndicatorInsets.bottom = multiSelectFooterOffset + pillClearance + extraBottom
            return
        }

        let existingInset = contentInset
        let multiSelectFooterOffset: CGFloat = multiSelectEnabled ? 80 : 0
        let miniPlayerOffset: CGFloat = ignoreMiniPlayer ? 0 : Constants.effectiveMiniPlayerOffset
        contentInset = UIEdgeInsets(top: existingInset.top, left: existingInset.left, bottom: miniPlayerOffset + multiSelectFooterOffset + extraBottom, right: existingInset.right)

        let existingScrollIndicatorInset = verticalScrollIndicatorInsets
        verticalScrollIndicatorInsets = UIEdgeInsets(top: existingScrollIndicatorInset.top, left: existingScrollIndicatorInset.left, bottom: miniPlayerOffset + multiSelectFooterOffset + extraBottom, right: existingScrollIndicatorInset.right)
    }
}
