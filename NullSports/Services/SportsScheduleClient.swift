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
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [[String: Any]]
        else { throw URLError(.cannotParseResponse) }
        return events.compactMap { event in
            guard let id = event["id"] as? String,
                  let date = event["date"] as? String,
                  let start = ISO8601DateFormatter().date(from: date),
                  let competitions = event["competitions"] as? [[String: Any]],
                  let contest = competitions.first,
                  let competitors = contest["competitors"] as? [[String: Any]],
                  let home = competitor("home", in: competitors),
                  let away = competitor("away", in: competitors)
            else { return nil }
            let status = ((event["status"] as? [String: Any])?["type"] as? [String: Any]) ?? [:]
            let broadcasts = contest["broadcasts"] as? [[String: Any]]
            let names = broadcasts?.first?["names"] as? [String]
            return SportsGame(
                id: "\(league.rawValue)-\(id)", league: league, start: start,
                awayTeam: away.name, homeTeam: home.name,
                awayAbbreviation: away.abbreviation, homeAbbreviation: home.abbreviation,
                status: status["shortDetail"] as? String ?? status["description"] as? String ?? "Scheduled",
                state: status["state"] as? String ?? "pre",
                broadcast: names?.first ?? ""
            )
        }.sorted { $0.start < $1.start }
    }

    private func competitor(_ side: String, in competitors: [[String: Any]]) -> (name: String, abbreviation: String)? {
        guard let entry = competitors.first(where: { $0["homeAway"] as? String == side }),
              let team = entry["team"] as? [String: Any],
              let name = team["displayName"] as? String
        else { return nil }
        return (name, team["abbreviation"] as? String ?? String(name.prefix(3)).uppercased())
    }
}
