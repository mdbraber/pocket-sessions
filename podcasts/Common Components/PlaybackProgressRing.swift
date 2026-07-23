import UIKit
import PocketCastsUtils

/// Fork: the shared played-progress ring — the exact drawing MainEpisodeActionView uses for the
/// play/pause states, extracted so the session list's play buttons render an IDENTICAL ring.
/// Played arc is faint (tint @ 0.3); the remaining (unplayed) arc is solid tint. Full circle from
/// 12 o'clock.
enum PlaybackProgressRing {
    static let circleStrokeWidth: CGFloat = 2
    static let circleRadius: CGFloat = 14
    static let startingAngle: CGFloat = -90
    static let endingAngle: CGFloat = 270

    static func playedAngle(forProgress progress: Double) -> CGFloat {
        if progress > 1 { return 360 + startingAngle }
        if progress > 0 { return CGFloat(360 * progress) + startingAngle }
        return startingAngle
    }

    static func draw(in context: CGContext, center: CGPoint, radius: CGFloat, playedAngle: CGFloat, tint: UIColor) {
        context.setLineWidth(circleStrokeWidth)
        // Played arc (faint).
        context.setStrokeColor(tint.withAlphaComponent(0.3).cgColor)
        context.addArc(center: center, radius: radius, startAngle: startingAngle.degreesToRadians, endAngle: playedAngle.degreesToRadians, clockwise: false)
        context.drawPath(using: .stroke)
        // Remaining arc (solid) — only until the episode is finished.
        if playedAngle < 270 {
            context.setStrokeColor(tint.cgColor)
            context.addArc(center: center, radius: radius, startAngle: playedAngle.degreesToRadians, endAngle: endingAngle.degreesToRadians, clockwise: false)
            context.drawPath(using: .stroke)
        }
    }
}

/// A standalone view that draws the shared played-progress ring — overlaid on the session list's
/// play buttons so their ring matches the details rows exactly.
final class PlaybackProgressRingView: UIView {
    var progress: Double = 0 { didSet { if progress != oldValue { setNeedsDisplay() } } }
    var ringTint: UIColor = .white { didSet { if ringTint != oldValue { setNeedsDisplay() } } }

    override init(frame: CGRect) { super.init(frame: frame); commonInit() }
    required init?(coder: NSCoder) { super.init(coder: coder); commonInit() }
    private func commonInit() {
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    override func draw(_ rect: CGRect) {
        guard progress > 0, let context = UIGraphicsGetCurrentContext() else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(PlaybackProgressRing.circleRadius, min(bounds.width, bounds.height) / 2 - 1)
        PlaybackProgressRing.draw(in: context, center: center, radius: radius,
                                  playedAngle: PlaybackProgressRing.playedAngle(forProgress: progress), tint: ringTint)
    }
}
