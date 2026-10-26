import Foundation

struct SiloCredential: Codable, Sendable {
    var accessToken: String
    var refreshToken: String? = nil
    var expiresAt: Date? = nil
    var profileToken: String? = nil
}

struct SiloAccount: Decodable, Sendable { let id: String; let username: String }
struct SiloProfile: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let has_pin: Bool
    let is_primary: Bool
}
struct SiloPage<T: Decodable & Sendable>: Decodable, Sendable {
    let items: [T]
    let page: Page?
    let total: Int?
    struct Page: Decodable, Sendable { let has_more: Bool; let next_cursor: String? }
}

private struct SiloLibrary: Decodable, Sendable { let id: String; let name: String; let type: String }
private struct SiloCollection: Decodable, Sendable { let id: String; let name: String; let item_count: Int?; let poster_url: String? }
private struct SiloCuratedCollection: Decodable, Sendable { let id: String; let title: String; let item_count: Int?; let poster_url: String? }
private struct SiloLibraryCollections: Decodable, Sendable { let collections: [SiloCuratedCollection] }
struct SiloServerPlayback: Sendable {
    let item: MediaItem
    let position: Double
    let duration: Double
    let updatedAt: Date
    let completed: Bool
}
private struct SiloSeason: Decodable, Sendable {
    let content_id: String
    let season_number: Int
    let title: String
    let episode_count: Int
    let poster_url: String?
}

private struct SiloTitle: Decodable, Sendable {
    let content_id: String
    let type: String?
    let title: String
    let overview: String?
    let year: Int?
    let runtime: Int?
    let duration_seconds: Double?
    let poster_url: String?
    let backdrop_url: String?
    let logo_url: String?
    let still_url: String?
    let genres: [String]?
    let content_rating: String?
    let rating_imdb: Double?
    let rating_tmdb: Double?
    let rating_rt_critic: Int?
    let season_number: Int?
    let episode_number: Int?
    let series_id: String?
    let series_title: String?
    let imdb_id: String?
    let tmdb_id: String?
    let tvdb_id: String?
    let release_date: String?
    let air_date: String?
    let show_status: String?
    let episode_count: Int?
    let user_state: UserState?
    let user_data: WatchState?
    let position_seconds: Double?
    let progress_updated_at: String?
    let cast: [Cast]?
    struct UserState: Decodable, Sendable { let played: Bool?; let is_favorite: Bool? }
    struct WatchState: Decodable, Sendable { let played: Bool?; let position_seconds: Double?; let unplayed_count: Int? }
    struct Cast: Decodable, Sendable { let name: String?; let character: String? }

