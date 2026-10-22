import Foundation

struct LibraryMetadataCredentials: Sendable {
    var tmdb: String
    var tvdb: String

    static var bundled: Self {
        guard let url = Bundle.main.url(forResource: "LineupMetadata", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else {
            return Self(tmdb: "", tvdb: "")
        }
        return Self(tmdb: values["tmdb"] ?? "", tvdb: values["tvdb"] ?? "")
    }

    func contains(_ source: LibraryMetadataSource) -> Bool {
        switch source {
        case .provider: return true
        case .tmdb: return !tmdb.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .tvdb: return !tvdb.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

enum TMDBCatalogMediaKind: String, Sendable, Hashable {
    case movie
    case series = "tv"
}

struct TMDBCatalogGenre: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
}

struct TMDBCatalogGenres: Decodable, Sendable {
    let movies: [TMDBCatalogGenre]
    let series: [TMDBCatalogGenre]
}

struct TMDBCatalogPage: Decodable, Sendable {
    let page: Int
    let total_pages: Int
    let results: [TMDBCatalogTitle]
}

struct TMDBCatalogTitle: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    let title: String?
    let name: String?
    let overview: String?
    let release_date: String?
    let first_air_date: String?
    let poster_path: String?
    let backdrop_path: String?

    var productionYear: Int? {
        (release_date ?? first_air_date).flatMap { Int($0.prefix(4)) }
    }

    func mediaItem(kind: TMDBCatalogMediaKind) -> MediaItem? {
        let displayName = (kind == .movie ? title : name)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let displayName, !displayName.isEmpty, id > 0 else { return nil }
        return MediaItem(id: "tmdb-catalog|\(kind.rawValue)|\(id)", name: displayName,
            type: kind == .movie ? "Movie" : "Series", overview: overview,
            productionYear: productionYear, primaryImageAspectRatio: nil, childCount: nil,
            providerIDs: ["tmdb": String(id)], posterURL: Self.imageURL(poster_path, size: "w500"),
            backdropURL: Self.imageURL(backdrop_path, size: "w1280"))
    }

    private static func imageURL(_ path: String?, size: String) -> String? {
        guard let path, path.hasPrefix("/"), !path.contains(".."),
              path.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "/-_.0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ").contains($0) }) else {
            return nil
        }
        return "https://image.tmdb.org/t/p/\(size)\(path)"
    }
}

