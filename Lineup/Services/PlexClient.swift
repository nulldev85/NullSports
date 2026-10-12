import Foundation

/// A Plex Media Server, asked Plex's own way and answered as the Library's
/// items.
///
/// Plex shares nothing with Jellyfin's API: libraries are "sections", a
/// title is a "metadata" item named by its rating key, artwork is a path the
/// server resizes on request, and a stream is a file part read straight off
/// the server. This turns each of those into what the Library already knows,
/// so a Plex server's shelves, pages, search and streams sit beside a
/// Jellyfin server's with nothing above this telling them apart.
///
/// What the Library needs that Plex has no notion of is said here plainly:
/// Plex keeps no favourites, so marking one is a no-op; Nullfin's addon routes
/// and Remux's scores answer the way a plain Jellyfin server does, 404.
struct PlexClient: MediaServerClient {
    let serverURL: URL
    let token: String
    /// Plex's X-Plex-Client-Identifier: this device, as Plex counts devices.
    let clientID: String
    private let session: URLSession

    init(serverURL: String, token: String, clientID: String, session: URLSession = .shared) throws {
        guard let url = JellyfinClient.address(from: serverURL) else { throw JellyfinError.invalidServer }
        self.serverURL = url
        self.token = token
        self.clientID = clientID
        self.session = session
    }

    // MARK: Ids
    //
    // A title is its rating key, as Plex names it. A library, its recently
    // added list and a collection are not titles, and are marked so the
    // routes that list what is in them can tell which they are.

    private static let sectionPrefix = "plex-section:"
    private static let recentPrefix = "plex-recent:"
    private static let collectionPrefix = "plex-collection:"

    /// The rating key behind an id, for anything Plex keeps as metadata.
    static func ratingKey(of id: String) -> String? {
        if id.hasPrefix(sectionPrefix) || id.hasPrefix(recentPrefix) { return nil }
        if id.hasPrefix(collectionPrefix) { return String(id.dropFirst(collectionPrefix.count)) }
        return id
    }

    // MARK: Libraries

    /// Each film and show library, twice: what was added to it lately --
    /// first, so a newly added server opens on what is new -- and the whole
    /// library in name order.
    func views(userID: String) async throws -> [MediaItem] {
        let sections = try await videoSections()
        let recent = sections.map { section in
            MediaItem(id: Self.recentPrefix + section.type + ":" + section.key,
                      name: "Recently Added " + section.title, type: "CollectionFolder",
                      overview: nil, productionYear: nil, primaryImageAspectRatio: nil, childCount: nil)
        }
        let libraries = sections.map { section in
            MediaItem(id: Self.sectionPrefix + section.key, name: section.title, type: "CollectionFolder",
                      overview: nil, productionYear: nil, primaryImageAspectRatio: nil, childCount: nil)
        }
        return recent + libraries
    }

    private struct VideoSection {
        let key: String
        let title: String
        /// "movie" or "show".
        let type: String
    }

    private func videoSections() async throws -> [VideoSection] {
        let container = try await get("/library/sections")
        return container.directories.compactMap { directory in
            guard let type = directory.type, type == "movie" || type == "show" else { return nil }
            return VideoSection(key: directory.key, title: directory.title ?? "Library", type: type)
        }
    }

