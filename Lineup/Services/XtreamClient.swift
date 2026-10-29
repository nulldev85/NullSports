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

/// What a guide server said identifies the guide it sent -- its `ETag` and
/// `Last-Modified` -- with the digest of those bytes, so the next refresh can
/// ask for them only if they changed. Kept per guide address, by a digest of
/// it: the address carries the account's password.
struct GuideValidators {
    struct Entry: Codable, Equatable {
        let digest: String
        let etag: String?
        let lastModified: String?
    }

    static let key = "Lineup.guideValidators.v1"
    let defaults: UserDefaults

    func entry(for url: URL) -> Entry? {
        guard let saved = defaults.data(forKey: Self.key),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: saved) else { return nil }
        return entries[Self.name(url)]
    }

    /// A server that sent neither validator has nothing to ask with, and
    /// its address is forgotten.
    func record(_ entry: Entry, for url: URL) {
        var entries = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        let name = Self.name(url)
        let kept = entry.etag != nil || entry.lastModified != nil ? entry : nil
        guard entries[name] != kept else { return }
        entries[name] = kept
        if entries.count > 16, let kept { entries = [name: kept] }
        defaults.set(try? JSONEncoder().encode(entries), forKey: Self.key)
    }

    private static func name(_ url: URL) -> String { XtreamPayloadDigest.of(Data(url.absoluteString.utf8)) }
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

/// How much of a download has arrived, for a refresh's percentage.
struct XtreamDownloadUpdate: Sendable {
    let received: Int64
    /// The size the server gave, or nil when it did not say.
    let expected: Int64?
    /// The last word on a download: `received` is everything that came.
    let finished: Bool
}

/// Hands back the task an async `data(for:delegate:)` call makes, so how much
/// of it has arrived can be read while the call is still waiting.
///
/// Read from a clock rather than told about each chunk: a ninety-megabyte
/// guide arrives in tens of thousands of chunks, and the download should not
/// slow down to report on itself.
private final class XtreamDownloadWatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        lock.withLock { self.task = task }
    }

    var counts: (received: Int64, expected: Int64)? {
        lock.withLock {
            task.map { (received: $0.countOfBytesReceived, expected: $0.countOfBytesExpectedToReceive) }
        }
    }
}

struct XtreamClient {
    /// Told how a download is going, on the main actor, a few times a second
    /// and once more when it is done.
    typealias DownloadProgress = @MainActor @Sendable (XtreamDownloadUpdate) -> Void

    let profile: XtreamProfile
    let password: String
    var session: URLSession = .shared

    func authenticate() async throws -> XtreamEnvelope {
        guard !profile.isPlaylist else { throw XtreamError.invalidServer }
        return try await request(action: nil)
    }

    func categories(ifChangedFrom digest: String?) async throws -> XtreamAnswer<[XtreamCategory]> {
        if profile.isPlaylist {
            let list = try await PlaylistDownloads.shared.load(profileID: profile.id, secret: password)
            return digest == list.digest ? .unchanged(bytes: list.bytes) : .fresh(XtreamPayload(value: list.categories, digest: list.digest, bytes: list.bytes))
        }
        return try await request(action: "get_live_categories", ifChangedFrom: digest)
    }

    /// On a large provider this list is the bulk of a refresh, and decoding it
    /// only to find it unchanged was most of what a refresh did.
    func streams(ifChangedFrom digest: String?,
                 progress: DownloadProgress? = nil) async throws -> XtreamAnswer<[XtreamStream]> {
        if profile.isPlaylist {
            let list = try await PlaylistDownloads.shared.load(profileID: profile.id, secret: password)
            return digest == list.digest ? .unchanged(bytes: list.bytes) : .fresh(XtreamPayload(value: list.streams, digest: list.digest, bytes: list.bytes))
        }
        return try await request(action: "get_live_streams", ifChangedFrom: digest, progress: progress)
    }

