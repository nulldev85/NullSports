import Foundation

/// Only successful public logo URLs, never API responses or credentials.
/// Remembering the URL lets the image byte cache work again after relaunch.
actor TitleLogoURLCache {
    static let shared = TitleLogoURLCache(cacheURL: FileManager.default.urls(for: .cachesDirectory,
        in: .userDomainMask).first?.appendingPathComponent("LineupTitleLogos-v1.json"))
    private struct Entry: Codable { let url: URL; let expires: Date }
    private let cacheURL: URL?
    private var entries: [String: Entry] = [:]
    private var restored = false

    init(cacheURL: URL?) { self.cacheURL = cacheURL }

    func logo(for key: String) -> URL? {
        restore()
        guard let entry = entries[key], entry.expires > Date() else { return nil }
        return entry.url
    }

    func remember(_ url: URL, for key: String) {
        guard key.count <= 4096, Self.isPublicLogo(url) else { return }
        restore()
        entries = entries.filter { $0.value.expires > Date() }
        entries[key] = Entry(url: url, expires: Date().addingTimeInterval(86_400))
        if entries.count > 256 {
            entries = Dictionary(uniqueKeysWithValues: entries.sorted { $0.value.expires > $1.value.expires }
                .prefix(256).map { ($0.key, $0.value) })
        }
        guard let cacheURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func restore() {
        guard !restored else { return }
        restored = true
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL), data.count <= 1_000_000,
              let saved = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        entries = Dictionary(uniqueKeysWithValues: saved.filter {
            $0.key.count <= 4096 && $0.value.expires > Date() && Self.isPublicLogo($0.value.url)
        }.sorted { $0.value.expires > $1.value.expires }.prefix(256).map { ($0.key, $0.value) })
    }

    private static func isPublicLogo(_ url: URL) -> Bool {
        if MobileFanartPolicy.imageURL(url.absoluteString) != nil { return true }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "image.tmdb.org",
              parts.port == nil, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.hasPrefix("/t/p/w1280/") else { return false }
        let path = String(parts.path.dropFirst("/t/p/w1280".count))
        return TMDBTitleLogoPolicy.imageURL(path) == url
    }
}