    func items(userID: String, parentID: String, sortBy: String, limit: Int) async throws -> [MediaItem] {
        let page = [URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
                    URLQueryItem(name: "X-Plex-Container-Size", value: String(limit)),
                    URLQueryItem(name: "includeGuids", value: "1")]
        if parentID.hasPrefix(Self.sectionPrefix) {
            let key = String(parentID.dropFirst(Self.sectionPrefix.count))
            return try await get("/library/sections/\(key)/all",
                                 query: page + [URLQueryItem(name: "sort", value: "titleSort")])
                .metadata.map(Self.mediaItem)
        }
        if parentID.hasPrefix(Self.recentPrefix) {
            // "plex-recent:<type>:<key>". A show library is ordered by when an
            // episode last arrived, which is what "recently added" means for
            // a show; a film library by when the film did.
            let rest = parentID.dropFirst(Self.recentPrefix.count).split(separator: ":").map(String.init)
            guard rest.count == 2 else { return [] }
            let sort = rest[0] == "show" ? "episode.addedAt:desc" : "addedAt:desc"
            let path = "/library/sections/\(rest[1])/all"
            do {
                return try await get(path, query: page + [URLQueryItem(name: "sort", value: sort)])
                    .metadata.map(Self.mediaItem)
            } catch JellyfinError.server(let status) where status == 400 && rest[0] == "show" {
                // An older server without that sort orders shows by their own date.
                return try await get(path, query: page + [URLQueryItem(name: "sort", value: "addedAt:desc")])
                    .metadata.map(Self.mediaItem)
            }
        }
        if parentID.hasPrefix(Self.collectionPrefix) {
            let key = String(parentID.dropFirst(Self.collectionPrefix.count))
            return try await get("/library/collections/\(key)/children", query: page).metadata.map(Self.mediaItem)
        }
        // A show's seasons, or a season's episodes, in Plex's own order.
        return try await get("/library/metadata/\(parentID)/children", query: page).metadata.map(Self.mediaItem)
    }

    func allCollections(userID: String, pageSize: Int, maxPages: Int) async throws -> [MediaItem] {
        var all: [MediaItem] = []
        for section in try await videoSections() {
            let found = (try? await get("/library/sections/\(section.key)/collections").metadata) ?? []
            all += found.map(Self.mediaItem)
        }
        return all
    }

    func episodes(userID: String, seriesID: String) async throws -> [MediaItem] {
        let found = try await get("/library/metadata/\(seriesID)/allLeaves",
                                  query: [URLQueryItem(name: "includeGuids", value: "1")], timeout: 30)
        return LocalEpisodeProgressionPolicy.ordered(found.metadata.map(Self.mediaItem))
    }

    func allTitles(userID: String, pageSize: Int, maxPages: Int) async throws -> [MediaItem] {
        var all: [MediaItem] = []
        for section in try await videoSections() {
            for page in 0..<maxPages {
                let found = try await get("/library/sections/\(section.key)/all", query: [
                    URLQueryItem(name: "includeGuids", value: "1"),
                    URLQueryItem(name: "X-Plex-Container-Start", value: String(page * pageSize)),
                    URLQueryItem(name: "X-Plex-Container-Size", value: String(pageSize))
                ]).metadata
                all += found.map(Self.mediaItem)
                if found.count < pageSize { break }
            }
        }
        return all
    }

    func item(userID: String, itemID: String) async throws -> MediaItem {
        if itemID.hasPrefix(Self.sectionPrefix) || itemID.hasPrefix(Self.recentPrefix) {
            guard let view = try await views(userID: userID).first(where: { $0.id == itemID }) else {
                throw JellyfinError.server(404)
            }
            return view
        }
        guard let key = Self.ratingKey(of: itemID),
              let found = try await get("/library/metadata/\(key)",
                                        query: [URLQueryItem(name: "includeGuids", value: "1")],
                                        timeout: 40).metadata.first else {
            throw JellyfinError.server(404)
        }
        return Self.mediaItem(found)
    }

    func similarItems(userID: String, itemID: String) async throws -> [MediaItem] {
        guard let key = Self.ratingKey(of: itemID) else { return [] }
        let found = try? await get("/library/metadata/\(key)/similar",
                                   query: [URLQueryItem(name: "count", value: "16")])
        return (found?.metadata ?? []).map(Self.mediaItem)
    }

    func libraryCounts(userID: String) async throws -> MediaLibraryCounts {
        var movies = 0, shows = 0, episodes = 0
        for section in try await videoSections() {
            if section.type == "movie" {
                movies += try await count(in: section.key, type: 1)
            } else {
                shows += try await count(in: section.key, type: 2)
                episodes += try await count(in: section.key, type: 4)
            }
        }
        return MediaLibraryCounts(movies: movies, shows: shows, episodes: episodes)
    }

