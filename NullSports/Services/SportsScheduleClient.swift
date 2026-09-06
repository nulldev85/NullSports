import Foundation

struct SportsScheduleClient: Sendable {
    struct Snapshot: Sendable {
        let games: [SportsLeague: [SportsGame]]
        let loadedLeagues: Set<SportsLeague>
        let errorMessage: String?
    }

    func gamesToday() async -> Snapshot {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        let today = formatter.string(from: Date())
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
        do { return try await combinedSchedule(for: day) }
        catch { return Snapshot(games: [:], loadedLeagues: [], errorMessage: Self.describe(error)) }
    }

    private func combinedSchedule(for day: String) async throws -> Snapshot {
        guard let url = URL(string: "https://sports.mateomedia.link/v1/games?date=\(day)") else {
            throw ScheduleError.invalidURL
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        request.setValue("\(version) (\(build))", forHTTPHeaderField: "X-NullSports-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ScheduleError.noHTTPResponse }
        guard http.statusCode == 200 else { throw ScheduleError.httpStatus(http.statusCode) }
        guard !data.isEmpty else { throw ScheduleError.emptyResponse }
        let envelope = try JSONDecoder().decode(CombinedEnvelope.self, from: data)
        guard envelope.schema == 2, envelope.date == day else { throw ScheduleError.invalidSchema }

        var result: [SportsLeague: [SportsGame]] = [:]
        var failed = Set(envelope.failedLeagues.compactMap(SportsLeague.init(rawValue:)))
        for league in SportsLeague.allCases {
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
                    status: game.status, state: game.state, broadcast: game.broadcast
                )
            }.sorted { $0.start < $1.start }
        }
        let loaded = Set(SportsLeague.allCases).subtracting(failed)
        let errorMessage = failed.isEmpty ? nil : "Temporarily unavailable: \(failed.map(\.shortName).sorted().joined(separator: ", "))."
        return Snapshot(games: result, loadedLeagues: loaded, errorMessage: errorMessage)
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

    private static func parseDate(_ value: String) -> Date? {
        let internet = ISO8601DateFormatter()
        if let date = internet.date(from: value) { return date }
        let formats = ["yyyy-MM-dd'T'HH:mmXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
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
