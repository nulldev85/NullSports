import Foundation

struct MobileSubtitleIdentity: Hashable, Sendable {
    let imdb: Int
    let season: Int?
    let episode: Int?
    var type: String { episode == nil ? "movie" : "episode" }

    init?(item: MediaItem, series: MediaItem? = nil) {
        if item.type == "Episode" {
            guard let series, let exact = MobileIntroIdentity(series: series, episode: item),
                  let id = Int(exact.imdb.dropFirst(2)), id > 0 else { return nil }
            imdb = id; season = exact.season; episode = exact.episode
        } else {
            guard item.type == "Movie", let id = LibraryMetadataIdentity.ids(item)["imdb"],
                  let number = Int(id.dropFirst(2)), number > 0 else { return nil }
            imdb = number; season = nil; episode = nil
        }
    }

    var query: [URLQueryItem] {
        var result = [URLQueryItem(name: episode == nil ? "imdb_id" : "parent_imdb_id", value: String(imdb)),
                      URLQueryItem(name: "type", value: type)]
        if let season, let episode {
            result += [.init(name: "season_number", value: String(season)), .init(name: "episode_number", value: String(episode))]
        }
        return result
    }
}

struct MobileOnlineSubtitle: Identifiable, Hashable, Sendable {
    let id: Int // A downloadable file ID, not a subtitle/feature ID.
    let title: String
    let language: String
    let hearingImpaired: Bool
    let foreignOnly: Bool
}

enum MobileSubtitleFailure: LocalizedError {
    case notConfigured, identity, unavailable, quota, busy, invalidFile, unsupported
    var errorDescription: String? {
        switch self {
        case .notConfigured: "Online subtitles are not configured in this build."
        case .identity: "This title needs an IMDb match before online subtitles can be found."
        case .unavailable: "OpenSubtitles couldn't be reached. Try again in a moment."
        case .quota: "The OpenSubtitles download allowance has been reached. Try again after it resets."
        case .busy: "OpenSubtitles is limiting requests. Wait a moment before trying again."
        case .invalidFile: "That download wasn't a usable subtitle file. Try another release."
        case .unsupported: "Downloaded subtitles aren't available with the compatibility player. Use AetherEngine, VLC, or MPVKit."
        }
    }
}

