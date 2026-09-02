import Foundation

struct SportsScheduleClient: Sendable {
    struct Snapshot: Sendable {
        let games: [SportsLeague: [SportsGame]]
        let loadedLeagues: Set<SportsLeague>
        let errorMessage: String?
    }

    func gamesToday() async -> Snapshot {
        do {
            return try await combinedSchedule()
        } catch {
            return Snapshot(games: [:], loadedLeagues: [], errorMessage: Self.describe(error))
        }
    }

    private func combinedSchedule() async throws -> Snapshot {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        let day = formatter.string(from: Date())
        guard let url = URL(string: "https://sports.mateomedia.link/v1/games?date=\(day)") else {
            throw ScheduleError.invalidURL
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("0.8.0", forHTTPHeaderField: "X-NullSports-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ScheduleError.noHTTPResponse }
        guard http.statusCode == 200 else { throw ScheduleError.httpStatus(http.statusCode) }
        guard !data.isEmpty else { throw ScheduleError.emptyResponse }
        let envelope = try JSONDecoder().decode(CombinedEnvelope.self, from: data)
        guard envelope.schema == 2, envelope.date == day else { throw ScheduleError.invalidSchema }

        var result: [SportsLeague: [SportsGame]] = [:]
        for league in SportsLeague.allCases {
            guard let remoteGames = envelope.leagues[league.rawValue] else {
                throw ScheduleError.missingLeague(league.rawValue.uppercased())
            }
            result[league] = remoteGames.compactMap { game in
                guard let start = ISO8601DateFormatter().date(from: game.start) else { return nil }
                return SportsGame(
                    id: "\(league.rawValue)-\(game.id)", league: league, start: start,
                    awayTeam: game.awayTeam, homeTeam: game.homeTeam,
                    awayAbbreviation: game.awayAbbreviation, homeAbbreviation: game.homeAbbreviation,
                    status: game.status, state: game.state, broadcast: game.broadcast
                )
            }.sorted { $0.start < $1.start }
        }
        return Snapshot(games: result, loadedLeagues: Set(SportsLeague.allCases), errorMessage: nil)
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

    struct Game: Decodable {
        let id: String
        let start: String
        let awayTeam: String
        let homeTeam: String
        let awayAbbreviation: String
        let homeAbbreviation: String
        let status: String
        let state: String
        let broadcast: String
    }
}
