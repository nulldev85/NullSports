import Foundation

// What Silo's own app offers beyond a library's pages, read from the same
// server: its Home rows, For You, the viewer's Watchlist, Favorites and
// History, the Calendar, a title's box set, trailers and cast, the people in
// it, and the titles Silo finds like it. Only Silo has these; the Library
// shows them when the server it is showing is Silo.

/// A Home card that can be taken off Continue Watching or Next Up, and what
/// Silo needs to know which one: the progress it stands for, or its show.
struct SiloDismissal: Hashable, Codable, Sendable {
    enum Surface: String, Codable, Sendable { case continueWatching = "continue_watching", nextUp = "next_up" }
    let surface: Surface
    let progressUpdatedAt: String?
    let seriesID: String?
}

/// Silo's Home: its rows, and which of their cards can be taken off them.
struct SiloHome: Codable, Sendable {
    var rows: [ServerLibraryRow] = []
    var badges: [String: ServerLibraryBadges] = [:]
    /// By row id, then by title id.
    var dismissals: [String: [String: SiloDismissal]] = [:]
}

/// One day of Silo's Calendar.
struct SiloCalendarDay: Identifiable, Sendable, Equatable {
    let date: String
    let events: [SiloCalendarEvent]
    var id: String { date }
}

/// An episode airing, a season starting or a film coming out.
struct SiloCalendarEvent: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let kind: String
    let season: Int?
    let episode: Int?
    let episodeTitle: String?
    let seriesID: String?
    let posterURL: URL?
    let airsAt: Date?
    /// "Series Premiere", "Season Premiere", "Finale".
    let badges: [String]
    let watched: Bool

    /// "S2 · E5", or nothing for a film.
    var episodeCode: String? {
        guard let season, let episode else { return season.map { "Season \($0)" } }
        return "S\(season) · E\(episode)"
    }
}

/// A film's box set: the films of its series the viewer has, in order.
struct SiloBoxSet: Sendable, Equatable {
    let id: String
    let libraryID: String?
    let title: String
    let overview: String?
    let posterURL: URL?
    let years: String?
    let items: [MediaItem]
}

/// What a title's page adds from Silo: whether it is on the Watchlist, its
/// trailers, who is in it, and its box set.
struct SiloTitleExtras: Sendable, Equatable {
    var inWatchlist = false
    var trailers: [MediaTrailer] = []
    /// Silo's own ids for the people in it, by name, for their pages.
    var people: [String: String] = [:]
    var boxSet: SiloBoxSet?
}

/// Someone in a title, as Silo knows them, with what else of theirs the
/// server has.
struct SiloPerson: Sendable, Equatable {
    let id: String
    let name: String
    let bio: String?
    let born: String?
    let died: String?
    let birthplace: String?
    let photoURL: URL?
    let titles: [MediaItem]
}

/// A row of For You.
struct SiloForYou: Sendable {
    var rows: [ServerLibraryRow] = []
    var badges: [String: ServerLibraryBadges] = [:]
}

/// The viewer's own lists on Silo.
enum SiloPersonalList: String, CaseIterable, Identifiable, Sendable {
    case watchlist, favorites, history
    var id: String { rawValue }
    var title: String {
        switch self {
        case .watchlist: "Watchlist"
        case .favorites: "Favorites"
        case .history: "History"
        }
    }
}

