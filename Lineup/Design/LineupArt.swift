import ImageIO
import SwiftUI
import UIKit

/// Artwork fetched once, decoded once, and kept.
///
/// Every picture in the app came through `AsyncImage`, which is written for a
/// picture that appears once and stays. In a scrolling list it is the wrong
/// shape entirely: a row scrolled off is torn down, and the row that takes its
/// place starts the same download over from nothing, every time. Nothing is
/// remembered between the two.
///
/// What that costs is paid on the main thread, a frame at a time. A JPEG is
/// decoded where it is drawn, at whatever size the server sent -- a 600-pixel
/// poster for a 150-point cell, a channel logo at its full original size for a
/// 44-point badge -- and a full-size decode is megabytes of pixels produced to
/// be thrown away by the downscale in the next breath. Do that for the rows
/// arriving during a flick and the frame is late. That is the stutter.
///
/// So: the bytes are fetched once, decoded once, off the main thread, at the
/// size they will actually be drawn, and the result is held. A cell scrolling
/// back into view finds its picture already made and draws it in the same
/// frame it appears -- no request, no decode, no flash of the placeholder.
enum LineupArt {
    /// Decoded, already sized to its cell. The cost is the pixels, so that is
    /// what the limit counts.
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    /// Art the app asked for and the server did not have. A channel list is
    /// full of these, and without remembering them every recycled row asks
    /// again and waits for the same 404.
    ///
    /// Only a real answer goes in here. Recording a cancelled request as
    /// missing is how the detail page lost its artwork: opening it tears the
    /// hero down and rebuilds it once as the page settles, the first request
    /// was cancelled by that, and the rebuilt view then found the address
    /// marked as having nothing behind it -- for the rest of the session.
    private static let missing = Missing()

    private final class Missing: @unchecked Sendable {
        private var keys: Set<String> = []
        private let lock = NSLock()
        func contains(_ key: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return keys.contains(key)
        }
        func insert(_ key: String) {
            lock.lock(); defer { lock.unlock() }
            keys.insert(key)
        }
    }

    /// Loads already running, by key.
    ///
    /// Two things come from this. A picture two views want at once is fetched
    /// once, and -- the reason it exists -- a fetch outlives whoever asked for
    /// it. A view's `.task` dies when the view does, and a download killed
    /// halfway leaves nothing behind for the view that replaces it.
    private static let running = Running()

    private final class Running: @unchecked Sendable {
        private var tasks: [String: Task<UIImage?, Never>] = [:]
        private let lock = NSLock()

        /// The task for this key, starting one only if there is not one
        /// already. Unstructured on purpose: an unstructured task is not
        /// cancelled when the caller awaiting it is.
        func task(_ key: String, start: @escaping () async -> UIImage?) -> Task<UIImage?, Never> {
            lock.lock()
            if let existing = tasks[key] {
                lock.unlock()
                return existing
            }
            let task = Task { [weak self] () -> UIImage? in
                let image = await start()
                self?.finish(key)
                return image
            }
            tasks[key] = task
            lock.unlock()
            return task
        }

        private func finish(_ key: String) {
            lock.lock(); defer { lock.unlock() }
            tasks[key] = nil
        }
    }

