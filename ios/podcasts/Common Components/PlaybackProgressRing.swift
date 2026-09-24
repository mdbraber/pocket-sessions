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

    /// The play triangle — the EXACT path MainEpisodeActionView draws (9×10 at scale 1), including its
    /// optical-centering nudge, so the session list's glyph is pixel-identical to the details rows.
    static func drawPlayTriangle(in context: CGContext, center: CGPoint, tint: UIColor, scale: CGFloat) {
        let path = CGMutablePath()
        let height = 10 * scale
        let width = 9 * scale
        let startingY = center.y - (height / 2.0)
        // Triangles aren't weighted to be visually centered, so nudge right to compensate.
        let startingX = center.x - (width / 2.0) + (width / 6.0)
        path.move(to: CGPoint(x: startingX, y: startingY))
        path.addLine(to: CGPoint(x: startingX + width, y: startingY + (height / 2.0)))
        path.addLine(to: CGPoint(x: startingX, y: startingY + height))
        path.addLine(to: CGPoint(x: startingX, y: startingY))
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(tint.cgColor)
        context.fillPath()
    }

    /// The two pause bars — the EXACT geometry MainEpisodeActionView draws (3×10 bars, one bar-width gap).
    static func drawPauseBars(in context: CGContext, center: CGPoint, tint: UIColor, scale: CGFloat) {
        let width = 3 * scale
        let height = 10 * scale
        let gap = width
        let startAt = center.x - width - (gap / 2.0)
        let nextAt = startAt + width + gap
        let y = center.y - (height / 2.0)
        for barX in [startAt, nextAt] {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: barX, y: y))
            path.addLine(to: CGPoint(x: barX + width, y: y))
            path.addLine(to: CGPoint(x: barX + width, y: y + height))
            path.addLine(to: CGPoint(x: barX, y: y + height))
            path.addLine(to: CGPoint(x: barX, y: y))
            path.closeSubpath()
            context.addPath(path)
            context.setFillColor(tint.cgColor)
            context.fillPath()
        }
    }
}

/// A standalone view that draws the shared played-progress ring — overlaid on the session list's
/// play buttons so their ring matches the details rows exactly.
final class PlaybackProgressRingView: UIView {
    var progress: Double = 0 { didSet { if progress != oldValue { setNeedsDisplay() } } }
    var ringTint: UIColor = .white { didSet { if ringTint != oldValue { setNeedsDisplay() } } }
    /// When true draws the pause bars, otherwise the play triangle — same glyphs as MainEpisodeActionView.
    var isPlaying: Bool = false { didSet { if isPlaying != oldValue { setNeedsDisplay() } } }
    /// Draw the play/pause glyph in the centre (the session list opts in; a bare ring stays glyph-less).
    var drawsGlyph: Bool = false { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) { super.init(frame: frame); commonInit() }
    required init?(coder: NSCoder) { super.init(coder: coder); commonInit() }
    private func commonInit() {
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    override func draw(_ rect: CGRect) {
        // Always draw — at 0 progress this is a full SOLID ring, exactly like MainEpisodeActionView.
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(PlaybackProgressRing.circleRadius, min(bounds.width, bounds.height) / 2 - 1)
        PlaybackProgressRing.draw(in: context, center: center, radius: radius,
                                  playedAngle: PlaybackProgressRing.playedAngle(forProgress: progress), tint: ringTint)
        guard drawsGlyph else { return }
        // Scale the glyph off the ring radius so it always matches whatever ring we actually drew.
        let scale = radius / PlaybackProgressRing.circleRadius
        if isPlaying {
            PlaybackProgressRing.drawPauseBars(in: context, center: center, tint: ringTint, scale: scale)
        } else {
            PlaybackProgressRing.drawPlayTriangle(in: context, center: center, tint: ringTint, scale: scale)
        }
    }
}
