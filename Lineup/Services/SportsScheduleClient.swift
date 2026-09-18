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
        guard includeTomorrow else { return await snapshot(for: today) }
        let tomorrowDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let tomorrow = formatter.string(from: tomorrowDate)

        async let todaySnapshot = snapshot(for: today)
        async let tomorrowSnapshot = snapshot(for: tomorrow)
        let (first, second) = await (todaySnapshot, tomorrowSnapshot)
        var merged: [SportsLeague: [SportsGame]] = [:]
        for league in SportsLeague.allCases {
            let games = (first.games[league] ?? []) + (second.games[league] ?? [])
            merged[league] = Dictionary(grouping: games, by: \.id).values.compactMap { $0.first }.sorted { $0.start < $1.start }
        }
        let errors = [first.errorMessage, second.errorMessage].compactMap { $0 }
        return Snapshot(
            games: merged,
            loadedLeagues: first.loadedLeagues.intersection(second.loadedLeagues),
            errorMessage: errors.isEmpty ? nil : Array(Set(errors)).sorted().joined(separator: " ")
        )
    }

    private func snapshot(for day: String) async -> Snapshot {
        let base: Snapshot
        do { base = try await combinedSchedule(for: day) }
        catch { base = Snapshot(games: [:], loadedLeagues: [], errorMessage: Self.describe(error)) }

        var games = base.games
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
        var failed = Set(envelope.failedLeagues.compactMap(SportsLeague.init(rawValue:)))
        for league in SportsLeague.allCases where league != .ufc {
            guard let remoteGames = envelope.leagues[league.rawValue] else {
                failed.insert(league)
                continue
            }
            result[league] = remoteGames.compactMap { game in
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
            }.sorted { $0.start < $1.start }
        }
        let loaded = Set(SportsLeague.allCases.filter { $0 != .ufc }).subtracting(failed)
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
