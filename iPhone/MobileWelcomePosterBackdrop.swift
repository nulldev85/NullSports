#if os(iOS)
import SwiftUI
import UIKit

/// These small, official TMDB posters ship in the app. First launch, a slow
/// connection, and relaunch all draw the same complete artwork immediately.
@MainActor
enum MobileWelcomePosterArtwork {
    static let names = (1...12).map { String(format: "WelcomePoster%02d", $0) }
    static let images: [CGImage] = names.compactMap { UIImage(named: $0)?.cgImage }
}

struct MobileWelcomePosterBackdrop: UIViewRepresentable {
    let isActive: Bool

    func makeUIView(context: Context) -> MobileWelcomePosterCanvas {
        let view = MobileWelcomePosterCanvas(frame: .zero)
        view.setMotionEnabled(isActive)
        return view
    }

    func updateUIView(_ view: MobileWelcomePosterCanvas, context: Context) {
        view.setMotionEnabled(isActive)
    }

    static func dismantleUIView(_ view: MobileWelcomePosterCanvas, coordinator: ()) {
        view.setMotionEnabled(false)
    }
}

/// Core Animation moves only each track's horizontal transform. Every row has
/// its own fixed clipping layer, so artwork loads and SwiftUI form updates can
/// never animate a cell into another row. Identical updates do no work.
final class MobileWelcomePosterCanvas: UIView {
    struct Row {
        let viewport: CALayer
        let track: CALayer
        let motion: MobileWelcomeRowMotion
    }

    static let animationKey = "welcome-poster-scroll"
    private(set) var rows: [Row] = []
    private var laidOutSize: CGSize = .zero
    private var motionEnabled = false
    private var applicationActive = UIApplication.shared.applicationState == .active
    private var clock = MobileWelcomeAnimationClock()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        backgroundColor = .black
        isOpaque = true
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        layer.masksToBounds = true
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillResignActive(_:)),
            name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidBecomeActive(_:)),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func applicationWillResignActive(_ notification: Notification) {
        applicationActive = false
        updateRunningState()
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        applicationActive = true
        updateRunningState()
    }

    func setMotionEnabled(_ enabled: Bool) {
        guard motionEnabled != enabled else { return }
        motionEnabled = enabled
        updateRunningState()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateRunningState()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        rebuildRows()
    }

    private func rebuildRows() {
        let images = MobileWelcomePosterArtwork.images
        guard !images.isEmpty else { return }
        let rowCount = 6
        let gap: CGFloat = 8
        let preferredWidth = min(108, max(78, (bounds.width - 40) / 3.45))
        let fittingHeight = max(80, (bounds.height - gap * CGFloat(rowCount - 1)) / CGFloat(rowCount))
        let posterWidth = min(preferredWidth, fittingHeight / 1.5)
        let posterHeight = posterWidth * 1.5
        let step = posterWidth + gap
        let tilesPerStrip = max(images.count, Int(ceil(bounds.width / step)) + 2)
        let period = CGFloat(tilesPerStrip) * step
        let scale = max(1, traitCollection.displayScale)
        let top = (bounds.height - posterHeight * CGFloat(rowCount) - gap * CGFloat(rowCount - 1)) / 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rows.forEach { $0.viewport.removeFromSuperlayer() }
        rows.removeAll(keepingCapacity: true)
        for rowIndex in 0..<rowCount {
            let viewport = CALayer()
            viewport.contentsScale = scale
            viewport.frame = CGRect(x: 0, y: top + CGFloat(rowIndex) * (posterHeight + gap),
                                    width: bounds.width, height: posterHeight)
            viewport.masksToBounds = true
            let track = CALayer()
            track.contentsScale = scale
            track.frame = CGRect(x: 0, y: 0,
                                 width: CGFloat(MobileWelcomeRowMotion.copyCount) * period - gap,
                                 height: posterHeight)
            for copy in 0..<MobileWelcomeRowMotion.copyCount {
                for tile in 0..<tilesPerStrip {
                    let card = CALayer()
                    card.contentsScale = scale
                    card.frame = CGRect(x: CGFloat(copy * tilesPerStrip + tile) * step, y: 0,
                                        width: posterWidth, height: posterHeight)
                    card.contents = images[(tile + rowIndex * 3) % images.count]
                    card.contentsGravity = .resizeAspectFill
                    card.masksToBounds = true
                    card.cornerRadius = 13
                    card.cornerCurve = .continuous
                    card.borderWidth = 0.5
                    card.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
                    track.addSublayer(card)
                }
            }
            viewport.addSublayer(track)
            layer.addSublayer(viewport)
            rows.append(Row(viewport: viewport, track: track,
                            motion: MobileWelcomeRowMotion(rowIndex: rowIndex, rowCount: rowCount, period: period)))
        }
        CATransaction.commit()
        applyMotion(at: CACurrentMediaTime())
    }

    private func updateRunningState() {
        let shouldRun = motionEnabled && applicationActive && window != nil
        guard shouldRun != clock.isRunning else { return }
        let now = CACurrentMediaTime()
        clock.setRunning(shouldRun, at: now)
        applyMotion(at: now)
    }

    private func applyMotion(at now: CFTimeInterval) {
        let elapsed = clock.elapsed(at: now)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for row in rows {
            row.track.removeAnimation(forKey: Self.animationKey)
            row.track.setAffineTransform(CGAffineTransform(translationX: row.motion.offset(atElapsed: elapsed), y: 0))
            if clock.isRunning {
                let scroll = CABasicAnimation(keyPath: "transform.translation.x")
                scroll.fromValue = row.motion.startOffset
                scroll.toValue = row.motion.endOffset
                scroll.duration = row.motion.duration
                scroll.timingFunction = CAMediaTimingFunction(name: .linear)
                scroll.repeatCount = .infinity
                scroll.beginTime = row.track.convertTime(now, from: nil) - elapsed
                row.track.add(scroll, forKey: Self.animationKey)
            }
        }
        CATransaction.commit()
    }
}
#endif
