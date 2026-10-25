import SwiftUI
import UIKit

/// The same progressive title-art path on phone and television. A faster
/// source can display while the preferred one resolves in the background.
@MainActor
final class LineupTitleArtwork: ObservableObject {
    static let pixels = 1280
    private struct Loaded { let key: String; let image: UIImage; let rank: Int }
    private final class Cached {
        let image: UIImage
        let rank: Int
        let url: URL
        let expires = Date().addingTimeInterval(86_400)
        init(image: UIImage, rank: Int, url: URL) { self.image = image; self.rank = rank; self.url = url }
    }
    private static let cache: NSCache<NSString, Cached> = {
        let value = NSCache<NSString, Cached>()
        value.countLimit = 64
        value.totalCostLimit = 48 * 1024 * 1024
        return value
    }()
    @Published private var loaded: Loaded?
    private var generation = UUID()

    static func cacheKey(for item: MediaItem, catalogEnabled: Bool) -> String {
        let raw = item.withMetadata(nil)
        return [raw.libraryKey, raw.type, raw.name, String(catalogEnabled)].joined(separator: "|")
    }

    static func ready(for cacheKey: String) -> UIImage? { cached(cacheKey)?.image }

    private static func cached(_ key: String) -> Cached? {
        guard let value = cache.object(forKey: key as NSString), value.expires > Date() else { return nil }
        return value
    }

    func image(for key: String) -> UIImage? { loaded?.key == key ? loaded?.image : nil }

    func load(key: String, pixels: Int, server: URL?, cacheKey: String? = nil,
              fanart: @escaping @MainActor () async -> URL?,
              tmdb: @escaping @MainActor () async -> URL?,
              fetch: @escaping @MainActor (URL, Int) async -> UIImage? = LineupArt.load) async {
        guard !Task.isCancelled else { return }
        let token = UUID(); generation = token
        if let cacheKey, let held = Self.cached(cacheKey) {
            let rank = held.rank == 0 && held.url != server ? Int.max : held.rank
            loaded = Loaded(key: key, image: held.image, rank: rank)
        }
        if let server, let ready = LineupArt.ready(server, pixels: pixels) {
            publish(ready, key: key, rank: 0, url: server, cacheKey: cacheKey)
            return
        }
        async let own: Void = candidate(key: key, token: token, rank: 0, pixels: pixels,
            cacheKey: cacheKey, resolve: { server }, fetch: fetch)
        async let catalog: Void = candidate(key: key, token: token, rank: 1, pixels: pixels,
            cacheKey: cacheKey, resolve: fanart, fetch: fetch)
        async let fallback: Void = candidate(key: key, token: token, rank: 2, pixels: pixels,
            cacheKey: cacheKey, resolve: tmdb, fetch: fetch)
        _ = await (own, catalog, fallback)
    }

    private func candidate(key: String, token: UUID, rank: Int, pixels: Int, cacheKey: String?,
                           resolve: @MainActor () async -> URL?,
                           fetch: @MainActor (URL, Int) async -> UIImage?) async {
        guard !Task.isCancelled, let url = await resolve(), !Task.isCancelled,
              let image = await fetch(url, pixels), !Task.isCancelled, generation == token else { return }
        guard loaded?.key != key || rank < (loaded?.rank ?? Int.max) else { return }
        publish(image, key: key, rank: rank, url: url, cacheKey: cacheKey)
    }

    private func publish(_ image: UIImage, key: String, rank: Int, url: URL, cacheKey: String?) {
        loaded = Loaded(key: key, image: image, rank: rank)
        guard let cacheKey, Self.cached(cacheKey).map({ rank <= $0.rank }) ?? true else { return }
        let cost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
        Self.cache.setObject(Cached(image: image, rank: rank, url: url), forKey: cacheKey as NSString, cost: cost)
    }
}

struct LineupTitleLogo<Fallback: View>: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: MediaItem
    let width: CGFloat
    let height: CGFloat
    var alignment: Alignment = .leading
    @ViewBuilder var fallback: () -> Fallback
    @StateObject private var artwork = LineupTitleArtwork()

    init(item: MediaItem, width: CGFloat, height: CGFloat, alignment: Alignment = .leading,
         @ViewBuilder fallback: @escaping () -> Fallback) {
        self.item = item; self.width = width; self.height = height
        self.alignment = alignment; self.fallback = fallback
    }

    private var cacheKey: String { LineupTitleArtwork.cacheKey(for: item, catalogEnabled: media.fanartEnabled) }
    private var requestID: String {
        let ids = LibraryMetadataIdentity.ids(item)
        return [cacheKey, ids["imdb"] ?? "", ids["tmdb"] ?? "", ids["tvdb"] ?? "",
                media.logoURL(for: item)?.absoluteString ?? ""].joined(separator: "|")
    }

    var body: some View {
        let image = artwork.image(for: requestID) ?? LineupTitleArtwork.ready(for: cacheKey)
            ?? LineupArt.ready(media.logoURL(for: item), pixels: LineupTitleArtwork.pixels)
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
            await artwork.load(key: requestID, pixels: LineupTitleArtwork.pixels,
                server: media.logoURL(for: subject), cacheKey: cacheKey,
                fanart: { enabled ? await media.fastFanartLogo(for: subject) : nil },
                tmdb: { enabled ? await media.tmdbTitleLogo(for: subject) : nil })
        }
    }
}
