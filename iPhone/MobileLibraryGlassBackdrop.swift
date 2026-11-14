import SwiftUI

/// Behind the Library's shelves: the hero's current picture, blurred to a wash
/// of its colours, over a glow in the accent colour.
///
/// Liquid Glass shows what lies behind it, and over plain black the shelves'
/// glass read as a flat dark card. The wash begins where the hero ends and
/// fades in, so the hero's own fade to black meets it without a seam; it
/// scrolls with the shelves and fades out again further down the page.
struct MobileLibraryGlassBackdrop: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.mobileShelfBleed) private var bleed
    @AppStorage(LineupAccent.storageKey) private var accentHex = LineupAccent.red.hex
    /// The title the hero is showing; nil before the hero has one, or with
    /// no hero at all, leaving the glow alone.
    let item: MediaItem?
    /// Where the wash starts: the hero's foot.
    let top: CGFloat

    static let height: CGFloat = 1_300
    /// How far the wash takes to come up from black.
    static let fadeIn: CGFloat = 240

    var body: some View {
        let accent = LineupAccent.accent(forHex: accentHex).color
        ZStack {
            RadialGradient(colors: [accent.opacity(0.26), .clear], center: UnitPoint(x: 0.82, y: 0.32),
                           startRadius: 0, endRadius: 560)
            if let item {
                // The hero's own address, so the picture comes from the cache
                // the hero filled; drawn tiny, as the blur leaves no detail.
                LineupArtView(url: media.backdropURL(for: item, width: 1800), width: 120) { image in
                    if let image { image.resizable().scaledToFill() } else { Color.clear }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .blur(radius: 60, opaque: true)
                .saturation(1.5)
                .opacity(0.55)
                .id(item.libraryKey)
                .transition(.opacity)
            }
        }
        .frame(height: Self.height)
        .mask {
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: Self.fadeIn / Self.height),
                .init(color: .black, location: 0.5),
                .init(color: .clear, location: 1)
            ], startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 1.2), value: item?.libraryKey)
        .padding(.leading, -bleed.leading)
        .padding(.trailing, -bleed.trailing)
        .offset(y: top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
