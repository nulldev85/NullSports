import CoreImage
import SwiftUI
import UIKit

/// The picture's own colours, softly spread into the black around it, as
/// YouTube's ambient mode does.
///
/// Every few seconds the player is asked for the frame on screen, which is
/// shrunk to a handful of pixels; that, blurred far beyond recognition and
/// dimmed, fills the bars beside the picture and fades from one sample to
/// the next. The engines paint their own black behind the picture, so the
/// glow lies over the surface with the picture itself cut out of it -- the
/// frame's shape says where the picture is, and black bars sent inside the
/// frame itself (a 4:3 channel in a 16:9 stream) count as black around it.
/// An engine that cannot hand over a frame simply has none.
struct LineupAmbientGlow: View {
    /// The frame on screen, from whichever player is showing it.
    let frames: @MainActor () async -> CapturedVideoFrame?
    var enabled = true

    @AppStorage(LineupAmbientGlow.preferenceKey) private var preference = true
    @State private var sample: Sample?

    static let preferenceKey = "Lineup.player.ambient.v1"
    /// How often the colours are taken again: slow, as the glow is.
    static let interval: Duration = .seconds(2.5)
    /// How often a picture that fills the screen, with no black to light, is
    /// looked at again -- in case what is playing changes shape.
    static let idleInterval: Duration = .seconds(10)

    struct Sample: Equatable {
        let id = UUID()
        let image: UIImage
        /// The frame's width over its height.
        let aspect: CGFloat
        /// The part of the frame that is picture, as fractions of its width
        /// and height: less than whole where the stream carries its own bars.
        let content: CGSize
    }