    func playbackURLs(for stream: XtreamStream) -> [URL] {
        if profile.isPlaylist {
            return PlaylistCache.read(profileID: profile.id, secret: password)?.urls[stream.id].map { [$0] } ?? []
        }
        guard let base = normalizedBaseURL else { return [] }
        let root = base.appendingPathComponent("live")
            .appendingPathComponent(profile.username)
            .appendingPathComponent(password)
        return ["m3u8", "ts"].map { root.appendingPathComponent("\(stream.streamID).\($0)") }
    }

    // MARK: - Catch-up

    /// Where a channel's recording plays from, starting at `start` and
    /// running `minutes`: the panel's path form first, which nearly every
    /// panel answers, and its older script form after it.
    ///
    /// The start is written in the server's own time -- that is how panels
    /// read it -- and to the minute, as finely as either form can say.
    func catchUpURLs(for stream: XtreamStream, from start: Date, minutes: Int,
                     serverTimeZone: TimeZone) -> [URL] {
        guard !profile.isPlaylist else { return [] }
        guard let base = normalizedBaseURL else { return [] }
        let stamp = CatchUpPolicy.addressStamp(start, in: serverTimeZone)
        let path = base.appendingPathComponent("timeshift")
            .appendingPathComponent(profile.username)
            .appendingPathComponent(password)
            .appendingPathComponent(String(minutes))
            .appendingPathComponent(stamp)
            .appendingPathComponent("\(stream.streamID).ts")
        var urls = [path]
        if var components = URLComponents(url: base.appendingPathComponent("streaming")
                                            .appendingPathComponent("timeshift.php"),
                                          resolvingAgainstBaseURL: false) {
            components.queryItems = [
                URLQueryItem(name: "username", value: profile.username),
                URLQueryItem(name: "password", value: password),
                URLQueryItem(name: "stream", value: String(stream.streamID)),
                URLQueryItem(name: "start", value: stamp),
                URLQueryItem(name: "duration", value: String(minutes))
            ]
            if let script = components.url { urls.append(script) }
        }
        return urls
    }

