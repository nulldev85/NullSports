import QuartzCore
import SwiftUI
import UIKit

// MARK: - The drift

/// How one title's art moves on a service's poster: it fills the card,
/// slightly zoomed, and over its span eases back to rest while gliding from
/// one side towards the other. The art covers the card at every moment of
/// that, so no edge of it ever shows.
///
/// Worked out as plain geometry so the canvas and its checks agree, and so
/// the canvas can stop and pick up again anywhere along the way.
struct StreamingPosterDrift: Equatable {
    static let zoom: CGFloat = 1.08

    /// The art's size at rest: the smallest, kept to its own shape, that
    /// covers the card.
    let fill: CGSize
    /// How far either side of centre it travels.
    let reach: CGFloat
    /// Which way: alternate titles go opposite ways.
    let direction: CGFloat

    init(picture: CGSize, card: CGSize, direction: CGFloat) {
        if picture.width > 0, picture.height > 0, card.width > 0, card.height > 0 {
            let scale = max(card.width / picture.width, card.height / picture.height)
            fill = CGSize(width: picture.width * scale, height: picture.height * scale)
        } else {
            fill = card
        }
        // The room at rest is the least there ever is, since the art only
        // grows from there; using part of it keeps the travel gentle.
        let room = max(0, (fill.width - card.width) / 2)
        reach = min(room * 0.6, card.width * 0.45)
        self.direction = direction < 0 ? -1 : 1
    }

    func scale(at progress: CGFloat) -> CGFloat {
        Self.zoom + (1 - Self.zoom) * Self.clamped(progress)
    }

    func offset(at progress: CGFloat) -> CGFloat {
        reach * direction * (1 - 2 * Self.clamped(progress))
    }

    /// Scaled about the card's centre, then moved across it.
    func transform(at progress: CGFloat) -> CATransform3D {
        let scale = scale(at: progress)
        return CATransform3DScale(CATransform3DMakeTranslation(offset(at: progress), 0, 0), scale, scale, 1)
    }

    /// Whether the art covers a card of this size all the way round.
    func covers(_ card: CGSize, at progress: CGFloat) -> Bool {
        let scale = scale(at: progress)
        let width = fill.width * scale, height = fill.height * scale
        let slack = (width - card.width) / 2 - abs(offset(at: progress))
        return slack >= -0.001 && height >= card.height - 0.001
    }

    private static func clamped(_ progress: CGFloat) -> CGFloat { min(max(progress, 0), 1) }
}

// MARK: - The art

/// The art behind a service's mark, drawn and moved by Core Animation.
///
/// Nothing about the motion goes through SwiftUI. Each title's drift and
/// each crossfade is one animation handed to the render server, which plays
/// it at the display's rate whatever the app is doing: a Library scrolling,
/// a shelf of artwork decoding, a page being built. SwiftUI only says which
/// picture is up and whether it should be moving.
struct StreamingPosterArt: UIViewRepresentable {
    let picture: StreamingPosterPicture?
    let direction: CGFloat
    let moving: Bool
    /// How long the drift of one title lasts.
    let span: Double
    /// How long a new title takes to fade in over the last.
    let fade: Double

    func makeUIView(context: Context) -> StreamingPosterCanvas {
        let canvas = StreamingPosterCanvas(frame: .zero)
        canvas.span = span
        canvas.setMotionEnabled(moving)
        canvas.show(picture, direction: direction, fade: 0)
        return canvas
    }

    func updateUIView(_ canvas: StreamingPosterCanvas, context: Context) {
        canvas.span = span
        canvas.setMotionEnabled(moving)
        // A change made inside `withAnimation` fades; any other is a cut.
        canvas.show(picture, direction: direction, fade: context.transaction.animation == nil ? 0 : fade)
    }

    static func dismantleUIView(_ canvas: StreamingPosterCanvas, coordinator: ()) {
        canvas.setMotionEnabled(false)
    }
}

/// A picture on a service's poster, and the address it came from.
struct StreamingPosterPicture {
    let url: URL
    let image: UIImage
}

/// The layers behind `StreamingPosterArt`. The picture on show moves under
/// one animation for its whole drift; a new one is laid over it and faded
/// in, and the old one goes once it is covered. Stopped -- out of the
/// window, the app in the background, Reduce Motion, or on the television a
/// poster out of focus -- the picture holds exactly where it was and carries
/// on from there.
final class StreamingPosterCanvas: UIView {
    private static let driftKey = "streaming-poster-drift"
    private static let fadeKey = "streaming-poster-fade"