    /// How many of one kind a library holds, from an empty page of it.
    private func count(in section: String, type: Int) async throws -> Int {
        let container = try await get("/library/sections/\(section)/all", query: [
            URLQueryItem(name: "type", value: String(type)),
            URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "0")
        ])
        return container.totalSize ?? container.size ?? 0
    }

    /// The episode Plex has on deck for a show: where the viewer is up to.
    func nextUp(userID: String, seriesID: String) async throws -> [MediaItem] {
        let found = try await get("/library/metadata/\(seriesID)",
                                  query: [URLQueryItem(name: "includeOnDeck", value: "1")])
        return (found.metadata.first?.onDeck?.metadata ?? []).map(Self.mediaItem)
    }

    /// Plex keeps no favourites on the server.
    func setFavorite(userID: String, itemID: String, isFavorite: Bool) async throws {}

    func setPlayed(userID: String, itemID: String, isPlayed: Bool) async throws {
        guard let key = Self.ratingKey(of: itemID) else { return }
        _ = try await data("/:/\(isPlayed ? "scrobble" : "unscrobble")", query: [
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            URLQueryItem(name: "key", value: key)
        ])
    }

    func publicInfo() async throws -> MediaServerPublicInfo { throw JellyfinError.server(404) }

    func items(userID: String, ids: [String]) async throws -> [MediaItem] {
        let keys = ids.compactMap(Self.ratingKey(of:))
        guard !keys.isEmpty else { return [] }
        return try await get("/library/metadata/\(keys.joined(separator: ","))",
                             query: [URLQueryItem(name: "includeGuids", value: "1")], timeout: 30)
            .metadata.map(Self.mediaItem)
    }

    /// Plex's library has no lookup by another service's id; the caller goes
    /// on to search by name, which Plex does well.
    func items(userID: String, providerIDs: [String: String], types: [String]) async throws -> [MediaItem] { [] }

    func search(userID: String, query: String, types: [String]) async throws -> [MediaItem] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !types.isEmpty else { return [] }
        let wanted = Set(types.compactMap { type -> String? in
            switch type {
            case "Movie": return "movie"
            case "Series": return "show"
            case "Episode": return "episode"
            case "Video": return "clip"
            default: return nil
            }
        })
        let found = try await get("/hubs/search", query: [
            URLQueryItem(name: "query", value: value),
            URLQueryItem(name: "limit", value: "30"),
            URLQueryItem(name: "includeGuids", value: "1")
        ], timeout: 30)
        return found.hubs
            .filter { wanted.contains($0.type ?? "") }
            .flatMap { $0.metadata }
            .filter { wanted.contains($0.type ?? "") }
            .map(Self.mediaItem)
    }

    // MARK: Artwork

    /// A title's artwork, resized by the server to the width asked for.
    /// "primary" is its poster (an episode's still), "backdrop" its art and
    /// "logo" its clear logo, which keeps its transparency.
    func imageURL(itemID: String, type: String, maxWidth: Int) -> URL? {
        guard let key = Self.ratingKey(of: itemID) else { return nil }
        let kind: String, height: Int
        switch type.lowercased() {
        case "backdrop": kind = "art"; height = maxWidth * 9 / 16
        case "logo": kind = "clearLogo"; height = maxWidth / 2
        default: kind = "thumb"; height = maxWidth * 3 / 2
        }
        var query = [
            URLQueryItem(name: "width", value: String(maxWidth)),
            URLQueryItem(name: "height", value: String(height)),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "upscale", value: "1"),
            URLQueryItem(name: "url", value: "/library/metadata/\(key)/\(kind)"),
            URLQueryItem(name: "X-Plex-Token", value: token)
        ]
        if kind == "clearLogo" { query.append(URLQueryItem(name: "format", value: "png")) }
        return url("/photo/:/transcode", query: query)
    }

    // MARK: Streams

    /// A file part, read straight from the server.
    func playbackURL(itemID: String, mediaSourceID: String?) -> URL? {
        guard let part = mediaSourceID, part.hasPrefix("/library/parts/") else { return nil }
        return url(part, query: [URLQueryItem(name: "X-Plex-Token", value: token)])
    }

    /// Each version of a title Plex holds, one stream for each of its files,
    /// played straight from the file.
    func playbackInfo(itemID: String) async throws -> MediaPlaybackInfo {
        guard let key = Self.ratingKey(of: itemID),
              let found = try await get("/library/metadata/\(key)", timeout: 30).metadata.first else {
            throw JellyfinError.server(404)
        }
        let sources = (found.media ?? []).flatMap { media in
            (media.parts ?? []).map { part -> MediaPlaybackSource in
                var source = MediaPlaybackSource(
                    sourceID: part.key, name: Self.describe(media), path: part.file,
                    container: part.container ?? media.container, size: part.size,
                    bitrate: media.bitrate.map { Int64($0) * 1000 }, remux: nil)
                source.directURL = playbackURL(itemID: key, mediaSourceID: part.key)
                return source
            }
        }
        return MediaPlaybackInfo(mediaSources: sources)
    }

    /// "4K · HEVC · HDR · TrueHD 7.1": what a version is chosen by.
    static func describe(_ media: PlexMedia) -> String {
        var parts: [String] = []
        if let resolution = media.videoResolution?.lowercased() {
            switch resolution {
            case "4k": parts.append("4K")
            case "sd": parts.append("SD")
            default: parts.append(resolution.hasSuffix("p") ? resolution : resolution + "p")
            }
        }
        if let codec = media.videoCodec { parts.append(codec.uppercased()) }
        if let range = media.videoDynamicRange, range.uppercased() != "SDR" { parts.append(range) }
        if let audio = media.audioCodec {
            var line = audio.uppercased()
            if let channels = media.audioChannels {
                line += " " + (channels == 6 ? "5.1" : channels == 8 ? "7.1" : channels == 2 ? "2.0" : "\(channels)ch")
            }
            parts.append(line)
        }
        return parts.isEmpty ? "Plex" : parts.joined(separator: " · ")
    }

    // MARK: Nullfin's routes, which Plex does not have

    func addons() async throws -> [NullfinAddon] { throw JellyfinError.server(404) }
    func addonCatalogs(addonID: String) async throws -> [NullfinCatalog] { throw JellyfinError.server(404) }
    func setCatalog(addonID: String, catalogID: String, enabled: Bool) async throws { throw JellyfinError.server(404) }
    func refreshLibrary() async throws { throw JellyfinError.server(404) }
    func itemMetrics(itemID: String) async throws -> [MediaMetric] { throw JellyfinError.server(404) }

    // MARK: Plex's items as the Library's

    static func mediaItem(_ metadata: PlexMetadata) -> MediaItem {
        let kind = metadata.type ?? ""
        let type: String
        switch kind {
        case "movie": type = "Movie"
        case "show": type = "Series"
        case "season": type = "Season"
        case "episode": type = "Episode"
        case "collection": type = "BoxSet"
        case "clip": type = "Video"
        default: type = "Folder"
        }
        let key = metadata.ratingKey
        let duration = metadata.duration ?? 0
        let played: Bool
        if kind == "show" || kind == "season" {
            played = (metadata.leafCount ?? 0) > 0 && metadata.viewedLeafCount == metadata.leafCount
        } else {
            played = (metadata.viewCount ?? 0) > 0
        }
        let progress = (metadata.viewOffset ?? 0) > 0 && duration > 0
            ? Double(metadata.viewOffset ?? 0) / Double(duration) * 100 : nil
        var tags: [String: String] = [:]
        if let thumb = metadata.thumb { tags["Primary"] = thumb }
        if metadata.images?.contains(where: { $0.type == "clearLogo" }) == true { tags["Logo"] = "clearLogo" }
        let critic = metadata.ratingImage?.contains("rottentomatoes") == true ? metadata.rating.map { $0 * 10 } : nil
        var people: [MediaPerson] = []
        people += (metadata.roles ?? []).map {
            MediaPerson(personID: nil, name: $0.tag, role: $0.role, type: "Actor", primaryImageTag: nil)
        }
        people += (metadata.directors ?? []).map {
            MediaPerson(personID: nil, name: $0.tag, role: nil, type: "Director", primaryImageTag: nil)
        }
        people += (metadata.writers ?? []).map {
            MediaPerson(personID: nil, name: $0.tag, role: nil, type: "Writer", primaryImageTag: nil)
        }
        return MediaItem(
            id: kind == "collection" ? collectionPrefix + key : key,
            name: metadata.title ?? "Untitled",
            type: type,
            overview: metadata.summary.flatMap { $0.isEmpty ? nil : $0 },
            productionYear: metadata.year ?? metadata.originallyAvailableAt.flatMap { Int($0.prefix(4)) },
            primaryImageAspectRatio: kind == "episode" ? 16.0 / 9.0 : 2.0 / 3.0,
            childCount: kind == "season" ? metadata.leafCount : metadata.childCount,
            genres: metadata.genres.map { $0.map(\.tag) },
            officialRating: metadata.contentRating,
            communityRating: metadata.audienceRating ?? (critic == nil ? metadata.rating : nil),
            criticRating: critic,
            runTimeTicks: duration > 0 ? Int64(duration) * 10_000 : nil,
            premiereDate: metadata.originallyAvailableAt.map { $0 + "T00:00:00.0000000Z" },
            indexNumber: metadata.index,
            parentIndexNumber: kind == "episode" ? metadata.parentIndex : nil,
            seriesName: kind == "episode" ? metadata.grandparentTitle : (kind == "season" ? metadata.parentTitle : nil),
            seriesID: kind == "episode" ? metadata.grandparentRatingKey : (kind == "season" ? metadata.parentRatingKey : nil),
            userData: MediaUserData(played: played, isFavorite: nil, playedPercentage: progress),
            imageTags: tags.isEmpty ? nil : tags,
            backdropImageTags: metadata.art.map { [$0] },
            studios: metadata.studio.map { [MediaNamedInfo(name: $0)] },
            productionLocations: metadata.countries.map { $0.map(\.tag) },
            people: people.isEmpty ? nil : people,
            providerIDs: providerIDs(from: metadata.guids)
        )
    }

    /// "imdb://tt0111161" and the like, keyed as Jellyfin keys its own.
    static func providerIDs(from guids: [PlexTag]?) -> [String: String]? {
        var ids: [String: String] = [:]
        for guid in guids ?? [] {
            let value = guid.tag
            for (scheme, name) in [("imdb://", "Imdb"), ("tmdb://", "Tmdb"), ("tvdb://", "Tvdb")]
            where value.hasPrefix(scheme) {
                ids[name] = String(value.dropFirst(scheme.count))
            }
        }
        return ids.isEmpty ? nil : ids
    }

    // MARK: Requests

    /// What Plex is told about the asker on every request.
    static func headers(clientID: String) -> [String: String] {
        #if os(tvOS)
        let platform = "tvOS", device = "Apple TV"
        #else
        let platform = "iOS", device = "iPhone"
        #endif
        return ["Accept": "application/json",
                "X-Plex-Product": "Lineup",
                "X-Plex-Version": "1.0",
                "X-Plex-Client-Identifier": clientID,
                "X-Plex-Platform": platform,
                "X-Plex-Device": device,
                "X-Plex-Device-Name": "Lineup on " + device]
    }

    private func url(_ path: String, query: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + path
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }

    private func data(_ path: String, query: [URLQueryItem] = [], timeout: TimeInterval = 20) async throws -> Data {
        guard let url = url(path, query: query) else { throw JellyfinError.invalidServer }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        for (name, value) in Self.headers(clientID: clientID) { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JellyfinError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw JellyfinError.authenticationFailed }
            throw JellyfinError.server(http.statusCode)
        }
        return data
    }

    private func get(_ path: String, query: [URLQueryItem] = [], timeout: TimeInterval = 20) async throws -> PlexMediaContainer {
        let body = try await data(path, query: query, timeout: timeout)
        do { return try JSONDecoder().decode(PlexResponse.self, from: body).mediaContainer }
        catch { throw JellyfinError.invalidResponse }
    }
}

