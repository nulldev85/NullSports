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
/// picture is up, since when, and whether it should be moving.
struct StreamingPosterArt: UIViewRepresentable {
    let picture: StreamingPosterPicture?
    let motion: StreamingPosterCanvas.Motion
    /// How long one way of a drift takes.
    let span: Double
    /// How long a new title takes to fade in over the last.
    let fade: Double

    func makeUIView(context: Context) -> StreamingPosterCanvas {
        let canvas = StreamingPosterCanvas(span: span, motion: motion)
        canvas.show(picture, fade: 0)
        return canvas
    }

    func updateUIView(_ canvas: StreamingPosterCanvas, context: Context) {
        canvas.setMotion(motion)
        // A change made inside `withAnimation` fades; any other is a cut.
        canvas.show(picture, fade: context.transaction.animation == nil ? 0 : fade)
    }
}

/// A picture on a service's poster: where it came from, its place in the
/// reel, and when its drift began, on the device's clock (nil for now).
struct StreamingPosterPicture {
    let url: URL
    let image: UIImage
    let index: Int
    let began: CFTimeInterval?

    func began(_ time: CFTimeInterval?) -> StreamingPosterPicture {
        StreamingPosterPicture(url: url, image: image, index: index, began: time)
    }
}

/// The layers behind `StreamingPosterArt`.
///
/// Each picture is two layers: an outer one that fades, and the art inside
/// it that drifts. The drift is a single animation that runs to the far side
/// and eases back, over and over, so a picture never comes to rest while it
/// is up -- whether the next title is late or there is no next title. On the
/// television a poster out of focus freezes its art exactly where it was,
/// and the fade, on the outer layer, is never caught by that.
final class StreamingPosterCanvas: UIView {
    enum Motion: Equatable {
        /// Drifting, and changing title on the beat.
        case running
        /// Held exactly where it is, ready to carry on.
        case paused
        /// Reduce Motion: the art still, at its middle.
        case still
    }

    private static let driftKey = "streaming-poster-drift"
    private static let fadeKey = "streaming-poster-fade"

