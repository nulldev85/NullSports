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

    func items(userID: String, parentID: String) async throws -> [MediaItem] {
        let query = [
            URLQueryItem(name: "ParentId", value: parentID),
            URLQueryItem(name: "Fields", value: "Overview,PrimaryImageAspectRatio,ProductionYear,ChildCount"),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary"),
            URLQueryItem(name: "Limit", value: "40"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending")
        ]
        let response: JellyfinItemsResponse = try await send(
            try request(path: "users/\(userID)/items", query: query))
        return response.items
    }

    func imageURL(itemID: String, maxWidth: Int = 600) -> URL? {
        authenticatedURL(path: "items/\(itemID)/images/primary", query: [
            URLQueryItem(name: "maxWidth", value: String(maxWidth)),
            URLQueryItem(name: "quality", value: "88")
        ])
    }

    func playbackURL(itemID: String) -> URL? {
        authenticatedURL(path: "videos/\(itemID)/stream", query: [
            URLQueryItem(name: "static", value: "true")
        ])
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

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JellyfinError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw JellyfinError.authenticationFailed }
            throw JellyfinError.server(http.statusCode)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw JellyfinError.invalidResponse }
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