// MARK: - plex.tv

/// The Plex account: linking this device to it with a code, and finding the
/// servers it can reach.
///
/// Linking is Plex's own way in, the one every Plex app on a television
/// uses: the app asks plex.tv for a short code, the viewer enters it at
/// plex.tv/link while signed in, and the app is handed the account's token.
/// No password passes through Lineup.
enum PlexAccount {
    private static let base = URL(string: "https://plex.tv/api/v2")!

    struct Pin: Decodable, Sendable {
        let id: Int
        let code: String
        let authToken: String?
    }

    struct User: Decodable, Sendable {
        let username: String?
        let title: String?
        var displayName: String { title ?? username ?? "Plex" }
    }

    /// A server the account can reach, with every address plex.tv knows for
    /// it and the token that opens it.
    struct Server: Decodable, Identifiable, Sendable, Hashable {
        let name: String
        let clientIdentifier: String
        let accessToken: String?
        let owned: Bool?
        let provides: String?
        let connections: [Connection]?
        var id: String { clientIdentifier }

        struct Connection: Decodable, Sendable, Hashable {
            let uri: String
            let local: Bool?
            let relay: Bool?
        }

        /// The addresses to try, the nearest first: on the same network, then
        /// across the internet, and Plex's relay only when nothing else works.
        var addressesToTry: [URL] {
            let ranked = (connections ?? []).sorted { rank($0) < rank($1) }
            return ranked.compactMap { URL(string: $0.uri) }
        }

