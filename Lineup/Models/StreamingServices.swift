import Foundation

/// A streaming service on the Library's Streaming Services row: its name, its
/// mark, and the public MDBList lists that say what it has on.
///
/// The lists are kept by MDBList's curators and refreshed by them every day:
/// the popular ones follow each service's own top-ten chart, the latest ones
/// what the service has added, newest first. Nothing in them is played from
/// the service itself -- a title only reaches the row once one of the
/// viewer's own sources can play it.
struct StreamingService: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// Each list as MDBList's `user/slug`, or nil where no list worth
    /// trusting exists.
    let popularMovies: String?
    let latestMovies: String?
    let popularShows: String?
    let latestShows: String?

    /// The service's official mark, in the asset catalog.
    var logoAsset: String { "Streaming-\(id)" }

    /// Its poster on the row. A folder to the Library, so it opens a page of
    /// its own rather than a list of streams.
    func item(titles: Int) -> MediaItem {
        MediaItem(id: Self.itemPrefix + id, name: name, type: Self.itemType, overview: nil,
                  productionYear: nil, primaryImageAspectRatio: nil, childCount: titles)
    }

    /// Every list the service draws on, with what each one is.
    var lists: [StreamingList] {
        let all: [StreamingList?] = [
            popularMovies.map { StreamingList(path: $0, kind: .movie, chart: .popular) },
            latestMovies.map { StreamingList(path: $0, kind: .movie, chart: .latest) },
            popularShows.map { StreamingList(path: $0, kind: .show, chart: .popular) },
            latestShows.map { StreamingList(path: $0, kind: .show, chart: .latest) }
        ]
        return all.compactMap { $0 }
    }

    static let itemType = "StreamingService"
    static let itemPrefix = "streaming:"
    /// The row itself, as the Library's shelves are named.
    static let rowID = "streaming:services"
    static let rowTitle = "Streaming Services"

    static func service(for item: MediaItem) -> StreamingService? {
        guard item.type == itemType, item.id.hasPrefix(itemPrefix) else { return nil }
        let id = String(item.id.dropFirst(itemPrefix.count))
        return all.first { $0.id == id }
    }

    /// The big names, in the order the row shows them.
    static let all: [StreamingService] = [
        StreamingService(id: "netflix", name: "Netflix",
                         popularMovies: "snoak/netflix-top-10-movies",
                         latestMovies: "snoak/latest-netflix-movies",
                         popularShows: "snoak/netflix-top-10-shows",
                         latestShows: "snoak/latest-netflix-tv-shows"),
        // The movie chart's slug says shows; the list is the films.
        StreamingService(id: "prime", name: "Prime Video",
                         popularMovies: "snoak/amazon-prime-top-10-shows",
                         latestMovies: "snoak/latest-amazon-prime-movies",
                         popularShows: "snoak/amazon-prime-top-10-tv-shows",
                         latestShows: "snoak/latest-amazon-prime-tv-shows"),
        StreamingService(id: "disney", name: "Disney+",
                         popularMovies: "snoak/disney-plus-top-10-movies",
                         latestMovies: "snoak/latest-disney-plus-movies",
                         popularShows: "snoak/disney-plus-top-10-tv-shows",
                         latestShows: "snoak/latest-disney-plus-tv-shows"),
        StreamingService(id: "hbomax", name: "HBO Max",
                         popularMovies: "snoak/hbo-top-10-movies-2",
                         latestMovies: "snoak/latest-max-movies",
                         popularShows: "snoak/hbo-top-10-tv-shows",
                         latestShows: "snoak/latest-max-tv-shows"),
        StreamingService(id: "appletv", name: "Apple TV",
                         popularMovies: "snoak/apple-tv-top-10-movies",
                         latestMovies: "snoak/latest-apple-tv-plus-movies",
                         popularShows: "snoak/apple-tv-top-10-tv-shows",
                         latestShows: "snoak/latest-apple-tv-plus-tv-shows"),
        StreamingService(id: "paramount", name: "Paramount+",
                         popularMovies: "snoak/paramount-plus-top-10-movies",
                         latestMovies: "snoak/latest-paramount-plus-movies",
                         popularShows: "snoak/paramount-plus-top-10-tv-shows",
                         latestShows: "snoak/latest-paramount-plus-tv-shows"),
        StreamingService(id: "hulu", name: "Hulu",
                         popularMovies: "boholiday/popular-hulu-movies",
                         latestMovies: "garycrawfordgc/hulu-movies",
                         popularShows: "boholiday/top-20-hulu-shows",
                         latestShows: "garycrawfordgc/hulu-shows"),
        StreamingService(id: "peacock", name: "Peacock",
                         popularMovies: "febsho/popular-peacock-movies",
                         latestMovies: "replay/peacock-movies",
                         popularShows: "boholiday/top-20-peacock-shows",
                         latestShows: nil)
    ]

    /// How far down each list is read. The popular lists are charts, whose
    /// tail is old news; the latest lists run to hundreds.
    static let popularDepth = 40
    static let latestDepth = 60
}

