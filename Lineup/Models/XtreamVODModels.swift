import Foundation

// The provider's video library: its films and its shows, beside the live
// channels the rest of the Xtream models describe.
//
// Panels disagree about types. An id arrives as 42 or "42", a rating as 7.4,
// "7.4" or "", a list of backdrops as an array or a single string. Everything
// here is read whichever way it came, and a field that will not read is left
// out rather than failing the whole list: one odd entry in a library of
// thousands is no reason to lose the other thousands.

/// A film, as `get_vod_streams` lists it.
struct XtreamVODStream: Codable, Identifiable, Hashable, Sendable {
    let streamID: Int
    let name: String
    let icon: String?
    let categoryID: String?
    let containerExtension: String?
    let rating: Double?
    /// TMDB's id for the film, where the panel records it.
    let tmdbID: String?
    let year: Int?

    var id: Int { streamID }

    enum CodingKeys: String, CodingKey {
        case streamID = "stream_id", name, title
        case icon = "stream_icon", categoryID = "category_id"
        case containerExtension = "container_extension"
        case rating, tmdb, tmdbID = "tmdb_id", year, releaseDate = "release_date", releasedate
    }

    init(streamID: Int, name: String, icon: String? = nil, categoryID: String? = nil,
         containerExtension: String? = nil, rating: Double? = nil, tmdbID: String? = nil, year: Int? = nil) {
        self.streamID = streamID
        self.name = name
        self.icon = icon
        self.categoryID = categoryID
        self.containerExtension = containerExtension
        self.rating = rating
        self.tmdbID = tmdbID
        self.year = year
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let streamID = values.lenientInt(.streamID) else {
            throw DecodingError.dataCorruptedError(forKey: .streamID, in: values,
                                                   debugDescription: "A film with no id")
        }
        self.streamID = streamID
        name = values.lenientString(.name) ?? values.lenientString(.title) ?? ""
        icon = values.lenientString(.icon)
        categoryID = values.lenientString(.categoryID)
        containerExtension = values.lenientString(.containerExtension)
        rating = values.lenientDouble(.rating)
        tmdbID = (values.lenientString(.tmdb) ?? values.lenientString(.tmdbID)).flatMap(XtreamVOD.tmdbID)
        year = values.lenientInt(.year).flatMap(XtreamVOD.plausibleYear)
            ?? XtreamVOD.year(in: values.lenientString(.releaseDate) ?? values.lenientString(.releasedate))
            ?? XtreamVOD.year(inTitle: name)
    }

    /// Written in the panel's own keys, so the copy kept on the device reads
    /// back through the same decoder as the panel's answer.
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(streamID, forKey: .streamID)
        try values.encode(name, forKey: .name)
        try values.encodeIfPresent(icon, forKey: .icon)
        try values.encodeIfPresent(categoryID, forKey: .categoryID)
        try values.encodeIfPresent(containerExtension, forKey: .containerExtension)
        try values.encodeIfPresent(rating, forKey: .rating)
        try values.encodeIfPresent(tmdbID, forKey: .tmdb)
        try values.encodeIfPresent(year, forKey: .year)
    }
}

/// A show, as `get_series` lists it.
struct XtreamSeries: Codable, Identifiable, Hashable, Sendable {
    let seriesID: Int
    let name: String
    let cover: String?
    let plot: String?
    let genre: String?
    let rating: Double?
    let backdrop: String?
    let categoryID: String?
    let tmdbID: String?
    let year: Int?

    var id: Int { seriesID }

    enum CodingKeys: String, CodingKey {
        case seriesID = "series_id", name, title, cover, plot, genre, rating
        case backdrop = "backdrop_path", categoryID = "category_id"
        case tmdb, tmdbID = "tmdb_id", year, releaseDate, releaseDateSnake = "release_date"
    }

