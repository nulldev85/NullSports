import Foundation

enum SeerrMediaKind: String, Codable, CaseIterable, Sendable { case movie, tv
    var title: String { self == .movie ? "Movies" : "Series" }
}
enum SeerrSignInMethod: String, CaseIterable, Sendable {
    case local, plex, jellyfin, emby, apiKey
    var title: String {
        switch self { case .local: "Seerr Account"; case .plex: "Plex"; case .jellyfin: "Jellyfin"; case .emby: "Emby"; case .apiKey: "API Key" }
    }
}
struct SeerrPublicSettings: Decodable, Sendable { let initialized: Bool; let plexClientIdentifier: String? }

struct SeerrUser: Codable, Sendable, Equatable {
    let id: Int
    let permissions: Int?
    let username: String?
    let email: String?
    let displayName: String?
    var name: String { displayName ?? username ?? email ?? "Seerr user" }
    func permits(_ flag: Int) -> Bool { ((permissions ?? 0) & 2) != 0 || ((permissions ?? 0) & flag) != 0 }
    var managesRequests: Bool { permits(16) }
    func canRequest(_ kind: SeerrMediaKind, is4k: Bool = false) -> Bool {
        guard permits(32) || permits(kind == .movie ? 262144 : 524288) else { return false }
        return !is4k || permits(1024) || permits(kind == .movie ? 2048 : 4096)
    }
}

struct SeerrTitle: Decodable, Identifiable, Sendable {
    let id: Int
    let mediaType: String?
    let title: String?
    let name: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let mediaInfo: SeerrMediaInfo?
    let seasons: [SeerrSeason]?
    var displayName: String { title ?? name ?? "Untitled" }
    var kind: SeerrMediaKind { mediaType == "tv" || (title == nil && name != nil) ? .tv : .movie }
    var posterURL: URL? {
        guard let posterPath, posterPath.hasPrefix("/"), !posterPath.hasPrefix("//") else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w342" + posterPath)
    }
}

struct SeerrSeason: Decodable, Identifiable, Sendable {
    let id: Int
    let seasonNumber: Int
    let episodeCount: Int?
    let name: String?
}

struct SeerrMediaInfo: Decodable, Sendable {
    let id: Int?
    let tmdbId: Int?
    let mediaType: String?
    let status: Int?
    let status4k: Int?
    let requests: [SeerrRequest]?
    let seasons: [SeerrMediaSeason]?
    static func statusTitle(_ value: Int?) -> String {
        switch value {
        case 2: return "Pending approval"
        case 3: return "Processing"
        case 4: return "Partially available"
        case 5: return "Available"
        case 6: return "Unavailable" // Blocklisted in current Seerr; deleted in older APIs.
        case 7: return "Removed from server"
        default: return "Not requested"
        }
    }
}

struct SeerrMediaSeason: Decodable, Sendable {
    let seasonNumber: Int
    let status: Int?
    let status4k: Int?
}

struct SeerrRequest: Decodable, Identifiable, Sendable {
    let id: Int
    let status: Int
    let media: SeerrMediaInfo?
    let requestedBy: SeerrUser?
    let is4k: Bool?
    let createdAt: String?
    let seasons: [SeerrMediaSeason]?
    var statusTitle: String {
        switch status {
        case 1: return "Pending approval"; case 2: return "Approved"; case 3: return "Declined"
        case 4: return "Failed"; case 5: return "Completed"; default: return "Unknown status"
        }
    }
}

struct SeerrPage<T: Decodable & Sendable>: Decodable, Sendable {
    let page: Int?
    let totalPages: Int?
    let totalResults: Int?
    let results: [T]
    let pageInfo: PageInfo?
    struct PageInfo: Decodable, Sendable { let pages: Int?; let results: Int?; let page: Int? }
}

struct SeerrQuota: Decodable, Sendable {
    struct Limit: Decodable, Sendable { let days: Int?; let limit: Int?; let used: Int?; let remaining: Int?; let restricted: Bool? }
    let movie: Limit?
    let tv: Limit?
}

struct SeerrCredential: Codable, Sendable {
    var apiKey: String? = nil
    var cookie: String? = nil
}

struct SeerrService: Decodable, Identifiable, Sendable {
    let id: Int
    let name: String
    let is4k: Bool?
    let isDefault: Bool?
    let activeProfileId: Int?
    let activeDirectory: String?
}
struct SeerrServiceDetails: Decodable, Sendable {
    let server: SeerrService
    let profiles: [Profile]
    let rootFolders: [Folder]?
    let languageProfiles: [Profile]?
    struct Profile: Decodable, Identifiable, Sendable { let id: Int; let name: String }
    struct Folder: Decodable, Identifiable, Sendable { let id: Int; let path: String }
}
struct SeerrRequestOptions: Equatable, Sendable {
    let serverID: Int
    let serverName: String
    var profileID: Int?
    var rootFolder: String?
    var languageProfileID: Int?
}

