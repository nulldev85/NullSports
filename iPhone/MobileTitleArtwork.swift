import SwiftUI
import UIKit

/// Each source can publish its first usable image immediately. A slow catalog
/// never holds a faster source behind it; recycled titles reject old responses.
@MainActor
final class MobileTitleArtwork: ObservableObject {
    private struct Loaded { let key: String; let image: UIImage; let rank: Int }
    @Published private var loaded: Loaded?
    private var generation = UUID()

    func image(for key: String) -> UIImage? { loaded?.key == key ? loaded?.image : nil }

    func load(key: String, pixels: Int, server: URL?,
              fanart: @escaping @MainActor () async -> URL?,
              tmdb: @escaping @MainActor () async -> URL?,
              fetch: @escaping @MainActor (URL, Int) async -> UIImage? = LineupArt.load) async {
        guard !Task.isCancelled else { return }
        let token = UUID(); generation = token
        if let server, let ready = LineupArt.ready(server, pixels: pixels) {
            loaded = Loaded(key: key, image: ready, rank: 0)
            return
        }
        async let own: Void = candidate(key: key, token: token, rank: 0, pixels: pixels, resolve: { server }, fetch: fetch)
        async let catalog: Void = candidate(key: key, token: token, rank: 1, pixels: pixels, resolve: fanart, fetch: fetch)
        async let fallback: Void = candidate(key: key, token: token, rank: 2, pixels: pixels, resolve: tmdb, fetch: fetch)
        _ = await (own, catalog, fallback)
    }

    private func candidate(key: String, token: UUID, rank: Int, pixels: Int,
                           resolve: @MainActor () async -> URL?,
                           fetch: @MainActor (URL, Int) async -> UIImage?) async {
        guard !Task.isCancelled, let url = await resolve(), !Task.isCancelled,
              let image = await fetch(url, pixels), !Task.isCancelled, generation == token else { return }
        guard loaded?.key != key || rank < (loaded?.rank ?? Int.max) else { return }
        loaded = Loaded(key: key, image: image, rank: rank)
    }
}
