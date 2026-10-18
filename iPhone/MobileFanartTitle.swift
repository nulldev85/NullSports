import SwiftUI

struct MobileFanartTitle<Fallback: View>: View {
    @EnvironmentObject private var media: MediaLibrary
    @Environment(\.displayScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: MediaItem
    let width: CGFloat
    let height: CGFloat
    @ViewBuilder var fallback: () -> Fallback
    @State private var logo: URL?

    private var requestID: String {
        let ids = LibraryMetadataIdentity.ids(item)
        return [item.libraryKey, ids["imdb"] ?? "", ids["tmdb"] ?? "", ids["tvdb"] ?? "",
                String(media.fanartEnabled)].joined(separator: "|")
    }
    var body: some View {
        MobileLibraryArtView(url: media.fanartEnabled ? logo : nil, pixels: max(32, Int(ceil(width * max(1, scale))))) { image in
            ZStack(alignment: .leading) {
                fallback().opacity(image == nil ? 1 : 0)
                if let image {
                    image.resizable().scaledToFit().frame(width: width, height: height, alignment: .leading)
                        .shadow(color: .black.opacity(0.65), radius: 8, y: 3)
                }
            }.frame(width: width, height: height, alignment: .leading)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: image != nil)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(item.name)
        .task(id: requestID) {
            logo = nil
            guard media.fanartEnabled, MobileFanart.configured, ["Movie", "Series"].contains(item.type) else { return }
            await media.resolveMetadata(for: item)
            guard !Task.isCancelled else { return }
            var matched = media.displayItem(item)
            if Self.identity(for: matched) == nil {
                matched = await media.libraryExternalIdentity(item, requiring: item.isSeries ? "tvdb" : "imdb")
            }
            guard !Task.isCancelled, let identity = Self.identity(for: matched) else { return }
            let found = await MobileFanart.shared.logo(for: identity)
            guard !Task.isCancelled else { return }
            logo = found
        }
    }

    static func identity(for item: MediaItem) -> MobileFanartIdentity? {
        let ids = LibraryMetadataIdentity.ids(item)
        if item.type == "Series", let tvdb = ids["tvdb"] {
            return MobileFanartIdentity(kind: .series, id: tvdb)
        }
        if item.type == "Movie" {
            for provider in ["tmdb", "imdb"] {
                if let id = ids[provider], let identity = MobileFanartIdentity(kind: .movie, id: id) { return identity }
            }
        }
        return nil
    }
}
