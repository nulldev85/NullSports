import Foundation

struct SportsScheduleClient: Sendable {
    func gamesToday() async -> [SportsLeague: [SportsGame]] {
        await withTaskGroup(of: (SportsLeague, [SportsGame]).self) { group in
            for league in SportsLeague.allCases {
                group.addTask { (league, (try? await games(for: league)) ?? []) }
            }
            var result: [SportsLeague: [SportsGame]] = [:]
            for await (league, games) in group { result[league] = games }
            return result
        }
    }

    private func games(for league: SportsLeague) async throws -> [SportsGame] {
        let path: String
        switch league {
        case .nfl: path = "football/nfl"
        case .nba: path = "basketball/nba"
        case .nhl: path = "hockey/nhl"
        case .mlb: path = "baseball/mlb"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        let day = formatter.string(from: Date())
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(path)/scoreboard?dates=\(day)&limit=100") else { return [] }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
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
