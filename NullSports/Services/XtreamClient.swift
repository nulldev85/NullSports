import Foundation

struct XtreamClient {
    let profile: XtreamProfile
    let password: String

    func authenticate() async throws -> XtreamEnvelope {
        try await request(action: nil)
    }

    func categories() async throws -> [XtreamCategory] {
        try await request(action: "get_live_categories")
    }

    func streams() async throws -> [XtreamStream] {
        try await request(action: "get_live_streams")
    }

    func playbackURLs(for stream: XtreamStream) -> [URL] {
        guard let base = normalizedBaseURL else { return [] }
        let root = base.appendingPathComponent("live")
            .appendingPathComponent(profile.username)
            .appendingPathComponent(password)
        return ["m3u8", "ts"].map { root.appendingPathComponent("\(stream.streamID).\($0)") }
    }

    func programsToday() async throws -> [String: [CurrentProgram]] {
        guard let base = normalizedBaseURL,
              var components = URLComponents(url: base.appendingPathComponent("xmltv.php"), resolvingAgainstBaseURL: false)
        else { throw XtreamError.invalidServer }
        components.queryItems = [
            URLQueryItem(name: "username", value: profile.username),
            URLQueryItem(name: "password", value: password)
        ]
        guard let url = components.url else { throw XtreamError.invalidServer }
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.cachePolicy = .reloadRevalidatingCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw XtreamError.serverRejected
        }
        return await Task.detached(priority: .utility) {
            XMLTVParser().parse(data)
        }.value
    }

    private func request<T: Decodable>(action: String?) async throws -> T {
        guard let base = normalizedBaseURL,
              var components = URLComponents(url: base.appendingPathComponent("player_api.php"), resolvingAgainstBaseURL: false)
        else { throw XtreamError.invalidServer }
        var items = [
            URLQueryItem(name: "username", value: profile.username),
            URLQueryItem(name: "password", value: password)
        ]
        if let action { items.append(URLQueryItem(name: "action", value: action)) }
        components.queryItems = items
        guard let url = components.url else { throw XtreamError.invalidServer }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw XtreamError.serverRejected
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw XtreamError.invalidResponse }
    }

    private var normalizedBaseURL: URL? {
        let trimmed = profile.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        return URL(string: value)?.standardized
    }

    enum XtreamError: LocalizedError {
        case invalidServer, serverRejected, invalidResponse, unauthorized
        var errorDescription: String? {
            switch self {
            case .invalidServer: "Enter a valid server URL."
            case .serverRejected: "The IPTV server did not accept the connection."
            case .invalidResponse: "The server returned data NullSports could not read."
            case .unauthorized: "The username or password was not accepted."
            }
        }
    }
}