/// One of a service's lists, and what it is.
struct StreamingList: Hashable, Sendable {
    let path: String
    let kind: StreamingTitle.Kind
    let chart: StreamingTitle.Chart
}

/// One title a service has on, as one of the viewer's sources holds it, and
/// where it stands on the service's charts.
struct StreamingTitle: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case movie, show }
    enum Chart: String, Codable, Sendable { case popular, latest }

    var item: MediaItem
    /// Its place on the popular chart, from 1, or nil when it is not on it.
    var popularRank: Int?
    /// Its place among what the service added, newest first.
    var latestRank: Int?
    /// The year the list gives, which a source's copy may not.
    var year: Int?

    var releaseYear: Int? { year ?? item.productionYear }
}

/// What one service has on that the viewer can play.
struct StreamingServiceTitles: Codable, Hashable, Sendable {
    var movies: [StreamingTitle] = []
    var shows: [StreamingTitle] = []

    var isEmpty: Bool { movies.isEmpty && shows.isEmpty }
    var count: Int { movies.count + shows.count }

    func titles(_ kind: StreamingTitle.Kind) -> [StreamingTitle] {
        kind == .movie ? movies : shows
    }

    /// Only what the connected sources still hold.
    func held(by sources: Set<UUID>) -> StreamingServiceTitles {
        let keep = { (title: StreamingTitle) -> Bool in title.item.serverID.map { sources.contains($0) } ?? false }
        return StreamingServiceTitles(movies: movies.filter(keep), shows: shows.filter(keep))
    }
}

/// The ways a service's films or shows can be ordered.
enum StreamingSort: String, CaseIterable, Identifiable, Codable, Sendable {
    case popular
    case latest
    case newest
    case title

    var id: String { rawValue }

    var label: String {
        switch self {
        case .popular: "Most Popular"
        case .latest: "Recently Added"
        case .newest: "Release Year"
        case .title: "A–Z"
        }
    }

    var symbol: String {
        switch self {
        case .popular: "flame"
        case .latest: "sparkles.tv"
        case .newest: "calendar"
        case .title: "textformat"
        }
    }

    /// The titles in this order. Each falls back on the other charts, so a
    /// title missing from one chart still has a sensible place.
    func sorted(_ titles: [StreamingTitle]) -> [StreamingTitle] {
        let byName = { (left: StreamingTitle, right: StreamingTitle) -> Bool in
            left.item.name.localizedStandardCompare(right.item.name) == .orderedAscending
        }
        let ascending = Self.ascending
        let descending = Self.descending
        return titles.sorted { left, right in
            switch self {
            case .popular:
                return ascending(left.popularRank, right.popularRank)
                    ?? ascending(left.latestRank, right.latestRank)
                    ?? byName(left, right)
            case .latest:
                return ascending(left.latestRank, right.latestRank)
                    ?? descending(left.releaseYear, right.releaseYear)
                    ?? ascending(left.popularRank, right.popularRank)
                    ?? byName(left, right)
            case .newest:
                return descending(left.releaseYear, right.releaseYear)
                    ?? ascending(left.popularRank, right.popularRank)
                    ?? ascending(left.latestRank, right.latestRank)
                    ?? byName(left, right)
            case .title:
                return byName(left, right)
            }
        }
    }
}