    init(seriesID: Int, name: String, cover: String? = nil, plot: String? = nil, genre: String? = nil,
         rating: Double? = nil, backdrop: String? = nil, categoryID: String? = nil,
         tmdbID: String? = nil, year: Int? = nil) {
        self.seriesID = seriesID
        self.name = name
        self.cover = cover
        self.plot = plot
        self.genre = genre
        self.rating = rating
        self.backdrop = backdrop
        self.categoryID = categoryID
        self.tmdbID = tmdbID
        self.year = year
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let seriesID = values.lenientInt(.seriesID) else {
            throw DecodingError.dataCorruptedError(forKey: .seriesID, in: values,
                                                   debugDescription: "A show with no id")
        }
        self.seriesID = seriesID
        name = values.lenientString(.name) ?? values.lenientString(.title) ?? ""
        cover = values.lenientString(.cover)
        plot = values.lenientString(.plot)
        genre = values.lenientString(.genre)
        rating = values.lenientDouble(.rating)
        // An array of backdrops on most panels, a single one on some.
        backdrop = (try? values.decode([String].self, forKey: .backdrop))?.first { !$0.isEmpty }
            ?? values.lenientString(.backdrop)
        categoryID = values.lenientString(.categoryID)
        tmdbID = (values.lenientString(.tmdb) ?? values.lenientString(.tmdbID)).flatMap(XtreamVOD.tmdbID)
        year = values.lenientInt(.year).flatMap(XtreamVOD.plausibleYear)
            ?? XtreamVOD.year(in: values.lenientString(.releaseDate) ?? values.lenientString(.releaseDateSnake))
            ?? XtreamVOD.year(inTitle: name)
    }

    /// Written in the panel's own keys, like a film.
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(seriesID, forKey: .seriesID)
        try values.encode(name, forKey: .name)
        try values.encodeIfPresent(cover, forKey: .cover)
        try values.encodeIfPresent(plot, forKey: .plot)
        try values.encodeIfPresent(genre, forKey: .genre)
        try values.encodeIfPresent(rating, forKey: .rating)
        try values.encodeIfPresent(backdrop, forKey: .backdrop)
        try values.encodeIfPresent(categoryID, forKey: .categoryID)
        try values.encodeIfPresent(tmdbID, forKey: .tmdb)
        try values.encodeIfPresent(year, forKey: .year)
    }
}

/// One episode of a show, from `get_series_info`.
struct XtreamEpisode: Decodable, Identifiable, Hashable, Sendable {
    /// The id its stream is played by.
    let id: String
    let season: Int
    let episodeNumber: Int
    let title: String
    let containerExtension: String?
    let plot: String?
    let image: String?
    let durationSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case id, season, episodeNumber = "episode_num", title
        case containerExtension = "container_extension", info
    }

    enum InfoKeys: String, CodingKey {
        case plot, image = "movie_image", durationSeconds = "duration_secs", season
    }

    init(id: String, season: Int, episodeNumber: Int, title: String, containerExtension: String? = nil,
         plot: String? = nil, image: String? = nil, durationSeconds: Int? = nil) {
        self.id = id
        self.season = season
        self.episodeNumber = episodeNumber
        self.title = title
        self.containerExtension = containerExtension
        self.plot = plot
        self.image = image
        self.durationSeconds = durationSeconds
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = values.lenientString(.id), let number = values.lenientInt(.episodeNumber) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: values,
                                                   debugDescription: "An episode with no id or number")
        }
        self.id = id
        episodeNumber = number
        let info = try? values.nestedContainer(keyedBy: InfoKeys.self, forKey: .info)
        // The season is on the episode on most panels and only in its info on
        // some; the list it came in says it too, and is used when neither does.
        season = values.lenientInt(.season) ?? info?.lenientInt(.season) ?? -1
        title = values.lenientString(.title) ?? "Episode \(number)"
        containerExtension = values.lenientString(.containerExtension)
        plot = info?.lenientString(.plot)
        image = info?.lenientString(.image)
        durationSeconds = info?.lenientInt(.durationSeconds)
    }

    /// The same episode, placed in the season whose list it came in when it
    /// did not say its own.
    func inSeason(_ listed: Int) -> XtreamEpisode {
        guard season < 0 else { return self }
        return XtreamEpisode(id: id, season: listed, episodeNumber: episodeNumber, title: title,
                             containerExtension: containerExtension, plot: plot, image: image,
                             durationSeconds: durationSeconds)
    }
}