        private func rank(_ connection: Connection) -> Int {
            if connection.relay == true { return 2 }
            return connection.local == true ? 0 : 1
        }
    }

    static func requestPin(clientID: String) async throws -> Pin {
        var request = URLRequest(url: base.appendingPathComponent("pins"))
        request.httpMethod = "POST"
        request.httpBody = Data("strong=false".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return try await send(request, clientID: clientID)
    }

    static func checkPin(_ id: Int, clientID: String) async throws -> Pin {
        try await send(URLRequest(url: base.appendingPathComponent("pins/\(id)")), clientID: clientID)
    }

    static func user(token: String, clientID: String) async throws -> User {
        try await send(URLRequest(url: base.appendingPathComponent("user")), clientID: clientID, token: token)
    }

    /// The account's servers: its own, and any shared with it.
    static func servers(token: String, clientID: String) async throws -> [Server] {
        var components = URLComponents(url: base.appendingPathComponent("resources"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "includeHttps", value: "1"),
                                 URLQueryItem(name: "includeRelay", value: "1")]
        let all: [Server] = try await send(URLRequest(url: components.url!), clientID: clientID, token: token)
        return all.filter { ($0.provides ?? "").split(separator: ",").contains("server") }
    }

    /// The first of a server's addresses that answers, tried nearest first.
    static func reachableAddress(of server: Server, clientID: String) async -> URL? {
        guard let token = server.accessToken else { return nil }
        for address in server.addressesToTry {
            var request = URLRequest(url: address.appendingPathComponent("identity"))
            request.timeoutInterval = 6
            for (name, value) in PlexClient.headers(clientID: clientID) { request.setValue(value, forHTTPHeaderField: name) }
            request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return address
            }
        }
        return nil
    }

