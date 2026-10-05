import Foundation

struct MediaServerProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var serverURL: String
    var username: String
    var userID: String

    init(id: UUID = UUID(), name: String, serverURL: String, username: String, userID: String) {
        self.id = id
        self.name = name
        self.serverURL = serverURL
        self.username = username
        self.userID = userID
    }
}

/// An addon registered on a Nullfin server, as `GET /addons` returns it.
///
/// Only the fields Lineup needs are declared: the route answers with a good
/// deal more, and an unknown key is simply not decoded, so a server that adds
/// or drops one elsewhere does not break this.
struct NullfinAddon: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let enabled: Bool
}

/// One catalog an addon offers, as `GET /addons/{id}/catalogs` returns it.
struct NullfinCatalog: Codable, Identifiable, Hashable, Sendable {
    /// `addon:{addon id}:{the addon's own id for it}`.
    let catalogId: String
    let name: String
    /// Whether the server imports this catalog. Catalogs arrive switched off.
    let enabled: Bool
    /// The collection this catalog becomes once imported. Absent until the
    /// server can resolve one.
    let collectionId: String?

    var id: String { catalogId }
}

enum MDBListCatalogSection: String, CaseIterable, Hashable, Sendable {
    case yourLists
    case liked
    case curated
    case popular

    var title: String {
        switch self {
        case .yourLists: "YOUR MDBLIST LISTS"
        case .liked: "LIKED LISTS"
        case .curated: "MDBLIST CURATED"
        case .popular: "POPULAR ON MDBLIST"
        }
    }

    var detail: String {
        switch self {
        case .yourLists: "Lists created or saved directly in your account"
        case .liked: "Public lists you follow on MDBList"
        case .curated: "Hand-picked catalogs from MDBList"
        case .popular: "Popular, regularly updated MDBList catalogs"
        }
    }
}

/// A playlist offered by MDBList. The numeric list id is the stable API
/// identity; the slug is presentation metadata and can change when a list is
/// renamed.
struct MDBListCatalog: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let slug: String?
    let itemCount: Int?
    let likes: Int?
    let section: MDBListCatalogSection

    var shelfID: String { "mdblist:\(id)" }
}

struct MDBListAccount: Equatable, Sendable {
    let username: String
    let name: String?
    let plan: String?
    let dailyLimit: Int?
    let requestsUsed: Int?

    var requestsRemaining: Int? {
        guard let dailyLimit, let requestsUsed else { return nil }
        return max(0, dailyLimit - requestsUsed)
    }
}

/// The metadata needed to match an MDBList entry to the same playable title
/// on the connected Jellyfin-compatible server.
struct MDBListCatalogItem: Hashable, Sendable {
    let title: String
    let mediaType: String
    let releaseYear: Int?
    let imdbID: String?
    let tmdbID: String?
    let tvdbID: String?
    let rank: Int?
}

