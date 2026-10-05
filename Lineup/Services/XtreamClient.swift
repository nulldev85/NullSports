import Foundation
import CryptoKit

/// A digest of exactly the bytes a server sent.
///
/// Swift's own hashing is seeded per process, so a `hashValue` written to the
/// cache means nothing on the next launch. This is stable, which is the whole
/// point: the comparison that matters is against what the server sent the last
/// time the app ran.
enum XtreamPayloadDigest {
    static func of(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Something a server sent, and the digest of the bytes it arrived in.
struct XtreamPayload<Value: Sendable>: Sendable {
    let value: Value
    let digest: String
    /// How much arrived. The digest saves the app parsing these bytes; it does
    /// not save downloading them, and the difference is worth being able to
    /// see rather than assume.
    let bytes: Int
}

/// What a server said when asked "only if it changed".
enum XtreamAnswer<Value: Sendable>: Sendable {
    /// The same bytes as last time. They still came down the wire -- this says
    /// how many -- but nothing was parsed, compared or written.
    case unchanged(bytes: Int)
    case fresh(XtreamPayload<Value>)

    var payload: XtreamPayload<Value>? {
        if case .fresh(let payload) = self { return payload }
        return nil
    }

    var bytes: Int {
        switch self {
        case .unchanged(let bytes): return bytes
        case .fresh(let payload): return payload.bytes
        }
    }
}

struct XtreamClient {
    let profile: XtreamProfile
    let password: String

    func authenticate() async throws -> XtreamEnvelope {
        try await request(action: nil)
    }

    func categories(ifChangedFrom digest: String?) async throws -> XtreamAnswer<[XtreamCategory]> {
        try await request(action: "get_live_categories", ifChangedFrom: digest)
    }

    /// On a large provider this list is the bulk of a refresh, and decoding it
    /// only to find it unchanged was most of what a refresh did.
    func streams(ifChangedFrom digest: String?) async throws -> XtreamAnswer<[XtreamStream]> {
        try await request(action: "get_live_streams", ifChangedFrom: digest)
    }

    func playbackURLs(for stream: XtreamStream) -> [URL] {
        guard let base = normalizedBaseURL else { return [] }
        let root = base.appendingPathComponent("live")
            .appendingPathComponent(profile.username)
            .appendingPathComponent(password)
        return ["m3u8", "ts"].map { root.appendingPathComponent("\(stream.streamID).\($0)") }
    }

    /// The guide, or nil when the server sent the same bytes as last time.
    ///
    /// Identical bytes parse to an identical guide, so the comparison happens
    /// on 32 bytes of digest instead of on every listing of every channel --
    /// and, better, the parse is skipped entirely. Parsing a day of XMLTV for
    /// a full channel list is the most expensive thing a refresh does.
    ///
    /// The one thing this does not refresh is the parser's own trailing edge:
    /// listings are trimmed relative to when the parse runs, so skipping it
    /// keeps whatever the last parse kept. That is exactly what the app did
    /// before when it found the guide unchanged, and nothing reads past the
    /// hour of history the Guide draws.
    func programsToday(ifChangedFrom digest: String?) async throws -> XtreamAnswer<[String: [CurrentProgram]]> {
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
        let fresh = XtreamPayloadDigest.of(data)
        if let digest, digest == fresh { return .unchanged(bytes: data.count) }
        let programs = await Task.detached(priority: .utility) {
            XMLTVParser().parse(data)
        }.value
        return .fresh(XtreamPayload(value: programs, digest: fresh, bytes: data.count))
    }

    // MARK: - Video library

    /// Every film the provider has. On a large provider that is tens of
    /// thousands of entries and several megabytes, so it gets longer than a
    /// channel list does.
    func vodStreams() async throws -> [XtreamVODStream] {
        try Self.decodeList(try await payload(action: "get_vod_streams", timeout: 90))
    }

    /// Every show the provider has.
    func series() async throws -> [XtreamSeries] {
        try Self.decodeList(try await payload(action: "get_series", timeout: 90))
    }

    /// One show's episodes, season by season.
    func seriesInfo(seriesID: Int) async throws -> XtreamSeriesInfo {
        let data = try await payload(action: "get_series_info",
            extra: [URLQueryItem(name: "series_id", value: String(seriesID))], timeout: 30)
        do { return try JSONDecoder().decode(XtreamSeriesInfo.self, from: data) }
        catch { throw XtreamError.invalidResponse }
    }

    /// What the provider says about one film beyond its list entry.
    func vodInfo(streamID: Int) async throws -> XtreamVODInfo {
        let data = try await payload(action: "get_vod_info",
            extra: [URLQueryItem(name: "vod_id", value: String(streamID))], timeout: 30)
        do { return try JSONDecoder().decode(XtreamVODInfo.self, from: data) }
        catch { throw XtreamError.invalidResponse }
    }

    func vodCategories() async throws -> [XtreamCategory] {
        try Self.decodeList(try await payload(action: "get_vod_categories"))
    }

    func seriesCategories() async throws -> [XtreamCategory] {
        try Self.decodeList(try await payload(action: "get_series_categories"))
    }

    /// Where a film plays from: `/movie/<user>/<password>/<id>.<extension>`.
    func movieURL(for film: XtreamVODStream) -> URL? {
        mediaURL(kind: "movie", id: String(film.streamID), container: film.containerExtension)
    }

    /// Where an episode plays from: `/series/<user>/<password>/<id>.<extension>`.
    func episodeURL(for episode: XtreamEpisode) -> URL? {
        mediaURL(kind: "series", id: episode.id, container: episode.containerExtension)
    }

    private func mediaURL(kind: String, id: String, container: String?) -> URL? {
        guard let base = normalizedBaseURL else { return nil }
        let ext = container?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return base.appendingPathComponent(kind)
            .appendingPathComponent(profile.username)
            .appendingPathComponent(password)
            .appendingPathComponent(ext.isEmpty ? id : "\(id).\(ext)")
    }

    /// A list whose entries are read one at a time, so an entry that will not
    /// read is dropped rather than failing the list.
    private static func decodeList<T: Decodable & Sendable>(_ data: Data) throws -> [T] {
        do { return try JSONDecoder().decode([Lenient<T>].self, from: data).compactMap(\.value) }
        catch { throw XtreamError.invalidResponse }
    }

    /// The bytes an action answers with, before anything has been made of
    /// them. Both request paths go through here so the digest is taken of
    /// exactly what arrived.
    private func payload(action: String?, extra: [URLQueryItem] = [],
                         timeout: TimeInterval = 20) async throws -> Data {
        guard let base = normalizedBaseURL,
              var components = URLComponents(url: base.appendingPathComponent("player_api.php"), resolvingAgainstBaseURL: false)
        else { throw XtreamError.invalidServer }
        var items = [
            URLQueryItem(name: "username", value: profile.username),
            URLQueryItem(name: "password", value: password)
        ]
        if let action { items.append(URLQueryItem(name: "action", value: action)) }
        components.queryItems = items + extra
        guard let url = components.url else { throw XtreamError.invalidServer }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw XtreamError.serverRejected
        }
        return data
    }

    private func request<T: Decodable>(action: String?) async throws -> T {
        let data = try await payload(action: action)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw XtreamError.invalidResponse }
    }

    private func request<T: Decodable & Sendable>(action: String?,
                                                 ifChangedFrom digest: String?) async throws -> XtreamAnswer<T> {
        let data = try await payload(action: action)
        let fresh = XtreamPayloadDigest.of(data)
        if let digest, digest == fresh { return .unchanged(bytes: data.count) }
        do {
            return .fresh(XtreamPayload(value: try JSONDecoder().decode(T.self, from: data),
                                        digest: fresh, bytes: data.count))
        } catch { throw XtreamError.invalidResponse }
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
            case .invalidResponse: "The server returned data Lineup could not read."
            case .unauthorized: "The username or password was not accepted."
            }
        }
    }
}
