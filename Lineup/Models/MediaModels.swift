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
    let userData: MediaUserData?
    let imageTags: [String: String]?
    let backdropImageTags: [String]?

    // Set only on an item that came from a Stremio addon rather than a media
    // server. An addon names its own artwork outright and answers about its own
    // ids, so those four facts are all it takes for the rest of the app --
    // cards, shelves, show pages, the stream picker -- to treat an addon item
    // as any other item. A server item leaves every one of them nil.
    /// Which installed addon this came from.
    let addonID: String?
    /// The addon's own kind: "movie", "series", "channel".
    let stremioType: String?
    /// The addon's own id: "tt0108778", or "tt0108778:1:1" for an episode.
    let stremioID: String?
    let posterURL: String?
    let backdropURL: String?

    // An optional `let` gets no implicit default, so the added fields are given
    // one here and every existing caller keeps the call it already makes.
    init(id: String, name: String, type: String, overview: String?,
         productionYear: Int?, primaryImageAspectRatio: Double?, childCount: Int?,
         genres: [String]? = nil, officialRating: String? = nil,
         communityRating: Double? = nil, criticRating: Double? = nil,
         runTimeTicks: Int64? = nil, premiereDate: String? = nil,
         indexNumber: Int? = nil, parentIndexNumber: Int? = nil,
         seriesName: String? = nil, userData: MediaUserData? = nil,
         imageTags: [String: String]? = nil, backdropImageTags: [String]? = nil,
         addonID: String? = nil, stremioType: String? = nil, stremioID: String? = nil,
         posterURL: String? = nil, backdropURL: String? = nil) {
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
        self.userData = userData
        self.imageTags = imageTags
        self.backdropImageTags = backdropImageTags
        self.addonID = addonID
        self.stremioType = stremioType
        self.stremioID = stremioID
        self.posterURL = posterURL
        self.backdropURL = backdropURL
    }

    /// Whether this item is an addon's rather than a server's, which is the
    /// one question every routed call in the library asks.
    var isAddonItem: Bool { addonID != nil }

    var isPlayable: Bool {
        ["Movie", "Episode", "Video"].contains(type)
    }

    var isFolder: Bool { !isPlayable }

    var isSeries: Bool { type == "Series" }

    var isPlayed: Bool { userData?.played == true }

    var isFavorite: Bool { userData?.isFavorite == true }

    var hasLogo: Bool { imageTags?["Logo"] != nil }

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
    var formattedAirDate: String? {
        guard let premiereDate, premiereDate.count >= 10 else { return nil }
        let parts = premiereDate.prefix(10).split(separator: "-")
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
        case userData = "UserData"
        case imageTags = "ImageTags"
        case backdropImageTags = "BackdropImageTags"
        // Lineup's own, never sent by a server: an absent key decodes to nil,
        // so a server's answer is unaffected by their existence.
        case addonID = "LineupAddonId"
        case stremioType = "LineupAddonType"
        case stremioID = "LineupAddonItemId"
        case posterURL = "LineupPoster"
        case backdropURL = "LineupBackdrop"
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

struct MediaCatalog: Identifiable, Hashable, Sendable {
    let root: MediaItem
    let items: [MediaItem]
    var id: String { root.id }
    var title: String { root.name }
}

struct JellyfinItemsResponse: Codable, Sendable {
    let items: [MediaItem]

    enum CodingKeys: String, CodingKey { case items = "Items" }
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

struct MediaPlaybackSource: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String?
    let path: String?
    let container: String?
    let size: Int64?
    let bitrate: Int64?
    let remux: RemuxInfo?

    struct RemuxInfo: Decodable, Hashable, Sendable {
        let providerInfo: ProviderInfo?
        enum CodingKeys: String, CodingKey { case providerInfo = "ProviderInfo" }
    }

    struct ProviderInfo: Decodable, Hashable, Sendable {
        let source: String?
        let filename: String?
        let description: String?
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case path = "Path"
        case container = "Container"
        case size = "Size"
        case bitrate = "Bitrate"
        case remux = "Remux"
    }

    var displayLines: [String] {
        (name ?? remux?.providerInfo?.description ?? "Stream")
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    var provider: String {
        remux?.providerInfo?.source ?? displayLines.first ?? "Media Server"
    }

    var releaseName: String {
        if let filename = remux?.providerInfo?.filename {
            return filename.replacingOccurrences(of: #"^🎯 SCORE [+-]?\d+ 🎯 •\s*"#,
                with: "", options: .regularExpression)
        }
        return displayLines.dropFirst(2).first ?? displayLines.dropFirst().first ?? "Available stream"
    }

    var score: Int? {
        let text = [name, remux?.providerInfo?.filename, remux?.providerInfo?.description]
            .compactMap { $0 }.joined(separator: " ")
        guard let match = text.range(of: #"(?i)score[: ]+([+-]?\d+)"#, options: .regularExpression) else { return nil }
        let value = text[match].replacingOccurrences(of: #"(?i)score[: ]+"#, with: "", options: .regularExpression)
        return Int(value)
    }

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
        return nil
    }

    // The server's search line reads "\u{1F50D} StreamNZB Library - altHUB \u{2022} \u{1F3AF} Score: +70494".
    // Only the tail names the indexer; the rest repeats the addon shown beside it.
    var indexer: String? {
        guard let line = displayLines.first(where: { $0.contains("\u{1F50D}") }) else { return nil }
        let head = line.split(separator: Character("\u{2022}")).first.map(String.init) ?? line
        let cleaned = head.replacingOccurrences(of: "\u{1F50D}", with: "")
            .trimmingCharacters(in: .whitespaces)
        let name = cleaned.components(separatedBy: " - ").last?
            .trimmingCharacters(in: .whitespaces) ?? cleaned
        guard !name.isEmpty, name.caseInsensitiveCompare(provider) != .orderedSame else { return nil }
        return name
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
    var facts: [String] {
        [formattedSize, formattedBitrate, containerLabel, indexer].compactMap { $0 }
    }

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