extension StreamingSort {
    /// Which of two places comes first, smallest first and a missing one
    /// last, or nil when they tie.
    fileprivate static func ascending(_ left: Int?, _ right: Int?) -> Bool? {
        switch (left, right) {
        case let (left?, right?): return left == right ? nil : left < right
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return nil
        }
    }

    /// The same, largest first.
    fileprivate static func descending(_ left: Int?, _ right: Int?) -> Bool? {
        switch (left, right) {
        case let (left?, right?): return left == right ? nil : left > right
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return nil
        }
    }
}

/// The row's own record of its last build, kept on the device.
struct StreamingServicesSnapshot: Codable, Sendable {
    var builtAt: Date
    /// The sources it was built from, so a server added or removed builds it
    /// again rather than waiting for tomorrow.
    var sources: [String]
    var services: [String: StreamingServiceTitles]
}

/// Turns the lists' entries into titles the viewer can play, and gathers
/// each service's.
enum StreamingCatalogBuilder {
    /// The key one entry is known by across lists: the same film on two
    /// services' charts is looked up once.
    static func key(of entry: MDBListCatalogItem) -> String {
        if let imdb = entry.imdbID.flatMap({ MediaTitleMatch.canonicalID("imdb", $0) }) { return entry.mediaType + "|" + imdb }
        if let tmdb = entry.tmdbID { return entry.mediaType + "|tmdb:" + tmdb }
        return entry.mediaType + "|" + MediaTitleMatch.normalized(entry.title) + "|"
            + (entry.releaseYear.map(String.init) ?? "")
    }

    /// The entries each list contributes, read only as deep as it is worth.
    static func entries(of list: [MDBListCatalogItem], chart: StreamingTitle.Chart,
                        kind: StreamingTitle.Kind) -> [MDBListCatalogItem] {
        let wanted = kind == .movie ? "movie" : "show"
        let depth = chart == .popular ? StreamingService.popularDepth : StreamingService.latestDepth
        return Array(list.filter { $0.mediaType == wanted }.prefix(depth))
    }

    /// One service's films or shows: the popular chart and the latest list
    /// merged, each title once, with its place on both.
    static func titles(popular: [MDBListCatalogItem], latest: [MDBListCatalogItem],
                       resolve: (MDBListCatalogItem) -> MediaItem?) -> [StreamingTitle] {
        var order: [String] = []
        var found: [String: StreamingTitle] = [:]
        func add(_ entries: [MDBListCatalogItem], chart: StreamingTitle.Chart) {
            for (index, entry) in entries.enumerated() {
                guard let item = resolve(entry) else { continue }
                let key = item.libraryKey
                var title = found[key] ?? StreamingTitle(item: item, year: entry.releaseYear)
                switch chart {
                case .popular: title.popularRank = title.popularRank ?? index + 1
                case .latest: title.latestRank = title.latestRank ?? index + 1
                }
                if found[key] == nil { order.append(key) }
                found[key] = title
            }
        }
        add(popular, chart: .popular)
        add(latest, chart: .latest)
        return order.compactMap { found[$0] }
    }

    /// A stand-in for an entry, for asking the IPTV provider's index, which
    /// looks titles up the way it looks up a server's.
    static func probe(for entry: MDBListCatalogItem) -> MediaItem {
        var ids: [String: String] = [:]
        if let tmdb = entry.tmdbID { ids["Tmdb"] = tmdb }
        if let imdb = entry.imdbID { ids["Imdb"] = imdb }
        return MediaItem(id: "", name: entry.title, type: entry.mediaType == "show" ? "Series" : "Movie",
                         overview: nil, productionYear: entry.releaseYear, primaryImageAspectRatio: nil,
                         childCount: nil, providerIDs: ids.isEmpty ? nil : ids)
    }
}