    /// The display's own steady rate. A slow glide shows every dropped frame
    /// as a stutter, so the system is asked not to take it lower; nothing
    /// this slow is any smoother faster.
    private static let frameRate = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)

    private final class Shown {
        let layer = CALayer()
        let url: URL
        let image: UIImage
        let direction: CGFloat
        var drift: StreamingPosterDrift
        /// How far along its drift it was when it last stopped, and when it
        /// last started again.
        var progress: CGFloat = 0
        var startedAt: CFTimeInterval?

        init(_ picture: StreamingPosterPicture, direction: CGFloat, card: CGSize) {
            url = picture.url
            image = picture.image
            self.direction = direction
            drift = StreamingPosterDrift(picture: picture.image.size, card: card, direction: direction)
        }
    }

    var span: Double = 8.4
    private var shown: Shown?
    private var leaving: [CALayer] = []
    private var motionEnabled = false
    private var applicationActive = UIApplication.shared.applicationState != .background
    private var laidOutSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        backgroundColor = .clear
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        layer.masksToBounds = true
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillResignActive),
            name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func applicationWillResignActive() {
        applicationActive = false
        updateRunning()
    }

    @objc private func applicationDidBecomeActive() {
        applicationActive = true
        updateRunning()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateRunning()
    }

    private var shouldRun: Bool { motionEnabled && applicationActive && window != nil }

    func setMotionEnabled(_ enabled: Bool) {
        guard enabled != motionEnabled else { return }
        motionEnabled = enabled
        updateRunning()
    }

    // MARK: Pictures

    func show(_ picture: StreamingPosterPicture?, direction: CGFloat, fade: Double) {
        if let shown, let picture, shown.url == picture.url, shown.image === picture.image { return }
        guard let picture else {
            clear()
            return
        }
        let next = Shown(picture, direction: direction, card: bounds.size)
        next.layer.contents = picture.image.cgImage
        next.layer.contentsGravity = .resize
        // Decoded at about the size it is drawn, so plain linear filtering
        // is all the scaling it needs.
        next.layer.allowsEdgeAntialiasing = false
        let previous = shown
        shown = next
        // The very first picture comes up out of the flat card a little
        // quicker than one title gives way to the next.
        let fade = previous == nil ? min(fade, 0.6) : fade

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place(next)
        layer.addSublayer(next.layer)
        if fade > 0 {
            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0
            fadeIn.toValue = 1
            fadeIn.duration = fade
            fadeIn.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fadeIn.preferredFrameRateRange = Self.frameRate
            next.layer.add(fadeIn, forKey: Self.fadeKey)
        }
        CATransaction.commit()

        // The old picture keeps moving under the new one until it is
        // covered, then goes. Only one is ever left behind.
        leaving.forEach { $0.removeFromSuperlayer() }
        leaving.removeAll()
        if let previous {
            if fade > 0 {
                leaving.append(previous.layer)
                let layer = previous.layer
                DispatchQueue.main.asyncAfter(deadline: .now() + fade) { [weak self] in
                    guard let self, let index = self.leaving.firstIndex(where: { $0 === layer }) else { return }
                    layer.removeFromSuperlayer()
                    self.leaving.remove(at: index)
                }
            } else {
                previous.layer.removeFromSuperlayer()
            }
        }
    }

    private func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shown?.layer.removeFromSuperlayer()
        leaving.forEach { $0.removeFromSuperlayer() }
        CATransaction.commit()
        shown = nil
        leaving.removeAll()
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        guard let shown else { return }
        // A card of a new size gets the drift worked out afresh, from where
        // the picture had got to.
        let now = CACurrentMediaTime()
        shown.progress = progress(of: shown, at: now)
        if shown.startedAt != nil { shown.startedAt = now }
        shown.drift = StreamingPosterDrift(picture: shown.image.size, card: bounds.size, direction: shown.direction)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place(shown)
        CATransaction.commit()
    }

    /// Sizes and centres a picture, sets it where its drift has got to, and
    /// sends it on from there if the canvas is running.
    private func place(_ shown: Shown) {
        let layer = shown.layer
        layer.bounds = CGRect(origin: .zero, size: shown.drift.fill)
        layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let now = CACurrentMediaTime()
        if shouldRun {
            if shown.startedAt == nil { shown.startedAt = now }
            run(shown, from: progress(of: shown, at: now), at: now)
        } else {
            shown.progress = progress(of: shown, at: now)
            shown.startedAt = nil
            layer.removeAnimation(forKey: Self.driftKey)
            layer.transform = shown.drift.transform(at: shown.progress)
        }
    }

    // MARK: Motion

    private func updateRunning() {
        guard let shown else { return }
        let running = shown.startedAt != nil
        guard running != shouldRun else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place(shown)
        CATransaction.commit()
    }

    private func progress(of shown: Shown, at now: CFTimeInterval) -> CGFloat {
        guard let startedAt = shown.startedAt, span > 0 else { return shown.progress }
        return min(1, shown.progress + CGFloat((now - startedAt) / span))
    }

    /// One animation for the rest of the drift. Its model value is the end,
    /// so a drift that finishes simply rests there.
    private func run(_ shown: Shown, from progress: CGFloat, at now: CFTimeInterval) {
        let layer = shown.layer
        layer.removeAnimation(forKey: Self.driftKey)
        shown.progress = progress
        shown.startedAt = now
        layer.transform = shown.drift.transform(at: 1)
        let remaining = Double(1 - progress) * span
        guard remaining > 0.01 else { return }
        let drift = CABasicAnimation(keyPath: "transform")
        drift.fromValue = shown.drift.transform(at: progress)
        drift.toValue = shown.drift.transform(at: 1)
        drift.duration = remaining
        drift.timingFunction = CAMediaTimingFunction(name: .linear)
        drift.preferredFrameRateRange = Self.frameRate
        layer.add(drift, forKey: Self.driftKey)
    }
}
