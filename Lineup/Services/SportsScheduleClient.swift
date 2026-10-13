import Foundation

struct SportsScheduleClient: Sendable {
    struct Snapshot: Sendable {
        let games: [SportsLeague: [SportsGame]]
        let loadedLeagues: Set<SportsLeague>
        let errorMessage: String?
    }

    // `includeTomorrow` lets a frequent, light-weight caller (e.g. a live-score poll)
    // skip refetching the next day's slate, which rarely changes intraday. The
    // caller is responsible for preserving any previously-fetched tomorrow games.
    func gamesToday(includeTomorrow: Bool = true) async -> Snapshot {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        let today = formatter.string(from: Date())
        let tomorrowDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let tomorrow = formatter.string(from: tomorrowDate)
        // Tennis is one request a tour for both days rather than one a day:
        // the feed answers with whole tournaments either way.
        async let tennis = tennisSchedule(from: Calendar.current.startOfDay(for: Date()),
                                          days: includeTomorrow ? 2 : 1)
        guard includeTomorrow else { return Self.adding(await tennis, to: await snapshot(for: today)) }

        async let todaySnapshot = snapshot(for: today)
        async let tomorrowSnapshot = snapshot(for: tomorrow)
        let (first, second) = await (todaySnapshot, tomorrowSnapshot)
        var merged: [SportsLeague: [SportsGame]] = [:]
        for league in SportsLeague.allCases {
            let games = (first.games[league] ?? []) + (second.games[league] ?? [])
            merged[league] = Dictionary(grouping: games, by: \.id).values.compactMap { $0.first }.sorted { $0.start < $1.start }
        }
        let errors = [first.errorMessage, second.errorMessage].compactMap { $0 }
        return Self.adding(await tennis, to: Snapshot(
            games: merged,
            loadedLeagues: first.loadedLeagues.intersection(second.loadedLeagues),
            errorMessage: errors.isEmpty ? nil : Array(Set(errors)).sorted().joined(separator: " ")
        ))
    }

    /// The leagues with a feed of their own rather than a place in the
    /// combined schedule.
    private static let ownFeeds: Set<SportsLeague> = [.ufc, .atp, .wta]

    private static func adding(_ tennis: Result<[SportsGame], Error>, to snapshot: Snapshot) -> Snapshot {
        var games = snapshot.games
        var loaded = snapshot.loadedLeagues
        var errors = [snapshot.errorMessage].compactMap { $0 }
        switch tennis {
        case .success(let matches):
            games[.atp] = matches.filter { $0.league == .atp }
            games[.wta] = matches.filter { $0.league == .wta }
            loaded.formUnion([.atp, .wta])
        case .failure:
            errors.append("Tennis schedule unavailable.")
        }
        return Snapshot(games: games, loadedLeagues: loaded,
                        errorMessage: errors.isEmpty ? nil : errors.joined(separator: " "))
    }

    private func snapshot(for day: String) async -> Snapshot {
        // Fetched alongside the schedule, never instead of it: a game without
        // its rank is still the game.
        async let rankings = CollegeFootballRankings.shared.ranks(for: day)
        let base: Snapshot
        do { base = try await combinedSchedule(for: day) }
        catch { base = Snapshot(games: [:], loadedLeagues: [], errorMessage: Self.describe(error)) }

        var games = base.games
        let ranks = await rankings
        if let college = games[.ncaaf] {
            games[.ncaaf] = college.map { ranks.applied(to: $0) }
        }
        var loaded = base.loadedLeagues
        var errors = [base.errorMessage].compactMap { $0 }
        do {
            games[.ufc] = try await ufcSchedule(for: day)
            loaded.insert(.ufc)
        } catch {
            errors.append("UFC schedule unavailable.")
        }
        return Snapshot(games: games, loadedLeagues: loaded,
            errorMessage: errors.isEmpty ? nil : errors.joined(separator: " "))
    }

