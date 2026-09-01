import Foundation

struct SportsScheduleClient: Sendable {
    struct Snapshot: Sendable {
        let games: [SportsLeague: [SportsGame]]
        let loadedLeagues: Set<SportsLeague>
    }

    func gamesToday() async -> Snapshot {
        await withTaskGroup(of: (SportsLeague, [SportsGame], Bool).self) { group in
            for league in SportsLeague.allCases {
                group.addTask {
                    do { return (league, try await games(for: league), true) }
                    catch { return (league, [], false) }
                }
            }
            var result: [SportsLeague: [SportsGame]] = [:]
            var loaded: Set<SportsLeague> = []
            for await (league, games, succeeded) in group {
                result[league] = games
                if succeeded { loaded.insert(league) }
            }
            return Snapshot(games: result, loadedLeagues: loaded)
        }
    }

    private func games(for league: SportsLeague) async throws -> [SportsGame] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        let day = formatter.string(from: Date())
        guard let url = URL(string: "https://sports.mateomedia.link/v1/games/\(league.rawValue)?date=\(day)") else { return [] }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("0.6.2", forHTTPHeaderField: "X-NullSports-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let envelope = try JSONDecoder().decode(GamesEnvelope.self, from: data)
        guard envelope.schema == 1, envelope.league == league.rawValue else { throw URLError(.cannotParseResponse) }
        return envelope.games.compactMap { game in
            guard let start = ISO8601DateFormatter().date(from: game.start) else { return nil }
            return SportsGame(
                id: "\(league.rawValue)-\(game.id)", league: league, start: start,
                awayTeam: game.awayTeam, homeTeam: game.homeTeam,
                awayAbbreviation: game.awayAbbreviation, homeAbbreviation: game.homeAbbreviation,
                status: game.status, state: game.state, broadcast: game.broadcast
            )
        }.sorted { $0.start < $1.start }
    }
}

private struct GamesEnvelope: Decodable {
    let schema: Int
    let league: String
    let games: [Game]

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