struct MediaItem: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let type: String
    let overview: String?
    let productionYear: Int?
    let primaryImageAspectRatio: Double?
    let childCount: Int?
    // Everything below is optional so an older server, or an addon that returns
    // only the basics, still decodes: a missing field simply goes unshown.
    let genres: [String]?
    let officialRating: String?
    let communityRating: Double?
    let criticRating: Double?
    let runTimeTicks: Int64?
    let premiereDate: String?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let seriesName: String?
    let seriesID: String?
    let userData: MediaUserData?
    let imageTags: [String: String]?
    let backdropImageTags: [String]?
    let status: String?
    let endDate: String?
    let tags: [String]?
    let studios: [MediaNamedInfo]?
    let productionLocations: [String]?
    let people: [MediaPerson]?
    let remoteTrailers: [MediaTrailer]?
    let providerIDs: [String: String]?

    // Artwork a source names outright rather than hosting behind an image
    // route, which is how a catalog imported from elsewhere arrives.
    let posterURL: String?
    let backdropURL: String?
    let logoArtworkURL: String?

    /// The connected server this came from. Lineup's own, like the artwork
    /// above: every item a server hands back is marked with it on arrival,
    /// because with several servers connected an item id only means something
    /// to the server that issued it.
    var serverID: UUID?

    // An optional `let` gets no implicit default, so the added fields are given
    // one here and every existing caller keeps the call it already makes.
    init(id: String, name: String, type: String, overview: String?,
         productionYear: Int?, primaryImageAspectRatio: Double?, childCount: Int?,
         genres: [String]? = nil, officialRating: String? = nil,
         communityRating: Double? = nil, criticRating: Double? = nil,
         runTimeTicks: Int64? = nil, premiereDate: String? = nil,
         indexNumber: Int? = nil, parentIndexNumber: Int? = nil,
         seriesName: String? = nil, seriesID: String? = nil, userData: MediaUserData? = nil,
         imageTags: [String: String]? = nil, backdropImageTags: [String]? = nil,
         status: String? = nil, endDate: String? = nil, tags: [String]? = nil,
         studios: [MediaNamedInfo]? = nil, productionLocations: [String]? = nil,
         people: [MediaPerson]? = nil, remoteTrailers: [MediaTrailer]? = nil,
         providerIDs: [String: String]? = nil,
         posterURL: String? = nil, backdropURL: String? = nil,
         logoArtworkURL: String? = nil, serverID: UUID? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.overview = overview
        self.productionYear = productionYear
        self.primaryImageAspectRatio = primaryImageAspectRatio
        self.childCount = childCount
        self.genres = genres
        self.officialRating = officialRating
        self.communityRating = communityRating
        self.criticRating = criticRating
        self.runTimeTicks = runTimeTicks
        self.premiereDate = premiereDate
        self.indexNumber = indexNumber
        self.parentIndexNumber = parentIndexNumber
        self.seriesName = seriesName
        self.seriesID = seriesID
        self.userData = userData
        self.imageTags = imageTags
        self.backdropImageTags = backdropImageTags
        self.status = status
        self.endDate = endDate
        self.tags = tags
        self.studios = studios
        self.productionLocations = productionLocations
        self.people = people
        self.remoteTrailers = remoteTrailers
        self.providerIDs = providerIDs
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.logoArtworkURL = logoArtworkURL
        self.serverID = serverID
    }

    /// The same item, marked as coming from `server`.
    func servedBy(_ server: UUID) -> MediaItem {
        var copy = self
        copy.serverID = server
        return copy
    }

    /// Unique across servers, for lists that mix them: two servers can hand
    /// out the same item id for different things.
    var libraryKey: String { (serverID?.uuidString ?? "") + "|" + id }

    /// One of the IPTV provider's films, shows or episodes, rather than a
    /// media server's.
    var isProviderTitle: Bool { ProviderItem(id: id) != nil }

    var isPlayable: Bool {
        ["Movie", "Episode", "Video"].contains(type)
    }

    var isFolder: Bool { !isPlayable }

    var isSeries: Bool { type == "Series" }

    /// Whether this has a page of its own: art, description, facts, and a play
    /// button. A series has always had one; a film has one too, because the
    /// decision to watch a film is made from exactly those things.
    var hasDetailPage: Bool { isSeries || type == "Movie" }

    /// Whether choosing this on a shelf opens a page rather than going
    /// straight to a list of streams. An episode goes straight there: it was
    /// chosen from the page its series already gave.
    var opensPage: Bool { isFolder || hasDetailPage }

    var isPlayed: Bool { userData?.played == true }

    var isFavorite: Bool { userData?.isFavorite == true }

    var hasLogo: Bool { imageTags?["Logo"] != nil || logoArtworkURL != nil }

    var hasBackdrop: Bool { backdropImageTags?.isEmpty == false }

    // Servers count in ticks of 100 nanoseconds, and a runtime is read in minutes.
    var runtimeMinutes: Int? {
        guard let runTimeTicks, runTimeTicks > 0 else { return nil }
        return max(1, Int(runTimeTicks / 600_000_000))
    }

    var formattedRuntime: String? {
        guard let minutes = runtimeMinutes else { return nil }
        guard minutes >= 60 else { return "\(minutes)m" }
        let remainder = minutes % 60
        return remainder == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(remainder)m"
    }

    // A premiere arrives as "2026-08-11T00:00:00.0000000Z", whose seven fractional
    // digits defeat the ISO parser, and only the day is ever shown. Reading the
    // date part directly avoids both the parser and a cached formatter.
    var formattedAirDate: String? { Self.formattedDate(premiereDate) }
    var formattedEndDate: String? { Self.formattedDate(endDate) }

    private static func formattedDate(_ raw: String?) -> String? {
        guard let raw, raw.count >= 10 else { return nil }
        let parts = raw.prefix(10).split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]),
              let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = Calendar(identifier: .gregorian).date(from: components) else { return nil }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    var episodeLabel: String? {
        indexNumber.map { "Episode \($0)" }
    }

    // "S04E04", the way a viewer names the place they are up to.
    var episodeCode: String? {
        guard let indexNumber else { return nil }
        let season = parentIndexNumber ?? 1
        return String(format: "S%02dE%02d", season, indexNumber)
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case overview = "Overview"
        case productionYear = "ProductionYear"
        case primaryImageAspectRatio = "PrimaryImageAspectRatio"
        case childCount = "ChildCount"
        case genres = "Genres"
        case officialRating = "OfficialRating"
        case communityRating = "CommunityRating"
        case criticRating = "CriticRating"
        case runTimeTicks = "RunTimeTicks"
        case premiereDate = "PremiereDate"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case seriesName = "SeriesName"
        case seriesID = "SeriesId"
        case userData = "UserData"
        case imageTags = "ImageTags"
        case backdropImageTags = "BackdropImageTags"
        case status = "Status"
        case endDate = "EndDate"
        case tags = "Tags"
        case studios = "Studios"
        case productionLocations = "ProductionLocations"
        case people = "People"
        case remoteTrailers = "RemoteTrailers"
        case providerIDs = "ProviderIds"
        // Lineup's own, never sent by a server: an absent key decodes to nil,
        // so a server's answer is unaffected by their existence.
        case posterURL = "LineupPoster"
        case backdropURL = "LineupBackdrop"
        case logoArtworkURL = "LineupLogo"
        case serverID = "LineupServer"
    }
}

struct MediaNamedInfo: Codable, Hashable, Sendable {
    let name: String
    enum CodingKeys: String, CodingKey { case name = "Name" }
}

