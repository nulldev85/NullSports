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

    // MARK: On demand

    func onDemandCategories(_ kind: OnDemandKind) async throws -> [OnDemandCategory] {
        let list: OnDemandWire.Lossy<OnDemandWire.Category> = try await onDemand(
            action: kind == .movies ? "get_vod_categories" : "get_series_categories")
        var seen = Set<String>()
        return list.values.map(\.category).filter { seen.insert($0.id).inserted }
    }

    /// One category's titles, or the whole catalogue when `categoryID` is nil.
    /// The whole catalogue is the one request here that can be large, so it is
    /// given the time a large answer needs.
    func onDemandTitles(_ kind: OnDemandKind, categoryID: String?) async throws -> [OnDemandTitle] {
        let list: OnDemandWire.Lossy<OnDemandWire.Title> = try await onDemand(
            action: kind == .movies ? "get_vod_streams" : "get_series",
            parameters: categoryID.map { [URLQueryItem(name: "category_id", value: $0)] } ?? [],
            timeout: categoryID == nil ? 120 : 45)
        var seen = Set<String>()
        return list.values.map(\.title).filter { $0.kind == kind && seen.insert($0.id).inserted }
    }

    func movieDetail(streamID: String) async throws -> OnDemandMovieDetail {
        let info: OnDemandWire.MovieInfo = try await onDemand(
            action: "get_vod_info", parameters: [URLQueryItem(name: "vod_id", value: streamID)])
        return info.detail
    }

    func seriesDetail(seriesID: String) async throws -> OnDemandSeriesDetail {
        let info: OnDemandWire.SeriesInfo = try await onDemand(
            action: "get_series_info", parameters: [URLQueryItem(name: "series_id", value: seriesID)],
            timeout: 45)
        return info.detail(seriesID: seriesID)
    }

    /// `/movie/…/{id}.{ext}` for a film, `/series/…/{id}.{ext}` for an episode.
    /// A title with no file type named is asked for as mp4, which is what
    /// panels serve when they are not told otherwise.
    func onDemandURL(_ kind: OnDemandPlayback.Kind, streamID: String, containerExtension: String?) -> URL? {
        guard let base = normalizedBaseURL, !streamID.isEmpty else { return nil }
        let ext = containerExtension?.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        return base.appendingPathComponent(kind == .movie ? "movie" : "series")
            .appendingPathComponent(profile.username)
            .appendingPathComponent(password)
            .appendingPathComponent("\(streamID).\(ext?.isEmpty == false ? ext! : "mp4")")
    }

    private func onDemand<T: Decodable & Sendable>(action: String, parameters: [URLQueryItem] = [],
                                        timeout: TimeInterval = 30) async throws -> T {
        let data = try await payload(action: action, parameters: parameters, timeout: timeout)
        // A full catalogue can be tens of megabytes; decoding it is not work
        // for whichever thread happened to ask.
        return try await Task.detached(priority: .userInitiated) {
            do { return try JSONDecoder().decode(T.self, from: data) }
            catch { throw XtreamError.invalidResponse }
        }.value
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

    /// The bytes an action answers with, before anything has been made of
    /// them. Both request paths go through here so the digest is taken of
    /// exactly what arrived.
    private func payload(action: String?, parameters: [URLQueryItem] = [],
                         timeout: TimeInterval = 20) async throws -> Data {
        guard let base = normalizedBaseURL,
              var components = URLComponents(url: base.appendingPathComponent("player_api.php"), resolvingAgainstBaseURL: false)
        else { throw XtreamError.invalidServer }
        var items = [
            URLQueryItem(name: "username", value: profile.username),
            URLQueryItem(name: "password", value: password)
        ]
        if let action { items.append(URLQueryItem(name: "action", value: action)) }
        components.queryItems = items + parameters
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