/// Shared by every shelf and detail page. Coalesces identical lookups, bounds
/// network work, and caches successful matches on disk without storing keys.
actor LibraryMetadataResolver {
    private struct Entry: Codable {
        let value: LibraryMetadata?
        let expires: Date
    }
    private enum Failure: Error { case unavailable, http(Int) }
    private let credentials: LibraryMetadataCredentials
    private let session: URLSession
    private let cacheURL: URL?
    private var restored = false
    private var cache: [String: Entry] = [:]
    private var inFlight: [String: Task<LibraryMetadata?, Never>] = [:]
    private var saveTask: Task<Void, Never>?
    private var token: (value: String, expires: Date)?
    private var loginTask: Task<String, Error>?
    private var activeRequests = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var retryAfter: [String: Date] = [:]
    private struct CatalogEntry { let data: Data; let expires: Date }
    private var catalogCache: [String: CatalogEntry] = [:]
    private var catalogInFlight: [String: Task<Data, Error>] = [:]

    init(credentials: LibraryMetadataCredentials = .bundled,
         session: URLSession = .shared,
         cacheURL: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LineupMetadata-v1.json")) {
        self.credentials = credentials
        self.session = session
        self.cacheURL = cacheURL
    }

    func resolve(_ item: MediaItem, source: LibraryMetadataSource, parent: MediaItem? = nil) async -> LibraryMetadata? {
        guard source != .provider, credentials.contains(source),
              ["Movie", "Series", "Episode"].contains(item.type) else { return nil }
        restore()
        let key = LibraryMetadataIdentity.requestKey(item, source: source)
            + (parent.map { "|parent:" + LibraryMetadataIdentity.requestKey($0, source: source) } ?? "")
        if let entry = cache[key], entry.expires > Date() { return entry.value }
        if let task = inFlight[key] { return await task.value }
        let task = Task<LibraryMetadata?, Never> {
            do {
                let value = try await self.fetch(item.withMetadata(nil), source: source, parent: parent?.withMetadata(nil))
                self.remember(value, key: key, lifetime: value == nil ? 300 : 7 * 86_400)
                return value
            } catch {
                // A transient failure never replaces provider data or produces
                // an alert over the Library. Avoid hammering failed endpoints.
                self.remember(nil, key: key, lifetime: 30)
                return nil
            }
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    func browseGenres() async throws -> TMDBCatalogGenres {
        let movieData = try await tmdbCatalogData("genre/movie/list", query: [:], lifetime: 86_400)
        let seriesData = try await tmdbCatalogData("genre/tv/list", query: [:], lifetime: 86_400)
        let movies = try JSONDecoder().decode(TMDBGenreList.self, from: movieData).genres
        let series = try JSONDecoder().decode(TMDBGenreList.self, from: seriesData).genres
        return TMDBCatalogGenres(movies: movies, series: series)
    }

    func discover(genreID: Int, kind: TMDBCatalogMediaKind, page: Int) async throws -> TMDBCatalogPage {
        guard genreID > 0, (1...500).contains(page) else { throw Failure.unavailable }
        let data = try await tmdbCatalogData("discover/\(kind.rawValue)", query: [
            "with_genres": String(genreID),
            "sort_by": "popularity.desc",
            "include_adult": "false",
            "page": String(page)
        ], lifetime: 900)
        return try JSONDecoder().decode(TMDBCatalogPage.self, from: data)
    }

    private func tmdbCatalogData(_ path: String, query: [String: String], lifetime: TimeInterval) async throws -> Data {
        guard credentials.contains(.tmdb) else { throw Failure.unavailable }
        let cacheKey = ([path] + query.keys.sorted().map { "\($0)=\(query[$0] ?? "")" }).joined(separator: "?")
        if let entry = catalogCache[cacheKey], entry.expires > Date() { return entry.data }
        if let task = catalogInFlight[cacheKey] { return try await task.value }
        let task = Task<Data, Error> { try await self.tmdbData(path, query: query) }
        catalogInFlight[cacheKey] = task
        do {
            let data = try await task.value
            catalogInFlight[cacheKey] = nil
            catalogCache[cacheKey] = CatalogEntry(data: data, expires: Date().addingTimeInterval(lifetime))
            if catalogCache.count > 80 {
                catalogCache = catalogCache.filter { $0.value.expires > Date() }
            }
            return data
        } catch {
            catalogInFlight[cacheKey] = nil
            throw error
        }
    }

    private func tmdbData(_ path: String, query: [String: String]) async throws -> Data {
        var query = query
        query["language"] = "en-US"
        let credential = credentials.tmdb.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = credential.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil
        if apiKey { query["api_key"] = credential }
        return try await requestData(base: "https://api.themoviedb.org/3/", path: path, query: query,
                                     bearer: apiKey ? nil : credential)
    }

    private func fetch(_ item: MediaItem, source: LibraryMetadataSource, parent: MediaItem?) async throws -> LibraryMetadata? {
        if item.type == "Episode" {
            if parent == nil, source == .tvdb, let id = LibraryMetadataIdentity.ids(item)["tvdb"] {
                let response: TVDBEnvelope<TVDBRecord> = try await tvdb("episodes/\(id)/extended")
                guard let record = response.data,
                      item.parentIndexNumber.map({ record.seasonNumber == $0 }) ?? true,
                      item.indexNumber.map({ record.number == $0 }) ?? true else { return nil }
                return record.metadata(kind: "episode")
            }
            guard let parent else { return nil }
            let packed = LibraryMetadataIdentity.packed(item)
            guard let season = item.parentIndexNumber ?? packed?.season,
                  let episode = item.indexNumber ?? packed?.episode, season >= 0, episode > 0 else { return nil }
            if source == .tmdb {
                guard let id = try await tmdbID(parent) else { return nil }
                let record: TMDBRecord = try await tmdb("tv/\(id)/season/\(season)/episode/\(episode)")
                guard record.season_number == season, record.episode_number == episode else { return nil }
                return record.metadata(source: source, kind: "episode", parentID: id)
            }
            guard let id = try await tvdbID(parent) else { return nil }
            // Official aired numbering is intentional: never silently remap
            // provider episode numbers to DVD or absolute order.
            let response: TVDBEnvelope<TVDBEpisodes> = try await tvdb("series/\(id)/episodes/official", query: [
                "page": "0", "season": String(season), "episodeNumber": String(episode)
            ])
            let matching = (response.data?.episodes ?? []).filter {
                $0.seasonNumber == season && $0.number == episode && $0.seriesId == Int(id)
            }
            guard matching.count == 1, let record = matching.first else { return nil }
            return record.metadata(kind: "episode")
        }
        if source == .tmdb {
            guard let id = try await tmdbID(item) else { return nil }
            let kind = item.isSeries ? "tv" : "movie"
            let record: TMDBRecord = try await tmdb("\(kind)/\(id)", query: ["append_to_response": "external_ids"])
            return record.metadata(source: source, kind: kind)
        }
        guard let id = try await tvdbID(item) else { return nil }
        let kind = item.isSeries ? "series" : "movies"
        let record: TVDBEnvelope<TVDBRecord> = try await tvdb("\(kind)/\(id)/extended")
        return record.data?.metadata(kind: item.isSeries ? "series" : "movie")
    }

    private func tmdbID(_ item: MediaItem) async throws -> String? {
        let ids = LibraryMetadataIdentity.ids(item)
        if let id = ids["tmdb"] { return id }
        if let imdb = ids["imdb"] {
            return try await tmdbFind(imdb, externalSource: "imdb_id", series: item.isSeries)
        }
        if let tvdb = ids["tvdb"] {
            if item.isSeries { return try await tmdbFind(tvdb, externalSource: "tvdb_id", series: true) }
            if credentials.contains(.tvdb) {
                let record: TVDBEnvelope<TVDBRecord> = try await self.tvdb("movies/\(tvdb)/extended")
                let remote = record.data?.externalIDs ?? [:]
                if let id = remote["tmdb"] { return id }
                if let imdb = remote["imdb"] { return try await tmdbFind(imdb, externalSource: "imdb_id", series: false) }
            }
            return nil
        }
        guard let title = LibraryMetadataIdentity.searchableTitle(item) else { return nil }
        var query = ["query": title, "include_adult": "false"]
        if let year = item.productionYear { query[item.isSeries ? "first_air_date_year" : "year"] = String(year) }
        let response: TMDBSearch = try await tmdb("search/" + (item.isSeries ? "tv" : "movie"), query: query)
        let match = LibraryMetadataIdentity.uniqueMatch(response.results, item: item,
            title: { $0.title ?? $0.name ?? "" }, year: { $0.year })
        return match.map { String($0.id) }
    }

    private func tmdbFind(_ id: String, externalSource: String, series: Bool) async throws -> String? {
        let response: TMDBFind = try await tmdb("find/\(id)", query: ["external_source": externalSource])
        let results = series ? response.tv_results : response.movie_results
        return results.count == 1 ? results.first.map { String($0.id) } : nil
    }

    private func tvdbID(_ item: MediaItem) async throws -> String? {
        var ids = LibraryMetadataIdentity.ids(item)
        if let id = ids["tvdb"] { return id }
        if ids["imdb"] == nil, let tmdb = ids["tmdb"], credentials.contains(.tmdb) {
            let kind = item.isSeries ? "tv" : "movie"
            let record: TMDBExternalIDs = try await self.tmdb("\(kind)/\(tmdb)/external_ids")
            if let tvdb = record.tvdb_id, tvdb > 0, item.isSeries { return String(tvdb) }
            ids["imdb"] = record.imdb_id
        }
        if let imdb = ids["imdb"] {
            let response: TVDBEnvelope<[TVDBRemoteResult]> = try await tvdb("search/remoteid/\(imdb)")
            let records = (response.data ?? []).compactMap { item.isSeries ? $0.series : $0.movie }
            return records.count == 1 ? records.first.map { String($0.id) } : nil
        }
        // Never reinterpret a TMDB numeric ID as a TVDB numeric ID.
        guard ids.isEmpty, let title = LibraryMetadataIdentity.searchableTitle(item) else { return nil }
        var query = ["query": title, "type": item.isSeries ? "series" : "movie", "limit": "25"]
        if let year = item.productionYear { query["year"] = String(year) }
        let response: TVDBEnvelope<[TVDBSearch]> = try await tvdb("search", query: query)
        let candidates = (response.data ?? []).filter { $0.type == (item.isSeries ? "series" : "movie") }
        let match = LibraryMetadataIdentity.uniqueMatch(candidates, item: item,
            title: { $0.name ?? "" }, year: { $0.year.flatMap(Int.init) })
        return match?.tvdb_id.flatMap { LibraryMetadataIdentity.positiveID("tvdb", $0) }
    }

    private func tmdb<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        guard credentials.contains(.tmdb) else { throw Failure.unavailable }
        var query = query
        query["language"] = "en-US"
        let credential = credentials.tmdb.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = credential.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil
        if apiKey { query["api_key"] = credential }
        return try await request(base: "https://api.themoviedb.org/3/", path: path, query: query,
                                 bearer: apiKey ? nil : credential)
    }

    private func tvdb<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        let bearer = try await tvdbToken()
        do {
            return try await request(base: "https://api4.thetvdb.com/v4/", path: path, query: query, bearer: bearer)
        } catch Failure.http(401) {
            if token?.value == bearer { token = nil }
            let renewed = try await tvdbToken()
            return try await request(base: "https://api4.thetvdb.com/v4/", path: path, query: query, bearer: renewed)
        }
    }

    private func tvdbToken() async throws -> String {
        guard credentials.contains(.tvdb) else { throw Failure.unavailable }
        if let token, token.expires > Date() { return token.value }
        if let loginTask { return try await loginTask.value }
        let task = Task<String, Error> {
            let body = try JSONEncoder().encode(["apikey": self.credentials.tvdb.trimmingCharacters(in: .whitespacesAndNewlines)])
            let response: TVDBEnvelope<TVDBLogin> = try await self.request(
                base: "https://api4.thetvdb.com/v4/", path: "login", body: body)
            guard let value = response.data?.token, !value.isEmpty else { throw Failure.unavailable }
            return value
        }
        loginTask = task
        defer { loginTask = nil }
        let value = try await task.value
        token = (value, Date().addingTimeInterval(27 * 86_400))
        return value
    }

    private func acquire() async {
        if activeRequests < 4 { activeRequests += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { activeRequests -= 1 }
        else { waiters.removeFirst().resume() }
    }

    private func request<T: Decodable>(base: String, path: String, query: [String: String] = [:],
                                       bearer: String? = nil, body: Data? = nil) async throws -> T {
        let data = try await requestData(base: base, path: path, query: query, bearer: bearer, body: body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func requestData(base: String, path: String, query: [String: String] = [:],
                             bearer: String? = nil, body: Data? = nil) async throws -> Data {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        guard retryAfter[base].map({ $0 <= Date() }) ?? true else { throw Failure.http(429) }
        guard var components = URLComponents(string: base + path) else { throw Failure.unavailable }
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw Failure.unavailable }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.unavailable }
        if http.statusCode == 429 {
            let seconds = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 60
            retryAfter[base] = Date().addingTimeInterval(max(1, seconds))
        }
        guard (200..<300).contains(http.statusCode) else { throw Failure.http(http.statusCode) }
        return data
    }

    private func restore() {
        guard !restored else { return }
        restored = true
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL),
              let saved = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        cache = saved.filter { $0.value.expires > Date() }
    }

    private func remember(_ value: LibraryMetadata?, key: String, lifetime: TimeInterval) {
        cache[key] = Entry(value: value, expires: Date().addingTimeInterval(lifetime))
        if cache.count > 1500 {
            cache = Dictionary(uniqueKeysWithValues: cache.sorted { $0.value.expires > $1.value.expires }.prefix(1200).map { ($0.key, $0.value) })
        }
        guard cacheURL != nil, saveTask == nil else { return }
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            self.save()
        }
    }

    private func save() {
        saveTask = nil
        guard let cacheURL, let data = try? JSONEncoder().encode(cache.filter { $0.value.value != nil }) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}

