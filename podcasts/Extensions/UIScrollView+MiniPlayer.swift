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
        // Never inset by more than the pill's own height (capped at the standard offset): a stale or
        // cross-hierarchy frame can otherwise report a huge overlap and let the list scroll far past
        // the pill instead of stopping just above it.
        return min(max(0, overlap), min(pillFrame.height, Constants.Values.miniPlayerOffset))
    }

    func applyInsetForMiniPlayer(additionalBottomInset: CGFloat = 0) {
        guard !LiquidGlass.isEnabled else {return }

        let existingInset = contentInset
        contentInset = UIEdgeInsets(top: existingInset.top, left: existingInset.left, bottom: existingInset.bottom + Constants.Values.miniPlayerOffset + additionalBottomInset, right: existingInset.right)

        let existingScrollIndicatorInset = verticalScrollIndicatorInsets
        verticalScrollIndicatorInsets = UIEdgeInsets(top: existingScrollIndicatorInset.top, left: existingScrollIndicatorInset.left, bottom: existingScrollIndicatorInset.bottom + Constants.Values.miniPlayerOffset + additionalBottomInset, right: existingScrollIndicatorInset.right)
    }

    func updateContentInset(multiSelectEnabled: Bool, ignoreMiniPlayer: Bool = false) {
        if LiquidGlass.isEnabled {
            let multiSelectFooterOffset: CGFloat = multiSelectEnabled ? 60 : 0
            // The tab-accessory safe area doesn't always cover the pill on every screen — top up
            // the measured overhang so the last row clears it.
            let pillClearance = ignoreMiniPlayer ? 0 : miniPlayerOverlapClearance()
            contentInset.bottom = multiSelectFooterOffset + pillClearance
            verticalScrollIndicatorInsets.bottom = multiSelectFooterOffset + pillClearance
            return
        }

        let existingInset = contentInset
        let multiSelectFooterOffset: CGFloat = multiSelectEnabled ? 80 : 0
        let miniPlayerOffset: CGFloat = ignoreMiniPlayer ? 0 : Constants.effectiveMiniPlayerOffset
        contentInset = UIEdgeInsets(top: existingInset.top, left: existingInset.left, bottom: miniPlayerOffset + multiSelectFooterOffset, right: existingInset.right)

        let existingScrollIndicatorInset = verticalScrollIndicatorInsets
        verticalScrollIndicatorInsets = UIEdgeInsets(top: existingScrollIndicatorInset.top, left: existingScrollIndicatorInset.left, bottom: miniPlayerOffset + multiSelectFooterOffset, right: existingScrollIndicatorInset.right)
    }
}