    func media(http: MediaIntegrationHTTP, forcedType: String? = nil, series: MediaItem? = nil) -> MediaItem {
        let normalized = forcedType ?? ["movie": "Movie", "series": "Series", "episode": "Episode", "season": "Season"][type ?? ""] ?? "Video"
        let seconds = duration_seconds ?? runtime.map { Double($0) * 60 }
        var ids: [String: String] = [:]
        if let imdb_id { ids["Imdb"] = imdb_id }
        if let tmdb_id { ids["Tmdb"] = tmdb_id }
        if let tvdb_id { ids["Tvdb"] = tvdb_id }
        return MediaItem(id: content_id, name: title, type: normalized, overview: overview,
            productionYear: year, primaryImageAspectRatio: normalized == "Episode" ? 16 / 9 : 2 / 3,
            childCount: episode_count, genres: genres, officialRating: content_rating,
            communityRating: rating_imdb ?? rating_tmdb, criticRating: rating_rt_critic.map(Double.init),
            runTimeTicks: Self.ticks(seconds), premiereDate: air_date ?? release_date,
            indexNumber: episode_number ?? (normalized == "Season" ? season_number : nil), parentIndexNumber: season_number,
            seriesName: series_title ?? series?.name, seriesID: series_id ?? series?.id,
            userData: MediaUserData(played: user_state?.played ?? user_data?.played,
                isFavorite: user_state?.is_favorite,
                playedPercentage: Self.fraction(position_seconds ?? user_data?.position_seconds, duration: seconds)),
            status: show_status, people: cast?.compactMap { person in
                person.name.map { MediaPerson(personID: nil, name: $0, role: person.character, type: "Actor", primaryImageTag: nil) }
            }, providerIDs: ids.isEmpty ? nil : ids,
            posterURL: http.resolvedURL(poster_url ?? still_url)?.absoluteString,
            backdropURL: http.resolvedURL(backdrop_url)?.absoluteString,
            logoArtworkURL: http.resolvedURL(logo_url)?.absoluteString)
    }
    static func ticks(_ value: Double?) -> Int64? {
        guard let value, value.isFinite, value >= 0, value < Double(Int64.max) / 10_000_000 else { return nil }
        return Int64(value * 10_000_000)
    }
    static func fraction(_ position: Double?, duration: Double?) -> Double? {
        guard let position, let duration, position.isFinite, duration.isFinite, duration > 0 else { return nil }
        return min(100, max(0, 100 * position / duration))
    }
    // Read for every title in a progress list, so they are made once.
    private static let fractionalTime: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let wholeTime = ISO8601DateFormatter()
    func playback(http: MediaIntegrationHTTP) -> SiloServerPlayback? {
        guard ["movie", "episode"].contains(type ?? ""), let raw = progress_updated_at,
              let duration = duration_seconds ?? runtime.map({ Double($0) * 60 }), duration.isFinite, duration > 0,
              let position = position_seconds ?? user_data?.position_seconds, position.isFinite, position >= 0 else { return nil }
        guard let updatedAt = Self.fractionalTime.date(from: raw) ?? Self.wholeTime.date(from: raw) else { return nil }
        return SiloServerPlayback(item: media(http: http), position: min(position, duration), duration: duration,
            updatedAt: updatedAt, completed: user_state?.played ?? user_data?.played ?? false)
    }
}

private struct SiloFile: Decodable, Sendable {
    let file_id: String
    let file_name: String?
    let resolution: String
    let codec_video: String
    let codec_audio: String
    let container: String
    let file_size: Int64
    let bitrate: Int64
    let duration: Int
    var source: MediaPlaybackSource {
        MediaPlaybackSource(sourceID: file_id, name: [resolution, codec_video, codec_audio].filter { !$0.isEmpty }.joined(separator: " · "),
            path: nil, container: container, size: file_size,
            bitrate: bitrate > 0 && bitrate <= Int64.max / 1000 ? bitrate * 1000 : nil,
            remux: .init(providerInfo: .init(source: "Silo", filename: file_name, description: nil)), siloFileID: file_id)
    }
}

struct SiloPlaybackCapabilities: Decodable, Sendable {
    let protocol_versions: [Int]
    let features: [String]
    let deliveries: [String]
    let installation_id: String?
    let state: String
    let allowed: Bool
}

struct SiloPlaybackDecision: Decodable, Sendable {
    let protocol_version: Int
    let outcome: String
    let session_id: String?
    let playback_plan: Plan?
    struct Plan: Decodable, Sendable {
        let delivery: String
        let plan_id: String
        let plan_attempt_key: String
        let selected_tracks: [String: Track]?
        let source: Source
        let stream: Stream
        let timeline: Timeline
        struct Stream: Decodable, Sendable { let url: String; let headers: [String: String]; let header_refresh: String }
        struct Timeline: Decodable, Sendable {
            let player_start_seconds: Double
            let timeline_offset_seconds: Double
            let source_start_seconds: Double
            let can_seek_anywhere: Bool
        }
        struct Track: Codable, Sendable { let id: String?; let index: Int? }
        struct Source: Decodable, Sendable { let duration_seconds: Double? }
    }
}

struct SiloPlaybackLease: Hashable, Sendable {
    let sessionID: String
    let installationID: String
    let profileID: String
    let playerStart: Double
    let timelineOffset: Double
}

/// Native Silo v2 adapter. All account and content identifiers remain strings.
/// Read-only browsing never creates a playback session.
struct SiloClient: MediaServerClient {
    let transport: SiloTransport
    let http: MediaIntegrationHTTP
    init(address: String, credential: SiloCredential, profileID: String?, deviceID: String,
         session: URLSession? = nil, persist: (@Sendable (SiloCredential) async -> Void)? = nil) throws {
        let http = try MediaIntegrationHTTP(address: address, session: session)
        self.http = http
        transport = SiloTransport(http: http, credential: credential, profileID: profileID, deviceID: deviceID, persist: persist)
    }