struct MediaPerson: Codable, Hashable, Sendable, Identifiable {
    let personID: String?
    let name: String
    let role: String?
    let type: String?
    let primaryImageTag: String?
    var id: String { personID ?? "\(name)|\(role ?? "")" }
    enum CodingKeys: String, CodingKey {
        case personID = "Id", name = "Name", role = "Role", type = "Type"
        case primaryImageTag = "PrimaryImageTag"
    }
}

struct MediaTrailer: Codable, Hashable, Sendable {
    let name: String?
    let url: String?
    enum CodingKeys: String, CodingKey { case name = "Name", url = "Url" }

    var thumbnailURL: URL? {
        guard let url, let address = URLComponents(string: url),
              let host = address.host?.lowercased() else { return nil }
        let videoID: String?
        if host == "youtu.be" || host == "www.youtu.be" {
            videoID = address.path.split(separator: "/").first.map(String.init)
        } else if host == "youtube.com" || host == "www.youtube.com"
                    || host == "m.youtube.com" {
            videoID = address.queryItems?.first { $0.name == "v" }?.value
        } else {
            videoID = nil
        }
        guard let videoID,
              videoID.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil
        else { return nil }
        return URL(string: "https://img.youtube.com/vi/\(videoID)/hqdefault.jpg")
    }
}

struct MediaUserData: Codable, Hashable, Sendable {
    let played: Bool?
    let isFavorite: Bool?
    let playedPercentage: Double?

    enum CodingKeys: String, CodingKey {
        case played = "Played"
        case isFavorite = "IsFavorite"
        case playedPercentage = "PlayedPercentage"
    }
}

/// Lineup's on-device account of a title's playback. Jellyfin-compatible
/// servers do not all expose or reliably update resume state, so the Library
/// keeps this small record itself as well. The server profile is part of the
/// identity: two people can connect servers whose item ids happen to match
/// without seeing one another's history.
struct LocalMediaPlayback: Codable, Hashable, Sendable, Identifiable {
    let profileID: UUID
    var item: MediaItem
    var position: TimeInterval
    var duration: TimeInterval
    var updatedAt: Date
    var completed: Bool
    /// A local "Remove from Watched" must outrank stale server user data.
    /// Optional keeps records written by the first tracking build decodable.
    var explicitlyUnwatched: Bool? = nil
    /// An episode selected by local progression rather than by recorded
    /// playback. Optional keeps existing on-device records decodable.
    var isUpNext: Bool? = nil

    var id: String { profileID.uuidString + "|" + item.id }

    var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }
}

enum LocalEpisodeProgressionPolicy {
    static func ordered(_ episodes: [MediaItem]) -> [MediaItem] {
        episodes.filter { $0.type == "Episode" }.sorted { left, right in
            let leftKey = (left.parentIndexNumber ?? Int.max, left.indexNumber ?? Int.max)
            let rightKey = (right.parentIndexNumber ?? Int.max, right.indexNumber ?? Int.max)
            if leftKey.0 != rightKey.0 { return leftKey.0 < rightKey.0 }
            if leftKey.1 != rightKey.1 { return leftKey.1 < rightKey.1 }
            return left.id < right.id
        }
    }

    static func nextEpisode(after current: MediaItem, in episodes: [MediaItem],
                            isWatched: (MediaItem) -> Bool) -> MediaItem? {
        let values = ordered(episodes)
        guard let currentIndex = values.firstIndex(where: { $0.id == current.id }),
              currentIndex + 1 < values.count else { return nil }
        return values[(currentIndex + 1)...].first { !isWatched($0) }
    }
}

struct LocalMediaFavorite: Codable, Hashable, Sendable, Identifiable {
    let profileID: UUID
    var item: MediaItem
    let addedAt: Date

    var id: String { profileID.uuidString + "|" + item.id }
}

enum LocalMediaTrackingPolicy {
    static func isComplete(position: TimeInterval, duration: TimeInterval) -> Bool {
        guard duration > 0, position >= 0 else { return false }
        let safePosition = min(position, duration)
        let remaining = duration - safePosition
        return safePosition / duration >= 0.92 || (safePosition >= 60 && remaining <= 120)
    }

    static func resumePosition(for record: LocalMediaPlayback) -> TimeInterval? {
        guard !record.completed, record.explicitlyUnwatched != true, record.position >= 10,
              record.duration - record.position > 30 else { return nil }
        return record.position
    }
}

/// A score from one metrics addon, as `GET /remux/metrics/{id}` returns it.
/// Only a Nullfin server has that route; a Jellyfin server answers 404 and the
/// row simply does not appear.
struct MediaMetric: Decodable, Identifiable, Hashable, Sendable {
    let source: String
    let value: Double
    let date: String

    var id: String { source }

    // Sources are stored lowercase and keyed by addon name.
    var displayName: String {
        switch source.lowercased() {
        case "imdb": return "IMDb"
        case "tmdb": return "TMDB"
        case "tvdb": return "TVDB"
        case "trakt": return "Trakt"
        case "metacritic": return "Metacritic"
        case "rottentomatoes", "rotten_tomatoes": return "Rotten Tomatoes"
        case "popcorn": return "Popcorn"
        case "letterboxd": return "Letterboxd"
        default: return source.capitalized
        }
    }