    private func combinedSchedule(for day: String) async throws -> Snapshot {
        guard let url = URL(string: "https://sports.mateomedia.link/v1/games?date=\(day)") else {
            throw ScheduleError.invalidURL
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        request.setValue("\(version) (\(build))", forHTTPHeaderField: "X-Lineup-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ScheduleError.noHTTPResponse }
        guard http.statusCode == 200 else { throw ScheduleError.httpStatus(http.statusCode) }
        guard !data.isEmpty else { throw ScheduleError.emptyResponse }
        let envelope = try JSONDecoder().decode(CombinedEnvelope.self, from: data)
        guard envelope.schema == 2, envelope.date == day else { throw ScheduleError.invalidSchema }

        var result: [SportsLeague: [SportsGame]] = [:]
        var failed = Set(envelope.failedLeagues.compactMap(SportsLeague.init(rawValue:))).subtracting(Self.ownFeeds)
        for league in SportsLeague.allCases where !Self.ownFeeds.contains(league) {
            guard let remoteGames = envelope.leagues[league.rawValue] else {
                failed.insert(league)
                continue
            }
            var games: [SportsGame] = remoteGames.compactMap { game -> SportsGame? in
                guard let start = Self.parseDate(game.start) else { return nil }
                return SportsGame(
                    id: "\(league.rawValue)-\(game.id)", league: league, start: start,
                    awayTeam: game.awayTeam, homeTeam: game.homeTeam,
                    awayAbbreviation: game.awayAbbreviation, homeAbbreviation: game.homeAbbreviation,
                    awayLogo: game.awayLogo ?? "", homeLogo: game.homeLogo ?? "",
                    awayScore: game.awayScore ?? "", homeScore: game.homeScore ?? "",
                    awayColor: game.awayColor, homeColor: game.homeColor,
                    awayRecord: game.awayRecord, homeRecord: game.homeRecord,
                    venue: game.venue, location: game.location,
                    status: game.status, state: game.state, broadcast: game.broadcast,
                    eventName: nil
                )
            }
            if league == .nfl, let redZone = NFLRedZoneSchedule.event(for: games) {
                games.append(redZone)
            }
            result[league] = games.sorted { $0.start < $1.start }
        }
        let loaded = Set(SportsLeague.allCases).subtracting(Self.ownFeeds).subtracting(failed)
        let errorMessage = failed.isEmpty ? nil : "Temporarily unavailable: \(failed.map(\.shortName).sorted().joined(separator: ", "))."
        return Snapshot(games: result, loadedLeagues: loaded, errorMessage: errorMessage)
    }

    /// UFC cards are events rather than team games, so the shared schedule
    /// service does not model them. ESPN's UFC scoreboard supplies every card
    /// type (numbered PPVs, Fight Nights, prelims and special events) and the
    /// main-event fighters fit Lineup's existing two-side presentation.
    private func ufcSchedule(for day: String) async throws -> [SportsGame] {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/mma/ufc/scoreboard?dates=\(day)") else {
            throw ScheduleError.invalidURL
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ScheduleError.noHTTPResponse }
        guard http.statusCode == 200 else { throw ScheduleError.httpStatus(http.statusCode) }
        let envelope = try JSONDecoder().decode(UFCEnvelope.self, from: data)
        return envelope.events.compactMap { event in
            guard let start = Self.parseDate(event.date) else { return nil }
            // ESPN orders cards from early prelims toward the headliner. Match
            // number 1 is the main event regardless of that array order.
            let competition = event.competitions.min {
                ($0.matchNumber ?? Int.max) < ($1.matchNumber ?? Int.max)
            }
            let ordered = (competition?.competitors ?? []).sorted {
                ($0.homeAway == "away" ? 0 : 1) < ($1.homeAway == "away" ? 0 : 1)
            }
            let namesFromTitle = Self.ufcNames(from: event.shortName ?? event.name)
            let away = ordered.first
            let home = ordered.dropFirst().first
            let awayName = away?.athlete?.displayName ?? namesFromTitle.0
            let homeName = home?.athlete?.displayName ?? namesFromTitle.1
            let status = competition?.status ?? event.status
            let broadcast = (competition?.broadcasts ?? []).flatMap(\.names)
                .filter { !$0.isEmpty }.joined(separator: " / ")
            let location = competition?.venue?.address.map {
                [$0.city, $0.state].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            }
            return SportsGame(
                id: "ufc-\(event.id)", league: .ufc, start: start,
                awayTeam: awayName, homeTeam: homeName,
                awayAbbreviation: Self.fighterAbbreviation(awayName),
                homeAbbreviation: Self.fighterAbbreviation(homeName),
                awayLogo: away?.athlete?.headshot?.href ?? "",
                homeLogo: home?.athlete?.headshot?.href ?? "",
                awayScore: away?.score ?? "", homeScore: home?.score ?? "",
                awayColor: nil, homeColor: nil,
                awayRecord: away?.records?.first?.summary, homeRecord: home?.records?.first?.summary,
                venue: competition?.venue?.fullName, location: location,
                status: status?.type.shortDetail ?? status?.type.description ?? event.name,
                state: status?.type.state ?? "pre", broadcast: broadcast,
                eventName: event.name
            )
        }.sorted { $0.start < $1.start }
    }

    /// Both tours' singles, from ESPN's tennis scoreboards.
    ///
    /// A scoreboard answers with whole tournaments -- every match of the
    /// fortnight, played or not -- so the days asked for are cut out here.
    /// Kept: main-draw singles whose players are known and whose time is
    /// real. Qualifying, doubles, and the "TBD vs TBD" rounds still to be
    /// drawn are left out; nobody looks for those on a sports channel.
    private func tennisSchedule(from day: Date, days: Int) async -> Result<[SportsGame], Error> {
        let calendar = Calendar.current
        let end = calendar.date(byAdding: .day, value: days, to: day) ?? day.addingTimeInterval(Double(days) * 86_400)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        // One day a request: ESPN answers a range of dates with nothing at
        // all. Each day still brings its tournaments whole, so tomorrow is
        // asked for only to catch an event that has not begun yet.
        let dates = (0..<max(days, 1)).compactMap { calendar.date(byAdding: .day, value: $0, to: day) }
            .map { formatter.string(from: $0) }
        do {
            // All or nothing: a schedule with a tour missing would replace a
            // complete one, and the next refresh is thirty seconds away.
            let events = try await withThrowingTaskGroup(
                of: [(tour: SportsLeague, event: TennisEnvelope.Event)].self
            ) { group in
                for tour in [SportsLeague.atp, .wta] {
                    for date in dates {
                        group.addTask { try await tennisTour(tour, date: date) }
                    }
                }
                var all: [(tour: SportsLeague, event: TennisEnvelope.Event)] = []
                for try await batch in group { all += batch }
                return all
            }
            let matches = events.flatMap { Self.tennisMatches(in: $0.event, tour: $0.tour, from: day, to: end) }
            return .success(Dictionary(grouping: matches, by: \.id).values.compactMap(\.first)
                .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start })
        } catch {
            return .failure(error)
        }
    }

