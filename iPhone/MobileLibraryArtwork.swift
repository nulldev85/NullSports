import SwiftUI
import Observation
import UIKit

/// The server needs a pixel width; ImageIO needs the longest edge. A portrait
/// decoded with its width as the longest edge is undersized on a Retina screen.
struct MobileLibraryArtworkSize: Equatable {
    let width: Int
    let longestEdge: Int

    init(width: CGFloat, ratio: CGFloat, scale: CGFloat) {
        let pixelWidth = max(32, ceil(width * max(1, scale)))
        self.width = Int(pixelWidth)
        longestEdge = Int(ceil(pixelWidth / min(1, max(0.1, ratio))))
    }
}

struct MobileLibraryArtworkRequest: Hashable {
    let url: URL?
    let pixels: Int
    var fallbackURL: URL? = nil

    init(url: URL?, pixels: Int, fallbackURL: URL? = nil) {
        self.url = url
        self.pixels = pixels
        self.fallbackURL = fallbackURL == url ? nil : fallbackURL
    }
}

@MainActor
final class MobileLibraryArtwork: ObservableObject {
    private struct Loaded {
        let request: MobileLibraryArtworkRequest
        let image: UIImage?
    }
    @Published private var loaded: Loaded?
    @Published private var activeRequest: MobileLibraryArtworkRequest?
    private var generation = UUID()

    func image(for request: MobileLibraryArtworkRequest) -> UIImage? {
        loaded?.request == request ? loaded?.image : nil
    }

    func isLoading(for request: MobileLibraryArtworkRequest) -> Bool {
        activeRequest == request
    }

    func hasSettled(for request: MobileLibraryArtworkRequest) -> Bool {
        loaded?.request == request
    }

    func load(_ request: MobileLibraryArtworkRequest,
              cached: (URL?, Int) -> UIImage? = LineupArt.ready,
              fetch: (URL, Int) async -> UIImage? = LineupArt.load) async {
        guard !Task.isCancelled else { return }
        let token = UUID()
        generation = token
        let candidates = [request.url, request.fallbackURL].compactMap { $0 }
        guard !candidates.isEmpty else {
            activeRequest = nil
            loaded = nil
            return
        }
        for url in candidates {
            if let image = cached(url, request.pixels) {
                activeRequest = nil
                loaded = Loaded(request: request, image: image)
                return
            }
        }
        activeRequest = request
        // The shared download survives recycling to warm the cache. Its old
        // subscriber must not publish into a cell now showing a different item.
        var found: UIImage?
        for url in candidates {
            if let image = await fetch(url, request.pixels) {
                found = image
                break
            }
            guard !Task.isCancelled, generation == token else { return }
        }
        guard !Task.isCancelled, generation == token else { return }
        activeRequest = nil
        loaded = Loaded(request: request, image: found)
    }
}

struct MobileLibraryArtView<Content: View>: View {
    let url: URL?
    var fallbackURL: URL? = nil
    let pixels: Int
    private let content: (Image?, Bool) -> Content
    @StateObject private var artwork = MobileLibraryArtwork()

    init(url: URL?, fallbackURL: URL? = nil, pixels: Int, @ViewBuilder content: @escaping (Image?) -> Content) {
        self.url = url
        self.fallbackURL = fallbackURL
        self.pixels = pixels
        self.content = { image, _ in content(image) }
    }

    init(url: URL?, fallbackURL: URL? = nil, pixels: Int, @ViewBuilder content: @escaping (Image?, Bool) -> Content) {
        self.url = url
        self.fallbackURL = fallbackURL
        self.pixels = pixels
        self.content = content
    }

    var body: some View {
        let request = MobileLibraryArtworkRequest(url: url, pixels: pixels, fallbackURL: fallbackURL)
        let ready = artwork.image(for: request)
            ?? LineupArt.ready(url, pixels: pixels)
            ?? LineupArt.ready(fallbackURL, pixels: pixels)
        let hasCandidate = url != nil || fallbackURL != nil
        let loading = ready == nil && hasCandidate && (artwork.isLoading(for: request) || !artwork.hasSettled(for: request))
        content(ready.map { Image(uiImage: $0) }, loading)
            .task(id: request) { await artwork.load(request) }
    }
}

/// Held by the screen, observed only by the carousel. A change in scroll phase
/// must pause rotation without rebuilding every shelf and its tracking state.
@Observable
final class MobileLibraryScrollActivity {
    var isActive = false
}
