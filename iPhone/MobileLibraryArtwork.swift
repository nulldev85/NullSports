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
}

@MainActor
final class MobileLibraryArtwork: ObservableObject {
    private struct Loaded {
        let request: MobileLibraryArtworkRequest
        let image: UIImage?
    }
    @Published private var loaded: Loaded?
    private var generation = UUID()

    func image(for request: MobileLibraryArtworkRequest) -> UIImage? {
        loaded?.request == request ? loaded?.image : nil
    }

    func load(_ request: MobileLibraryArtworkRequest,
              cached: (URL?, Int) -> UIImage? = LineupArt.ready,
              fetch: (URL, Int) async -> UIImage? = LineupArt.load) async {
        guard !Task.isCancelled else { return }
        let token = UUID()
        generation = token
        guard let url = request.url else {
            loaded = nil
            return
        }
        if let image = cached(url, request.pixels) {
            loaded = Loaded(request: request, image: image)
            return
        }
        // The shared download survives recycling to warm the cache. Its old
        // subscriber must not publish into a cell now showing a different item.
        let image = await fetch(url, request.pixels)
        guard !Task.isCancelled, generation == token else { return }
        loaded = Loaded(request: request, image: image)
    }
}

struct MobileLibraryArtView<Content: View>: View {
    let url: URL?
    let pixels: Int
    @ViewBuilder var content: (Image?) -> Content
    @StateObject private var artwork = MobileLibraryArtwork()

    var body: some View {
        let request = MobileLibraryArtworkRequest(url: url, pixels: pixels)
        content((artwork.image(for: request) ?? LineupArt.ready(url, pixels: pixels)).map { Image(uiImage: $0) })
            .task(id: request) { await artwork.load(request) }
    }
}

/// Held by the screen, observed only by the carousel. A change in scroll phase
/// must pause rotation without rebuilding every shelf and its tracking state.
@Observable
final class MobileLibraryScrollActivity {
    var isActive = false
}