private struct TMDBSearch: Decodable { let results: [TMDBRecord] }
private struct TMDBGenreList: Decodable { let genres: [TMDBCatalogGenre] }
private struct TMDBFind: Decodable { let movie_results: [TMDBRecord]; let tv_results: [TMDBRecord] }
private struct TMDBExternalIDs: Decodable { let imdb_id: String?; let tvdb_id: Int? }
private struct MetadataGenre: Decodable { let name: String? }
private struct TMDBRecord: Decodable {
    let id: Int
    let title: String?
    let name: String?
    let overview: String?
    let release_date: String?
    let first_air_date: String?
    let air_date: String?
    let poster_path: String?
    let backdrop_path: String?
    let still_path: String?
    let genres: [MetadataGenre]?
    let external_ids: TMDBExternalIDs?
    let season_number: Int?
    let episode_number: Int?

    var year: Int? { (release_date ?? first_air_date ?? air_date).flatMap { Int($0.prefix(4)) } }
    func metadata(source: LibraryMetadataSource, kind: String, parentID: String? = nil) -> LibraryMetadata? {
        guard let title = (title ?? name)?.metadataText else { return nil }
        func image(_ path: String?, size: String) -> String? {
            guard let path, path.hasPrefix("/"), !path.contains("..") else { return nil }
            return "https://image.tmdb.org/t/p/" + size + path
        }
        var ids = ["tmdb": String(id)]
        if let imdb = external_ids?.imdb_id { ids["imdb"] = imdb }
        if let tvdb = external_ids?.tvdb_id, tvdb > 0 { ids["tvdb"] = String(tvdb) }
        let link = kind == "episode"
            ? "https://www.themoviedb.org/tv/\(parentID ?? "")/season/\(season_number ?? 0)/episode/\(episode_number ?? 0)"
            : "https://www.themoviedb.org/\(kind)/\(id)"
        return LibraryMetadata(source: source, title: title, overview: overview?.metadataText, year: year,
            genres: genres?.compactMap { $0.name?.metadataText }.nonempty,
            premiereDate: (release_date ?? first_air_date ?? air_date)?.metadataText,
            poster: image(kind == "episode" ? still_path : poster_path, size: "w500"),
            backdrop: image(backdrop_path, size: "w1280"), externalIDs: ids, attributionURL: link)
    }
}