private struct SiloHomeSection: Decodable, Sendable {
    let id: String
    let title: String
    let section_type: String?
    let items: [SiloTitle]?
    let total_count: Int?
}
private struct SiloHomeSections: Decodable, Sendable { let sections: [SiloHomeSection] }
private struct SiloRecommendationRows: Decodable, Sendable {
    struct Row: Decodable, Sendable {
        let title: String
        let type: String?
        let kind: String?
        let key: String?
        let items: [SiloTitle]?
    }
    let items: [Row]
}
private struct SiloLettersAnswer: Decodable, Sendable {
    struct Letter: Decodable, Sendable { let letter: String; let position: Int; let count: Int }
    let letters: [Letter]
    let total: Int?
}
private struct SiloCalendarAnswer: Decodable, Sendable {
    struct Day: Decodable, Sendable { let date: String; let items: [Event]? }
    struct Event: Decodable, Sendable {
        let content_id: String
        let title: String
        let type: String?
        let season_number: Int?
        let episode_number: Int?
        let episode_title: String?
        let series_id: String?
        let poster_url: String?
        let air_at: String?
        let badges: [String]?
        let watched: Bool?
    }
    let events: [Day]
}
private struct SiloTitleDetail: Decodable, Sendable {
    struct State: Decodable, Sendable { let in_watchlist: Bool? }
    struct Video: Decodable, Sendable { let name: String?; let site: String?; let site_key: String?; let type: String? }
    struct Credit: Decodable, Sendable { let name: String?; let person_id: String? }
    let user_state: State?
    let videos: [Video]?
    let cast: [Credit]?
    let crew: [Credit]?
}
private struct SiloBoxSetAnswer: Decodable, Sendable {
    struct BoxSet: Decodable, Sendable {
        let id: String
        let library_id: String?
        let title: String
        let overview: String?
        let poster_url: String?
        let first_year: Int?
        let last_year: Int?
        let items: [SiloTitle]?
    }
    let box_set: BoxSet?
}
private struct SiloPersonAnswer: Decodable, Sendable {
    let id: String
    let name: String
    let bio: String?
    let birth_date: String?
    let death_date: String?
    let birthplace: String?
    let photo_url: String?
}

extension SiloClient: ServerLibraryJumping {
    private static let artwork: [URLQueryItem] = [.init(name: "poster_width", value: "500")]

    // MARK: Home

    /// Silo's Home rows for the profile in use, with Continue Watching and
    /// Next Up cards marked as ones that can be taken off.
    func siloHome() async throws -> SiloHome {
        let answer: SiloHomeSections = try await transport.get(["home", "sections"],
            query: Self.artwork + [.init(name: "item_limit", value: String(ServerLibraryQuery.rowSize))])
        var home = SiloHome()
        for section in answer.sections {
            let titles = section.items ?? []
            guard !titles.isEmpty else { continue }
            let type = section.section_type?.lowercased() ?? ""
            let removable = ["continue_watching", "in_progress", "next_up"].contains(type)
            var dismissals: [String: SiloDismissal] = [:]
            for title in titles {
                if let badges = title.badges { home.badges[title.content_id] = badges }
                guard removable else { continue }
                if let stamp = title.progress_updated_at, !stamp.isEmpty {
                    dismissals[title.content_id] = SiloDismissal(surface: .continueWatching,
                                                                 progressUpdatedAt: stamp, seriesID: nil)
                } else if let series = title.series_id, !series.isEmpty {
                    dismissals[title.content_id] = SiloDismissal(surface: .nextUp, progressUpdatedAt: nil,
                                                                 seriesID: series)
                }
            }
            if !dismissals.isEmpty { home.dismissals[section.id] = dismissals }
            home.rows.append(ServerLibraryRow(id: section.id, title: section.title,
                                              items: titles.map { $0.media(http: http) },
                                              source: .section(section.id), total: section.total_count))
        }
        return home
    }

    /// A Home row in full, for its own page.
    func siloHomeRow(_ row: ServerLibraryRow, cursor: String?) async throws -> ServerLibraryPage {
        guard case .section(let id) = row.source else { return ServerLibraryPage(items: row.items) }
        return try await page([.init(name: "source", value: "section"), .init(name: "scope", value: "home"),
                               .init(name: "section_id", value: id)], cursor: cursor)
    }

    /// Takes a card off Continue Watching or Next Up. For a show, Silo
    /// takes the whole show off both until it is watched again.
    func siloDismiss(itemID: String, _ dismissal: SiloDismissal) async throws {
        var body: [String: Any] = [:]
        if let stamp = dismissal.progressUpdatedAt { body["progress_updated_at"] = stamp }
        if let series = dismissal.seriesID { body["series_id"] = series }
        try await transport.mutate(["home", "dismissals", dismissal.surface.rawValue, itemID], method: "PUT", body: body)
    }

