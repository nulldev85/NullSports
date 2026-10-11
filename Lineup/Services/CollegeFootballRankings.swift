import Foundation

/// College football's Top 25 as ESPN prints it beside each team: the AP poll,
/// then the playoff committee's rankings once those are out. The shared
/// schedule service does not carry ranks, so they come from ESPN's scoreboard
/// for the day, where each side of a game has its own.
///
/// Ranks change once a week, so a day's are kept for a while rather than
/// fetched again with every live-score poll, and a failed fetch keeps the
/// ranks already on hand instead of taking them off every card.
actor CollegeFootballRankings {
    static let shared = CollegeFootballRankings()

    struct Ranks: Sendable {
        struct Sides: Sendable, Equatable {
            var away: Int?
            var home: Int?
        }

        /// By ESPN game, which settles it where the schedule shares ESPN's IDs.
        var byGame: [String: Sides] = [:]
        /// By team name and abbreviation, for a game whose ID differs.
        var byTeam: [String: Int] = [:]

        static let empty = Ranks()

        func applied(to game: SportsGame) -> SportsGame {
            guard game.league == .ncaaf, !game.isEvent else { return game }
            var ranked = game
            let espnID = game.id.hasPrefix("ncaaf-") ? String(game.id.dropFirst(6)) : game.id
            if let sides = byGame[espnID] {
                ranked.awayRank = sides.away
                ranked.homeRank = sides.home
            } else {
                ranked.awayRank = rank(name: game.awayTeam, abbreviation: game.awayAbbreviation)
                ranked.homeRank = rank(name: game.homeTeam, abbreviation: game.homeAbbreviation)
            }
            return ranked
        }

        /// The full name first: it is the one no two schools share.
        private func rank(name: String, abbreviation: String) -> Int? {
            byTeam[Self.nameKey(name)] ?? byTeam[Self.abbreviationKey(abbreviation)]
        }

        fileprivate static func nameKey(_ name: String) -> String {
            "name:" + name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        fileprivate static func abbreviationKey(_ abbreviation: String) -> String {
            "code:" + abbreviation.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }

        /// Reads a scoreboard. Unranked teams carry 99, so only 1 to 25 count.
        static func parse(_ data: Data) throws -> Ranks {
            let board = try JSONDecoder().decode(Scoreboard.self, from: data)
            var ranks = Ranks()
            for event in board.events ?? [] {
                guard let competition = event.competitions?.first else { continue }
                var sides = Sides()
                for competitor in competition.competitors ?? [] {
                    guard let current = competitor.curatedRank?.current, (1...25).contains(current) else { continue }
                    switch competitor.homeAway {
                    case "away": sides.away = current
                    case "home": sides.home = current
                    default: break
                    }
                    if let name = competitor.team?.displayName, !name.isEmpty {
                        ranks.byTeam[nameKey(name)] = current
                    }
                    if let code = competitor.team?.abbreviation, !code.isEmpty {
                        ranks.byTeam[abbreviationKey(code)] = current
                    }
                }
                if let id = event.id { ranks.byGame[id] = sides }
            }
            return ranks
        }
    }

    private struct Entry {
        var ranks: Ranks
        var checkedAt: Date
        var succeeded: Bool
    }

    private static let lifetime: TimeInterval = 30 * 60
    private static let retryAfterFailure: TimeInterval = 5 * 60

    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<Ranks?, Never>] = [:]

    /// The day's ranks, `day` in the schedule's own yyyyMMdd form.
    func ranks(for day: String) async -> Ranks {
        if let entry = entries[day] {
            let age = Date().timeIntervalSince(entry.checkedAt)
            if age < (entry.succeeded ? Self.lifetime : Self.retryAfterFailure) { return entry.ranks }
        }
        let task: Task<Ranks?, Never>
        if let running = inFlight[day] {
            task = running
        } else {
            task = Task { try? await Self.fetch(day) }
            inFlight[day] = task
        }
        let fetched = await task.value
        inFlight[day] = nil
        if let fetched {
            entries[day] = Entry(ranks: fetched, checkedAt: Date(), succeeded: true)
            return fetched
        }
        let kept = entries[day]?.ranks ?? .empty
        entries[day] = Entry(ranks: kept, checkedAt: Date(), succeeded: false)
        return kept
    }

    private static func fetch(_ day: String) async throws -> Ranks {
        // Group 80 is every FBS game, which is every game a ranked team plays.
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/football/college-football/scoreboard?dates=\(day)&groups=80&limit=300") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try Ranks.parse(data)
    }
}

/// Only what the ranks need, all of it optional: a scoreboard missing some
/// other part still gives its ranks.
private struct Scoreboard: Decodable {
    let events: [Event]?

    struct Event: Decodable {
        let id: String?
        let competitions: [Competition]?
    }

    struct Competition: Decodable {
        let competitors: [Competitor]?
    }

    struct Competitor: Decodable {
        let homeAway: String?
        let team: Team?
        let curatedRank: CuratedRank?
    }

    struct Team: Decodable {
        let abbreviation: String?
        let displayName: String?
    }

    struct CuratedRank: Decodable {
        let current: Int?
    }
}
