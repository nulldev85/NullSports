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
        guard let url = URL(string: "https://sports.mateomedia.link/v1/scoreboard/\(league.rawValue)?date=\(day)") else { return [] }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let payload = try JSONDecoder().decode(Scoreboard.self, from: data)
        return payload.events.compactMap { event in
            guard let contest = event.competitions.first,
                  let home = contest.competitors.first(where: { $0.homeAway == "home" }),
                  let away = contest.competitors.first(where: { $0.homeAway == "away" }),
                  let start = ISO8601DateFormatter().date(from: event.date)
            else { return nil }
            return SportsGame(
                id: "\(league.rawValue)-\(event.id)", league: league, start: start,
                awayTeam: away.team.displayName, homeTeam: home.team.displayName,
                awayAbbreviation: away.team.abbreviation ?? String(away.team.displayName.prefix(3)).uppercased(),
                homeAbbreviation: home.team.abbreviation ?? String(home.team.displayName.prefix(3)).uppercased(),
                status: event.status.type.shortDetail ?? event.status.type.description ?? "Scheduled",
                state: event.status.type.state ?? "pre",
                broadcast: contest.broadcasts?.first?.names.first ?? ""
            )
        }.sorted { $0.start < $1.start }
    }
}

private struct Scoreboard: Decodable {
    let events: [Event]
    struct Event: Decodable { let id: String; let date: String; let status: Status; let competitions: [Competition] }
    struct Status: Decodable { let type: StatusType }
    struct StatusType: Decodable { let state: String?; let description: String?; let shortDetail: String? }
    struct Competition: Decodable { let competitors: [Competitor]; let broadcasts: [Broadcast]? }
    struct Competitor: Decodable { let homeAway: String; let team: Team }
    struct Team: Decodable { let displayName: String; let abbreviation: String? }
    struct Broadcast: Decodable { let names: [String] }
}
