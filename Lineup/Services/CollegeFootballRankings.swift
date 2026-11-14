import Foundation

/// College football's Top 25 beside each team, from the poll the viewer
/// follows: the AP poll unless they chose the coaches' poll or the playoff
/// committee's rankings. ESPN's own scoreboard switches to the committee's
/// rankings in November, so a viewer reading the AP poll saw numbers that
/// looked a week stale; the poll is read from ESPN's rankings instead, the
/// latest week of it, and the day's scoreboard is the fallback when the
/// rankings can't be reached.
///
/// Ranks change once a week, so they are kept for a while rather than
/// fetched again with every live-score poll, and a failed fetch keeps the
/// ranks already on hand instead of taking them off every card.
actor CollegeFootballRankings {
    static let shared = CollegeFootballRankings()

    /// The ranking a viewer follows.
    enum Poll: String, CaseIterable, Identifiable, Sendable {
        case ap, coaches, playoff

        static let storageKey = "Lineup.sports.collegeFootballPoll.v1"
        var id: String { rawValue }

        var title: String {
            switch self {
            case .ap: "AP Top 25"
            case .coaches: "Coaches Poll"
            case .playoff: "Playoff Rankings"
            }
        }

        /// ESPN's name for the ranking.
        var espnType: String {
            switch self {
            case .ap: "ap"
            case .coaches: "usa"
            case .playoff: "cfp"
            }
        }

        static var chosen: Poll {
            UserDefaults.standard.string(forKey: storageKey).flatMap(Poll.init(rawValue:)) ?? .ap
        }
    }

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

        /// Reads ESPN's rankings for one poll. The committee's rankings only
        /// appear in November; until then the AP poll stands in for them.
        static func parse(polls data: Data, poll: Poll) throws -> Ranks {
            let rankings = try JSONDecoder().decode(Rankings.self, from: data).rankings ?? []
            guard let chosen = rankings.first(where: { $0.type == poll.espnType })
                ?? rankings.first(where: { $0.type == Poll.ap.espnType }) else {
                throw URLError(.cannotParseResponse)
            }
            var ranks = Ranks()
            for entry in chosen.ranks ?? [] {
                guard let current = entry.current, (1...25).contains(current), let team = entry.team else { continue }
                let location = team.location ?? ""
                let full = [location, team.name ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
                // A schedule may name a team in full ("Georgia Bulldogs") or
                // by its school alone ("Georgia").
                for name in [full, location, team.nickname ?? ""] where !name.isEmpty {
                    ranks.byTeam[nameKey(name)] = current
                }
                if let code = team.abbreviation, !code.isEmpty {
                    ranks.byTeam[abbreviationKey(code)] = current
                }
            }
            return ranks
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

    /// The ranks for a day's games, `day` in the schedule's own yyyyMMdd
    /// form: the chosen poll's latest week, or the day's scoreboard if the
    /// rankings can't be read.
    func ranks(for day: String) async -> Ranks {
        let poll = Poll.chosen
        if let ranks = await pollRanks(poll), !ranks.byTeam.isEmpty { return ranks }
        return await scoreboardRanks(for: day)
    }

    private func pollRanks(_ poll: Poll) async -> Ranks? {
        let key = "poll|" + poll.rawValue
        if let entry = entries[key], entry.succeeded,
           Date().timeIntervalSince(entry.checkedAt) < Self.lifetime { return entry.ranks }
        if let entry = entries[key], !entry.succeeded,
           Date().timeIntervalSince(entry.checkedAt) < Self.retryAfterFailure { return nil }
        let task: Task<Ranks?, Never>
        if let running = inFlight[key] {
            task = running
        } else {
            task = Task { try? await Self.fetchPolls(poll) }
            inFlight[key] = task
        }
        let fetched = await task.value
        inFlight[key] = nil
        if let fetched {
            entries[key] = Entry(ranks: fetched, checkedAt: Date(), succeeded: true)
            return fetched
        }
        // A poll read before stays until a new one can be read.
        let kept = entries[key]?.ranks
        entries[key] = Entry(ranks: kept ?? .empty, checkedAt: Date(), succeeded: false)
        return kept
    }

    private func scoreboardRanks(for day: String) async -> Ranks {
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

    private static func fetchPolls(_ poll: Poll) async throws -> Ranks {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/football/college-football/rankings") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try Ranks.parse(polls: data, poll: poll)
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

/// ESPN's rankings, cut to what the ranks need.
private struct Rankings: Decodable {
    let rankings: [Ranking]?

    struct Ranking: Decodable {
        let type: String?
        let ranks: [Entry]?
    }

    struct Entry: Decodable {
        let current: Int?
        let team: Team?
    }

    struct Team: Decodable {
        let location: String?
        let name: String?
        let nickname: String?
        let abbreviation: String?
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
