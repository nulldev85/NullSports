import Foundation

/// The provider's on-demand catalogue: films, and series with their episodes.
///
/// Foundation only, on purpose. Everything here -- the shapes, the decoding of
/// what a provider actually sends, the cleaning of names, search -- is checked
/// by `Tests/OnDemandChecks.swift` with nothing but `swiftc`, the same way the
/// channel matchers are.
enum OnDemandKind: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case movies
    case series

    var id: String { rawValue }
    var title: String { self == .movies ? "Movies" : "Series" }
}

/// A shelf of the catalogue, as the provider groups it.
struct OnDemandCategory: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
}

/// One film or one series, as a category list names it.
///
/// Deliberately small. A category list can run to thousands of these, and a
/// full catalogue to tens of thousands, so everything that only a detail page
/// needs -- the plot, the cast, the backdrop -- waits for that page to ask.
struct OnDemandTitle: Codable, Hashable, Identifiable, Sendable {
    let kind: OnDemandKind
    /// `stream_id` for a film, `series_id` for a series. Kept as text: some
    /// providers send numbers and some send strings, and nothing does arithmetic
    /// with it.
    let providerID: String
    /// Exactly what the provider called it, for search to fall back on.
    let rawName: String
    /// The same name without the provider's language tag or trailing year.
    let name: String
    let artwork: String?
    /// Out of ten.
    let rating: Double?
    let year: Int?
    let added: Date?
    let categoryIDs: [String]
    /// Films only: the file type the play URL ends in.
    let containerExtension: String?

    var id: String { kind.rawValue + ":" + providerID }

    var formattedRating: String? {
        guard let rating, rating > 0 else { return nil }
        return String(format: "%.1f", rating)
    }
}

/// What a detail page says about a film or a series, whichever it is.
struct OnDemandFacts: Codable, Hashable, Sendable {
    var plot: String?
    var genre: String?
    var director: String?
    var cast: String?
    var releaseDate: String?
    var durationSeconds: Int?
    var backdrops: [String]
    var poster: String?
    var rating: Double?
    var trailer: String?

    static let empty = OnDemandFacts(plot: nil, genre: nil, director: nil, cast: nil,
                                     releaseDate: nil, durationSeconds: nil, backdrops: [],
                                     poster: nil, rating: nil, trailer: nil)

    var year: Int? { OnDemandNaming.year(fromDate: releaseDate) }

    var formattedRuntime: String? { OnDemandNaming.runtime(durationSeconds) }
}

struct OnDemandMovieDetail: Codable, Hashable, Sendable {
    let facts: OnDemandFacts
    let containerExtension: String?
}

struct OnDemandEpisode: Codable, Hashable, Identifiable, Sendable {
    /// The episode's own stream identifier -- what its play URL is built from.
    let id: String
    let seriesID: String
    let season: Int
    let number: Int
    let title: String
    let plot: String?
    let still: String?
    let durationSeconds: Int?
    let releaseDate: String?
    let containerExtension: String

    var code: String { String(format: "S%02dE%02d", season, number) }
    var formattedRuntime: String? { OnDemandNaming.runtime(durationSeconds) }
}

struct OnDemandSeason: Codable, Hashable, Identifiable, Sendable {
    let number: Int
    let name: String
    let episodes: [OnDemandEpisode]

    var id: Int { number }
    var isSpecials: Bool { number == 0 }
}

struct OnDemandSeriesDetail: Codable, Hashable, Sendable {
    let facts: OnDemandFacts
    /// Numbered seasons in order, specials last.
    let seasons: [OnDemandSeason]

    var episodeCount: Int { seasons.reduce(0) { $0 + $1.episodes.count } }
}

// MARK: - Names