/// What `get_vod_info` says about a film beyond its list entry. Panels with
/// nothing to say answer with an empty list where the object belongs, which
/// reads as nothing here rather than as an error.
struct XtreamVODInfo: Decodable, Sendable {
    let plot: String?
    let genre: String?
    let backdrop: String?
    let durationSeconds: Int?
    let releaseDate: String?
    let tmdbID: String?
    let cast: String?
    let director: String?

    enum CodingKeys: String, CodingKey { case info }

    enum InfoKeys: String, CodingKey {
        case plot, description, genre, backdrop = "backdrop_path", durationSeconds = "duration_secs"
        case releaseDate = "releasedate", tmdbID = "tmdb_id", cast, actors, director
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let info = try? values.nestedContainer(keyedBy: InfoKeys.self, forKey: .info)
        plot = info?.lenientString(.plot) ?? info?.lenientString(.description)
        genre = info?.lenientString(.genre)
        backdrop = (try? info?.decode([String].self, forKey: .backdrop))?.first { !$0.isEmpty }
            ?? info?.lenientString(.backdrop)
        durationSeconds = info?.lenientInt(.durationSeconds)
        releaseDate = info?.lenientString(.releaseDate)
        tmdbID = info?.lenientString(.tmdbID).flatMap(XtreamVOD.tmdbID)
        cast = info?.lenientString(.cast) ?? info?.lenientString(.actors)
        director = info?.lenientString(.director)
    }
}

/// What `get_series_info` says about a show: its episodes, season by season.
struct XtreamSeriesInfo: Decodable, Sendable {
    let episodes: [XtreamEpisode]

    enum CodingKeys: String, CodingKey { case episodes }

    init(episodes: [XtreamEpisode]) { self.episodes = episodes }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Keyed by season number on most panels; a flat list on a few.
        if let bySeason = try? values.decode([String: [Lenient<XtreamEpisode>]].self, forKey: .episodes) {
            episodes = bySeason.flatMap { season, list in
                list.compactMap(\.value).map { $0.inSeason(Int(season) ?? -1) }
            }
            .sorted { ($0.season, $0.episodeNumber) < ($1.season, $1.episodeNumber) }
        } else if let flat = try? values.decode([Lenient<XtreamEpisode>].self, forKey: .episodes) {
            episodes = flat.compactMap(\.value)
                .sorted { ($0.season, $0.episodeNumber) < ($1.season, $1.episodeNumber) }
        } else {
            episodes = []
        }
    }
}

/// A list entry decoded on its own, so one that will not read is skipped
/// rather than failing the list around it.
struct Lenient<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

enum XtreamVOD {
    /// A TMDB id as a bare number, from "693134", "tmdb:693134" or 693134.
    static func tmdbID(_ raw: String) -> String? {
        MediaTitleMatch.canonicalID("tmdb", raw).flatMap { $0 == "0" ? nil : $0 }
    }

    static func plausibleYear(_ year: Int) -> Int? {
        (1888...2100).contains(year) ? year : nil
    }

    /// The year a date like "2024-03-01" starts with.
    static func year(in date: String?) -> Int? {
        guard let date, date.count >= 4, let year = Int(date.prefix(4)) else { return nil }
        return plausibleYear(year)
    }

    /// A year in brackets, as a provider writes one into a title.
    static let bracketedYear = CompiledPattern(#"\((19|20)\d{2}\)"#)

    /// The year a provider wrote into a title: "Dune: Part Two (2024)".
    static func year(inTitle title: String) -> Int? {
        guard title.contains("("), let range = bracketedYear.firstRange(in: title) else { return nil }
        return Int(title[range].dropFirst().dropLast())
    }
}

extension KeyedDecodingContainer {
    /// A string, however the panel wrote it: a number reads as its digits,
    /// and an empty string as nothing.
    func lenientString(_ key: Key) -> String? {
        if let text = try? decode(String.self, forKey: key) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = try? decode(Int.self, forKey: key) { return String(number) }
        if let number = try? decode(Double.self, forKey: key) {
            return number.rounded() == number ? String(Int(number)) : String(number)
        }
        return nil
    }