actor MobileOpenSubtitles {
    static let shared = MobileOpenSubtitles()
    static let bundledKey: String = {
        guard let url = Bundle.main.url(forResource: "LineupMetadata", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return "" }
        return values["opensubtitles"] ?? ""
    }()
    static var configured: Bool { !bundledKey.isEmpty }
    private struct CacheKey: Hashable { let identity: MobileSubtitleIdentity; let language: String }
    private let key: String
    private let session: URLSession
    private var cache: [CacheKey: (Date, [MobileOnlineSubtitle])] = [:]
    private var retryAfter = Date.distantPast
    private var downloads: [Int: (Date, Data)] = [:]

    init(key: String = MobileOpenSubtitles.bundledKey, session: URLSession? = nil) {
        self.key = key
        if let session { self.session = session } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForResource = 25
            self.session = URLSession(configuration: config, delegate: SubtitleRedirectGuard(), delegateQueue: nil)
        }
    }

    func search(_ identity: MobileSubtitleIdentity, language: String) async throws -> [MobileOnlineSubtitle] {
        guard Self.validLanguage(language) else { return [] }
        let cacheKey = CacheKey(identity: identity, language: language)
        if let entry = cache[cacheKey], entry.0 > Date() { return entry.1 }
        let data = try await request("subtitles", query: identity.query + [.init(name: "languages", value: language)])
        let results = try Self.results(data, identity: identity, language: language)
        try Task.checkCancellation()
        if cache.count >= 128 { cache.removeAll() }
        cache[cacheKey] = (Date().addingTimeInterval(600), results)
        return results
    }

    func download(_ subtitle: MobileOnlineSubtitle) async throws -> Data {
        guard subtitle.id > 0 else { throw MobileSubtitleFailure.invalidFile }
        if let cached = downloads[subtitle.id], cached.0 > Date() { return cached.1 }
        let body = try JSONSerialization.data(withJSONObject: ["file_id": subtitle.id, "sub_format": "srt", "strip_html": true])
        let reply = try await request("download", body: body)
        struct Download: Decodable { let link: URL }
        guard let link = try? JSONDecoder().decode(Download.self, from: reply).link,
              Self.allowedDownload(link) else { throw MobileSubtitleFailure.invalidFile }
        // This request deliberately has no application API key or user token.
        let (data, response) = try await session.data(for: URLRequest(url: link, timeoutInterval: 15))
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let normalized = Self.normalizedSubtitle(data) else { throw MobileSubtitleFailure.invalidFile }
        if downloads.count >= 8 || downloads.values.reduce(0, { $0 + $1.1.count }) + normalized.count > 8_000_000 { downloads.removeAll() }
        downloads[subtitle.id] = (Date().addingTimeInterval(600), normalized)
        return normalized
    }

    private func request(_ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        guard !key.isEmpty else { throw MobileSubtitleFailure.notConfigured }
        guard Date() >= retryAfter else { throw MobileSubtitleFailure.busy }
        var url = URLComponents(string: "https://api.opensubtitles.com/api/v1/" + path)!
        if !query.isEmpty { url.queryItems = query.sorted { $0.name < $1.name } }
        var request = URLRequest(url: url.url!, timeoutInterval: 15)
        request.setValue(key, forHTTPHeaderField: "Api-Key")
        request.setValue("Lineup v0.19.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"; request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, data.count <= 5_000_000 else { throw MobileSubtitleFailure.unavailable }
        if http.statusCode == 406 { throw MobileSubtitleFailure.quota }
        if http.statusCode == 429 {
            let delay = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            retryAfter = Date().addingTimeInterval(delay.isFinite ? min(3600, max(1, delay)) : 60)
            throw MobileSubtitleFailure.busy
        }
        guard http.statusCode == 200 else { throw MobileSubtitleFailure.unavailable }
        return data
    }

    static func results(_ data: Data, identity: MobileSubtitleIdentity, language: String) throws -> [MobileOnlineSubtitle] {
        struct Feature: Decodable, Sendable {
            let feature_type: String
            let imdb_id: Int
            let parent_imdb_id: Int?
            let season_number: Int?
            let episode_number: Int?
        }
        struct File: Decodable, Sendable { let file_id: Int; let file_name: String?; let cd_number: Int? }
        struct Attributes: Decodable, Sendable {
            let language: String
            let release: String?
            let hearing_impaired: Bool?
            let foreign_parts_only: Bool?
            let feature_details: Feature
            let files: [File]
        }
        struct Row: Decodable, Sendable { let attributes: Attributes }
        struct Reply: Decodable { let data: [Lenient<Row>] }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        var seen: Set<Int> = []
        return reply.data.compactMap(\.value).flatMap { row -> [MobileOnlineSubtitle] in
            let value = row.attributes, feature = value.feature_details
            guard value.language == language, feature.feature_type.lowercased() == identity.type else { return [] }
            if identity.episode == nil {
                guard feature.imdb_id == identity.imdb else { return [] }
            } else {
                guard feature.parent_imdb_id == identity.imdb, feature.season_number == identity.season,
                      feature.episode_number == identity.episode else { return [] }
            }
            // Multipart subtitles need a timeline for each part. Do not attach
            // only CD1 to a complete movie and call it a matching subtitle.
            guard value.files.count == 1 else { return [] }
            return value.files.compactMap { file in
                guard file.file_id > 0, (file.cd_number ?? 1) <= 1, seen.insert(file.file_id).inserted else { return nil }
                return MobileOnlineSubtitle(id: file.file_id, title: value.release ?? file.file_name ?? "Subtitle",
                    language: value.language, hearingImpaired: value.hearing_impaired ?? false, foreignOnly: value.foreign_parts_only ?? false)
            }
        }
    }

    static func validLanguage(_ code: String) -> Bool {
        code.range(of: "^[a-z]{2}(-[a-z]{2})?$", options: .regularExpression) != nil
    }
    static func allowedDownload(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return ["opensubtitles.com", "opensubtitles.org"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
    static func allowedRedirect(_ request: URLRequest, original: URLRequest?) -> URLRequest? {
        guard let url = request.url, allowedDownload(url) else { return nil }
        if original?.value(forHTTPHeaderField: "Api-Key") != nil,
           !["api.opensubtitles.com", "vip-api.opensubtitles.com"].contains(url.host?.lowercased() ?? "") { return nil }
        return request
    }
    static func normalizedSubtitle(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count <= 5_000_000 else { return nil }
        for encoding in [String.Encoding.utf8, .utf16, .isoLatin1] {
            guard let raw = String(data: data, encoding: encoding) else { continue }
            let text = raw.replacingOccurrences(of: "\u{feff}", with: "")
            if text.range(of: "(?m)^\\s*\\d+\\s*\\r?\\n\\d{1,3}:[0-5]\\d:[0-5]\\d[,\\.]\\d{3}\\s+-->\\s+\\d{1,3}:[0-5]\\d:[0-5]\\d[,\\.]\\d{3}", options: .regularExpression) != nil {
                return Data(text.utf8)
            }
        }
        return nil
    }
}

private final class SubtitleRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(MobileOpenSubtitles.allowedRedirect(request, original: task.originalRequest))
    }
}

extension MediaLibrary {
    func onlineSubtitleIdentity(for item: MediaItem) async -> MobileSubtitleIdentity? {
        if item.type == "Episode" {
            guard let parent = await metadataParent(for: item) else { return nil }
            let series = await libraryExternalIdentity(parent)
            return MobileSubtitleIdentity(item: item, series: series)
        }
        let matched = await libraryExternalIdentity(item)
        return MobileSubtitleIdentity(item: matched)
    }
}