    private func tennisTour(_ tour: SportsLeague, date: String) async throws -> [(tour: SportsLeague, event: TennisEnvelope.Event)] {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/tennis/\(tour.rawValue)/scoreboard?dates=\(date)") else {
            throw ScheduleError.invalidURL
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ScheduleError.noHTTPResponse }
        guard http.statusCode == 200 else { throw ScheduleError.httpStatus(http.statusCode) }
        return try JSONDecoder().decode(TennisEnvelope.self, from: data).events.map { (tour: tour, event: $0) }
    }

    /// A major is on both tours' scoreboards with both draws in it, so a
    /// match's tour is read from its draw; the feed it came in on settles
    /// only a draw that does not say.
    static func tennisMatches(in event: TennisEnvelope.Event, tour: SportsLeague,
                              from start: Date, to end: Date) -> [SportsGame] {
        let tournament = event.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups: [(slug: String?, competitions: [TennisEnvelope.Competition])] =
            event.groupings.map { ($0.grouping?.slug, $0.competitions) } + [(nil, event.competitions)]
        return groups.flatMap { group in
            group.competitions.compactMap { match -> SportsGame? in
                let kind = (match.type?.slug ?? group.slug ?? "").lowercased()
                guard kind.contains("singles") else { return nil }
                // "womens-singles" holds "mens-singles", so women first.
                let league: SportsLeague = kind.contains("women") ? .wta : (kind.contains("men") ? .atp : tour)
                let round = match.round?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !round.lowercased().contains("qualif") else { return nil }
                let state = match.status?.type.state ?? "pre"
                // A time ESPN marks as unknown is only the day: "12:00 AM".
                guard state != "pre" || match.timeValid != false,
                      let date = Self.parseDate(match.date) else { return nil }
                guard state == "in" || (date >= start && date < end) else { return nil }
                let players = match.competitors.sorted { ($0.order ?? 9) < ($1.order ?? 9) }
                guard players.count == 2,
                      let first = players[0].athlete, let second = players[1].athlete,
                      Self.isKnown(first.displayName), Self.isKnown(second.displayName) else { return nil }
                let score = Self.tennisScore(players[0], players[1],
                                             bestOf: match.format?.regulation?.periods ?? 3)
                let status = Self.tennisStatus(state: state, detail: match.status?.type, score: score)
                let court = match.venue?.court?.trimmingCharacters(in: .whitespacesAndNewlines)
                var networks: [String] = []
                for name in match.broadcasts.flatMap(\.names) where !name.isEmpty && !networks.contains(name) {
                    networks.append(name)
                }
                return SportsGame(
                    // ESPN numbers a match once across both tours, and a
                    // major is on both scoreboards: the id alone keeps it once.
                    id: "tennis-\(match.id)", league: league, start: date,
                    awayTeam: first.displayName, homeTeam: second.displayName,
                    awayAbbreviation: Self.surname(first), homeAbbreviation: Self.surname(second),
                    awayLogo: first.flag?.href ?? "", homeLogo: second.flag?.href ?? "",
                    awayScore: state == "pre" ? "" : String(score.awaySets),
                    homeScore: state == "pre" ? "" : String(score.homeSets),
                    awayColor: nil, homeColor: nil,
                    awayRecord: first.flag?.alt, homeRecord: second.flag?.alt,
                    venue: [tournament, round].filter { !$0.isEmpty }.joined(separator: " \u{00B7} "),
                    location: court?.isEmpty == false ? court : nil,
                    status: status, state: state,
                    broadcast: networks.joined(separator: ", "),
                    eventName: nil,
                    awayRank: players[0].curatedRank?.current, homeRank: players[1].curatedRank?.current,
                    tennis: score.sets.isEmpty ? nil : score
                )
            }
        }
    }

    private static func isKnown(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.uppercased() != "TBD" && name.uppercased() != "BYE"
    }

    /// "J. Sinner" to "SINNER", "A. de Minaur" to "DE MINAUR".
    private static func surname(_ athlete: TennisEnvelope.Athlete) -> String {
        if let short = athlete.shortName, let space = short.firstIndex(of: " "),
           short[..<space].hasSuffix(".") {
            return short[short.index(after: space)...].uppercased()
        }
        return (athlete.displayName.split(separator: " ").last.map(String.init) ?? athlete.displayName).uppercased()
    }

    private static func tennisScore(_ first: TennisEnvelope.Competitor, _ second: TennisEnvelope.Competitor,
                                    bestOf: Int) -> TennisScore {
        let firstLines = first.linescores ?? [], secondLines = second.linescores ?? []
        let sets = zip(firstLines, secondLines).map { away, home in
            let awayGames = Int(away.value ?? 0), homeGames = Int(home.value ?? 0)
            // ESPN marks a set's winner once it is over; the set in play has
            // neither side marked. The mark can trail the score by a refresh
            // or two, so a set the games have already settled -- six with a
            // two-game lead, or seven -- counts as over.
            let awayWon: Bool? = away.winner == true ? true
                : (home.winner == true ? false : Self.settled(awayGames, homeGames))
            return TennisScore.SetGames(away: awayGames, home: homeGames,
                                        awayTiebreak: away.tiebreak.map { Int($0) },
                                        homeTiebreak: home.tiebreak.map { Int($0) },
                                        awayWon: awayWon)
        }
        return TennisScore(sets: sets, bestOf: bestOf == 5 ? 5 : 3)
    }

    /// Who has taken a set on its games alone, or nil while it is open.
    static func settled(_ away: Int, _ home: Int) -> Bool? {
        if away == 7 || (away >= 6 && away - home >= 2) { return true }
        if home == 7 || (home >= 6 && home - away >= 2) { return false }
        return nil
    }

    /// "Set 3 · 4-3" while it is played; "Final · 6-4 7-6(5)" after, or
    /// the feed's own word for a match that ended early.
    private static func tennisStatus(state: String, detail: TennisEnvelope.StatusType?, score: TennisScore) -> String {
        switch state {
        case "in":
            guard let current = score.current else {
                return score.sets.isEmpty ? (detail?.description ?? "In Progress") : "Between sets"
            }
            return "Set \(score.sets.count) \u{00B7} \(current.away)-\(current.home)"
        case "post":
            let word = detail?.shortDetail ?? detail?.description ?? "Final"
            return score.sets.isEmpty ? word : "\(word) \u{00B7} \(score.line)"
        default:
            return detail?.shortDetail ?? detail?.description ?? ""
        }
    }

    private static func ufcNames(from title: String) -> (String, String) {
        let card = title.split(separator: ":", maxSplits: 1).last.map(String.init) ?? title
        for separator in [" vs. ", " vs ", " v. ", " at "] {
            let names = card.components(separatedBy: separator)
            if names.count == 2 { return (names[0], names[1]) }
        }
        return (title, "UFC")
    }

    private static func fighterAbbreviation(_ name: String) -> String {
        let parts = name.split(separator: " ")
        guard let last = parts.last else { return "UFC" }
        return String(last.prefix(4)).uppercased()
    }

    private static func describe(_ error: Error) -> String {
        if let decoding = error as? DecodingError {
            switch decoding {
            case .keyNotFound(let key, let context): return "Schedule data is missing \(key.stringValue) at \(path(context.codingPath))."
            case .typeMismatch(_, let context): return "Schedule data has the wrong type at \(path(context.codingPath))."
            case .valueNotFound(_, let context): return "Schedule data is empty at \(path(context.codingPath))."
            case .dataCorrupted(let context): return "Schedule data is invalid at \(path(context.codingPath))."
            @unknown default: return "Schedule data could not be read."
            }
        }
        return error.localizedDescription
    }

    // Built once rather than per game. This is the same trap the guide parser
    // had, at a smaller scale: every kick-off time built an ISO8601 formatter
    // and up to three DateFormatters, and building one costs more than using
    // it. Four constructions per game, discarded immediately, across every
    // game in every league on every schedule refresh.
    private static let internetDate = ISO8601DateFormatter()
    private static let fallbackDates: [DateFormatter] = [
        "yyyy-MM-dd'T'HH:mmXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    private static func parseDate(_ value: String) -> Date? {
        if let date = internetDate.date(from: value) { return date }
        for formatter in fallbackDates {
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private static func path(_ codingPath: [CodingKey]) -> String {
        let value = codingPath.map(\.stringValue).joined(separator: ".")
        return value.isEmpty ? "the response" : value
    }
}

private enum ScheduleError: LocalizedError {
    case invalidURL, noHTTPResponse, httpStatus(Int), emptyResponse, invalidSchema, missingLeague(String)
    var errorDescription: String? {
        switch self {
        case .invalidURL: "The schedule address is invalid."
        case .noHTTPResponse: "The schedule server did not return an HTTP response."
        case .httpStatus(let status): "The schedule server returned HTTP \(status)."
        case .emptyResponse: "The schedule server returned an empty response."
        case .invalidSchema: "The schedule server returned an unsupported response."
        case .missingLeague(let league): "The schedule response is missing \(league)."
        }
    }
}

private struct CombinedEnvelope: Decodable {
    let schema: Int
    let date: String
    let leagues: [String: [Game]]
    let failedLeagues: [String]

    enum CodingKeys: String, CodingKey { case schema, date, leagues, failedLeagues }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decode(Int.self, forKey: .schema)
        date = try values.decode(String.self, forKey: .date)
        leagues = try values.decode([String: [Game]].self, forKey: .leagues)
        failedLeagues = try values.decodeIfPresent([String].self, forKey: .failedLeagues) ?? []
    }

    struct Game: Decodable {
        let id: String
        let start: String
        let awayTeam: String
        let homeTeam: String
        let awayAbbreviation: String
        let homeAbbreviation: String
        let awayLogo: String?
        let homeLogo: String?
        let awayScore: String?
        let homeScore: String?
        let awayColor: String?
        let homeColor: String?
        let awayRecord: String?
        let homeRecord: String?
        let venue: String?
        let location: String?
        let status: String
        let state: String
        let broadcast: String
    }
}

