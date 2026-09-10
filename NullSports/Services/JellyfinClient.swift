import Foundation

struct JellyfinClient: Sendable {
    let serverURL: URL
    let accessToken: String?
    let deviceID: String
    private let session: URLSession

    init(serverURL: String, accessToken: String? = nil, deviceID: String,
         session: URLSession = .shared) throws {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed), let scheme = url.scheme,
              ["http", "https"].contains(scheme.lowercased()), url.host != nil else {
            throw JellyfinError.invalidServer
        }
        self.serverURL = url
        self.accessToken = accessToken
        self.deviceID = deviceID
        self.session = session
    }

    func authenticate(username: String, password: String) async throws -> JellyfinAuthenticationResponse {
        var request = try request(path: "users/authenticatebyname", method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])
        return try await send(request)
    }

    func views(userID: String) async throws -> [MediaItem] {
        let response: JellyfinItemsResponse = try await send(try request(path: "users/\(userID)/views"))
        return response.items
    }

    // Everything a shelf card, a show page and an episode card between them need.
    // Asked for once, so no screen has to go back for a second round.
    static let fields = "Overview,Genres,OfficialRating,CommunityRating,CriticRating,"
        + "RunTimeTicks,PremiereDate,PrimaryImageAspectRatio,ProductionYear,ChildCount"

    func items(userID: String, parentID: String,
               sortBy: String = "SortName", limit: Int = 40) async throws -> [MediaItem] {
        let query = [
            URLQueryItem(name: "ParentId", value: parentID),
            URLQueryItem(name: "Fields", value: Self.fields),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Logo"),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "SortBy", value: sortBy),
            URLQueryItem(name: "SortOrder", value: "Ascending")
        ]
        let response: JellyfinItemsResponse = try await send(
            try request(path: "users/\(userID)/items", query: query))
        return response.items
    }

    func item(userID: String, itemID: String) async throws -> MediaItem {
        try await send(try request(path: "users/\(userID)/items/\(itemID)"))
    }

    // The server already knows where a viewer is up to in a series, and it is a
    // better answer than any guess made from which episodes are marked played.
    func nextUp(userID: String, seriesID: String) async throws -> [MediaItem] {
        let query = [
            URLQueryItem(name: "userId", value: userID),
            URLQueryItem(name: "seriesId", value: seriesID),
            URLQueryItem(name: "Fields", value: Self.fields),
            URLQueryItem(name: "Limit", value: "1")
        ]
        let response: JellyfinItemsResponse = try await send(
            try request(path: "shows/nextup", query: query))
        return response.items
    }

    func setFavorite(userID: String, itemID: String, isFavorite: Bool) async throws {
        try await sendIgnoringBody(
            try request(path: "users/\(userID)/favoriteitems/\(itemID)",
                method: isFavorite ? "POST" : "DELETE"))
    }

    func search(userID: String, query: String) async throws -> [MediaItem] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return [] }
        let parameters = [
            URLQueryItem(name: "UserId", value: userID),
            URLQueryItem(name: "SearchTerm", value: value),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series,Episode,Video"),
            URLQueryItem(name: "Fields", value: Self.fields),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Logo"),
            URLQueryItem(name: "Limit", value: "60")
        ]
        let response: JellyfinItemsResponse = try await send(
            try request(path: "users/\(userID)/items", query: parameters))
        return response.items
    }

    func imageURL(itemID: String, type: String = "primary", maxWidth: Int = 600) -> URL? {
        authenticatedURL(path: "items/\(itemID)/images/\(type)", query: [
            URLQueryItem(name: "maxWidth", value: String(maxWidth)),
            URLQueryItem(name: "quality", value: "88")
        ])
    }

    func playbackURL(itemID: String) -> URL? {
        playbackURL(itemID: itemID, mediaSourceID: nil)
    }

    func playbackInfo(itemID: String) async throws -> MediaPlaybackInfo {
        var value = try request(path: "items/\(itemID)/playbackinfo", method: "POST")
        value.httpBody = Data("{}".utf8)
        return try await send(value)
    }

    func playbackURL(itemID: String, mediaSourceID: String?) -> URL? {
        var query = [URLQueryItem(name: "static", value: "true")]
        if let mediaSourceID { query.append(URLQueryItem(name: "MediaSourceId", value: mediaSourceID)) }
        return authenticatedURL(path: "videos/\(itemID)/stream", query: query)
    }

    private func request(path: String, method: String = "GET", query: [URLQueryItem] = []) throws -> URLRequest {
        guard var components = URLComponents(url: serverURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw JellyfinError.invalidServer
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw JellyfinError.invalidServer }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var authorization = "MediaBrowser Client=\"NullSports\", Device=\"Apple\", DeviceId=\"\(deviceID)\", Version=\"1.0\""
        if let accessToken { authorization += ", Token=\"\(accessToken)\"" }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        if let accessToken { request.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token") }
        return request
    }

    private func authenticatedURL(path: String, query: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(url: serverURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { return nil }
        var values = query
        if let accessToken { values.append(URLQueryItem(name: "api_key", value: accessToken)) }
        components.queryItems = values
        return components.url
    }

    private func sendIgnoringBody(_ request: URLRequest) async throws {
        let (_, response) = try await session.data(for: request)
        try Self.check(response)
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw JellyfinError.invalidResponse }
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw JellyfinError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw JellyfinError.authenticationFailed }
            throw JellyfinError.server(http.statusCode)
        }
    }
}

enum JellyfinError: LocalizedError {
    case invalidServer
    case authenticationFailed
    case invalidResponse
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .invalidServer: "Enter a valid Jellyfin or Nullfin server URL."
        case .authenticationFailed: "The media server rejected those credentials."
        case .invalidResponse: "The server returned an unsupported response."
        case .server(let status): "The media server returned HTTP \(status)."
        }
    }
}