    private static func send<T: Decodable>(_ request: URLRequest, clientID: String, token: String? = nil) async throws -> T {
        var request = request
        request.timeoutInterval = 20
        for (name, value) in PlexClient.headers(clientID: clientID) { request.setValue(value, forHTTPHeaderField: name) }
        if let token { request.setValue(token, forHTTPHeaderField: "X-Plex-Token") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JellyfinError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw JellyfinError.authenticationFailed }
            throw JellyfinError.server(http.statusCode)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw JellyfinError.invalidResponse }
    }
}

// MARK: - Plex's JSON

struct PlexResponse: Decodable, Sendable {
    let mediaContainer: PlexMediaContainer
    enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
}

/// Every Plex answer is one of these, holding whichever lists it has.
struct PlexMediaContainer: Decodable, Sendable {
    let size: Int?
    let totalSize: Int?
    let directories: [PlexDirectory]
    let metadata: [PlexMetadata]
    let hubs: [PlexHub]

    enum CodingKeys: String, CodingKey {
        case size, totalSize
        case directories = "Directory", metadata = "Metadata", hubs = "Hub"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        size = values.lenientInt(.size)
        totalSize = values.lenientInt(.totalSize)
        directories = (try? values.decodeIfPresent([Lenient<PlexDirectory>].self, forKey: .directories))?
            .flatMap { $0.compactMap(\.value) } ?? []
        metadata = (try? values.decodeIfPresent([Lenient<PlexMetadata>].self, forKey: .metadata))?
            .flatMap { $0.compactMap(\.value) } ?? []
        hubs = (try? values.decodeIfPresent([Lenient<PlexHub>].self, forKey: .hubs))?
            .flatMap { $0.compactMap(\.value) } ?? []
    }
}