private struct UFCEnvelope: Decodable {
    let events: [Event]

    struct Event: Decodable {
        let id: String
        let name: String
        let shortName: String?
        let date: String
        let status: Status?
        let competitions: [Competition]
    }

    struct Competition: Decodable {
        let competitors: [Competitor]
        let status: Status?
        let broadcasts: [Broadcast]
        let venue: Venue?
        let matchNumber: Int?

        enum CodingKeys: String, CodingKey { case competitors, status, broadcasts, venue, matchNumber }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            competitors = try values.decodeIfPresent([Competitor].self, forKey: .competitors) ?? []
            status = try values.decodeIfPresent(Status.self, forKey: .status)
            broadcasts = try values.decodeIfPresent([Broadcast].self, forKey: .broadcasts) ?? []
            venue = try values.decodeIfPresent(Venue.self, forKey: .venue)
            matchNumber = try values.decodeIfPresent(Int.self, forKey: .matchNumber)
        }
    }

    struct Competitor: Decodable {
        let homeAway: String?
        let athlete: Athlete?
        let score: String?
        let records: [Record]?
    }

    struct Athlete: Decodable {
        let displayName: String
        let headshot: Headshot?
    }

    struct Headshot: Decodable { let href: String? }
    struct Record: Decodable { let summary: String? }
    struct Broadcast: Decodable { let names: [String] }
    struct Status: Decodable { let type: StatusType }
    struct StatusType: Decodable {
        let state: String
        let description: String?
        let shortDetail: String?
    }
    struct Venue: Decodable {
        let fullName: String?
        let address: Address?
    }
    struct Address: Decodable {
        let city: String?
        let state: String?
    }
}