    /// The display's own steady rate. A slow glide shows every dropped frame
    /// as a stutter, so the system is asked not to take it lower; nothing
    /// this slow is any smoother faster.
    private static let frameRate = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)

    private final class Shown {
        let frame = CALayer()
        let art = CALayer()
        let url: URL
        let image: UIImage
        var drift: StreamingPosterDrift

        init(_ picture: StreamingPosterPicture, card: CGSize) {
            url = picture.url
            image = picture.image
            // Alternate titles travel opposite ways.
            drift = StreamingPosterDrift(picture: picture.image.size, card: card,
                                         direction: picture.index.isMultiple(of: 2) ? 1 : -1)
        }

        var direction: CGFloat { drift.direction }
    }

    private let span: Double
    private var motion: Motion
    private var shown: Shown?
    private var leaving: [CALayer] = []
    private var laidOutSize: CGSize = .zero

    init(span: Double, motion: Motion) {
        self.span = span
        self.motion = motion
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        layer.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Pictures

    func show(_ picture: StreamingPosterPicture?, fade: Double) {
        // The same picture is the same picture, however it was handed over.
        if shown?.url == picture?.url { return }
        guard let picture else {
            clear()
            return
        }
        let next = Shown(picture, card: bounds.size)
        next.art.contents = picture.image.cgImage
        next.art.contentsGravity = .resize
        next.art.allowsEdgeAntialiasing = false
        let previous = shown
        shown = next
        // The very first picture comes up out of the flat card a little
        // quicker than one title gives way to the next.
        let fade = previous == nil ? min(fade, 0.6) : fade

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        next.frame.addSublayer(next.art)
        layer.addSublayer(next.frame)
        size(next)
        startDrift(next, began: picture.began ?? CACurrentMediaTime())
        if fade > 0 {
            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0
            fadeIn.toValue = 1
            fadeIn.duration = fade
            fadeIn.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fadeIn.preferredFrameRateRange = Self.frameRate
            next.frame.add(fadeIn, forKey: Self.fadeKey)
        }
        CATransaction.commit()

        // The old picture keeps moving under the new one until it is
        // covered, then goes. Only one is ever left behind.
        leaving.forEach { $0.removeFromSuperlayer() }
        leaving.removeAll()
        guard let previous else { return }
        guard fade > 0 else {
            previous.frame.removeFromSuperlayer()
            return
        }
        let old = previous.frame
        leaving.append(old)
        DispatchQueue.main.asyncAfter(deadline: .now() + fade) { [weak self] in
            guard let self, let index = self.leaving.firstIndex(where: { $0 === old }) else { return }
            old.removeFromSuperlayer()
            self.leaving.remove(at: index)
        }
    }

    private func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shown?.frame.removeFromSuperlayer()
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
        // A card of a new size gets its drift worked out afresh, keeping the
        // time it began, so it carries on from the same moment.
        let began = shown.art.animation(forKey: Self.driftKey)?.beginTime
        shown.drift = StreamingPosterDrift(picture: shown.image.size, card: bounds.size, direction: shown.direction)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        size(shown)
        if let began {
            shown.art.removeAnimation(forKey: Self.driftKey)
            addDrift(to: shown, localBegin: began)
        } else {
            settle(shown)
        }
        CATransaction.commit()
    }

    private func size(_ shown: Shown) {
        shown.frame.frame = bounds
        shown.art.bounds = CGRect(origin: .zero, size: shown.drift.fill)
        shown.art.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    // MARK: Motion

    func setMotion(_ motion: Motion) {
        guard motion != self.motion else { return }
        self.motion = motion
        guard let shown else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch motion {
        case .still:
            shown.art.removeAnimation(forKey: Self.driftKey)
            resume(shown.art)
            settle(shown)
        case .running:
            if shown.art.animation(forKey: Self.driftKey) == nil { startDrift(shown, began: CACurrentMediaTime()) }
            resume(shown.art)
        case .paused:
            if shown.art.animation(forKey: Self.driftKey) == nil { startDrift(shown, began: CACurrentMediaTime()) }
            pause(shown.art)
        }
        CATransaction.commit()
    }

    /// Sets a new picture moving from `began`, a time on the device's clock,
    /// or holds it there.
    private func startDrift(_ shown: Shown, began: CFTimeInterval) {
        guard motion != .still else {
            settle(shown)
            return
        }
        addDrift(to: shown, localBegin: shown.art.convertTime(began, from: nil))
        if motion == .paused { pause(shown.art) }
    }

    private func settle(_ shown: Shown) {
        shown.art.transform = shown.drift.transform(at: 0.5)
    }

    /// To the far side and back, eased at each end, for as long as the
    /// picture is up. Never removed on completion: it has none, and keeping
    /// it is what carries it through the app going to the background.
    private func addDrift(to shown: Shown, localBegin: CFTimeInterval) {
        let drift = CABasicAnimation(keyPath: "transform")
        drift.fromValue = shown.drift.transform(at: 0)
        drift.toValue = shown.drift.transform(at: 1)
        drift.duration = span
        drift.autoreverses = true
        drift.repeatCount = .infinity
        drift.beginTime = localBegin
        drift.fillMode = .both
        drift.isRemovedOnCompletion = false
        drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        drift.preferredFrameRateRange = Self.frameRate
        shown.art.transform = shown.drift.transform(at: 0)
        shown.art.add(drift, forKey: Self.driftKey)
    }

    /// Stops a layer's own clock where it is.
    private func pause(_ layer: CALayer) {
        guard layer.speed != 0 else { return }
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.speed = 0
        layer.timeOffset = now
    }

    /// Starts it again from exactly where it stopped.
    private func resume(_ layer: CALayer) {
        guard layer.speed == 0 else { return }
        let stopped = layer.timeOffset
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
        layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - stopped
    }
}
