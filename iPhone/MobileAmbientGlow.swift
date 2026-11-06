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
/// frame's shape says where the picture is. An engine that cannot hand over
/// a frame simply has none.
struct MobileAmbientGlow: View {
    let controller: MobilePlaybackController
    var enabled = true

    @AppStorage(MobileAmbientGlow.preferenceKey) private var preference = true
    @State private var sample: Sample?

    static let preferenceKey = "Lineup.player.ambient.v1"
    /// How often the colours are taken again: slow, as the glow is.
    static let interval: Duration = .seconds(2.5)

    struct Sample: Equatable {
        let id = UUID()
        let image: UIImage
        /// The picture's width over its height.
        let aspect: CGFloat
    }

    var body: some View {
        GeometryReader { geometry in
            if let sample {
                let picture = Self.fitted(sample.aspect, in: geometry.size)
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
                if let frame = await controller.captureFrame(),
                   let reduced = await MobileAmbientSampler.reduce(frame) {
                    withAnimation(.easeInOut(duration: 1.6)) {
                        sample = Sample(image: UIImage(cgImage: reduced.image), aspect: reduced.aspect)
                    }
                }
                try? await Task.sleep(for: Self.interval)
            }
        }
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
enum MobileAmbientSampler {
    nonisolated(unsafe) private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// The frame at a few dozen pixels across, and its shape, made off the
    /// main thread.
    static func reduce(_ frame: CapturedVideoFrame) async -> (image: CGImage, aspect: CGFloat)? {
        let source: CIImage
        switch frame {
        case .pixelBuffer(let buffer): source = CIImage(cvPixelBuffer: buffer)
        case .image(let image): source = CIImage(cgImage: image)
        }
        return await Task.detached(priority: .utility) { () -> (image: CGImage, aspect: CGFloat)? in
            let extent = source.extent
            guard extent.width > 0, extent.height > 0 else { return nil }
            let scale = 32 / extent.width
            let small = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let image = context.createCGImage(small, from: small.extent.integral) else { return nil }
            return (image, extent.width / extent.height)
        }.value
    }
}