    func account() async throws -> SiloAccount { try await transport.get(["account", "me"]) }
    func signIn(username: String, password: String) async throws -> SiloAccount { try await transport.signIn(username: username, password: password) }
    func profiles() async throws -> [SiloProfile] {
        let result: SiloPage<SiloProfile> = try await transport.get(["profiles"])
        return result.items
    }
    func selectProfile(_ profile: SiloProfile, pin: String) async throws { try await transport.select(profile, pin: pin) }
    func credential() async -> SiloCredential { await transport.currentCredential() }

    func views(userID: String) async throws -> [MediaItem] {
        let page: SiloPage<SiloLibrary> = try await transport.get(["user", "libraries"])
        return page.items.filter { ["movies", "series", "mixed"].contains($0.type) }.map {
            MediaItem(id: "silo-library:" + $0.id, name: $0.name, type: "CollectionFolder", overview: nil,
                productionYear: nil, primaryImageAspectRatio: nil, childCount: nil)
        }
    }
    private func catalog(_ query: [URLQueryItem], limit: Int, pages: Int = 1) async throws -> [MediaItem] {
        var all: [MediaItem] = [], ids: Set<String> = [], cursors: Set<String> = []
        var cursor: String?
        for _ in 0..<max(1, min(pages, 125)) {
            try Task.checkCancellation()
            var parameters = query + [.init(name: "limit", value: String(min(200, max(1, limit)))), .init(name: "poster_width", value: "500")]
            if let cursor { parameters.append(.init(name: "cursor", value: cursor)) }
            let page: SiloPage<SiloTitle> = try await transport.get(["catalog"], query: parameters)
            all += page.items.filter { ids.insert($0.content_id).inserted }.map { $0.media(http: http) }
            guard page.page?.has_more == true, let next = page.page?.next_cursor, !next.isEmpty else { break }
            guard cursors.insert(next).inserted else { throw MediaIntegrationError.invalidResponse }
            cursor = next
        }
        return all
    }
    func items(userID: String, parentID: String, sortBy: String, limit: Int) async throws -> [MediaItem] {
        if parentID.hasPrefix("silo-curated:") {
            let parts = parentID.dropFirst("silo-curated:".count).split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let libraryBytes = Data(base64Encoded: String(parts[0])),
                  let collectionBytes = Data(base64Encoded: String(parts[1])),
                  let library = String(data: libraryBytes, encoding: .utf8), let collection = String(data: collectionBytes, encoding: .utf8) else {
                throw MediaIntegrationError.invalidResponse
            }
            return try await catalog([.init(name: "source", value: "library_collection"), .init(name: "library_id", value: library),
                .init(name: "collection_id", value: collection)], limit: limit)
        }
        if parentID.hasPrefix("silo-library:") {
            return try await catalog([.init(name: "library_id", value: String(parentID.dropFirst("silo-library:".count))),
                .init(name: "type", value: "video"), .init(name: "sort", value: "title")], limit: limit)
        }
        if parentID.hasPrefix("silo-collection:") {
            return try await catalog([.init(name: "source", value: "user_collection"),
                .init(name: "collection_id", value: String(parentID.dropFirst("silo-collection:".count)))], limit: limit)
        }
        let parent = try await item(userID: userID, itemID: parentID)
        return try await items(userID: userID, parent: parent, sortBy: sortBy, limit: limit)
    }
    func items(userID: String, parent: MediaItem, sortBy: String, limit: Int) async throws -> [MediaItem] {
        if parent.isSeries {
            let page: SiloPage<SiloSeason> = try await transport.get(["catalog", "series", parent.id, "seasons"])
            return page.items.map { season in
                MediaItem(id: season.content_id, name: season.title, type: "Season", overview: nil,
                    productionYear: nil, primaryImageAspectRatio: 2 / 3, childCount: season.episode_count,
                    indexNumber: season.season_number, parentIndexNumber: season.season_number, seriesName: parent.name,
                    seriesID: parent.id, posterURL: http.resolvedURL(season.poster_url)?.absoluteString)
            }.sorted { ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0) }
        }
        if parent.type == "Season", let seriesID = parent.seriesID, let number = parent.indexNumber {
            let page: SiloPage<SiloTitle> = try await transport.get(["catalog", "series", seriesID, "seasons", String(number), "episodes"])
            let series = MediaItem(id: seriesID, name: parent.seriesName ?? "", type: "Series", overview: nil,
                productionYear: nil, primaryImageAspectRatio: nil, childCount: nil)
            return page.items.map { $0.media(http: http, forcedType: "Episode", series: series) }
        }
        if ["silo-library:", "silo-collection:", "silo-curated:"].contains(where: { parent.id.hasPrefix($0) }) {
            return try await items(userID: userID, parentID: parent.id, sortBy: sortBy, limit: limit)
        }
        return []
    }
    func allCollections(userID: String, pageSize: Int, maxPages: Int) async throws -> [MediaItem] {
        let page: SiloPage<SiloCollection> = try await transport.get(["collections"])
        var result = page.items.map { MediaItem(id: "silo-collection:" + $0.id, name: $0.name, type: "BoxSet", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: $0.item_count, posterURL: http.resolvedURL($0.poster_url)?.absoluteString) }
        let libraries: SiloPage<SiloLibrary> = try await transport.get(["user", "libraries"])
        for library in libraries.items where ["movies", "series", "mixed"].contains(library.type) {
            try Task.checkCancellation()
            let tab: SiloLibraryCollections = try await transport.get(["library", library.id, "collections"])
            result += tab.collections.map { collection in
                let id = "silo-curated:" + Data(library.id.utf8).base64EncodedString() + ":" + Data(collection.id.utf8).base64EncodedString()
                return MediaItem(id: id, name: collection.title, type: "BoxSet", overview: nil, productionYear: nil,
                    primaryImageAspectRatio: nil, childCount: collection.item_count, posterURL: http.resolvedURL(collection.poster_url)?.absoluteString)
            }
        }
        return result
    }
    func recentPlayback() async throws -> [SiloServerPlayback] {
        var result: [SiloServerPlayback] = [], cursor: String?, seen: Set<String> = []
        for _ in 0..<3 {
            var query = [URLQueryItem(name: "source", value: "history"), .init(name: "limit", value: "100")]
            if let cursor { query.append(.init(name: "cursor", value: cursor)) }
            let page: SiloPage<SiloTitle> = try await transport.get(["catalog"], query: query)
            result += page.items.compactMap { $0.playback(http: http) }
            guard page.page?.has_more == true, let next = page.page?.next_cursor else { break }
            guard !next.isEmpty, seen.insert(next).inserted else { throw MediaIntegrationError.invalidResponse }
            cursor = next
        }
        return result
    }
    func favorites() async throws -> [MediaItem] {
        try await catalog([.init(name: "source", value: "favorites"), .init(name: "type", value: "video")], limit: 100, pages: 10)
            .filter { $0.type == "Movie" || $0.type == "Series" }
    }
    func episodes(userID: String, seriesID: String) async throws -> [MediaItem] {
        let series = try await item(userID: userID, itemID: seriesID)
        let page: SiloPage<SiloTitle> = try await transport.get(["catalog", "items", seriesID, "episodes"])
        return LocalEpisodeProgressionPolicy.ordered(page.items.map { $0.media(http: http, forcedType: "Episode", series: series) })
    }
    func allTitles(userID: String, pageSize: Int, maxPages: Int) async throws -> [MediaItem] {
        try await catalog([.init(name: "type", value: "video"), .init(name: "sort", value: "title")],
            limit: min(200, pageSize), pages: min(125, maxPages * max(1, (pageSize + 199) / 200)))
    }
    func item(userID: String, itemID: String) async throws -> MediaItem {
        let title: SiloTitle = try await transport.get(["catalog", "items", itemID], query: [.init(name: "image_size", value: "large")])
        guard title.content_id == itemID else { throw MediaIntegrationError.invalidResponse }
        return title.media(http: http)
    }
    func similarItems(userID: String, itemID: String) async throws -> [MediaItem] {
        let item = try await item(userID: userID, itemID: itemID)
        guard let genre = item.genres?.first else { return [] }
        return try await catalog([.init(name: "type", value: item.isSeries ? "series" : "movie"), .init(name: "genre", value: genre)], limit: 16)
            .filter { $0.id != itemID }
    }
    func libraryCounts(userID: String) async throws -> MediaLibraryCounts {
        // The three counts are asked for together.
        let transport = transport
        @Sendable func count(_ kind: String) async throws -> Int {
            let result: SiloPage<SiloTitle> = try await transport.get(["catalog"], query: [.init(name: "type", value: kind), .init(name: "limit", value: "1")])
            guard let total = result.total else { throw MediaIntegrationError.invalidResponse }
            return total
        }
        async let movies = count("movie")
        async let shows = count("series")
        async let episodes = count("episode")
        let totals = try await (movies, shows, episodes)
        return MediaLibraryCounts(movies: totals.0, shows: totals.1, episodes: totals.2)
    }
    func nextUp(userID: String, seriesID: String) async throws -> [MediaItem] {
        Array(try await episodes(userID: userID, seriesID: seriesID).filter { !$0.isPlayed && !$0.isUnaired }.prefix(1))
    }
    func setFavorite(userID: String, itemID: String, isFavorite: Bool) async throws {
        try await transport.mutate(["favorites", itemID], method: isFavorite ? "PUT" : "DELETE")
    }
    func setPlayed(userID: String, itemID: String, isPlayed: Bool) async throws {
        try await transport.mutate(["watched", itemID], method: isPlayed ? "POST" : "DELETE")
    }
    func publicInfo() async throws -> MediaServerPublicInfo {
        struct Info: Decodable { let server_version: String; let api_major: Int }
        let (data, _) = try await http.send(["api", "v2", "system", "info"])
        let info = try JSONDecoder().decode(Info.self, from: data)
        guard info.api_major == 2 else { throw MediaIntegrationError.unavailable("This Silo server needs a supported v2 API.") }
        return MediaServerPublicInfo(serverName: "Silo", version: info.server_version, remuxVersion: nil, aiostreams: nil)
    }
    func items(userID: String, ids: [String]) async throws -> [MediaItem] {
        var result: [MediaItem] = []
        for id in ids { result.append(try await item(userID: userID, itemID: id)) }
        return result
    }
    func items(userID: String, providerIDs: [String: String], types: [String]) async throws -> [MediaItem] {
        // Native catalog IDs are not TMDB/IMDb IDs. Cross-server matching uses
        // the normal title search and validates returned external identities.
        []
    }
    func search(userID: String, query: String, types: [String]) async throws -> [MediaItem] {
        // Search each supported media kind: no assumption that the optional
        // video_with_episodes capability is enabled on every Silo version.
        var result: [MediaItem] = []
        for kind in ["Movie", "Series", "Episode"] where types.contains(kind) {
            result += try await catalog([.init(name: "q", value: query), .init(name: "type", value: kind.lowercased())], limit: 40)
        }
        return result
    }
    func imageURL(itemID: String, type: String, maxWidth: Int) -> URL? { nil }
    func artworkURL(for item: MediaItem, type: String, maxWidth: Int) -> URL? {
        http.resolvedURL(type == "logo" ? item.logoArtworkURL : type == "backdrop" ? item.backdropURL : item.posterURL)
    }
    func playbackURL(itemID: String, mediaSourceID: String?) -> URL? { nil }
    func playbackInfo(itemID: String) async throws -> MediaPlaybackInfo {
        let page: SiloPage<SiloFile> = try await transport.get(["catalog", "items", itemID, "versions"])
        return MediaPlaybackInfo(mediaSources: page.items.map(\.source))
    }
    func addons() async throws -> [NullfinAddon] { [] }
    func addonCatalogs(addonID: String) async throws -> [NullfinCatalog] { [] }
    func setCatalog(addonID: String, catalogID: String, enabled: Bool) async throws { throw MediaIntegrationError.http(404, retryAfter: nil) }
    func refreshLibrary() async throws { throw MediaIntegrationError.unavailable("Silo library scans are managed on your server.") }
    func itemMetrics(itemID: String) async throws -> [MediaMetric] { [] }
}