    /// Its own session, because the shared one's cache is small enough that
    /// artwork evicts itself between launches. Cached bytes are preferred to a
    /// fresh check outright: a poster reissued on the server stays as it was
    /// until the cache drops it, which is the right trade for a picture that
    /// otherwise costs a round trip every time a shelf scrolls past.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024,
                                          diskCapacity: 256 * 1024 * 1024)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: configuration)
    }()

    private static func key(_ url: URL, _ pixels: Int) -> NSString {
        "\(url.absoluteString)|\(pixels)" as NSString
    }

    /// The longest edge, in pixels, the drawn art can use. Worked out once
    /// where the view is made, and carried from there as a plain number, so
    /// nothing downstream has to ask UIKit anything off the main thread.
    static func pixels(for width: CGFloat) -> Int {
        let scale = UITraitCollection.current.displayScale
        return max(32, Int((width * (scale > 0 ? scale : 2)).rounded(.up)))
    }

    /// What a view can draw this instant, without waiting for anything. A row
    /// coming back into view is answered from here, which is the whole point.
    static func ready(_ url: URL?, pixels: Int) -> UIImage? {
        guard let url else { return nil }
        return cache.object(forKey: key(url, pixels))
    }

    static func load(_ url: URL, pixels: Int) async -> UIImage? {
        let key = key(url, pixels) as String
        if let held = cache.object(forKey: key as NSString) { return held }
        if missing.contains(key) { return nil }
        return await running.task(key) { await fetch(url, pixels: pixels, key: key) }.value
    }

    /// One trip for one picture: bytes, then pixels, then kept.
    private static func fetch(_ url: URL, pixels: Int, key: String) async -> UIImage? {
        do {
            // A file:// or data: URL reaches this too; URLSession handles both.
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                // Only an answer that will not change is worth remembering.
                // The server saying it has no such picture is one; the server
                // having a bad minute is not, and writing those down would
                // empty every shelf in the app for anyone who opened it on a
                // weak connection.
                if http.statusCode == 404 || http.statusCode == 410 { missing.insert(key) }
                return nil
            }
            guard let image = await decode(data, to: pixels) else {
                // Bytes that are not a picture will not become one.
                missing.insert(key)
                return nil
            }
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            cache.setObject(image, forKey: key as NSString, cost: cost)
            return image
        } catch {
            // Cancelled, timed out, no route to the host: none of it is an
            // answer about the picture, so none of it is remembered. Asking
            // again later is the whole point.
            return nil
        }
    }

    /// Decoding happens here and not at the point it is drawn, which is the
    /// difference between paying for it off the main thread and paying for it
    /// during a scroll. ImageIO produces the reduced image directly from the
    /// file, so the full-size one is never built at all.
    private static func decode(_ data: Data, to pixels: Int) async -> UIImage? {
        await Task.detached(priority: .utility) { () -> UIImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false
            ] as CFDictionary) else { return nil }
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                // The decoded pixels are produced now, on this thread, rather
                // than lazily the first time the image is drawn.
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels
            ] as CFDictionary
            if let reduced = CGImageSourceCreateThumbnailAtIndex(source, 0, options) {
                return UIImage(cgImage: reduced)
            }
            // Whatever ImageIO could not read, UIKit still might.
            return UIImage(data: data)
        }.value
    }
}

/// A picture from the network, drawn through `LineupArt`.
///
/// Shaped like `AsyncImage` on purpose -- the content closure is handed the
/// image once there is one, and nil until then -- so a call site reads the
/// same either way. What differs is underneath: a cached picture is present
/// on the very first render rather than one frame later, and scrolling past a
/// row and back costs nothing.
struct LineupArtView<Content: View>: View {
    private let url: URL?
    private let pixels: Int
    private let content: (Image?) -> Content
    @State private var loaded: UIImage?

    /// - Parameter width: the width the art is drawn at, in points. It decides
    ///   what size is decoded and kept, so it should be the real drawn width
    ///   rather than the size of the file on the server.
    init(url: URL?, width: CGFloat, @ViewBuilder content: @escaping (Image?) -> Content) {
        let pixels = LineupArt.pixels(for: width)
        self.url = url
        self.pixels = pixels
        self.content = content
        // Not `.task` and not `.onAppear`: both land a frame after the row is
        // already on screen, which is the flash of grey that makes a fast
        // scroll look broken even when the picture was in hand the whole time.
        _loaded = State(initialValue: LineupArt.ready(url, pixels: pixels))
    }

    var body: some View {
        // The cache is asked again here, not just in `init`. A view rebuilt
        // while its own load was in flight keeps its identity and its empty
        // state, so without this it would sit blank over a picture that had
        // since been made and put away.
        content((loaded ?? LineupArt.ready(url, pixels: pixels)).map { Image(uiImage: $0) })
            .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            if loaded != nil { loaded = nil }
            return
        }
        // It may already be made -- by this view's own init, or by whichever
        // row asked for the same picture first.
        if let held = LineupArt.ready(url, pixels: pixels) {
            if loaded !== held { loaded = held }
            return
        }
        // A row reused for a different title keeps its old picture until this
        // point and no further: showing the last one under the new name is
        // worse than showing none.
        if loaded != nil { loaded = nil }
        loaded = await LineupArt.load(url, pixels: pixels)
    }
}