    func lenientInt(_ key: Key) -> Int? {
        if let number = try? decode(Int.self, forKey: key) { return number }
        if let number = try? decode(Double.self, forKey: key), number.isFinite { return Int(number) }
        guard let text = lenientString(key) else { return nil }
        return Int(text) ?? Double(text).flatMap { $0.isFinite ? Int($0) : nil }
    }

    func lenientDouble(_ key: Key) -> Double? {
        if let number = try? decode(Double.self, forKey: key) { return number.isFinite ? number : nil }
        return lenientString(key).flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }
    }
}

/// A provider's name for a title, as keys to find the same title by.
///
/// Providers decorate names -- "EN - Dune: Part Two (2024) [4K]", "|FR| Dune",
/// "Dune Part Two 2024 MULTI" -- and what is left once the decoration is gone
/// is compared the way two servers' names are.
enum ProviderTitle {
    /// Language, country and service codes a provider puts before a name with
    /// a colon, as in "EN: Dune". Only these: a colon after any other short
    /// word belongs to the title, as in "TRON: Legacy".
    private static let prefixCodes: Set<String> = [
        "EN", "ENG", "US", "USA", "UK", "CA", "AU", "IE", "FR", "DE", "ES", "IT", "NL", "BE", "PT",
        "BR", "LAT", "AR", "TR", "PL", "RU", "IN", "HI", "SE", "NO", "DK", "FI", "GR", "RO", "HU",
        "CZ", "SK", "BG", "HR", "RS", "AL", "KR", "JP", "CN", "TW", "PH", "PK", "IL", "MULTI",
        "NF", "NFLX", "AMZ", "DSNP", "HBO", "MAX", "ATV", "HULU", "PCOK", "PMTP", "4K", "UHD", "FHD", "HD"
    ]

    /// Quality and language marks a provider puts after a name.
    private static let suffixTags: Set<String> = [
        "4K", "UHD", "FHD", "HD", "SD", "HDR", "HDR10", "DV", "DOLBY", "HEVC", "H265", "X265",
        "2160P", "1080P", "720P", "MULTI", "MULTISUB", "MULTI-SUB", "VOSTFR", "DUAL", "SUB", "SUBS",
        "SUBBED", "DUB", "DUBBED", "LATINO", "EN", "ENG"
    ]

    /// One way a provider's name is filed, and the year that filing means.
    struct Filed: Hashable, Sendable {
        let key: String
        let year: Int?
    }

    /// The ways a provider's name is filed.
    ///
    /// Twice when a name ends in a bare year. "Dune Part Two 2024" is
    /// Dune: Part Two from 2024, and "Blade Runner 2049" is Blade Runner 2049
    /// from whenever -- so the name is filed both with the number, saying
    /// nothing of its year, and without it, as from that year. Whichever the
    /// title is, one of the two agrees with it.
    static func filings(for name: String) -> [Filed] {
        let (words, year) = cleaned(name)
        var filings = [Filed(key: MediaTitleMatch.normalized(words.joined(separator: " ")), year: year)]
        if words.count > 1, let last = words.last, last.count == 4,
           let bare = Int(last).flatMap(XtreamVOD.plausibleYear) {
            filings.append(Filed(key: MediaTitleMatch.normalized(words.dropLast().joined(separator: " ")),
                                 year: year ?? bare))
        }
        var seen: Set<String> = []
        return filings.filter { !$0.key.isEmpty && seen.insert($0.key).inserted }
    }

    /// The name to show for a provider's title: what is left once its
    /// decoration is gone, punctuation and all. The name itself when nothing
    /// would be left.
    static func displayName(for name: String) -> String {
        let shown = cleaned(name).words.joined(separator: " ")
        return shown.isEmpty ? name : shown
    }

    /// An episode's own name, without the show and the number a provider puts
    /// before it: "Breaking Bad - S01E01 - Pilot" is "Pilot".
    static func episodeName(_ title: String, number: Int) -> String {
        let name = episodeNumbering.replacing(in: title, with: "").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Episode \(number)" : name
    }

