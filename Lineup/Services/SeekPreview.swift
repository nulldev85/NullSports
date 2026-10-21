import Foundation
import UIKit
import ImageIO
import Combine

/// Jellyfin's documented Trickplay DTO. Interval is milliseconds; TileWidth
/// and TileHeight count cells, not pixels. Never borrow another media version.
struct MobileSeekPreviewInfo: Decodable, Equatable, Sendable {
    let width: Int, height: Int, columns: Int, rows: Int, count: Int, interval: Int
    enum CodingKeys: String, CodingKey {
        case width = "Width", height = "Height", columns = "TileWidth", rows = "TileHeight"
        case count = "ThumbnailCount", interval = "Interval"
    }
    var valid: Bool {
        (1...640).contains(width) && (1...640).contains(height) && (1...20).contains(columns)
            && (1...20).contains(rows) && (1...1_000_000).contains(count) && (100...120_000).contains(interval)
            && width * columns * height * rows <= 10_000_000
    }
    func index(at seconds: Double) -> Int? {
        guard valid, seconds.isFinite, seconds >= 0 else { return nil }
        return Int(min(Double(count - 1), (seconds * 1000 / Double(interval)).rounded(.down)))
    }
    func sheet(for index: Int) -> Int { index / (columns * rows) }
    func rect(for index: Int) -> CGRect {
        let cell = index % (columns * rows)
        return CGRect(x: CGFloat((cell % columns) * width), y: CGFloat((cell / columns) * height),
                      width: CGFloat(width), height: CGFloat(height))
    }
}

struct MobileSeekPreviewSource: Sendable {
    let info: MobileSeekPreviewInfo
    let firstTile: URLRequest
    func request(sheet: Int) -> URLRequest? {
        guard info.valid, sheet >= 0, sheet <= info.sheet(for: info.count - 1),
              let url = firstTile.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let prefix = (parts.percentEncodedPath as NSString).deletingLastPathComponent
        parts.percentEncodedPath = prefix + "/\(sheet).jpg"
        var request = firstTile
        request.url = parts.url
        request.timeoutInterval = 4
        return request.url == nil ? nil : request
    }
    static func versionKey(_ value: String) -> String? {
        let clean = value.lowercased().replacingOccurrences(of: "-", with: "")
        return clean.count == 32 && clean.allSatisfy(\.isHexDigit) ? clean : nil
    }
    static func select(_ data: Data, mediaSourceID: String) -> (String, MobileSeekPreviewInfo)? {
        struct Reply: Decodable { let Trickplay: [String: [String: Lenient<MobileSeekPreviewInfo>]]? }
        guard data.count <= 2_000_000, let selected = versionKey(mediaSourceID),
              let reply = try? JSONDecoder().decode(Reply.self, from: data),
              let match = reply.Trickplay?.first(where: { Self.versionKey($0.key) == selected }) else { return nil }
        let options = match.value.values.compactMap(\.value).filter(\.valid)
        // Prefer the smallest useful tile rather than fetching a 4K storyboard.
        guard let info = options.filter({ $0.width >= 320 }).min(by: { $0.width < $1.width })
                ?? options.max(by: { $0.width < $1.width }) else { return nil }
        return (match.key, info)
    }
}

/// Immutable, decoded pixels may safely cross from the image actor to UIKit.
struct MobileSeekPreviewFrame: @unchecked Sendable {
    let index: Int
    let image: CGImage
}