private struct TVDBEnvelope<T: Decodable>: Decodable { let data: T? }
private struct TVDBLogin: Decodable { let token: String? }
private struct TVDBEpisodes: Decodable { let episodes: [TVDBRecord]? }
private struct TVDBRemoteResult: Decodable { let series: TVDBRecord?; let movie: TVDBRecord? }
private struct TVDBSearch: Decodable { let name: String?; let tvdb_id: String?; let year: String?; let type: String? }
private struct TVDBRemoteID: Decodable { let id: String?; let sourceName: String? }
private struct TVDBArtwork: Decodable { let image: String?; let width: Int?; let height: Int? }
private struct TVDBRelease: Decodable { let date: String? }
private struct TVDBRecord: Decodable {
    let id: Int
    let name: String?
    let overview: String?
    let firstAired: String?
    let year: String?
    let first_release: TVDBRelease?
    let aired: String?
    let image: String?
    let genres: [MetadataGenre]?
    let artworks: [TVDBArtwork]?
    let remoteIds: [TVDBRemoteID]?
    let seasonNumber: Int?
    let number: Int?
    let seriesId: Int?

    var externalIDs: [String: String] {
        var ids = ["tvdb": String(id)]
        for remote in remoteIds ?? [] {
            guard let name = remote.sourceName?.lowercased(), let value = remote.id else { continue }
            let provider = name.contains("imdb") ? "imdb" : (name.contains("themoviedb") || name.contains("tmdb")) ? "tmdb" : ""
            if let id = LibraryMetadataIdentity.positiveID(provider, value) { ids[provider] = id }
        }
        return ids
    }

    func metadata(kind: String) -> LibraryMetadata? {
        guard let title = name?.metadataText else { return nil }
        func artwork(_ url: String?) -> String? {
            guard let url, let parsed = URL(string: url), parsed.scheme == "https", parsed.host != nil else { return nil }
            return url
        }
        let date = (aired ?? firstAired ?? first_release?.date)?.metadataText
        let backdrop = artworks?.first {
            guard let width = $0.width, let height = $0.height, height > 0 else { return false }
            return (1.6...1.9).contains(Double(width) / Double(height))
        }?.image
        return LibraryMetadata(source: .tvdb, title: title, overview: overview?.metadataText,
            year: year.flatMap(Int.init) ?? date.flatMap { Int($0.prefix(4)) },
            genres: genres?.compactMap { $0.name?.metadataText }.nonempty, premiereDate: date,
            poster: artwork(image), backdrop: artwork(backdrop), externalIDs: externalIDs,
            attributionURL: "https://www.thetvdb.com/dereferrer/\(kind)/\(id)")
    }
}

private extension String {
    var metadataText: String? {
        let clean = trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}
private extension Array {
    var nonempty: Self? { isEmpty ? nil : self }
}
