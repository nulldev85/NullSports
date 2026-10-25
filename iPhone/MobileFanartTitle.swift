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
    @StateObject private var artwork = MobileTitleArtwork()

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
                String(media.fanartEnabled), media.logoURL(for: item)?.absoluteString ?? "",
                String(pixels)].joined(separator: "|")
    }
    private var pixels: Int { max(32, Int(ceil(width * max(1, scale)))) }
    var body: some View {
        let image = artwork.image(for: requestID) ?? LineupArt.ready(media.logoURL(for: item), pixels: pixels)
        ZStack(alignment: alignment) {
            fallback().opacity(image == nil ? 1 : 0)
            if let image {
                Image(uiImage: image).resizable().scaledToFit().frame(width: width, height: height, alignment: alignment)
                    .shadow(color: .black.opacity(0.65), radius: 8, y: 3)
                    .id(ObjectIdentifier(image)).transition(.opacity)
            }
        }.frame(width: width, height: height, alignment: alignment)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: image.map { ObjectIdentifier($0) })
        .accessibilityElement(children: .ignore).accessibilityLabel(item.name)
        .task(id: requestID) {
            let subject = item, enabled = media.fanartEnabled
            await artwork.load(key: requestID, pixels: pixels, server: media.logoURL(for: subject),
                fanart: { enabled ? await media.fastFanartLogo(for: subject) : nil },
                tmdb: { enabled ? await media.tmdbTitleLogo(for: subject) : nil })
        }
    }

    static func identity(for item: MediaItem) -> MobileFanartIdentity? { MobileFanartIdentity(item: item) }
}