struct PlexDirectory: Decodable, Sendable {
    let key: String
    let title: String?
    let type: String?

    enum CodingKeys: String, CodingKey { case key, title, type }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let key = values.lenientString(.key) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "No key"))
        }
        self.key = key
        title = values.lenientString(.title)
        type = values.lenientString(.type)
    }
}

struct PlexHub: Decodable, Sendable {
    let type: String?
    let metadata: [PlexMetadata]

    enum CodingKeys: String, CodingKey { case type, metadata = "Metadata" }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = values.lenientString(.type)
        metadata = (try? values.decodeIfPresent([Lenient<PlexMetadata>].self, forKey: .metadata))?
            .flatMap { $0.compactMap(\.value) } ?? []
    }
}

/// A tag-like entry: a genre, a country, a person, or a guid.
struct PlexTag: Decodable, Sendable, Hashable {
    let tag: String
    let role: String?

    enum CodingKeys: String, CodingKey { case tag, role, id }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // A guid names itself in `id`; everything else in `tag`.
        guard let tag = values.lenientString(.tag) ?? values.lenientString(.id) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "No tag"))
        }
        self.tag = tag
        role = values.lenientString(.role)
    }
}

struct PlexImage: Decodable, Sendable, Hashable {
    let type: String?
    let url: String?
}

struct PlexPart: Decodable, Sendable, Hashable {
    let key: String
    let file: String?
    let size: Int64?
    let container: String?

    enum CodingKeys: String, CodingKey { case key, file, size, container }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let key = values.lenientString(.key) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "No part key"))
        }
        self.key = key
        file = values.lenientString(.file)
        size = values.lenientInt(.size).map(Int64.init)
        container = values.lenientString(.container)
    }
}

struct PlexMedia: Decodable, Sendable, Hashable {
    let bitrate: Int?
    let container: String?
    let videoCodec: String?
    let videoResolution: String?
    let videoDynamicRange: String?
    let audioCodec: String?
    let audioChannels: Int?
    let parts: [PlexPart]?

    enum CodingKeys: String, CodingKey {
        case bitrate, container, videoCodec, videoResolution, videoDynamicRange, audioCodec, audioChannels
        case parts = "Part"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bitrate = values.lenientInt(.bitrate)
        container = values.lenientString(.container)
        videoCodec = values.lenientString(.videoCodec)
        videoResolution = values.lenientString(.videoResolution)
        videoDynamicRange = values.lenientString(.videoDynamicRange)
        audioCodec = values.lenientString(.audioCodec)
        audioChannels = values.lenientInt(.audioChannels)
        parts = (try? values.decodeIfPresent([Lenient<PlexPart>].self, forKey: .parts))?
            .flatMap { $0.compactMap(\.value) }
    }
}