enum OnDemandNaming {
    /// "[EN] Heat", "|EN| Heat", "[4K] Heat". Square brackets and bars only:
    /// parentheses belong to titles -- "(500) Days of Summer".
    private static let bracketedTag = try! NSRegularExpression(
        pattern: #"^\s*[\[\|]\s*[A-Za-z0-9]{2,4}(?:[ /-][A-Za-z0-9]{2,4})?\s*[\]\|]\s*[-:|]?\s*"#)
    /// A bare two-letter code needs a real separator after it. "EN - Heat" is
    /// a language tag; "UFC: Fight Night" and "Up" are not.
    private static let bareTag = try! NSRegularExpression(
        pattern: #"^\s*[A-Z]{2}\s*(?:\||\s-\s)\s*"#)
    private static let trailingYear = try! NSRegularExpression(
        pattern: #"\s*[\(\[]((?:19|20)\d{2})[\)\]]\s*$"#)
    private static let episodeMarker = try! NSRegularExpression(
        pattern: #"S\d{1,3}\s?E\d{1,4}"#, options: [.caseInsensitive])

    /// A provider's name for a title, without the language tag in front of it
    /// or the year behind it. The year is handed back rather than thrown away:
    /// it is often the only year a category list gives.
    static func clean(_ raw: String) -> (name: String, year: Int?) {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in [bracketedTag, bareTag] {
            let range = NSRange(name.startIndex..., in: name)
            if let match = pattern.firstMatch(in: name, range: range),
               let found = Range(match.range, in: name) {
                let rest = String(name[found.upperBound...])
                if !rest.trimmingCharacters(in: .whitespaces).isEmpty { name = rest }
                break
            }
        }
        var year: Int?
        let range = NSRange(name.startIndex..., in: name)
        if let match = trailingYear.firstMatch(in: name, range: range),
           let whole = Range(match.range, in: name),
           let digits = Range(match.range(at: 1), in: name) {
            let rest = String(name[..<whole.lowerBound])
            if !rest.trimmingCharacters(in: .whitespaces).isEmpty {
                year = Int(name[digits])
                name = rest
            }
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? raw : name, year)
    }

    /// "Show - S01E02 - The Title" is how most providers name an episode. The
    /// page already says which show and which episode, so only the title is
    /// worth showing -- and when that is all there is, "Episode 2".
    static func episodeTitle(_ raw: String?, number: Int) -> String {
        let fallback = "Episode \(number)"
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return fallback
        }
        let range = NSRange(raw.startIndex..., in: raw)
        guard let match = episodeMarker.firstMatch(in: raw, range: range),
              let marker = Range(match.range, in: raw) else { return raw }
        let separators = CharacterSet(charactersIn: " -–—:|").union(.whitespaces)
        let after = raw[marker.upperBound...].trimmingCharacters(in: separators)
        return after.isEmpty ? fallback : after
    }

    static func year(fromDate raw: String?) -> Int? {
        guard let raw, raw.count >= 4, let year = Int(raw.prefix(4)),
              (1880...2100).contains(year) else { return nil }
        return year
    }

    static func runtime(_ seconds: Int?) -> String? {
        guard let seconds, seconds >= 60 else { return nil }
        let minutes = seconds / 60
        guard minutes >= 60 else { return "\(minutes)m" }
        let remainder = minutes % 60
        return remainder == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(remainder)m"
    }

    /// "01:42:10" or "42:10" as seconds.
    static func seconds(fromClock raw: String?) -> Int? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0 != nil }) else { return nil }
        let total = parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        return total > 0 ? total : nil
    }
}

// MARK: - Search

/// A title with its search key worked out once. Folding case and accents over
/// a whole catalogue on every keystroke is the slow part of search; doing it
/// when the catalogue arrives is not.
struct OnDemandSearchEntry: Sendable {
    let key: String
    let rawKey: String
    let title: OnDemandTitle

    init(_ title: OnDemandTitle) {
        self.title = title
        key = OnDemandSearch.key(title.name)
        rawKey = OnDemandSearch.key(title.rawName)
    }
}

enum OnDemandSearch {
    static func key(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var result = ""
        var lastWasSpace = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                result.append(" ")
                lastWasSpace = true
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Titles whose name holds every word of the query, best first: the exact
    /// name, then names that start with the query, then names with a word that
    /// does, then anything else that contains every word. Within a rank the
    /// catalogue's own order stands.
    static func matches(_ entries: [OnDemandSearchEntry], query: String,
                        limit: Int = 150) -> [OnDemandTitle] {
        let wanted = key(query)
        guard !wanted.isEmpty else { return [] }
        let words = wanted.split(separator: " ").map(String.init)
        var ranked: [[OnDemandTitle]] = [[], [], [], []]
        var seen = Set<String>()
        for entry in entries where !seen.contains(entry.title.id) {
            let rank: Int
            if entry.key == wanted { rank = 0 }
            else if entry.key.hasPrefix(wanted) { rank = 1 }
            else if entry.key.contains(" " + wanted) { rank = 2 }
            else if words.allSatisfy({ entry.key.contains($0) || entry.rawKey.contains($0) }) { rank = 3 }
            else { continue }
            seen.insert(entry.title.id)
            ranked[rank].append(entry.title)
        }
        return Array(ranked.joined().prefix(limit))
    }
}

// MARK: - What a provider sends

/// Decoding for Xtream's `player_api.php` on-demand actions.
///
/// Nothing a provider sends here can be trusted to keep its type. The same
/// field arrives as a number from one panel and a string from the next, a
/// missing object arrives as an empty array, and one malformed entry must not
/// cost a viewer the other nine thousand in the list. So every field is read
/// leniently and every list skips what it cannot read.
enum OnDemandWire {
    struct Key: CodingKey {
        let stringValue: String
        let intValue: Int?
        init(_ value: String) { stringValue = value; intValue = nil }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
    }

    struct Unreadable: Error {}

