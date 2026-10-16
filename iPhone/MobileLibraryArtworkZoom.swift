import SwiftUI

/// Keep the bottom of the artwork attached to the page as a pull exposes
/// more room above it. A visual effect follows scrolling without changing
/// layout, rebuilding the Library, or requesting a larger decoded image.
private struct MobileLibraryArtworkZoom: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let enabled = !reduceMotion
        content
            // Crop the original image before scaling it. The header's owner
            // must leave the result unclipped so it can fill the pulled gap.
            .clipped()
            .visualEffect { effect, geometry in
                let pull = enabled ? max(0, geometry.frame(in: .scrollView(axis: .vertical)).minY) : 0
                let scale = 1 + pull / max(geometry.size.height, 1)
                return effect.scaleEffect(scale, anchor: .bottom)
            }
    }
}

extension View {
    /// Use only on a Library header's artwork, before its fade and controls.
    func mobileLibraryArtworkZoom() -> some View {
        modifier(MobileLibraryArtworkZoom())
    }
}
