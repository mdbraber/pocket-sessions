import UIKit

/// Fork: the classic three-bar "now sounding" indicator. Bars bounce while
/// playback runs and freeze in place when paused — the view watches playback
/// notifications itself, so hosts only decide visibility.
class NowPlayingIndicatorView: UIView {
    private var bars: [CALayer] = []

    private static let barWidth: CGFloat = 3
    private static let barGap: CGFloat = 2.5
    private static let barMaxHeight: CGFloat = 12

    var color: UIColor = ThemeColor.primaryInteractive01() {
        didSet {
            bars.forEach { $0.backgroundColor = color.cgColor }
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: Self.barWidth * 3 + Self.barGap * 2, height: Self.barMaxHeight)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isUserInteractionEnabled = false
        for index in 0..<3 {
            let bar = CALayer()
            bar.backgroundColor = color.cgColor
            bar.anchorPoint = CGPoint(x: 0.5, y: 1)
            bar.frame = CGRect(
                x: CGFloat(index) * (Self.barWidth + Self.barGap),
                y: 0,
                width: Self.barWidth,
                height: Self.barMaxHeight
            )
            bar.position = CGPoint(x: bar.frame.midX, y: Self.barMaxHeight)
            bar.cornerRadius = Self.barWidth / 2
            layer.addSublayer(bar)
            bars.append(bar)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(refreshAnimation), name: Constants.Notifications.playbackStarted, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshAnimation), name: Constants.Notifications.playbackPaused, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshAnimation), name: Constants.Notifications.playbackEnded, object: nil)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshAnimation()
    }

    override var isHidden: Bool {
        didSet {
            refreshAnimation()
        }
    }

    @objc private func refreshAnimation() {
        guard window != nil, !isHidden, PlaybackManager.shared.playing() else {
            stopAnimating()
            return
        }
        startAnimating()
    }

    private func startAnimating() {
        for (index, bar) in bars.enumerated() {
            guard bar.animation(forKey: "bounce") == nil else { continue }
            let animation = CABasicAnimation(keyPath: "transform.scale.y")
            animation.fromValue = 0.3
            animation.toValue = 1.0
            animation.duration = 0.45 + Double(index) * 0.12
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timeOffset = Double(index) * 0.2
            bar.add(animation, forKey: "bounce")
        }
    }

    private func stopAnimating() {
        // Paused → a single, CONSISTENT static equalizer glyph: always the same varied resting shape,
        // never frozen at wherever the bounce happened to be (which made it depend on what was playing).
        let restingHeights: [CGFloat] = [0.5, 1.0, 0.7]
        for (index, bar) in bars.enumerated() {
            bar.removeAnimation(forKey: "bounce")
            bar.transform = CATransform3DMakeScale(1, restingHeights[index % restingHeights.count], 1)
        }
    }
}