    // MARK: For You

    /// Silo's recommendation rows for the profile in use.
    func siloForYou() async throws -> SiloForYou {
        let answer: SiloRecommendationRows = try await transport.get(["recommendations", "discover"], query: Self.artwork)
        var found = SiloForYou()
        for (index, row) in answer.items.enumerated() {
            let titles = row.items ?? []
            guard !titles.isEmpty else { continue }
            for title in titles { if let badges = title.badges { found.badges[title.content_id] = badges } }
            let id = [row.kind, row.key, row.type].compactMap { $0 }.joined(separator: ":")
            found.rows.append(ServerLibraryRow(id: id.isEmpty ? "row-\(index)" : id + "-\(index)", title: row.title,
                                               items: titles.map { $0.media(http: http) }))
        }
        return found
    }

    // MARK: The viewer's lists

    func siloList(_ list: SiloPersonalList, cursor: String?) async throws -> ServerLibraryPage {
        switch list {
        case .watchlist, .favorites:
            var query = Self.artwork + [.init(name: "limit", value: String(ServerLibraryQuery.pageSize))]
            if let cursor { query.append(.init(name: "cursor", value: cursor)) }
            let answer: SiloPage<SiloTitle> = try await transport.get([list.rawValue], query: query)
            var page = ServerLibraryPage(items: answer.items.map { $0.media(http: http) }, total: answer.total)
            for title in answer.items { if let badges = title.badges { page.badges[title.content_id] = badges } }
            if answer.page?.has_more == true, let next = answer.page?.next_cursor, !next.isEmpty, next != cursor {
                page.next = next
            }
            return page
        case .history:
            return try await page([.init(name: "source", value: "history")], cursor: cursor)
        }
    }

    func siloSetWatchlist(itemID: String, on: Bool) async throws {
        try await transport.mutate(["watchlist", itemID], method: on ? "PUT" : "DELETE")
    }

    // MARK: A–Z

    /// Where each letter starts in a library's titles in title order.
    func serverLibraryLetters(library: MediaItem, browse: ServerLibraryBrowse) async throws -> ServerLibraryLetters {
        guard let id = Self.libraryID(library), browse.jumpsByLetter else { return ServerLibraryLetters() }
        let body: [String: Any] = ["library_id": id, "type": browse.kind.itemType?.lowercased() ?? "video",
                                   "match": "all", "groups": [Any](), "order": browse.descending ? "desc" : "asc"]
        let answer: SiloLettersAnswer = try await transport.get(["catalog", "letters"], method: "POST", body: body)
        return ServerLibraryLetters(
            letters: answer.letters.map { .init(letter: $0.letter, position: $0.position, count: $0.count) },
            total: answer.total ?? answer.letters.reduce(0) { $0 + $1.count })
    }

    /// A page of a library's titles in title order, from `position`.
    func serverLibraryTitles(library: MediaItem, browse: ServerLibraryBrowse,
                             from position: Int) async throws -> ServerLibraryPage {
        guard let id = Self.libraryID(library) else { return ServerLibraryPage() }
        return try await page([.init(name: "library_id", value: id),
                               .init(name: "type", value: browse.kind.itemType?.lowercased() ?? "video"),
                               .init(name: "sort", value: (browse.descending ? "-" : "") + "title"),
                               .init(name: "seek", value: String(max(0, position)))], cursor: nil)
    }

    // MARK: Calendar