/// ESPN's tennis scoreboard. Read leniently: a field it leaves out costs that
/// match its detail, never the tournament.
struct TennisEnvelope: Decodable {
    let events: [Event]

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        events = (try? values.decodeIfPresent([Lenient<Event>].self, forKey: .events))?.compactMap(\.value) ?? []
    }

    enum CodingKeys: String, CodingKey { case events }

    struct Event: Decodable {
        let name: String
        let groupings: [Grouping]
        /// Some tournaments list matches here rather than by draw.
        let competitions: [Competition]

        enum CodingKeys: String, CodingKey { case name, groupings, competitions }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            name = (try? values.decodeIfPresent(String.self, forKey: .name)) ?? ""
            groupings = (try? values.decodeIfPresent([Lenient<Grouping>].self, forKey: .groupings))?
                .compactMap(\.value) ?? []
            competitions = (try? values.decodeIfPresent([Lenient<Competition>].self, forKey: .competitions))?
                .compactMap(\.value) ?? []
        }
    }

    struct Grouping: Decodable {
        let grouping: Draw?
        let competitions: [Competition]

        enum CodingKeys: String, CodingKey { case grouping, competitions }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            grouping = try? values.decodeIfPresent(Draw.self, forKey: .grouping)
            competitions = (try? values.decodeIfPresent([Lenient<Competition>].self, forKey: .competitions))?
                .compactMap(\.value) ?? []
        }
    }

    struct Draw: Decodable { let slug: String? }

    struct Competition: Decodable {
        let id: String
        let date: String
        let timeValid: Bool?
        let type: Draw?
        let round: Round?
        let venue: Venue?
        let status: Status?
        let format: Format?
        let broadcasts: [Broadcast]
        let competitors: [Competitor]

        enum CodingKeys: String, CodingKey {
            case id, date, timeValid, type, round, venue, status, format, broadcasts, competitors
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if let text = try? values.decode(String.self, forKey: .id) { id = text }
            else { id = String(try values.decode(Int.self, forKey: .id)) }
            date = try values.decode(String.self, forKey: .date)
            timeValid = try? values.decodeIfPresent(Bool.self, forKey: .timeValid)
            type = try? values.decodeIfPresent(Draw.self, forKey: .type)
            round = try? values.decodeIfPresent(Round.self, forKey: .round)
            venue = try? values.decodeIfPresent(Venue.self, forKey: .venue)
            status = try? values.decodeIfPresent(Status.self, forKey: .status)
            format = try? values.decodeIfPresent(Format.self, forKey: .format)
            broadcasts = (try? values.decodeIfPresent([Lenient<Broadcast>].self, forKey: .broadcasts))?
                .compactMap(\.value) ?? []
            competitors = (try? values.decodeIfPresent([Lenient<Competitor>].self, forKey: .competitors))?
                .compactMap(\.value) ?? []
        }
    }

    struct Round: Decodable { let displayName: String? }
    struct Venue: Decodable { let court: String? }
    struct Status: Decodable { let type: StatusType }
    struct StatusType: Decodable {
        let state: String
        let description: String?
        let shortDetail: String?
    }
    struct Format: Decodable { let regulation: Regulation? }
    struct Regulation: Decodable { let periods: Int? }
    struct Broadcast: Decodable {
        let names: [String]
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            names = (try? values.decodeIfPresent([String].self, forKey: .names)) ?? []
        }
        enum CodingKeys: String, CodingKey { case names }
    }

    struct Competitor: Decodable {
        let order: Int?
        let athlete: Athlete?
        let linescores: [LineScore]?
        let curatedRank: Rank?

        enum CodingKeys: String, CodingKey { case order, athlete, linescores, curatedRank }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            order = try? values.decodeIfPresent(Int.self, forKey: .order)
            athlete = try? values.decodeIfPresent(Athlete.self, forKey: .athlete)
            linescores = (try? values.decodeIfPresent([Lenient<LineScore>].self, forKey: .linescores))?
                .compactMap(\.value)
            curatedRank = try? values.decodeIfPresent(Rank.self, forKey: .curatedRank)
        }
    }

    struct Athlete: Decodable {
        let displayName: String
        let shortName: String?
        let flag: Flag?
    }
    struct Flag: Decodable {
        let href: String?
        let alt: String?
    }
    struct Rank: Decodable {
        let current: Int?
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            // ESPN writes 99 for "unseeded" in some feeds.
            let value = try? values.decodeIfPresent(Int.self, forKey: .current)
            current = value.flatMap { (1...64).contains($0) ? $0 : nil }
        }
        enum CodingKeys: String, CodingKey { case current }
    }
    struct LineScore: Decodable {
        let value: Double?
        let tiebreak: Double?
        let winner: Bool?
    }
}

