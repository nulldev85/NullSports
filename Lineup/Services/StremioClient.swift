import Foundation

/// One addon, talked to directly.
///
/// There is no account, no token and no session: an addon is a public JSON API
/// and every request is a plain GET. That is the whole reason to add them.
/// Where a media server has to be told to import a catalog and then walked
/// through minutes of work before anything shows up, an addon answers with the
/// catalog itself in one request.
struct StremioClient: Sendable {
    /// The addon's base, with `/manifest.json` taken off the end.
    let baseURL: URL
    private let session: URLSession

    init(address: String, session: URLSession = .shared) throws {
        self.baseURL = try Self.base(from: address)
        self.session = session
    }

    /// What people paste is rarely what the protocol wants.
    ///
    /// Addon links are handed out as `stremio://host/manifest.json` so that a
    /// desktop install can claim them, and copied with or without the manifest
    /// on the end and with or without a trailing slash. All four spellings name
    /// the same addon, so all four are accepted and reduced to the one thing
    /// the requests below are built from.
    static func base(from address: String) throws -> URL {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("stremio://") {
            text = "https://" + text.dropFirst("stremio://".count)
        }
        if !text.lowercased().hasPrefix("http") { text = "https://" + text }
        if let manifest = text.range(of: "/manifest.json", options: [.caseInsensitive, .backwards]),
           manifest.upperBound == text.endIndex {
            text.removeSubrange(manifest)
        }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let host = url.host, !host.isEmpty else {
            throw StremioError.invalidAddress
        }
        return url
    }

    func manifest() async throws -> StremioManifest {
        try await get(path: "manifest.json")
    }

    /// A row of things. `extra` carries the named parameters the protocol puts
    /// in the path rather than the query string: `skip=100`, `genre=Action`,
    /// `search=alien`.
    func catalog(type: String, id: String, extra: [(String, String)] = []) async throws -> [StremioMeta] {
        var path = "catalog/\(escape(type))/\(escape(id))"
        if !extra.isEmpty {
            let pairs = extra.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
            path += "/\(pairs)"
        }
        let response: StremioCatalogResponse = try await get(path: path + ".json")
        return response.metas
    }

    func meta(type: String, id: String) async throws -> StremioMeta {
        let response: StremioMetaResponse = try await get(
            path: "meta/\(escape(type))/\(escape(id)).json")
        return response.meta
    }

    func streams(type: String, id: String) async throws -> [StremioStream] {
        let response: StremioStreamResponse = try await get(
            path: "stream/\(escape(type))/\(escape(id)).json")
        return response.streams
    }

    // Ids are not tame. They carry colons ("tt0108778:1:1"), and the ones
    // addons mint for their own catalogs carry slashes, spaces and pipes, any
    // of which would otherwise end the path segment early or be refused.
    private func escape(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/=&")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func get<T: Decodable>(path: String) async throws -> T {
        guard let url = URL(string: baseURL.absoluteString + "/" + path) else {
            throw StremioError.invalidAddress
        }
        var request = URLRequest(url: url)
        // An addon that is asleep, rate limited or simply slow should not hold
        // a screen open indefinitely; the request behind it is one small JSON
        // document, and everything here asks several addons at once.
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw StremioError.server(http.statusCode)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw StremioError.badResponse }
    }
}

enum StremioError: LocalizedError {
    case invalidAddress
    case server(Int)
    case badResponse
    case notAnAddon

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "That does not look like an addon address. Paste the link that ends in /manifest.json."
        case .server(let status):
            return "The addon answered with error \(status)."
        case .badResponse:
            return "The addon answered with something this app could not read."
        case .notAnAddon:
            return "That address answered, but not with an addon manifest."
        }
    }
}