actor SiloTransport {
    let http: MediaIntegrationHTTP
    private var credential: SiloCredential
    private var profileID: String?
    private let deviceID: String
    private let persist: (@Sendable (SiloCredential) async -> Void)?
    private var refreshTask: Task<SiloCredential, Error>?
    private var backoffUntil: Date?
    init(http: MediaIntegrationHTTP, credential: SiloCredential, profileID: String?, deviceID: String,
         persist: (@Sendable (SiloCredential) async -> Void)?) {
        self.http = http; self.credential = credential; self.profileID = profileID; self.deviceID = deviceID; self.persist = persist
    }
    private struct Tokens: Decodable { let access_token: String; let refresh_token: String; let expires_in: Int; let user: SiloAccount? }
    func signIn(username: String, password: String) async throws -> SiloAccount {
        let (data, _) = try await http.send(["api", "v2", "auth", "login"], method: "POST",
            body: MediaIntegrationHTTP.body(["username": username, "password": password]))
        let tokens = try JSONDecoder().decode(Tokens.self, from: data)
        guard let user = tokens.user, !tokens.access_token.isEmpty else { throw MediaIntegrationError.invalidResponse }
        credential = SiloCredential(accessToken: tokens.access_token, refreshToken: tokens.refresh_token,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokens.expires_in)))
        return user
    }
    func currentCredential() -> SiloCredential { credential }
    func actingProfile() -> String? { profileID }
    func select(_ profile: SiloProfile, pin: String) async throws {
        if profile.has_pin {
            struct Proof: Decodable { let valid: Bool; let profile_token: String? }
            let proof: Proof = try await get(["profiles", profile.id, "verify-pin"], method: "POST", body: ["pin": pin])
            guard proof.valid, let token = proof.profile_token, !token.isEmpty else { throw MediaIntegrationError.http(403, retryAfter: nil) }
            credential.profileToken = token
        } else { credential.profileToken = nil }
        profileID = profile.id
    }
    private func authorize() async throws {
        guard let expiry = credential.expiresAt, expiry.timeIntervalSinceNow < 60,
              let refresh = credential.refreshToken else { return }
        let task: Task<SiloCredential, Error>
        if let existing = refreshTask { task = existing }
        else {
            let old = credential
            task = Task {
                let (data, _) = try await http.send(["api", "v2", "auth", "refresh"], method: "POST",
                    body: MediaIntegrationHTTP.body(["refresh_token": refresh]))
                let tokens = try JSONDecoder().decode(Tokens.self, from: data)
                return SiloCredential(accessToken: tokens.access_token, refreshToken: tokens.refresh_token,
                    expiresAt: Date().addingTimeInterval(TimeInterval(tokens.expires_in)), profileToken: old.profileToken)
            }
            refreshTask = task
        }
        do { credential = try await task.value; refreshTask = nil; await persist?(credential) }
        catch { refreshTask = nil; throw error }
    }
    func get<T: Decodable>(_ path: [String], method: String = "GET", query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> T {
        let data = try await raw(path, method: method, query: query, body: body)
        return try JSONDecoder().decode(T.self, from: data)
    }
    func mutate(_ path: [String], method: String, body: [String: Any]? = nil) async throws {
        _ = try await raw(path, method: method, body: body)
    }
    private func raw(_ path: [String], method: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> Data {
        if let backoffUntil, backoffUntil > Date() { throw MediaIntegrationError.http(429, retryAfter: backoffUntil.timeIntervalSinceNow) }
        try await authorize()
        guard !credential.accessToken.isEmpty else { throw MediaIntegrationError.disconnected }
        var headers = ["Authorization": "Bearer " + credential.accessToken, "X-Client-Name": "Lineup", "X-Silo-Device-Id": deviceID]
        if let profileID { headers["X-Profile-Id"] = profileID }
        if let proof = credential.profileToken { headers["X-Profile-Token"] = proof }
        do {
            return try await http.send(["api", "v2"] + path, method: method, query: query, headers: headers,
                body: body.map { try MediaIntegrationHTTP.body($0) }).0
        } catch let error as MediaIntegrationError {
            if case .http(429, let retry) = error { backoffUntil = Date().addingTimeInterval(max(1, retry ?? 30)) }
            throw error
        }
    }
}