actor MobileSeekPreviewImages {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let source: MobileSeekPreviewSource
    private let fetch: Fetch
    private var sheets: [Int: CGImage] = [:]
    private var frames: [Int: MobileSeekPreviewFrame] = [:]
    private var failures: [Int: Date] = [:]
    private var lastRequest = -Double.infinity
    init(source: MobileSeekPreviewSource, fetch: Fetch? = nil) {
        self.source = source
        self.fetch = fetch ?? { request in try await MobileSeekPreviewTransport.shared.data(for: request) }
    }

    func frame(at index: Int) async throws -> MobileSeekPreviewFrame? {
        guard source.info.valid, (0..<source.info.count).contains(index) else { return nil }
        if let cached = frames[index] { return cached }
        let sheet = source.info.sheet(for: index)
        if let until = failures[sheet], until > Date() { return nil }
        if failures.count >= 64 { failures.removeAll() }
        let image: CGImage
        if let cached = sheets[sheet] { image = cached } else {
            guard let request = source.request(sheet: sheet) else { return nil }
            do {
                // A finger oscillating across a tile boundary must not start
                // a request for every gesture callback. Cached crops never wait.
                while lastRequest + 0.12 > ProcessInfo.processInfo.systemUptime {
                    try await Task.sleep(for: .seconds(max(0, lastRequest + 0.12 - ProcessInfo.processInfo.systemUptime)))
                }
                try Task.checkCancellation()
                lastRequest = ProcessInfo.processInfo.systemUptime
                let (data, response) = try await fetch(request)
                try Task.checkCancellation()
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 8_000_000,
                      let decoded = Self.decode(data, info: source.info) else {
                    failures[sheet] = Date().addingTimeInterval(30); return nil
                }
                if sheets.values.reduce(0, { $0 + $1.bytesPerRow * $1.height }) + decoded.bytesPerRow * decoded.height > 48_000_000
                    || sheets.count >= 2 { sheets.removeAll() }
                sheets[sheet] = decoded
                image = decoded
            } catch {
                if !Task.isCancelled { failures[sheet] = Date().addingTimeInterval(30) }
                throw error
            }
        }
        try Task.checkCancellation()
        if frames.count > 21 { frames.removeAll() }
        // Adjacent cells cost only a small crop; no additional media connection.
        for cell in [index, index + 1, index - 1] where (0..<source.info.count).contains(cell) && source.info.sheet(for: cell) == sheet {
            if frames[cell] == nil, let pixels = Self.crop(image, rect: source.info.rect(for: cell)) {
                frames[cell] = MobileSeekPreviewFrame(index: cell, image: pixels)
            }
        }
        return frames[index]
    }

    static func decode(_ data: Data, info: MobileSeekPreviewInfo) -> CGImage? {
        guard info.valid, !data.isEmpty, data.count <= 8_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width == info.width * info.columns, height > 0, height <= info.height * info.rows,
              width * height <= 10_000_000 else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
    static func crop(_ image: CGImage, rect: CGRect) -> CGImage? {
        guard CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)).contains(rect),
              let cropped = image.cropping(to: rect) else { return nil }
        let width = min(320, Int(rect.width)), height = max(1, Int(CGFloat(width) * rect.height / rect.width))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return context.makeImage() // independent pixels, not a retained large JPEG backing
    }
}

@MainActor
final class MobileSeekPreviewSession: ObservableObject {
    // Do not forward frame publications to the fullscreen player/video host.
    let store = MobileSeekPreviewStore()
}

@MainActor
final class MobileSeekPreviewStore: ObservableObject {
    @Published private(set) var frame: MobileSeekPreviewFrame?
    @Published private(set) var source: MobileSeekPreviewSource?
    private var images: MobileSeekPreviewImages?
    private var work: Task<Void, Never>?
    private var latest: Int?
    private var wanted: Int?
    private var runningSheet: Int?
    private var generation = UUID()
    func configure(_ source: MobileSeekPreviewSource?, fetch: MobileSeekPreviewImages.Fetch? = nil) {
        cancel(); self.source = source; frame = nil
        images = source.map { value in
            if let fetch { return MobileSeekPreviewImages(source: value, fetch: fetch) }
            return MobileSeekPreviewImages(source: value)
        }
    }
    func request(at seconds: Double) {
        guard let source, let images, let index = source.info.index(at: seconds), index != latest else { return }
        latest = index; wanted = index
        let sheet = source.info.sheet(for: index)
        if runningSheet != nil, runningSheet != sheet { work?.cancel(); work = nil; generation = UUID() }
        guard work == nil else { return }
        runningSheet = sheet
        let token = generation
        work = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.work = nil; self.runningSheet = nil } }
            while let requested = self.wanted, !Task.isCancelled, self.generation == token {
                self.wanted = nil
                let result = try? await images.frame(at: requested)
                guard !Task.isCancelled, self.generation == token else { return }
                if self.latest == requested { self.frame = result }
            }
        }
    }
    func cancel() {
        generation = UUID(); work?.cancel(); work = nil; latest = nil; wanted = nil; runningSheet = nil; frame = nil
    }
}

private enum MobileSeekPreviewTransport {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 6
        config.httpMaximumConnectionsPerHost = 2
        config.urlCache = nil
        return URLSession(configuration: config, delegate: SameOriginPreviewRedirect(), delegateQueue: nil)
    }()
}
private final class SameOriginPreviewRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let target = request.url,
              original.scheme == target.scheme, original.host == target.host, original.port == target.port else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}
