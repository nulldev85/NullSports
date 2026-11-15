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
///
/// College basketball reads its poll the same way, from the same choice: its
/// AP or coaches' poll, the latest week of it. It has no committee rankings,
/// so a viewer who follows those sees basketball's AP poll.
actor CollegeFootballRankings {
    static let shared = CollegeFootballRankings()

    /// Which college sport's polls.
    enum Sport: String, Sendable {
        case football, basketball

        /// ESPN's path for the sport.
        var path: String {
            switch self {
            case .football: "football/college-football"
            case .basketball: "basketball/mens-college-basketball"
            }
        }

        /// The scoreboard group holding every game a ranked team plays:
        /// FBS for football, Division I for basketball.
        var groups: String {
            switch self {
            case .football: "80"
            case .basketball: "50"
            }
        }
    }

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
        /// By ESPN team. A game that carries ESPN's team IDs is settled by
        /// them alone: hundreds of schools share a word of a name or a code
        /// with one in the Top 25, and a guess on either put a number beside
        /// a team that isn't ranked.
        var byTeamID: [String: Int] = [:]

        static let empty = Ranks()

        func applied(to game: SportsGame) -> SportsGame {
            guard game.league.isCollege, !game.isEvent else { return game }
            var ranked = game
            let prefix = game.league.rawValue + "-"
            let espnID = game.id.hasPrefix(prefix) ? String(game.id.dropFirst(prefix.count)) : game.id
            if let sides = byGame[espnID] {
                ranked.awayRank = sides.away
                ranked.homeRank = sides.home
            } else {
                ranked.awayRank = rank(id: game.awayTeamID, name: game.awayTeam, abbreviation: game.awayAbbreviation)
                ranked.homeRank = rank(id: game.homeTeamID, name: game.homeTeam, abbreviation: game.homeAbbreviation)
            }
            return ranked
        }

        /// The team's ESPN ID when both sides have one; otherwise the full
        /// name first, the one no two schools share.
        private func rank(id: String?, name: String, abbreviation: String) -> Int? {
            if let id, !id.isEmpty, !byTeamID.isEmpty { return byTeamID[id] }
            return byTeam[Self.nameKey(name)] ?? byTeam[Self.abbreviationKey(abbreviation)]
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
                if let id = team.id?.value, !id.isEmpty { ranks.byTeamID[id] = current }
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
                    if let id = competitor.team?.id?.value, !id.isEmpty { ranks.byTeamID[id] = current }
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
    func ranks(for day: String, sport: Sport = .football) async -> Ranks {
        let poll = Poll.chosen
        if let ranks = await pollRanks(poll, sport: sport), !ranks.byTeam.isEmpty { return ranks }
        return await scoreboardRanks(for: day, sport: sport)
    }

    /// The chosen poll's latest week for a sport, or nil if it can't be read
    /// and none was read before: then a game keeps the rank its scoreboard
    /// gave it.
    func latestPoll(_ sport: Sport) async -> Ranks? {
        guard let ranks = await pollRanks(Poll.chosen, sport: sport), !ranks.byTeam.isEmpty else { return nil }
        return ranks
    }

    private func pollRanks(_ poll: Poll, sport: Sport) async -> Ranks? {
        let key = "poll|" + sport.rawValue + "|" + poll.rawValue
        if let entry = entries[key], entry.succeeded,
           Date().timeIntervalSince(entry.checkedAt) < Self.lifetime { return entry.ranks }
        if let entry = entries[key], !entry.succeeded,
           Date().timeIntervalSince(entry.checkedAt) < Self.retryAfterFailure { return nil }
        let task: Task<Ranks?, Never>
        if let running = inFlight[key] {
            task = running
        } else {
            task = Task { try? await Self.fetchPolls(poll, sport: sport) }
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

    private func scoreboardRanks(for day: String, sport: Sport) async -> Ranks {
        let key = sport.rawValue + "|" + day
        if let entry = entries[key] {
            let age = Date().timeIntervalSince(entry.checkedAt)
            if age < (entry.succeeded ? Self.lifetime : Self.retryAfterFailure) { return entry.ranks }
        }
        let task: Task<Ranks?, Never>
        if let running = inFlight[key] {
            task = running
        } else {
            task = Task { try? await Self.fetch(day, sport: sport) }
            inFlight[key] = task
        }
        let fetched = await task.value
        inFlight[key] = nil
        if let fetched {
            entries[key] = Entry(ranks: fetched, checkedAt: Date(), succeeded: true)
            return fetched
        }
        let kept = entries[key]?.ranks ?? .empty
        entries[key] = Entry(ranks: kept, checkedAt: Date(), succeeded: false)
        return kept
    }

    private static func fetchPolls(_ poll: Poll, sport: Sport) async throws -> Ranks {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(sport.path)/rankings") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try Ranks.parse(polls: data, poll: poll)
    }

    private static func fetch(_ day: String, sport: Sport) async throws -> Ranks {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(sport.path)/scoreboard?dates=\(day)&groups=\(sport.groups)&limit=400") else {
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
        let id: TeamID?
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
        let id: TeamID?
        let abbreviation: String?
        let displayName: String?
    }

    struct CuratedRank: Decodable {
        let current: Int?
    }
}

/// ESPN's team ID, written as text but read as a number too, so a feed that
/// changes how it writes one never loses every rank with it.
private struct TeamID: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let text = try? single.decode(String.self) {
            value = text
        } else {
            value = String(try single.decode(Int.self))
        }
    }
}