    // Every addon normalises to 0-100 before storing, so a score reads whole.
    var formattedValue: String { "\(Int(value.rounded()))" }

    enum CodingKeys: String, CodingKey {
        case source = "Source"
        case value = "Value"
        case date = "Date"
    }
}

struct MediaMetricsResponse: Decodable, Sendable {
    let metrics: [MediaMetric]

    enum CodingKeys: String, CodingKey { case metrics = "Metrics" }
}

struct MediaCatalog: Codable, Identifiable, Hashable, Sendable {
    let root: MediaItem
    let items: [MediaItem]
    var id: String { Self.id(for: root) }
    var title: String { root.name }

    /// A server's shelf is named by its server as well as its library: two
    /// servers on the same paths give their libraries the same ids. A shelf
    /// with no server -- an MDBList one, drawn from all of them -- is its own.
    static func id(for root: MediaItem) -> String {
        root.serverID.map { $0.uuidString + "|" + root.id } ?? root.id
    }
}

/// Whether two servers hold the same title.
///
/// Servers number their items independently, so the same film has a different
/// id on each. What they share is the film's own ids at IMDb, TMDB and TVDB,
/// and failing those its name and year. An episode is the same episode when
/// it is the same place in the same show.
enum MediaTitleMatch {
    static func isSame(_ left: MediaItem, _ right: MediaItem) -> Bool {
        guard family(of: left.type) == family(of: right.type) else { return false }
        if left.type == "Episode" {
            guard let season = left.parentIndexNumber, let number = left.indexNumber,
                  season == right.parentIndexNumber, number == right.indexNumber,
                  let leftShow = left.seriesName, let rightShow = right.seriesName else { return false }
            return !normalized(leftShow).isEmpty && normalized(leftShow) == normalized(rightShow)
        }
        // One shared id settles it.
        let leftIDs = providerIDs(of: left)
        let rightIDs = providerIDs(of: right)
        var conflicting: Set<String> = []
        for (provider, value) in leftIDs {
            guard let other = rightIDs[provider] else { continue }
            if other == value { return true }
            conflicting.insert(provider)
        }
        // Two IMDb ids settle it the other way, whatever the names say: IMDb
        // gives every film and show its own, and remakes share their names.
        // TMDB and TVDB ids are less sure -- a show's TMDB id stored as a
        // film's, a TVDB movie id beside a series' -- so a difference there
        // only asks the name and the year to agree exactly.
        guard !conflicting.contains("imdb") else { return false }
        let name = normalized(left.name)
        guard !name.isEmpty, name == normalized(right.name) else { return false }
        guard let leftYear = left.productionYear, let rightYear = right.productionYear else {
            return conflicting.isEmpty
        }
        // Providers disagree about a release year often enough -- a festival
        // premiere against a cinema release -- that one year apart still counts.
        return abs(leftYear - rightYear) <= (conflicting.isEmpty ? 1 : 0)
    }

    /// A film is a film whether a server files it as a Movie or as a Video.
    static func family(of type: String) -> String {
        type == "Video" ? "Movie" : type
    }

    /// The keys a title is known by. Two results sharing any one of them are
    /// the same title, which is how a search across servers lists it once.
    static func keys(of item: MediaItem) -> [String] {
        if item.type == "Episode" {
            guard let show = item.seriesName, !normalized(show).isEmpty,
                  let season = item.parentIndexNumber, let number = item.indexNumber else { return [] }
            return ["Episode|\(normalized(show))|\(season)|\(number)"]
        }
        var keys = providerIDs(of: item).map { "\(item.type)|\($0.key):\($0.value)" }.sorted()
        let name = normalized(item.name)
        if !name.isEmpty {
            keys.append("\(item.type)|\(name)|\(item.productionYear.map(String.init) ?? "")")
        }
        return keys
    }

    /// The IMDb, TMDB and TVDB ids, each written one way whichever server
    /// wrote it: "tmdb:693134" and "693134" are the same TMDB id, and
    /// "tt133093" the same IMDb id as "tt0133093".
    static func providerIDs(of item: MediaItem) -> [String: String] {
        var ids: [String: String] = [:]
        for (provider, value) in item.providerIDs ?? [:] {
            let name = provider.lowercased()
            guard let id = canonicalID(name, value) else { continue }
            ids[name] = id
        }
        return ids
    }

    /// One provider's id the way IMDb, TMDB and TVDB themselves write it --
    /// "tt" and at least seven digits for IMDb, the bare number for the
    /// others -- or nil for any other provider, or a value that is no id.
    static func canonicalID(_ provider: String, _ value: String) -> String? {
        let provider = provider.lowercased()
        guard ["imdb", "tmdb", "tvdb"].contains(provider) else { return nil }
        var id = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in [provider + ":", provider + "-"] where id.hasPrefix(prefix) {
            id.removeFirst(prefix.count)
        }
        if provider == "imdb", id.hasPrefix("tt") { id.removeFirst(2) }
        guard !id.isEmpty, id.allSatisfy(\.isASCII), id.allSatisfy(\.isNumber),
              let number = UInt64(id) else { return nil }
        guard provider == "imdb" else { return String(number) }
        let digits = String(number)
        return "tt" + String(repeating: "0", count: max(0, 7 - digits.count)) + digits
    }