/// One title, season, show or collection, as Plex describes it. Read
/// leniently: one odd field is no reason to lose a whole shelf.
struct PlexMetadata: Decodable, Sendable {
    let ratingKey: String
    let type: String?
    let title: String?
    let summary: String?
    let year: Int?
    let thumb: String?
    let art: String?
    let index: Int?
    let parentIndex: Int?
    let parentTitle: String?
    let parentRatingKey: String?
    let grandparentTitle: String?
    let grandparentRatingKey: String?
    let leafCount: Int?
    let viewedLeafCount: Int?
    let childCount: Int?
    let viewCount: Int?
    let viewOffset: Int?
    let duration: Int?
    let originallyAvailableAt: String?
    let contentRating: String?
    let rating: Double?
    let audienceRating: Double?
    let ratingImage: String?
    let studio: String?
    let genres: [PlexTag]?
    let countries: [PlexTag]?
    let roles: [PlexTag]?
    let directors: [PlexTag]?
    let writers: [PlexTag]?
    let guids: [PlexTag]?
    let images: [PlexImage]?
    let media: [PlexMedia]?
    let onDeck: OnDeck?

    struct OnDeck: Decodable, Sendable {
        let metadata: [PlexMetadata]?
        enum CodingKeys: String, CodingKey { case metadata = "Metadata" }
    }

    enum CodingKeys: String, CodingKey {
        case ratingKey, type, title, summary, year, thumb, art, index, parentIndex, parentTitle
        case parentRatingKey, grandparentTitle, grandparentRatingKey, leafCount, viewedLeafCount
        case childCount, viewCount, viewOffset, duration, originallyAvailableAt, contentRating
        case rating, audienceRating, ratingImage, studio
        case genres = "Genre", countries = "Country", roles = "Role", directors = "Director"
        case writers = "Writer", guids = "Guid", images = "Image", media = "Media", onDeck = "OnDeck"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let ratingKey = values.lenientString(.ratingKey) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "No rating key"))
        }
        self.ratingKey = ratingKey
        type = values.lenientString(.type)
        title = values.lenientString(.title)
        summary = values.lenientString(.summary)
        year = values.lenientInt(.year)
        thumb = values.lenientString(.thumb)
        art = values.lenientString(.art)
        index = values.lenientInt(.index)
        parentIndex = values.lenientInt(.parentIndex)
        parentTitle = values.lenientString(.parentTitle)
        parentRatingKey = values.lenientString(.parentRatingKey)
        grandparentTitle = values.lenientString(.grandparentTitle)
        grandparentRatingKey = values.lenientString(.grandparentRatingKey)
        leafCount = values.lenientInt(.leafCount)
        viewedLeafCount = values.lenientInt(.viewedLeafCount)
        childCount = values.lenientInt(.childCount)
        viewCount = values.lenientInt(.viewCount)
        viewOffset = values.lenientInt(.viewOffset)
        duration = values.lenientInt(.duration)
        originallyAvailableAt = values.lenientString(.originallyAvailableAt)
        contentRating = values.lenientString(.contentRating)
        rating = values.lenientDouble(.rating)
        audienceRating = values.lenientDouble(.audienceRating)
        ratingImage = values.lenientString(.ratingImage)
        studio = values.lenientString(.studio)
        func tags(_ key: CodingKeys) -> [PlexTag]? {
            (try? values.decodeIfPresent([Lenient<PlexTag>].self, forKey: key))?.flatMap { $0.compactMap(\.value) }
        }
        genres = tags(.genres)
        countries = tags(.countries)
        roles = tags(.roles)
        directors = tags(.directors)
        writers = tags(.writers)
        guids = tags(.guids)
        images = try? values.decodeIfPresent([PlexImage].self, forKey: .images)
        media = (try? values.decodeIfPresent([Lenient<PlexMedia>].self, forKey: .media))?
            .flatMap { $0.compactMap(\.value) }
        onDeck = try? values.decodeIfPresent(OnDeck.self, forKey: .onDeck)
    }
}
