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

    var segmentsIdentity: MobileSegmentIdentity { MobileSegmentIdentity(imdb: imdb, season: season, episode: episode)! }
    var url: URL { segmentsIdentity.url }
}

extension MobileIntroSegment {
    static func decode(_ data: Data, identity: MobileIntroIdentity) -> Self? {
        MobilePlaybackSegments.decode(data, identity: identity.segmentsIdentity)?.intro
    }
}

actor MobileIntroDB {
    static let shared = MobileIntroDB()
    private struct Entry {
        let segments: MobilePlaybackSegments?
        let expiry: Date
    }
    private var cache: [MobileSegmentIdentity: Entry] = [:]
    private var running: [MobileSegmentIdentity: Task<Entry, Never>] = [:]
    private var retryAfter = Date.distantPast
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func intro(for identity: MobileIntroIdentity) async -> MobileIntroSegment? {
        await segments(for: identity.segmentsIdentity)?.intro
    }

    func segments(for identity: MobileSegmentIdentity) async -> MobilePlaybackSegments? {
        if let entry = cache[identity], entry.expiry > Date() { return entry.segments }
        if let task = running[identity] { return await task.value.segments }
        guard retryAfter <= Date() else { return nil }
        let session = session
        let task = Task<Entry, Never> {
            var request = URLRequest(url: identity.url, timeoutInterval: 5)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Lineup/0.19 (iOS; IntroDB integration)", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    return Entry(segments: nil, expiry: Date().addingTimeInterval(60))
                }
                if http.statusCode == 429 {
                    let seconds = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
                    self.backOff(seconds)
                }
                guard http.statusCode == 200 else {
                    return Entry(segments: nil, expiry: Date().addingTimeInterval(http.statusCode == 404 ? 3600 : 60))
                }
                let segments = MobilePlaybackSegments.decode(data, identity: identity)
                return Entry(segments: segments, expiry: Date().addingTimeInterval(segments?.isEmpty != false ? 3600 : 86400))
            } catch { return Entry(segments: nil, expiry: Date().addingTimeInterval(60)) }
        }
        running[identity] = task
        let entry = await task.value
        running[identity] = nil
        if cache.count >= 256 { cache = cache.filter { $0.value.expiry > Date() }; if cache.count >= 256 { cache.removeAll() } }
        cache[identity] = entry
        return entry.segments
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

    func playbackSegments(for item: MediaItem) async -> MobilePlaybackSegments? {
        guard introDBEnabled || recapSkippingEnabled || creditsPromptEnabled || postCreditsNoticeEnabled else { return nil }
        if item.type == "Episode" {
            guard introDBEnabled || recapSkippingEnabled || creditsPromptEnabled else { return nil }
            guard let parent = await metadataParent(for: item) else { return nil }
            let series = await libraryExternalIdentity(parent)
            guard !Task.isCancelled, let identity = MobileIntroIdentity(series: series, episode: item) else { return nil }
            return await MobileIntroDB.shared.segments(for: identity.segmentsIdentity)
        }
        guard item.type == "Movie", postCreditsNoticeEnabled else { return nil }
        let matched = await libraryExternalIdentity(item)
        guard !Task.isCancelled, let imdb = LibraryMetadataIdentity.ids(matched)["imdb"],
              let identity = MobileSegmentIdentity(imdb: imdb, isMovie: true) else { return nil }
        return await MobileIntroDB.shared.segments(for: identity)
    }
}