    /// One channel's listings as the provider keeps them for catch-up: days
    /// back, each saying whether it was recorded.
    func catchUpTable(streamID: Int) async throws -> XtreamArchiveTable {
        let data = try await payload(action: "get_simple_data_table",
            extra: [URLQueryItem(name: "stream_id", value: String(streamID))], timeout: 25)
        do { return try JSONDecoder().decode(XtreamArchiveTable.self, from: data) }
        catch { throw XtreamError.invalidResponse }
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
    func programsToday(ifChangedFrom digest: String?,
                       progress: DownloadProgress? = nil) async throws -> XtreamAnswer<[String: [CurrentProgram]]> {
        let url: URL
        if profile.isPlaylist {
            let credentials = try PlaylistCredentials.read(password)
            // Guide refresh starts beside channel refresh. Use the same
            // playlist fetch when its header supplies the guide URL.
            var headerGuide: URL?
            if credentials.guide == nil {
                headerGuide = try await PlaylistDownloads.shared.load(profileID: profile.id, secret: password).guide
            }
            guard let guide = credentials.guide ?? headerGuide else {
                return .fresh(XtreamPayload(value: [:], digest: "no-guide", bytes: 0))
            }
            url = guide
        } else {
            guard let base = normalizedBaseURL,
                  var components = URLComponents(url: base.appendingPathComponent("xmltv.php"), resolvingAgainstBaseURL: false)
            else { throw XtreamError.invalidServer }
            components.queryItems = [
                URLQueryItem(name: "username", value: profile.username),
                URLQueryItem(name: "password", value: password)
            ]
            guard let address = components.url else { throw XtreamError.invalidServer }
            url = address
        }
        var request = URLRequest(url: url)
        // A guide service can build the file when it is asked for it and send
        // nothing for a minute or more, as panels do with their film lists.
        // This is the silence allowed before the first byte; a guide that is
        // still arriving never times out.
        request.timeoutInterval = 180
        // The guide is too big for the shared cache to keep, so the app keeps
        // the server's validators itself and asks whether the guide it holds
        // has changed. A server that keeps them answers 304 and sends nothing;
        // one that doesn't sends the guide as before.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let validators = GuideValidators(defaults: .standard)
        if let digest, let saved = validators.entry(for: url), saved.digest == digest {
            if let etag = saved.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let modified = saved.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        }
        let (data, response) = try await Self.data(for: request, progress: progress)
        guard let http = response as? HTTPURLResponse else { throw XtreamError.serverRejected }
        if http.statusCode == 304, digest != nil { return .unchanged(bytes: 0) }
        guard (200..<300).contains(http.statusCode) else { throw XtreamError.serverRejected }
        let fresh = XtreamPayloadDigest.of(data)
        let entry = GuideValidators.Entry(digest: fresh, etag: http.value(forHTTPHeaderField: "ETag"),
                                          lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
        if let digest, digest == fresh {
            validators.record(entry, for: url)
            return .unchanged(bytes: data.count)
        }
        let programs = try await Task.detached(priority: .utility) {
            try XMLTVParser.programs(fromGuide: data)
        }.value
        // Only for a guide that read: the validators stand for what is held.
        validators.record(entry, for: url)
        return .fresh(XtreamPayload(value: programs, digest: fresh, bytes: data.count))
    }

    // MARK: - Video library

    /// Every film the provider has. On a large provider that is tens of
    /// thousands of entries and many megabytes, which a panel can take a
    /// minute or more to start sending -- so it gets far longer than a
    /// channel list does. The wait is a silence before the first byte; a
    /// download that is still arriving never times out.
    func vodStreams() async throws -> [XtreamVODStream] {
        try Self.decodeList(try await payload(action: "get_vod_streams", timeout: 180))
    }

    /// Every show the provider has.
    func series() async throws -> [XtreamSeries] {
        try Self.decodeList(try await payload(action: "get_series", timeout: 180))
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
                         timeout: TimeInterval = 20, progress: DownloadProgress? = nil) async throws -> Data {
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
        let (data, response) = try await Self.data(for: request, progress: progress)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw XtreamError.serverRejected
        }
        return data
    }

    /// What a request answers with, reporting to `progress`, when there is
    /// one, how much has arrived as it arrives.
    private static func data(for request: URLRequest, progress: DownloadProgress?) async throws -> (Data, URLResponse) {
        guard let progress else { return try await session.data(for: request) }
        let watcher = XtreamDownloadWatcher()
        let ticker = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                if let counts = watcher.counts {
                    await progress(XtreamDownloadUpdate(received: counts.received,
                                                        expected: counts.expected > 0 ? counts.expected : nil,
                                                        finished: false))
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        let answer: (Data, URLResponse)
        do {
            answer = try await session.data(for: request, delegate: watcher)
        } catch {
            ticker.cancel()
            throw error
        }
        // The ticker is stopped before the last word, so nothing it was
        // about to say can arrive after it.
        ticker.cancel()
        await ticker.value
        let received = watcher.counts?.received ?? Int64(answer.0.count)
        await progress(XtreamDownloadUpdate(received: received, expected: received, finished: true))
        return answer
    }

    private func request<T: Decodable>(action: String?) async throws -> T {
        let data = try await payload(action: action)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw XtreamError.invalidResponse }
    }

    private func request<T: Decodable & Sendable>(action: String?, ifChangedFrom digest: String?,
                                                 progress: DownloadProgress? = nil) async throws -> XtreamAnswer<T> {
        let data = try await payload(action: action, progress: progress)
        let fresh = XtreamPayloadDigest.of(data)
        if let digest, digest == fresh { return .unchanged(bytes: data.count) }
        do {
            return .fresh(XtreamPayload(value: try JSONDecoder().decode(T.self, from: data),
                                        digest: fresh, bytes: data.count))
        } catch { throw XtreamError.invalidResponse }
    }

    private var normalizedBaseURL: URL? {
        guard !profile.isPlaylist else { return nil }
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