    /// Any JSON value at all, read as text when it is a scalar.
    struct Scalar: Decodable {
        let text: String?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { text = nil }
            else if let value = try? container.decode(String.self) { text = value }
            else if let value = try? container.decode(Int.self) { text = String(value) }
            else if let value = try? container.decode(Double.self) {
                text = value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
            }
            else if let value = try? container.decode(Bool.self) { text = value ? "1" : "0" }
            else { text = nil }
        }
    }

    /// Succeeds on anything without reading it, so a lossy list can step past
    /// an entry it could not use. Decoding an element is what moves a list on;
    /// failing to decode one would leave it stuck on the same entry forever.
    struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    /// A list that keeps what it can read. Anything that is not a list at all
    /// -- an error object, `null`, `false` -- is an empty one.
    struct Lossy<Element: Decodable>: Decodable {
        let values: [Element]
        init(from decoder: Decoder) throws {
            guard var container = try? decoder.unkeyedContainer() else { values = []; return }
            var result: [Element] = []
            while !container.isAtEnd {
                if let value = try? container.decode(Element.self) { result.append(value) }
                else if (try? container.decode(Skip.self)) == nil { break }
            }
            values = result
        }
    }

    struct Category: Decodable, Sendable {
        let category: OnDemandCategory
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            guard let id = container.text("category_id") else { throw Unreadable() }
            category = OnDemandCategory(id: id, name: container.text("category_name") ?? "Untitled")
        }
    }

    /// A row of `get_vod_streams` or `get_series`.
    struct Title: Decodable, Sendable {
        let title: OnDemandTitle
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            let isSeries = container.text("series_id") != nil && container.text("stream_id") == nil
            guard let id = container.text(isSeries ? "series_id" : "stream_id"),
                  let raw = container.text("name") else { throw Unreadable() }
            let cleaned = OnDemandNaming.clean(raw)
            var categories = container.texts("category_ids")
            if let single = container.text("category_id"), !categories.contains(single) {
                categories.insert(single, at: 0)
            }
            let year = container.int("year").flatMap { (1880...2100).contains($0) ? $0 : nil }
                ?? cleaned.year
                ?? OnDemandNaming.year(fromDate: container.text("releaseDate") ?? container.text("release_date"))
            let added = (container.double("added") ?? container.double("last_modified"))
                .flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            title = OnDemandTitle(
                kind: isSeries ? .series : .movies, providerID: id, rawName: raw, name: cleaned.name,
                artwork: container.text(isSeries ? "cover" : "stream_icon") ?? container.text("cover"),
                rating: container.rating(), year: year, added: added, categoryIDs: categories,
                containerExtension: isSeries ? nil : container.text("container_extension"))
        }
    }

    struct MovieInfo: Decodable, Sendable {
        let detail: OnDemandMovieDetail
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            let movie = container.object("movie_data")
            detail = OnDemandMovieDetail(
                facts: container.object("info").map(OnDemandFacts.init(info:)) ?? .empty,
                containerExtension: movie?.text("container_extension"))
        }
    }

    struct SeriesInfo: Decodable, Sendable {
        let facts: OnDemandFacts
        let seasonNames: [Int: String]
        let episodes: [Episode]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            facts = container.object("info").map(OnDemandFacts.init(info:)) ?? .empty
            var names: [Int: String] = [:]
            for season in (try? container.decode(Lossy<SeasonMeta>.self, forKey: Key("seasons")))?.values ?? [] {
                if let number = season.number, let name = season.name { names[number] = name }
            }
            seasonNames = names
            // Keyed by season number almost everywhere, but a few panels send
            // a plain list of lists instead.
            var found: [Episode] = []
            if let bySeason = try? container.decode([String: Lossy<Episode>].self, forKey: Key("episodes")) {
                for (key, list) in bySeason {
                    found += list.values.map { $0.inSeason(Int(key)) }
                }
            } else if let lists = try? container.decode(Lossy<Lossy<Episode>>.self, forKey: Key("episodes")) {
                for (index, list) in lists.values.enumerated() {
                    found += list.values.map { $0.inSeason(index + 1) }
                }
            }
            episodes = found
        }

        func detail(seriesID: String) -> OnDemandSeriesDetail {
            var bySeason: [Int: [OnDemandEpisode]] = [:]
            var seen = Set<String>()
            for episode in episodes where !seen.contains(episode.id) {
                seen.insert(episode.id)
                let season = episode.season ?? 1
                let number = episode.number ?? ((bySeason[season]?.count ?? 0) + 1)
                bySeason[season, default: []].append(OnDemandEpisode(
                    id: episode.id, seriesID: seriesID, season: season, number: number,
                    title: OnDemandNaming.episodeTitle(episode.title ?? episode.name, number: number),
                    plot: episode.plot, still: episode.still, durationSeconds: episode.durationSeconds,
                    releaseDate: episode.releaseDate, containerExtension: episode.containerExtension ?? "mp4"))
            }
            let order = bySeason.keys.sorted { left, right in
                // Specials after every numbered season, the way a viewer meets them.
                if (left == 0) != (right == 0) { return right == 0 }
                return left < right
            }
            let seasons = order.map { number in
                OnDemandSeason(number: number,
                               name: seasonNames[number].flatMap { $0.isEmpty ? nil : $0 }
                                   ?? (number == 0 ? "Specials" : "Season \(number)"),
                               episodes: (bySeason[number] ?? []).sorted {
                                   $0.number == $1.number ? $0.id < $1.id : $0.number < $1.number
                               })
            }
            return OnDemandSeriesDetail(facts: facts, seasons: seasons)
        }
    }

    struct SeasonMeta: Decodable, Sendable {
        let number: Int?
        let name: String?
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            number = container.int("season_number")
            name = container.text("name")
        }
    }

    struct Episode: Decodable, Sendable {
        let id: String
        let season: Int?
        let number: Int?
        let title: String?
        let name: String?
        let plot: String?
        let still: String?
        let durationSeconds: Int?
        let releaseDate: String?
        let containerExtension: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            guard let id = container.text("id") ?? container.text("stream_id") else { throw Unreadable() }
            self.id = id
            season = container.int("season")
            number = container.int("episode_num")
            title = container.text("title")
            containerExtension = container.text("container_extension")
            let info = container.object("info")
            name = info?.text("name")
            plot = info?.text("plot") ?? info?.text("description")
            still = info?.text("movie_image") ?? info?.text("cover_big")
            durationSeconds = info?.int("duration_secs") ?? OnDemandNaming.seconds(fromClock: info?.text("duration"))
            releaseDate = info?.text("releasedate") ?? info?.text("air_date") ?? info?.text("release_date")
        }

        private init(copying other: Episode, season: Int?) {
            id = other.id; self.season = season; number = other.number; title = other.title
            name = other.name; plot = other.plot; still = other.still
            durationSeconds = other.durationSeconds; releaseDate = other.releaseDate
            containerExtension = other.containerExtension
        }

        /// The episode's own season wins; the list it was filed under is the fallback.
        func inSeason(_ listed: Int?) -> Episode { Episode(copying: self, season: season ?? listed) }
    }
}