    /// What airs or comes out from `start` for `days` days, in the viewer's
    /// time zone.
    func siloCalendar(from start: Date, days: Int, timeZone: TimeZone = .current) async throws -> [SiloCalendarDay] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let end = calendar.date(byAdding: .day, value: max(0, min(30, days - 1)), to: start) ?? start
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = timeZone
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        let answer: SiloCalendarAnswer = try await transport.get(["calendar"], query: [
            .init(name: "start", value: format.string(from: start)), .init(name: "end", value: format.string(from: end)),
            .init(name: "timezone", value: timeZone.identifier)])
        let instant = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return answer.events.map { day in
            SiloCalendarDay(date: day.date, events: (day.items ?? []).map { event in
                SiloCalendarEvent(id: event.content_id, title: event.title, kind: event.type ?? "",
                                  season: event.season_number, episode: event.episode_number,
                                  episodeTitle: event.episode_title, seriesID: event.series_id,
                                  posterURL: http.resolvedURL(event.poster_url),
                                  airsAt: event.air_at.flatMap { fractional.date(from: $0) ?? instant.date(from: $0) },
                                  badges: (event.badges ?? []).map(Self.badgeName),
                                  watched: event.watched ?? false)
            })
        }
    }

    private static func badgeName(_ badge: String) -> String {
        badge.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    // MARK: A title's page

    /// What Silo adds to a title's page. A box set is looked for on films.
    func siloTitleExtras(itemID: String, isMovie: Bool) async throws -> SiloTitleExtras {
        let detail: SiloTitleDetail = try await transport.get(["catalog", "items", itemID])
        var extras = SiloTitleExtras(inWatchlist: detail.user_state?.in_watchlist ?? false)
        var seen: Set<String> = []
        extras.trailers = (detail.videos ?? []).compactMap { video in
            guard video.site?.lowercased() == "youtube", let key = video.site_key,
                  key.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil,
                  seen.insert(key).inserted else { return nil }
            return MediaTrailer(name: video.name ?? video.type ?? "Trailer",
                                url: "https://www.youtube.com/watch?v=" + key)
        }
        for credit in (detail.cast ?? []) + (detail.crew ?? []) {
            guard let name = credit.name, let id = credit.person_id, !id.isEmpty else { continue }
            if extras.people[name] == nil { extras.people[name] = id }
        }
        if isMovie {
            extras.boxSet = try? await siloBoxSet(itemID: itemID)
        }
        return extras
    }

    private func siloBoxSet(itemID: String) async throws -> SiloBoxSet? {
        let answer: SiloBoxSetAnswer = try await transport.get(["catalog", "items", itemID, "box-set"], query: Self.artwork)
        guard let set = answer.box_set, let titles = set.items, titles.count > 1 else { return nil }
        let years: String? = switch (set.first_year, set.last_year) {
        case let (first?, last?) where first != last: "\(first)–\(last)"
        case let (first?, _): String(first)
        default: nil
        }
        return SiloBoxSet(id: set.id, libraryID: set.library_id, title: set.title, overview: set.overview,
                          posterURL: http.resolvedURL(set.poster_url), years: years,
                          items: titles.map { $0.media(http: http, forcedType: "Movie") })
    }

    /// Titles Silo finds like this one, from what is on the server.
    func siloSimilar(itemID: String) async throws -> [MediaItem] {
        let answer: SiloPage<SiloTitle> = try await transport.get(["recommendations", "similar", itemID],
            query: Self.artwork + [.init(name: "limit", value: "20")])
        return answer.items.filter { $0.content_id != itemID }.map { $0.media(http: http) }
    }

    /// Someone in a title, and what else of theirs is on the server.
    func siloPerson(id: String) async throws -> SiloPerson {
        async let person: SiloPersonAnswer = transport.get(["catalog", "people", id])
        async let titles = page([.init(name: "source", value: "person"), .init(name: "person_id", value: id),
                                 .init(name: "type", value: "video")], cursor: nil)
        let (found, credits) = try await (person, titles)
        return SiloPerson(id: found.id, name: found.name, bio: found.bio, born: found.birth_date,
                          died: found.death_date, birthplace: found.birthplace,
                          photoURL: http.resolvedURL(found.photo_url),
                          titles: credits.items.filter { $0.type == "Movie" || $0.type == "Series" })
    }
}
