import Foundation

actor MobileFanart {
    static let shared = MobileFanart(logoCache: .shared)
    static let bundledKey: String = {
        guard let url = Bundle.main.url(forResource: "LineupMetadata", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return "" }
        return (values["fanart"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }()
    static var configured: Bool { !bundledKey.isEmpty }
    private struct Entry { let logo: URL?; let expiry: Date }
    private let key: String
    private let session: URLSession
    private let logoCache: TitleLogoURLCache
    private var cache: [MobileFanartIdentity: Entry] = [:]
    private var running: [MobileFanartIdentity: Task<Entry, Never>] = [:]
    private var retryAfter = Date.distantPast

    init(key: String = MobileFanart.bundledKey, session: URLSession? = nil,
         logoCache: TitleLogoURLCache = TitleLogoURLCache(cacheURL: nil)) {
        self.key = key
        self.logoCache = logoCache
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.httpMaximumConnectionsPerHost = 2
            config.timeoutIntervalForResource = 7
            self.session = URLSession(configuration: config, delegate: FanartRedirects(), delegateQueue: nil)
        }
    }

    func logo(for identity: MobileFanartIdentity) async -> URL? {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let cached = cache[identity], cached.expiry > Date() { return cached.logo }
        let logoKey = "fanart|\(identity.kind.rawValue)|\(identity.id)"
        if let remembered = await logoCache.logo(for: logoKey) { return remembered }
        if let task = running[identity] { return await task.value.logo }
        guard retryAfter <= Date(), running.count < 8, let request = identity.request(key: key) else { return nil }
        let session = session
        let task = Task<Entry, Never> {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, http.url?.scheme == "https",
                      http.url?.host == "webservice.fanart.tv" else {
                    return Entry(logo: nil, expiry: Date().addingTimeInterval(60))
                }
                if http.statusCode == 429 {
                    let seconds = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
                    self.retryAfter = Date().addingTimeInterval(seconds.isFinite ? min(3600, max(1, seconds)) : 60)
                } else if http.statusCode == 401 || http.statusCode == 403 {
                    self.retryAfter = Date().addingTimeInterval(600)
                }
                guard http.statusCode == 200 else {
                    return Entry(logo: nil, expiry: Date().addingTimeInterval(http.statusCode == 404 ? 21600 : 60))
                }
                let logo = MobileFanartPolicy.logo(data, identity: identity)
                return Entry(logo: logo, expiry: Date().addingTimeInterval(logo == nil ? 21600 : 86400))
            } catch { return Entry(logo: nil, expiry: Date().addingTimeInterval(60)) }
        }
        running[identity] = task
        let entry = await task.value
        running[identity] = nil
        if cache.count >= 256 {
            cache = cache.filter { $0.value.expiry > Date() }
            if cache.count >= 256 { cache.removeAll() }
        }
        cache[identity] = entry
        if let logo = entry.logo { await logoCache.remember(logo, for: logoKey) }
        return entry.logo
    }
}

private final class FanartRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Project keys remain on the exact configured API route.
        completionHandler(nil)
    }
}