    var body: some View {
        GeometryReader { geometry in
            if let sample {
                let frame = Self.fitted(sample.aspect, in: geometry.size)
                let picture = CGSize(width: frame.width * sample.content.width,
                                     height: frame.height * sample.content.height)
                ZStack {
                    Image(uiImage: sample.image)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: picture.width, height: picture.height)
                        // Spread past the picture's edges, more where the
                        // bars are deep.
                        .scaleEffect(x: max(1.15, geometry.size.width / max(picture.width, 1) * 1.1),
                                     y: max(1.15, geometry.size.height / max(picture.height, 1) * 0.9))
                        .blur(radius: 46)
                        .saturation(1.35)
                        .opacity(0.62)
                        .id(sample.id)
                        .transition(.opacity)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .mask {
                    ZStack {
                        Rectangle()
                        Rectangle()
                            .frame(width: picture.width, height: picture.height)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: enabled && preference) {
            guard enabled && preference else {
                sample = nil
                return
            }
            while !Task.isCancelled {
                var fills = false
                if let frame = await frames(),
                   let reduced = await LineupAmbientSampler.reduce(frame) {
                    withAnimation(.easeInOut(duration: 1.6)) {
                        sample = Sample(image: UIImage(cgImage: reduced.image), aspect: reduced.aspect,
                                        content: reduced.content)
                    }
                    fills = Self.fillsScreen(reduced.aspect * reduced.content.width / max(reduced.content.height, 0.01))
                }
                try? await Task.sleep(for: fills ? Self.idleInterval : Self.interval)
            }
        }
    }

    /// Whether a picture of this shape leaves no black on the screen.
    @MainActor
    static func fillsScreen(_ aspect: CGFloat) -> Bool {
        let bounds = UIScreen.main.bounds.size
        let screen = max(bounds.width, bounds.height) / max(min(bounds.width, bounds.height), 1)
        let picture = aspect >= 1 ? aspect : 1 / max(aspect, 0.01)
        return abs(picture - screen) / screen < 0.02
    }

    /// Where an aspect-fitted picture sits in a space, centred.
    static func fitted(_ aspect: CGFloat, in space: CGSize) -> CGSize {
        guard aspect > 0, space.width > 0, space.height > 0 else { return space }
        if space.width / space.height > aspect {
            return CGSize(width: space.height * aspect, height: space.height)
        }
        return CGSize(width: space.width, height: space.width / aspect)
    }
}

/// Shrinks frames for the glow, away from the screen's own actor.
enum LineupAmbientSampler {
    nonisolated(unsafe) private static let context = CIContext(options: [.useSoftwareRenderer: false])

    struct Reduced {
        /// The picture -- bars carried in the frame left out -- at a few
        /// dozen pixels across.
        let image: CGImage
        let aspect: CGFloat
        let content: CGSize
    }

    /// Made off the main thread.
    static func reduce(_ frame: CapturedVideoFrame) async -> Reduced? {
        let source: CIImage
        switch frame {
        case .pixelBuffer(let buffer): source = CIImage(cvPixelBuffer: buffer)
        case .image(let image): source = CIImage(cgImage: image)
        }
        return await Task.detached(priority: .utility) { () -> Reduced? in
            let extent = source.extent
            guard extent.width > 0, extent.height > 0 else { return nil }
            let content = bars(in: source) ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            // Core Image counts up from the bottom; the bars are measured
            // from the top.
            let crop = CGRect(x: extent.minX + content.minX * extent.width,
                              y: extent.minY + (1 - content.maxY) * extent.height,
                              width: content.width * extent.width,
                              height: content.height * extent.height)
            let picture = source.cropped(to: crop)
            let scale = 32 / max(crop.width, 1)
            let small = picture.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let image = context.createCGImage(small, from: small.extent.integral) else { return nil }
            return Reduced(image: image, aspect: extent.width / extent.height,
                           content: CGSize(width: content.width, height: content.height))
        }.value
    }

    /// The picture inside bars of solid black the stream carries itself, in
    /// fractions of the frame from its top left; nil when there are none.
    /// Bars come in pairs -- left and right, or top and bottom, about as
    /// deep as each other -- so a dark scene with one black edge is not
    /// mistaken for them.
    static func bars(in source: CIImage) -> CGRect? {
        let width = 64, height = 36
        let extent = source.extent
        let fitted = source.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / extent.width,
                                                              y: CGFloat(height) / extent.height))
            .transformed(by: CGAffineTransform(translationX: -extent.minX * CGFloat(width) / extent.width,
                                               y: -extent.minY * CGFloat(height) / extent.height))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(fitted, toBitmap: &pixels, rowBytes: width * 4,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        // Bars are found in pairs, so which end the rows start from does
        // not matter.
        func dark(_ x: Int, _ y: Int) -> Bool {
            let index = (y * width + x) * 4
            return max(pixels[index], pixels[index + 1], pixels[index + 2]) < 28
        }
        func darkColumn(_ x: Int) -> Bool { (0..<height).allSatisfy { dark(x, $0) } }
        func darkRow(_ y: Int) -> Bool { (0..<width).allSatisfy { dark($0, y) } }
        var left = 0, right = 0, top = 0, bottom = 0
        while left < width / 2, darkColumn(left) { left += 1 }
        while right < width / 2, darkColumn(width - 1 - right) { right += 1 }
        while top < height / 2, darkRow(top) { top += 1 }
        while bottom < height / 2, darkRow(height - 1 - bottom) { bottom += 1 }
        // A frame that is black all over is a black frame, not bars.
        guard left < width / 2, top < height / 2 else { return nil }
        let sides = min(left, right) >= 3 && abs(left - right) <= 2
        let ends = min(top, bottom) >= 2 && abs(top - bottom) <= 2
        guard sides || ends else { return nil }
        let x = sides ? CGFloat(left) / CGFloat(width) : 0
        let w = sides ? CGFloat(width - left - right) / CGFloat(width) : 1
        let y = ends ? CGFloat(top) / CGFloat(height) : 0
        let h = ends ? CGFloat(height - top - bottom) / CGFloat(height) : 1
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
