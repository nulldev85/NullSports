import Foundation

/// IntroDB keys episodes by the SHOW's IMDb ID, never the episode's IMDb ID.
struct MobileIntroIdentity: Hashable, Sendable {
    let imdb: String
    let season: Int
    let episode: Int

    init?(series: MediaItem, episode: MediaItem) {
        let packed = LibraryMetadataIdentity.packed(episode)
        guard episode.type == "Episode", series.isSeries,
              let season = episode.parentIndexNumber ?? packed?.season, season >= 0,
              let number = episode.indexNumber ?? packed?.episode, number > 0,
              let imdb = LibraryMetadataIdentity.ids(series)["imdb"],
              imdb.range(of: "^tt[0-9]{7,}$", options: .regularExpression) != nil else { return nil }
        self.imdb = imdb
        self.season = season
        self.episode = number
    }

    var url: URL {
        var url = URLComponents(string: "https://api.introdb.app/segments")!
        url.queryItems = [URLQueryItem(name: "imdb_id", value: imdb),
                         URLQueryItem(name: "season", value: String(season)),
                         URLQueryItem(name: "episode", value: String(episode))]
        return url.url!
    }
}

struct MobileIntroSegment: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval

    /// No inferred timing, recap skipping, or automatic seeking. A runtime is
    /// required so a bad community row cannot seek to the end of a title.
    func destination(at position: Double, duration: Double) -> Double? {
        guard position.isFinite, duration.isFinite, duration > end + 1,
              position >= start, position < end else { return nil }
        return end
    }

    static func decode(_ data: Data, identity: MobileIntroIdentity) -> Self? {
        struct Response: Decodable {
            let imdb_id: String
            let season: Int
            let episode: Int
            let is_movie: Bool
            let intro: Segment?
        }
        struct Segment: Decodable {
            let start_sec: Double?
            let end_sec: Double?
            let start_ms: Double?
            let end_ms: Double?
            let confidence: Double?
            let submission_count: Int?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              response.imdb_id == identity.imdb, !response.is_movie,
              response.season == identity.season, response.episode == identity.episode,
              let raw = response.intro,
              let start = raw.start_ms.map({ $0 / 1000 }) ?? raw.start_sec,
              let end = raw.end_ms.map({ $0 / 1000 }) ?? raw.end_sec,
              start.isFinite, end.isFinite, start >= 0, end - start >= 5, end - start <= 180,
              let confidence = raw.confidence, confidence >= 0.8, confidence <= 1,
              (raw.submission_count ?? 0) >= 1 else { return nil }
        return Self(start: start, end: end)
    }
}

actor MobileIntroDB {
    static let shared = MobileIntroDB()
    private struct Entry {
        let segment: MobileIntroSegment?
        let expiry: Date
    }
    private var cache: [MobileIntroIdentity: Entry] = [:]
    private var running: [MobileIntroIdentity: Task<Entry, Never>] = [:]
    private var retryAfter = Date.distantPast
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func intro(for identity: MobileIntroIdentity) async -> MobileIntroSegment? {
        if let entry = cache[identity], entry.expiry > Date() { return entry.segment }
        if let task = running[identity] { return await task.value.segment }
        guard retryAfter <= Date() else { return nil }
        let session = session
        let task = Task<Entry, Never> {
            var request = URLRequest(url: identity.url, timeoutInterval: 5)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Lineup/0.19 (iOS; IntroDB integration)", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    return Entry(segment: nil, expiry: Date().addingTimeInterval(60))
                }
                if http.statusCode == 429 {
                    let seconds = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
                    self.backOff(seconds)
                }
                guard http.statusCode == 200 else {
                    return Entry(segment: nil, expiry: Date().addingTimeInterval(http.statusCode == 404 ? 3600 : 60))
                }
                let segment = MobileIntroSegment.decode(data, identity: identity)
                return Entry(segment: segment, expiry: Date().addingTimeInterval(segment == nil ? 3600 : 86400))
            } catch { return Entry(segment: nil, expiry: Date().addingTimeInterval(60)) }
        }
        running[identity] = task
        let entry = await task.value
        running[identity] = nil
        if cache.count >= 256 { cache = cache.filter { $0.value.expiry > Date() }; if cache.count >= 256 { cache.removeAll() } }
        cache[identity] = entry
        return entry.segment
    }

    private func backOff(_ seconds: Double) {
        retryAfter = Date().addingTimeInterval(seconds.isFinite ? max(1, min(seconds, 3600)) : 60)
    }
}

extension MediaLibrary {
    func introSegment(for episode: MediaItem) async -> MobileIntroSegment? {
        guard introDBEnabled, episode.type == "Episode",
              let parent = await metadataParent(for: episode) else { return nil }
        // Resolve external IDs independently of the viewer's display choice.
        // Provider mode still keeps its original titles and artwork.
        let series = await libraryExternalIdentity(parent)
        guard !Task.isCancelled, let identity = MobileIntroIdentity(series: series, episode: episode) else { return nil }
        return await MobileIntroDB.shared.intro(for: identity)
    }
}