    /// What to search another server for to find a title: its name, then the
    /// name as plain words, for a search that does not see past punctuation.
    static func searchTerms(for name: String) -> [String] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let words = withoutYear(trimmed)
            .replacingOccurrences(of: "[’'`]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty, words.caseInsensitiveCompare(trimmed) != .orderedSame else { return [trimmed] }
        return [trimmed, words]
    }

    static func normalized(_ value: String) -> String {
        withoutYear(value).replacingOccurrences(of: "&", with: " and ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }

    /// "Dune (2021)" is "Dune": some servers put the year in the name.
    private static func withoutYear(_ value: String) -> String {
        value.contains("(") ? trailingYear.replacing(in: value, with: "") : value
    }

    // Compiled once: every title of an IPTV provider's list is filed through
    // here.
    private static let trailingYear = CompiledPattern("\\s*\\((19|20)\\d{2}\\)\\s*$")
}

/// What a server is, as far as finding a title on it goes.
///
/// Remux and AIOStreams both speak Jellyfin's API without being Jellyfin, and
/// each can be asked for a title by its IMDb, TMDB or TVDB id in a way
/// Jellyfin itself cannot. Everything else about them is plain Jellyfin.
enum MediaServerKind: Sendable, Equatable {
    case jellyfin
    case remux
    case aiostreams
}

/// What a server says about itself to anyone, signed in or not -- here, only
/// as far as telling which server it is.
struct MediaServerPublicInfo: Decodable, Sendable {
    let serverName: String?
    let version: String?
    /// Remux's own version, which only Remux sends.
    let remuxVersion: String?
    /// AIOStreams' extensions to the API, which only AIOStreams announces.
    let aiostreams: Extensions?

    struct Extensions: Decodable, Sendable {
        let configureURL: String?
        enum CodingKeys: String, CodingKey { case configureURL = "configureUrl" }
    }

    var kind: MediaServerKind {
        if aiostreams != nil { return .aiostreams }
        if remuxVersion != nil { return .remux }
        return .jellyfin
    }

    enum CodingKeys: String, CodingKey {
        case serverName = "ServerName", version = "Version"
        case remuxVersion = "RemuxVersion", aiostreams
    }
}

/// The item id AIOStreams gives a title, made from the id its addons know the
/// title by.
///
/// AIOStreams' Jellyfin server keeps no library. An item id is the title's
/// IMDb, TMDB or TVDB id packed into sixteen bytes, unpacked on every request
/// and answered from the addons, the way Stremio asks for a title's streams.
/// So any title can be asked for directly, whether or not one of the
/// configuration's catalogs lists it -- and its search only reaches catalogs
/// that support search, which a configuration kept for its streams may not
/// have at all.
///
/// The layout is AIOStreams' own, from packages/core/src/jellyfin/ids.ts: a
/// marker byte, the kind and the id's provider, the media type, the number in
/// six bytes, then the season and the episode, 0xffff where there is none.
/// It is not a documented interface, so what comes back is still checked to
/// be the same title; a server that lays its ids out differently one day
/// simply answers with nothing, and the search by name is asked instead.
enum AIOStreamsItemID {
    enum Kind: UInt8 {
        case movie = 1
        case series = 2
        case episode = 4
    }

    static func make(_ kind: Kind, provider: String, value: String,
                     season: Int? = nil, episode: Int? = nil) -> String? {
        let providerCode: UInt8
        switch provider.lowercased() {
        case "imdb": providerCode = 1
        case "tmdb": providerCode = 2
        case "tvdb": providerCode = 3
        default: return nil
        }
        guard let id = MediaTitleMatch.canonicalID(provider, value) else { return nil }
        let digits = provider.lowercased() == "imdb" ? String(id.dropFirst(2)) : id
        guard let number = UInt64(digits), number <= 0xFFFF_FFFF_FFFF else { return nil }
        var place: (season: UInt16, episode: UInt16) = (0xFFFF, 0xFFFF)
        if kind == .episode {
            guard let season, let episode, (0..<0xFFFF).contains(season),
                  (0..<0xFFFF).contains(episode) else { return nil }
            place = (UInt16(season), UInt16(episode))
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = 0xA1
        bytes[1] = kind.rawValue << 4 | providerCode
        // A film is filed as a movie and a show as a series: what the addons
        // answer to for an IMDb, TMDB or TVDB id.
        bytes[2] = kind == .movie ? 1 : 2
        for index in 0..<6 {
            bytes[3 + index] = UInt8(truncatingIfNeeded: number >> UInt64(8 * (5 - index)))
        }
        bytes[9] = UInt8(place.season >> 8)
        bytes[10] = UInt8(place.season & 0xFF)
        bytes[11] = UInt8(place.episode >> 8)
        bytes[12] = UInt8(place.episode & 0xFF)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

enum MediaHeroCatalogSelection {
    static func resolve(_ catalogs: [MediaCatalog], selectedID: String?) -> MediaCatalog? {
        if let selectedID,
           let selected = catalogs.first(where: { $0.id == selectedID && !$0.items.isEmpty }) {
            return selected
        }
        return catalogs.first { !$0.items.isEmpty }
    }

    static func featuredItems(in catalog: MediaCatalog, limit: Int = 10) -> [MediaItem] {
        guard limit > 0 else { return [] }
        let presentable = catalog.items.filter { $0.hasDetailPage || $0.isPlayable }
        return Array((presentable.isEmpty ? catalog.items : presentable).prefix(limit))
    }
}

struct MediaLibraryCounts: Codable, Equatable, Sendable {
    let movies: Int
    let shows: Int
    let episodes: Int
}

struct JellyfinItemsResponse: Codable, Sendable {
    let items: [MediaItem]
    let totalRecordCount: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items", totalRecordCount = "TotalRecordCount"
    }
}

struct JellyfinAuthenticationResponse: Codable, Sendable {
    struct User: Codable, Sendable { let id: String; let name: String
        enum CodingKeys: String, CodingKey { case id = "Id"; case name = "Name" }
    }
    let user: User
    let accessToken: String

    enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
    }
}

struct MediaPlaybackInfo: Decodable, Sendable {
    let mediaSources: [MediaPlaybackSource]

    enum CodingKeys: String, CodingKey { case mediaSources = "MediaSources" }
}

/// One subtitle choice exposed by the active playback engine. The engine keeps
/// its native track object; the view only needs a stable id, a readable name,
/// and the integer VLC uses when VLC is rendering the title.
struct PlaybackSubtitleTrack: Identifiable, Hashable, Sendable {
    static let off = PlaybackSubtitleTrack(id: "off", title: "Off", engineIndex: nil)

    let id: String
    let title: String
    let engineIndex: Int?

    static func vlcTracks(names: [String], indexes: [Int]) -> [PlaybackSubtitleTrack] {
        var tracks: [PlaybackSubtitleTrack] = [.off]
        var seen: Set<Int> = []
        for (name, index) in zip(names, indexes) where index >= 0 && seen.insert(index).inserted {
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = clean.lowercased()
            guard lowered != "disable" && lowered != "disabled" && lowered != "off" else { continue }
            tracks.append(PlaybackSubtitleTrack(id: "vlc-\(index)",
                                                title: clean.isEmpty ? "Subtitle \(tracks.count)" : clean,
                                                engineIndex: index))
        }
        return tracks
    }
}

/// An audio or video stream inside the playing file, as VLC numbers it. A
/// film can carry several of each -- languages, commentary, a director's cut
/// -- and the player offers them by this.
struct PlaybackStreamTrack: Identifiable, Hashable, Sendable {
    /// VLC's own index for the stream, which is what choosing it sets.
    let id: Int
    let title: String

    /// The streams VLC lists for a file, without the "Disable" entry it adds
    /// to each list: a picker offers the streams themselves.
    static func vlcTracks(names: [String], indexes: [Int], kind: String) -> [PlaybackStreamTrack] {
        var tracks: [PlaybackStreamTrack] = []
        var seen: Set<Int> = []
        for (name, index) in zip(names, indexes) where index >= 0 && seen.insert(index).inserted {
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = clean.lowercased()
            guard lowered != "disable" && lowered != "disabled" && lowered != "off" else { continue }
            tracks.append(PlaybackStreamTrack(id: index,
                                              title: clean.isEmpty ? "\(kind) \(tracks.count + 1)" : clean))
        }
        return tracks
    }
}

struct MediaPlaybackSource: Decodable, Identifiable, Hashable, Sendable {
    /// The server's own id for this stream, which is what playing it sends.
    let sourceID: String
    let name: String?
    let path: String?
    let container: String?
    let size: Int64?
    let bitrate: Int64?
    let remux: RemuxInfo?
    /// What AIOStreams adds about a stream. Absent from every other server.
    var aiostreams: AIOStreamsInfo? = nil

    // Lineup's own, filled in when the server answers: the streams for one
    // title can come from several servers, and each has to be played from
    // the server that offered it, as that server's copy of the title.
    var serverID: UUID? = nil
    var serverName: String? = nil
    var itemID: String? = nil
    /// Where a stream that no media server serves plays from: the IPTV
    /// provider's own address for a film or an episode.
    var directURL: URL? = nil

    /// Unique across servers, which can number their streams alike.
    var id: String { (serverID?.uuidString ?? "") + "|" + sourceID }

    struct RemuxInfo: Decodable, Hashable, Sendable {
        let providerInfo: ProviderInfo?
        enum CodingKeys: String, CodingKey { case providerInfo = "ProviderInfo" }
    }

    struct ProviderInfo: Decodable, Hashable, Sendable {
        let source: String?
        let filename: String?
        let description: String?
    }

    /// What AIOStreams knows of a stream beyond its formatted name: the
    /// add-on that found it, the release's own file name, and whether its
    /// debrid service already has it. Read however it is written, and left
    /// out when it will not read: one odd field is no reason to lose a
    /// server's whole list.
    struct AIOStreamsInfo: Decodable, Hashable, Sendable {
        let addon: String?
        let filename: String?
        let cached: Bool?

        enum CodingKeys: String, CodingKey { case addon, filename, cached }

        init(from decoder: Decoder) throws {
            let values = try? decoder.container(keyedBy: CodingKeys.self)
            addon = values?.lenientString(.addon)
            filename = values?.lenientString(.filename)
            cached = try? values?.decodeIfPresent(Bool.self, forKey: .cached)
        }
    }

    enum CodingKeys: String, CodingKey {
        case sourceID = "Id"
        case name = "Name"
        case path = "Path"
        case container = "Container"
        case size = "Size"
        case bitrate = "Bitrate"
        case remux = "Remux"
        case aiostreams
    }

    var displayLines: [String] {
        (name ?? remux?.providerInfo?.description ?? "Stream")
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    var provider: String {
        remux?.providerInfo?.source ?? aiostreams?.addon ?? displayLines.first ?? "Media Server"
    }

    /// The tab a stream is listed under in the stream list: the server it
    /// came from, or VOD for the IPTV provider's own copy. Each server's
    /// results together, whatever add-on found them; grouped by add-on, a
    /// server that names none had its streams split by the first line of
    /// their names -- by quality.
    var group: String {
        if directURL != nil { return "VOD" }
        return serverName ?? provider
    }

    var releaseName: String {
        if let filename = remux?.providerInfo?.filename {
            return filename.replacingOccurrences(of: #"^🎯 SCORE [+-]?\d+ 🎯 •\s*"#,
                with: "", options: .regularExpression)
        }
        // AIOStreams' name is laid out by its own formatter; the file name
        // is the release itself.
        if let filename = aiostreams?.filename { return filename }
        return displayLines.dropFirst(2).first ?? displayLines.dropFirst().first ?? "Available stream"
    }

    /// A stream its debrid service already has, which plays at once rather
    /// than after being fetched. Only AIOStreams says.
    var isInstant: Bool { aiostreams?.cached == true }

    /// The score the server ranked the stream by: StreamNZB's "Score: +68648",
    /// or the one AIOStreams' formatter writes in small digits at the end of
    /// a line ("ᴅᴠ ʜᴅʀ ₂₄₅").
    var score: Int? {
        let text = [name, remux?.providerInfo?.filename, remux?.providerInfo?.description]
            .compactMap { $0 }.joined(separator: " ")
        if let match = text.range(of: #"(?i)score[: ]+([+-]?\d+)"#, options: .regularExpression) {
            let value = text[match].replacingOccurrences(of: #"(?i)score[: ]+"#, with: "", options: .regularExpression)
            return Int(value)
        }
        guard aiostreams != nil, let name, let small = Self.smallScore.lastCapture(in: name) else { return nil }
        return Int(String(small.map { Self.smallDigits[$0] ?? $0 }))
    }

    /// The stars AIOStreams' formatter draws for a stream -- its score
    /// against the best stream it found -- exactly as it drew them. The
    /// lowest-ranked streams get a row of empty ones, which still says so.
    var stars: String? {
        guard aiostreams != nil, let name,
              let range = name.range(of: "★[★☆⯪]*|[☆⯪]{5}", options: .regularExpression)
        else { return nil }
        return String(name[range])
    }

    /// A server's streams, highest score first, as the server itself ranks
    /// them. Scores are only ever compared within one server's list.
    ///
    /// A stream with no score keeps its place among the others without one,
    /// after every scored stream -- except from AIOStreams, whose formatter
    /// writes no score when it is nought: there, an unwritten score among
    /// written ones ranks as zero, between the positive and the negative.
    static func ranked(_ sources: [MediaPlaybackSource]) -> [MediaPlaybackSource] {
        guard sources.contains(where: { $0.score != nil }) else { return sources }
        func rank(_ source: MediaPlaybackSource) -> Int? {
            source.score ?? (source.aiostreams != nil ? 0 : nil)
        }
        return sources.enumerated().sorted { left, right in
            switch (rank(left.element), rank(right.element)) {
            case let (a?, b?): a != b ? a > b : left.offset < right.offset
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): left.offset < right.offset
            }
        }.map(\.element)
    }

    /// The server's ranking, to put beside a stream: its stars, then its score.
    var rankLabel: String? {
        let ranked = score.map { "SCORE " + ($0 >= 0 ? "+" : "") + $0.formatted() }
        let parts = [stars, ranked].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // Standing alone, after a space: a tier's number written the same way
    // ("ᴛ₁") sits against its letter, and is not the score.
    private static let smallScore = CompiledPattern(#"(?:^|\s)([-₋]?[₀₁₂₃₄₅₆₇₈₉]+)(?=\s|$)"#)
    private static let smallDigits: [Character: Character] = [
        "₀": "0", "₁": "1", "₂": "2", "₃": "3", "₄": "4", "₅": "5", "₆": "6", "₇": "7", "₈": "8", "₉": "9", "₋": "-"
    ]

    // A release name and the server's own probe line describe the same stream in
    // different words: one says "H 265", the other "hevc". Reading both means a
    // detail shows up whichever of them happens to carry it.
    private var descriptorText: String {
        [releaseName, name, remux?.providerInfo?.filename, remux?.providerInfo?.description]
            .compactMap { $0 }.joined(separator: " ").lowercased()
    }

    // Separators are the only difference between "H.265", "H 265" and "H265",
    // so most of these tokens are easier to find with them gone.
    private var condensedDescriptor: String {
        descriptorText.replacingOccurrences(of: #"[ ._-]"#, with: "", options: .regularExpression)
    }

    var quality: String? {
        let value = descriptorText
        if value.contains("2160p") || value.contains("4k") || value.contains("uhd") { return "4K" }
        if value.contains("1440p") { return "1440p" }
        if value.contains("1080p") { return "1080p" }
        if value.contains("720p") { return "720p" }
        if value.contains("480p") { return "480p" }
        return nil
    }

    // A hybrid release carries both, and which one a TV can use depends on the TV,
    // so both are worth naming rather than picking one.
    var dynamicRangeTags: [String] {
        var tags: [String] = []
        let condensed = condensedDescriptor
        if condensed.contains("dolbyvision") || condensed.contains("dovi")
            || descriptorText.range(of: #"\bdv\b"#, options: .regularExpression) != nil {
            tags.append("DV")
        }
        if condensed.contains("hdr10plus") || condensed.contains("hdr10+") { tags.append("HDR10+") }
        else if condensed.contains("hdr10") { tags.append("HDR10") }
        else if condensed.contains("hdr") { tags.append("HDR") }
        return tags
    }

    var videoCodec: String? {
        let condensed = condensedDescriptor
        if condensed.contains("av1") { return "AV1" }
        if condensed.contains("hevc") || condensed.contains("h265") || condensed.contains("x265") { return "H.265" }
        if condensed.contains("h264") || condensed.contains("x264") || condensed.contains("avc") { return "H.264" }
        if condensed.contains("mpeg2") { return "MPEG-2" }
        return nil
    }

    var bitDepth: String? {
        let condensed = condensedDescriptor
        if condensed.contains("10bit") { return "10-bit" }
        if condensed.contains("8bit") { return "8-bit" }
        return nil
    }

    var audioCodec: String? {
        let condensed = condensedDescriptor
        if condensed.contains("truehd") { return "TrueHD" }
        if condensed.contains("dtsx") { return "DTS:X" }
        if condensed.contains("dtshd") { return "DTS-HD" }
        if condensed.contains("dts") { return "DTS" }
        if condensed.contains("eac3") || condensed.contains("ddp") || condensed.contains("dd+") { return "DD+" }
        if condensed.contains("ac3") { return "DD" }
        if condensed.contains("flac") { return "FLAC" }
        if condensed.contains("aac") { return "AAC" }
        if condensed.contains("opus") { return "Opus" }
        return nil
    }

    var hasAtmos: Bool { condensedDescriptor.contains("atmos") }

    // Channel counts are written "5.1" and "DDP5 1" alike. Bounding the digits
    // keeps a year or a score from reading as a surround layout.
    var audioChannels: String? {
        let text = descriptorText
        guard let range = text.range(of: #"(?<![0-9])[2567][. ][01](?![0-9])"#,
            options: .regularExpression) else { return nil }
        return text[range].replacingOccurrences(of: " ", with: ".")
    }

    var sourceTag: String? {
        let condensed = condensedDescriptor
        if condensed.contains("remux") { return "REMUX" }
        if condensed.contains("bluray") || condensed.contains("bdrip") || condensed.contains("brrip") { return "BluRay" }
        if condensed.contains("webdl") { return "WEB-DL" }
        if condensed.contains("webrip") { return "WEBRip" }
        if condensed.contains("hdtv") { return "HDTV" }
        if condensed.contains("dvdrip") { return "DVD" }
        // A release that says only "WEB", as in "2160p.WEB.H265".
        if descriptorText.range(of: #"\bweb\b"#, options: .regularExpression) != nil { return "WEB" }
        return nil
    }

    // Ordered the way a stream is judged: how it looks, then how it sounds, then
    // where it was mastered from.
    var badges: [String] {
        var badges = dynamicRangeTags
        if let videoCodec { badges.append(videoCodec) }
        if let bitDepth { badges.append(bitDepth) }
        if let audioCodec { badges.append(audioCodec) }
        if hasAtmos { badges.append("Atmos") }
        if let audioChannels { badges.append(audioChannels) }
        if let sourceTag { badges.append(sourceTag) }
        return badges
    }

    // The measurable facts, in the order someone compares two results by.
    // Servers name containers in full, and "MATROSKA" costs the width of the
    // numbers beside it for no more meaning than "MKV".
    var containerLabel: String? {
        guard let first = container?.split(separator: ",").first else { return nil }
        let value = first.trimmingCharacters(in: .whitespaces).lowercased()
        guard !value.isEmpty else { return nil }
        switch value {
        case "matroska": return "MKV"
        case "quicktime", "mpeg-4": return "MP4"
        default: return value.uppercased()
        }
    }

    var formattedSize: String? {
        guard let size, size > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    // Servers report bits per second. Mbps is how a release is usually described,
    // and one decimal separates neighbouring encodes without adding noise.
    var formattedBitrate: String? {
        guard let bitrate, bitrate > 0 else { return nil }
        let mbps = Double(bitrate) / 1_000_000
        return mbps >= 10 ? "\(Int(mbps.rounded())) Mbps" : String(format: "%.1f Mbps", mbps)
    }
}
