import SwiftUI

struct MobileFanartTitle<Fallback: View>: View {
    let item: MediaItem
    let width: CGFloat
    let height: CGFloat
    let alignment: Alignment
    @ViewBuilder var fallback: () -> Fallback

    init(item: MediaItem, width: CGFloat, height: CGFloat, alignment: Alignment = .leading,
         @ViewBuilder fallback: @escaping () -> Fallback) {
        self.item = item
        self.width = width
        self.height = height
        self.alignment = alignment
        self.fallback = fallback
    }

    var body: some View {
        LineupTitleLogo(item: item, width: width, height: height, alignment: alignment, fallback: fallback)
    }

    static func identity(for item: MediaItem) -> MobileFanartIdentity? { MobileFanartIdentity(item: item) }
}