extension OnDemandWire.Lossy: Sendable where Element: Sendable {}

extension OnDemandFacts {
    init(info container: KeyedDecodingContainer<OnDemandWire.Key>) {
        let runTime = container.int("episode_run_time").map { $0 * 60 }
        self.init(
            plot: container.text("plot") ?? container.text("description"),
            genre: container.text("genre"),
            director: container.text("director"),
            cast: container.text("cast") ?? container.text("actors"),
            releaseDate: container.text("releasedate") ?? container.text("releaseDate")
                ?? container.text("release_date"),
            durationSeconds: container.int("duration_secs")
                ?? OnDemandNaming.seconds(fromClock: container.text("duration")) ?? runTime,
            backdrops: container.texts("backdrop_path"),
            poster: container.text("movie_image") ?? container.text("cover_big") ?? container.text("cover"),
            rating: container.rating(),
            trailer: container.text("youtube_trailer"))
    }
}

extension KeyedDecodingContainer where K == OnDemandWire.Key {
    /// Any scalar, as trimmed text; nothing when missing, null or blank.
    func text(_ key: String) -> String? {
        guard let scalar = try? decodeIfPresent(OnDemandWire.Scalar.self, forKey: OnDemandWire.Key(key)),
              let value = scalar.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value.lowercased() != "null" else { return nil }
        return value
    }

    func int(_ key: String) -> Int? {
        guard let value = text(key) else { return nil }
        return Int(value) ?? Double(value).map { Int($0) }
    }

    func double(_ key: String) -> Double? {
        text(key).flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
    }

    /// A list of scalars, or a single one, as text.
    func texts(_ key: String) -> [String] {
        if let list = try? decodeIfPresent(OnDemandWire.Lossy<OnDemandWire.Scalar>.self, forKey: OnDemandWire.Key(key)) {
            let values = list.values.compactMap { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !values.isEmpty { return values }
        }
        return text(key).map { [$0] } ?? []
    }

    /// An object, or nothing -- including when a provider sends `[]` for one.
    func object(_ key: String) -> KeyedDecodingContainer<OnDemandWire.Key>? {
        try? nestedContainer(keyedBy: OnDemandWire.Key.self, forKey: OnDemandWire.Key(key))
    }

    /// Out of ten, from whichever of the two scales the provider filled in.
    func rating() -> Double? {
        if let rating = double("rating"), rating > 0 { return min(rating, 10) }
        if let five = double("rating_5based"), five > 0 { return min(five * 2, 10) }
        return nil
    }
}
