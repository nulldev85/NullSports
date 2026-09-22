import Foundation

/// The small, read-only portion of MDBList used by Lineup: account identity,
/// the viewer's lists, and the items in one list. API keys are supplied only as
/// the documented query parameter and are never persisted by this client.
struct MDBListClient: Sendable {
    private let apiKey: String
    private let session: URLSession
    private let baseURL = URL(string: "https://api.mdblist.com")!

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    func account() async throws -> MDBListAccount {
        let value = try await get(path: "user")
        guard let object = value as? [String: Any],
              let username = Self.string(object["username"]), !username.isEmpty else {
            throw MDBListError.invalidResponse
        }
        return MDBListAccount(
            username: username,
            name: Self.string(object["name"]),
            plan: Self.string(object["plan"]),
            dailyLimit: Self.integer(object["api_requests"]),
            requestsUsed: Self.integer(object["api_requests_count"])
        )
    }

    func lists() async throws -> [MDBListCatalog] {
        let value = try await get(path: "lists/user", query: [
            URLQueryItem(name: "sort", value: "ranked"),
            URLQueryItem(name: "unified", value: "true")
        ])
        guard let values = value as? [[String: Any]] else { throw MDBListError.invalidResponse }
        return values.compactMap { object in
            guard let id = Self.integer(object["id"]),
                  let name = Self.string(object["name"]), !name.isEmpty else { return nil }
            return MDBListCatalog(id: id, name: name, slug: Self.string(object["slug"]),
                                  itemCount: Self.integer(object["items"]),
                                  likes: Self.integer(object["likes"]))
        }
    }

    func items(in listID: Int, limit: Int = 100) async throws -> [MDBListCatalogItem] {
        let value = try await get(path: "lists/\(listID)/items", query: [
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 1_000))),
            URLQueryItem(name: "append_to_response", value: "poster,description,genres")
        ])
        guard let object = value as? [String: Any] else { throw MDBListError.invalidResponse }
        var result: [MDBListCatalogItem] = []
        result += Self.items(in: object["movies"], fallbackType: "movie")
        result += Self.items(in: object["shows"], fallbackType: "show")
        // Some list modes return a unified bucket. Accept it without making
        // the normal movie/show response dependent on it.
        result += Self.items(in: object["items"], fallbackType: nil)
        var seen: Set<String> = []
        return result.sorted { ($0.rank ?? .max) < ($1.rank ?? .max) }.filter { item in
            let identity = item.imdbID ?? item.tmdbID.map { "tmdb:" + $0 }
                ?? "\(item.mediaType)|\(item.title.lowercased())|\(item.releaseYear ?? 0)"
            return seen.insert(identity).inserted
        }
    }

    private func get(path: String, query: [URLQueryItem] = []) async throws -> Any {
        guard !apiKey.isEmpty else { throw MDBListError.missingAPIKey }
        guard var parts = URLComponents(url: baseURL.appendingPathComponent(path),
                                        resolvingAgainstBaseURL: false) else {
            throw MDBListError.invalidResponse
        }
        parts.queryItems = query + [URLQueryItem(name: "apikey", value: apiKey)]
        guard let url = parts.url else { throw MDBListError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MDBListError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw MDBListError.invalidAPIKey }
            if http.statusCode == 429 { throw MDBListError.rateLimited }
            throw MDBListError.server(http.statusCode)
        }
        do { return try JSONSerialization.jsonObject(with: data) }
        catch { throw MDBListError.invalidResponse }
    }

    private static func items(in raw: Any?, fallbackType: String?) -> [MDBListCatalogItem] {
        guard let values = raw as? [[String: Any]] else { return [] }
        return values.compactMap { object in
            guard let title = string(object["title"]), !title.isEmpty else { return nil }
            let ids = object["ids"] as? [String: Any]
            let kind = string(object["mediatype"]) ?? string(object["type"]) ?? fallbackType ?? "movie"
            return MDBListCatalogItem(
                title: title,
                mediaType: kind.lowercased(),
                releaseYear: integer(object["release_year"]) ?? integer(object["year"]),
                imdbID: string(ids?["imdb"]) ?? string(object["imdb_id"]),
                tmdbID: string(ids?["tmdb"]) ?? string(object["tmdb_id"]),
                tvdbID: string(ids?["tvdb"]) ?? string(object["tvdb_id"]),
                rank: integer(object["rank"])
            )
        }
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }
}

enum MDBListError: LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case rateLimited
    case invalidResponse
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Enter your MDBList API key."
        case .invalidAPIKey: "MDBList rejected that API key. Copy a current key from MDBList Preferences and try again."
        case .rateLimited: "MDBList's request limit has been reached. Try again after the quota resets."
        case .invalidResponse: "MDBList returned an unsupported response."
        case .server(let status): "MDBList returned HTTP \(status)."
        }
    }
}

/// Matches discovery-list entries to real server items. Provider ids win; an
/// exact title/year fallback keeps older libraries useful when their metadata
/// provider ids have not been populated.
enum MDBListCatalogMatcher {
    static func match(_ entries: [MDBListCatalogItem], to library: [MediaItem]) -> [MediaItem] {
        var providerIndex: [String: MediaItem] = [:]
        var titleIndex: [String: [MediaItem]] = [:]
        for item in library where item.type == "Movie" || item.type == "Series" {
            for (provider, value) in item.providerIDs ?? [:] {
                providerIndex[provider.lowercased() + ":" + value.lowercased()] = item
            }
            titleIndex[normalized(item.name), default: []].append(item)
        }

        var seen: Set<String> = []
        return entries.compactMap { entry in
            let requiredType = entry.mediaType == "show" ? "Series" : "Movie"
            let providerKeys = [
                entry.imdbID.map { "imdb:" + $0.lowercased() },
                entry.tmdbID.map { "tmdb:" + $0.lowercased() },
                entry.tvdbID.map { "tvdb:" + $0.lowercased() }
            ].compactMap { $0 }
            let providerMatch = providerKeys.lazy.compactMap { providerIndex[$0] }
                .first { $0.type == requiredType }
            let titleMatch = titleIndex[normalized(entry.title)]?.first { candidate in
                guard candidate.type == requiredType else { return false }
                guard let expected = entry.releaseYear, let actual = candidate.productionYear else { return true }
                return expected == actual
            }
            guard let match = providerMatch ?? titleMatch, seen.insert(match.id).inserted else { return nil }
            return match
        }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }
}