    // Each compiled once: a provider's list is cleaned name by name, tens of
    // thousands of times over.
    private static let episodeNumbering = CompiledPattern(#"(?i)^.*?\bS\d{1,3}\s*E\d{1,4}\b\s*[-:–|]?\s*"#)
    private static let bracketedMarks = CompiledPattern(#"\[[^\]]*\]|\{[^}]*\}|\|[^|]*\|"#)
    private static let leadingMark = CompiledPattern(#"^([A-Za-z0-9+]{2,5})\s*([-:•])\s+"#)
    private static let joinedLeadingMark = CompiledPattern(#"^([A-Z0-9+]{2,5})-(?=[A-Z0-9+]{2,5}\s*[-:])"#)

    /// A provider's name as its words, with its decoration gone, and the year
    /// it wrote in brackets.
    private static func cleaned(_ name: String) -> (words: [String], year: Int?) {
        let year = XtreamVOD.year(inTitle: name)
        var text = name
        if text.contains(where: { "[{|".contains($0) }) { text = bracketedMarks.replacing(in: text, with: " ") }
        if year != nil { text = XtreamVOD.bracketedYear.replacing(in: text, with: " ") }
        text = text.trimmingCharacters(in: .whitespaces)
        // Up to two leading marks: "4K-EN - Dune", "EN: Dune", "AMZ - Dune".
        for _ in 0..<2 {
            guard let match = leadingMark.firstRange(in: text) ?? joinedLeadingMark.firstRange(in: text)
            else { break }
            let mark = text[match].trimmingCharacters(in: CharacterSet(charactersIn: " -:•"))
            let isCode = prefixCodes.contains(mark.uppercased())
            let isDashMark = text[match].contains("-") && mark == mark.uppercased() && mark.count <= 4
            guard isCode || isDashMark else { break }
            text = String(text[match.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        // Trailing marks: "Dune 4K MULTI".
        var words = text.split(separator: " ").map(String.init)
        while words.count > 1, let last = words.last,
              suffixTags.contains(last.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: "-_."))) {
            words.removeLast()
        }
        return (words, year)
    }
}

/// A Library item that is one of the IPTV provider's titles, or one of its
/// categories, as its id says.
///
/// The provider's own ids are numbers, which a media server's could be too;
/// the prefix keeps them apart, and says how to play or open the item without
/// looking anything up.
enum ProviderItem: Equatable, Sendable {
    case film(streamID: Int)
    case series(seriesID: Int)
    case season(seriesID: Int, number: Int)
    case episode(seriesID: Int, episodeID: String)
    case filmCategory(String)
    case seriesCategory(String)

    init?(id: String) {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0] == "iptv" else { return nil }
        switch (parts[1], parts.count) {
        case ("film", 3): guard let value = Int(parts[2]) else { return nil }; self = .film(streamID: value)
        case ("series", 3): guard let value = Int(parts[2]) else { return nil }; self = .series(seriesID: value)
        case ("season", 4):
            guard let series = Int(parts[2]), let number = Int(parts[3]) else { return nil }
            self = .season(seriesID: series, number: number)
        case ("episode", 4):
            guard let series = Int(parts[2]), !parts[3].isEmpty else { return nil }
            self = .episode(seriesID: series, episodeID: parts[3])
        case ("vodcat", 3): self = .filmCategory(parts[2])
        case ("seriescat", 3): self = .seriesCategory(parts[2])
        default: return nil
        }
    }

    var id: String {
        switch self {
        case .film(let streamID): "iptv:film:\(streamID)"
        case .series(let seriesID): "iptv:series:\(seriesID)"
        case .season(let seriesID, let number): "iptv:season:\(seriesID):\(number)"
        case .episode(let seriesID, let episodeID): "iptv:episode:\(seriesID):\(episodeID)"
        case .filmCategory(let category): "iptv:vodcat:\(category)"
        case .seriesCategory(let category): "iptv:seriescat:\(category)"
        }
    }
}