/// Seerr API v1, verified against c57dca90. One authenticated user, no assumed
/// admin rights, and no automatic retry of a request/cancel/approval mutation.
actor SeerrClient {
    nonisolated let http: MediaIntegrationHTTP
    private var credential: SeerrCredential
    private var backoffUntil: Date?
    private var active = true

    init(address: String, credential: SeerrCredential, session: URLSession? = nil) throws {
        http = try MediaIntegrationHTTP(address: address, session: session)
        self.credential = credential
    }

    func signIn(email: String, password: String) async throws -> (SeerrUser, SeerrCredential) {
        try await establishSession(route: "local", body: ["email": email, "password": password])
    }
    func signInMediaServer(username: String, password: String, emby: Bool) async throws -> (SeerrUser, SeerrCredential) {
        try await establishSession(route: "jellyfin", body: ["username": username, "password": password, "serverType": emby ? 3 : 2])
    }
    func signInPlex(token: String) async throws -> (SeerrUser, SeerrCredential) {
        try await establishSession(route: "plex", body: ["authToken": token])
    }
    func publicSettings() async throws -> SeerrPublicSettings {
        let (data, _) = try await http.send(["api", "v1", "settings", "public"])
        return try JSONDecoder().decode(SeerrPublicSettings.self, from: data)
    }
    private func establishSession(route: String, body: [String: Any]) async throws -> (SeerrUser, SeerrCredential) {
        guard active else { throw MediaIntegrationError.disconnected }
        let (data, response) = try await http.send(["api", "v1", "auth", route], method: "POST", body: MediaIntegrationHTTP.body(body))
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            result[String(describing: pair.key)] = String(describing: pair.value)
        }
        guard let cookie = HTTPCookie.cookies(withResponseHeaderFields: fields, for: http.base)
            .first(where: { $0.name == "connect.sid" }), !cookie.value.contains(";"),
              cookie.value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw MediaIntegrationError.unavailable("Seerr did not return a sign-in session. Check that this account sign-in method is enabled on your server.")
        }
        credential = SeerrCredential(cookie: cookie.value)
        return (try JSONDecoder().decode(SeerrUser.self, from: data), credential)
    }

    private func send<T: Decodable>(_ path: [String], method: String = "GET", query: [URLQueryItem] = [],
                                    body: [String: Any]? = nil) async throws -> T {
        let data = try await raw(path, method: method, query: query, body: body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func raw(_ path: [String], method: String = "GET", query: [URLQueryItem] = [],
                     body: [String: Any]? = nil) async throws -> Data {
        guard active else { throw MediaIntegrationError.disconnected }
        if let backoffUntil, backoffUntil > Date() {
            throw MediaIntegrationError.http(429, retryAfter: backoffUntil.timeIntervalSinceNow)
        }
        var headers: [String: String] = [:]
        if let key = credential.apiKey, !key.isEmpty { headers["X-Api-Key"] = key }
        else if let cookie = credential.cookie, !cookie.isEmpty { headers["Cookie"] = "connect.sid=" + cookie }
        else { throw MediaIntegrationError.disconnected }
        do {
            return try await http.send(["api", "v1"] + path, method: method, query: query,
                headers: headers, body: body.map { try MediaIntegrationHTTP.body($0) }).0
        } catch let error as MediaIntegrationError {
            if case .http(429, let retry) = error { backoffUntil = Date().addingTimeInterval(max(1, retry ?? 30)) }
            throw error
        }
    }

    func me() async throws -> SeerrUser { try await send(["auth", "me"]) }
    func quota(userID: Int) async throws -> SeerrQuota { try await send(["user", String(userID), "quota"]) }
    func discover(kind: SeerrMediaKind, page: Int) async throws -> SeerrPage<SeerrTitle> {
        try await send(["discover", kind == .movie ? "movies" : "tv"], query: [.init(name: "page", value: String(max(1, page)))])
    }
    func search(_ query: String, page: Int) async throws -> SeerrPage<SeerrTitle> {
        try await send(["search"], query: [.init(name: "query", value: query), .init(name: "page", value: String(max(1, page)))])
    }
    func details(id: Int, kind: SeerrMediaKind) async throws -> SeerrTitle {
        let title: SeerrTitle = try await send([kind.rawValue, String(id)])
        guard id > 0, title.id == id else { throw MediaIntegrationError.invalidResponse }
        return title
    }
    func requests(skip: Int = 0, filter: String = "all") async throws -> SeerrPage<SeerrRequest> {
        try await send(["request"], query: [.init(name: "take", value: "20"), .init(name: "skip", value: String(max(0, skip))),
            .init(name: "filter", value: filter), .init(name: "sort", value: "modified")])
    }

    func services(kind: SeerrMediaKind) async throws -> [SeerrService] {
        try await send(["service", kind == .movie ? "radarr" : "sonarr"])
    }
    func serviceDetails(id: Int, kind: SeerrMediaKind) async throws -> SeerrServiceDetails {
        try await send(["service", kind == .movie ? "radarr" : "sonarr", String(id)])
    }

    func request(id: Int, kind: SeerrMediaKind, seasons: Set<Int>, is4k: Bool, options: SeerrRequestOptions? = nil) async throws -> SeerrRequest {
        guard id > 0 else { throw MediaIntegrationError.invalidResponse }
        let user = try await me()
        guard user.canRequest(kind, is4k: is4k) else {
            throw MediaIntegrationError.unavailable("Your Seerr account cannot request this media type or quality.")
        }
        let quotas = try await quota(userID: user.id)
        let limit = kind == .movie ? quotas.movie : quotas.tv
        guard limit?.restricted != true else { throw MediaIntegrationError.unavailable("Your Seerr request quota is currently reached.") }
        let latest = try await details(id: id, kind: kind)
        let status = is4k ? latest.mediaInfo?.status4k : latest.mediaInfo?.status
        guard status != 5 else { throw MediaIntegrationError.unavailable("This title is already available in that quality.") }
        var body: [String: Any] = ["mediaId": id, "mediaType": kind.rawValue, "is4k": is4k]
        if let options {
            guard user.permits(8192) || user.managesRequests else { throw MediaIntegrationError.http(403, retryAfter: nil) }
            let servers = try await services(kind: kind)
            guard servers.contains(where: { $0.id == options.serverID && ($0.is4k ?? false) == is4k }) else {
                throw MediaIntegrationError.unavailable("The selected request server is unavailable for this quality. Choose it again.")
            }
            let details = try await serviceDetails(id: options.serverID, kind: kind)
            guard details.server.id == options.serverID else { throw MediaIntegrationError.invalidResponse }
            body["serverId"] = options.serverID
            if let id = options.profileID {
                guard details.profiles.contains(where: { $0.id == id }) else { throw MediaIntegrationError.invalidResponse }
                body["profileId"] = id
            }
            if let folder = options.rootFolder {
                guard details.rootFolders?.contains(where: { $0.path == folder }) == true else { throw MediaIntegrationError.invalidResponse }
                body["rootFolder"] = folder
            }
            if let id = options.languageProfileID {
                guard kind == .tv, details.languageProfiles?.contains(where: { $0.id == id }) == true else { throw MediaIntegrationError.invalidResponse }
                body["languageProfileId"] = id
            }
        }
        if kind == .tv {
            let known = Set((latest.seasons ?? []).map(\.seasonNumber))
            let eligible = seasons.filter { number in
                guard number >= 0, known.contains(number) else { return false }
                let existing = latest.mediaInfo?.seasons?.first { $0.seasonNumber == number }
                return ![2, 3, 5].contains((is4k ? existing?.status4k : existing?.status) ?? 0)
            }
            guard !eligible.isEmpty else { throw MediaIntegrationError.unavailable("Choose at least one season that is not already available.") }
            body["seasons"] = eligible.sorted()
        } else if (latest.mediaInfo?.requests ?? []).contains(where: { [1, 2].contains($0.status) && ($0.is4k ?? false) == is4k }) {
            throw MediaIntegrationError.unavailable("A request already exists. Refresh to see its current status.")
        }
        return try await send(["request"], method: "POST", body: body)
    }

    func cancel(_ request: SeerrRequest) async throws {
        let user = try await me()
        guard user.managesRequests || (request.requestedBy?.id == user.id && request.status == 1) else {
            throw MediaIntegrationError.unavailable("Only your pending requests can be cancelled with this account.")
        }
        _ = try await raw(["request", String(request.id)], method: "DELETE")
    }
    func decide(_ request: SeerrRequest, approve: Bool) async throws -> SeerrRequest {
        guard try await me().managesRequests else { throw MediaIntegrationError.http(403, retryAfter: nil) }
        return try await send(["request", String(request.id), approve ? "approve" : "decline"], method: "POST")
    }
    func retry(_ request: SeerrRequest) async throws -> SeerrRequest {
        guard try await me().managesRequests else { throw MediaIntegrationError.http(403, retryAfter: nil) }
        return try await send(["request", String(request.id), "retry"], method: "POST")
    }
    func signOut() async {
        active = false
        let cookie = credential.cookie
        credential = SeerrCredential()
        if let cookie {
            _ = try? await http.send(["api", "v1", "auth", "logout"], method: "POST",
                headers: ["Cookie": "connect.sid=" + cookie])
        }
    }
}
