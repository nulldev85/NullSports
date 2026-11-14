import CoreImage
import SwiftUI
import UIKit

/// A picture blurred once, away from the screen, then drawn as a plain image.
///
/// A live blur is worked out again on every frame anything over or around it
/// moves. Behind the Library's hero -- which scrolls with the page and
/// stretches when it is pulled -- that was every frame of every scroll, and
/// the Library stuttered with it. Blurred ahead of time, the picture costs
/// what any picture does.
struct MobileBlurredArtwork: View {
    let url: URL?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().interpolation(.high).scaledToFill()
                    .transition(.opacity)
            } else {
                Color.clear
            }
        }
        .animation(.easeOut(duration: 0.3), value: image != nil)
        .task(id: url) {
            image = await Self.blurred(url)
        }
        .accessibilityHidden(true)
    }

    nonisolated(unsafe) private static let cache = NSCache<NSURL, UIImage>()
    nonisolated(unsafe) private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// The picture at a few dozen pixels across, softened past recognition.
    /// Drawn large, the small size is itself most of the blur.
    static func blurred(_ url: URL?) async -> UIImage? {
        guard let url else { return nil }
        if let kept = cache.object(forKey: url as NSURL) { return kept }
        guard let source = await LineupArt.load(url, pixels: 160), let picture = source.cgImage else { return nil }
        let result = await Task.detached(priority: .utility) { () -> UIImage? in
            let input = CIImage(cgImage: picture)
            // Edges carried outward first, so the blur doesn't fade to
            // nothing at the picture's sides.
            let soft = input.clampedToExtent().applyingGaussianBlur(sigma: 9).cropped(to: input.extent)
            guard let output = context.createCGImage(soft, from: input.extent) else { return nil }
            return UIImage(cgImage: output)
        }.value
        if let result { cache.setObject(result, forKey: url as NSURL) }
        return result
    }
}
