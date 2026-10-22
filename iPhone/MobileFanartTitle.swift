import SwiftUI

struct MobileFanartTitle<Fallback: View>: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.displayScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: MediaItem
    let width: CGFloat
    let height: CGFloat
    let alignment: Alignment
    @ViewBuilder var fallback: () -> Fallback
    @State private var logo: URL?

    init(item: MediaItem, width: CGFloat, height: CGFloat, alignment: Alignment = .leading,
         @ViewBuilder fallback: @escaping () -> Fallback) {
        self.item = item
        self.width = width
        self.height = height
        self.alignment = alignment
        self.fallback = fallback
    }

    private var requestID: String {
        let ids = LibraryMetadataIdentity.ids(item)
        return [item.libraryKey, ids["imdb"] ?? "", ids["tmdb"] ?? "", ids["tvdb"] ?? "",
                String(media.fanartEnabled)].joined(separator: "|")
    }
    var body: some View {
        MobileLibraryArtView(url: media.fanartEnabled ? logo : nil, pixels: max(32, Int(ceil(width * max(1, scale))))) { image in
            ZStack(alignment: alignment) {
                fallback().opacity(image == nil ? 1 : 0)
                if let image {
                    image.resizable().scaledToFit().frame(width: width, height: height, alignment: alignment)
                        .shadow(color: .black.opacity(0.65), radius: 8, y: 3)
                }
            }.frame(width: width, height: height, alignment: alignment)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: image != nil)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(item.name)
        .task(id: requestID) {
            logo = nil
            let found = await media.titleLogo(for: item)
            guard !Task.isCancelled else { return }
            logo = found
        }
    }

    static func identity(for item: MediaItem) -> MobileFanartIdentity? { MobileFanartIdentity(item: item) }
}
