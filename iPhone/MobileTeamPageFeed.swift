import Foundation

/// Where a team's page is read from on ESPN: the sport and league segments
/// of its paths and the team's own id. Kept apart from `SportsLeague` so the
/// parsing below compiles on its own for the CI checks.
struct TeamPagePath: Hashable, Sendable {
    let sport: String
    let league: String
    let teamID: String

    private static let site = "https://site.api.espn.com/apis/site/v2/sports"

    var team: URL? { URL(string: "\(Self.site)/\(sport)/\(league)/teams/\(teamID)") }
    var roster: URL? { URL(string: "\(Self.site)/\(sport)/\(league)/teams/\(teamID)/roster") }
    var news: URL? { URL(string: "\(Self.site)/\(sport)/\(league)/news?team=\(teamID)&limit=20") }
    /// Results, and for soccer the fixtures still to come, which ESPN keeps
    /// in a list of their own.
    var schedules: [URL] {
        let base = "\(Self.site)/\(sport)/\(league)/teams/\(teamID)/schedule"
        return ([base] + (sport == "soccer" ? [base + "?fixture=true"] : [])).compactMap(URL.init(string:))
    }
    var standings: URL? { URL(string: "https://site.api.espn.com/apis/v2/sports/\(sport)/\(league)/standings") }
}

struct TeamPageInfo: Equatable, Sendable {
    var name: String
    var abbreviation: String
    var logo: String?
    var color: String?
    var record: String?
    /// "1st in Atlantic Division".
    var standing: String?
}

struct TeamPageGame: Identifiable, Equatable, Sendable {
    enum Outcome: String, Sendable { case win = "W", loss = "L", tie = "T" }

    let id: String
    let date: Date
    let opponent: String
    let opponentAbbreviation: String
    let opponentLogo: String?
    let isHome: Bool
    /// "pre", "in" or "post", as ESPN has it.
    let state: String
    let teamScore: String?
    let opponentScore: String?
    let outcome: Outcome?
    let status: String
    let broadcast: String?
    /// "Week 6", "Premier League", "Wild Card".
    let label: String?

    var isFinished: Bool { state == "post" }
}

struct TeamPageStandings: Equatable, Sendable {
    struct Row: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let abbreviation: String
        let logo: String?
        let values: [String]
    }

    let group: String
    let columns: [String]
    let rows: [Row]
}

struct TeamPagePlayer: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let jersey: String?
    let position: String?
    let headshot: String?
    let injury: String?
    let injuryDate: Date?
}

struct TeamPageRosterGroup: Identifiable, Equatable, Sendable {
    let title: String
    let players: [TeamPagePlayer]
    var id: String { title }
}

struct TeamPageArticle: Identifiable, Equatable, Sendable {
    let id: String
    let headline: String
    let summary: String?
    let published: Date?
    let image: String?
    let link: URL?
}

enum TeamPageParser {
    // MARK: Team

    static func info(_ data: Data) -> TeamPageInfo? {
        guard let team = object(data)?["team"] as? [String: Any],
              let name = string(team["displayName"]) else { return nil }
        let items = (team["record"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
        let overall = items.first { string($0["type"]) == "total" } ?? items.first
        return TeamPageInfo(name: name, abbreviation: string(team["abbreviation"]) ?? "",
                            logo: logo(team), color: string(team["color"]),
                            record: overall.flatMap { string($0["summary"]) },
                            standing: string(team["standingSummary"]))
    }

    // MARK: Schedule

    /// Every game in the lists, once each, oldest first.
    static func schedule(_ lists: [Data], teamID: String) -> [TeamPageGame] {
        var seen: Set<String> = []
        var games: [TeamPageGame] = []
        for data in lists {
            for event in object(data)?["events"] as? [[String: Any]] ?? [] {
                guard let game = game(event, teamID: teamID), seen.insert(game.id).inserted else { continue }
                games.append(game)
            }
        }
        return games.sorted { $0.date < $1.date }
    }

    private static func game(_ event: [String: Any], teamID: String) -> TeamPageGame? {
        guard let id = string(event["id"]),
              let competition = (event["competitions"] as? [[String: Any]])?.first,
              let date = self.date(competition["date"]) ?? self.date(event["date"]) else { return nil }
        let competitors = competition["competitors"] as? [[String: Any]] ?? []
        guard let ours = competitors.first(where: { string($0["id"]) == teamID
                    || string(($0["team"] as? [String: Any])?["id"]) == teamID }),
              let theirs = competitors.first(where: { string($0["id"]) != string(ours["id"]) }) else { return nil }
        let opponent = theirs["team"] as? [String: Any] ?? [:]
        let status = (competition["status"] as? [String: Any])?["type"] as? [String: Any] ?? [:]
        let state = string(status["state"]) ?? "pre"
        let teamScore = score(ours["score"]), opponentScore = score(theirs["score"])
        var outcome: TeamPageGame.Outcome?
        if state == "post" {
            if let won = ours["winner"] as? Bool, let lost = theirs["winner"] as? Bool, won != lost {
                outcome = won ? .win : .loss
            } else if let a = teamScore.flatMap(Double.init), let b = opponentScore.flatMap(Double.init) {
                outcome = a > b ? .win : (a < b ? .loss : .tie)
            }
        }
        let broadcasts = competition["broadcasts"] as? [[String: Any]] ?? []
        let network = broadcasts.lazy.compactMap { string(($0["media"] as? [String: Any])?["shortName"]) }.first
        let week = string((event["week"] as? [String: Any])?["text"])
        let league = string((event["league"] as? [String: Any])?["abbreviation"])
        let seasonType = event["seasonType"] as? [String: Any]
        // A season's own name says nothing a regular-season row needs.
        let phase = string(seasonType?["type"]).flatMap { $0 == "2" ? nil : string(seasonType?["name"]) }
        return TeamPageGame(
            id: id, date: date,
            opponent: string(opponent["displayName"]) ?? string(opponent["shortDisplayName"]) ?? "TBD",
            opponentAbbreviation: string(opponent["abbreviation"]) ?? "",
            opponentLogo: logo(opponent),
            isHome: string(ours["homeAway"]) == "home",
            state: state, teamScore: teamScore, opponentScore: opponentScore, outcome: outcome,
            status: string(status["shortDetail"]) ?? string(status["detail"]) ?? "",
            broadcast: network, label: week ?? league ?? phase)
    }

    /// A score is a number, a string, or `{value, displayValue}`.
    private static func score(_ value: Any?) -> String? {
        if let score = value as? [String: Any] { return string(score["displayValue"]) ?? string(score["value"]) }
        return string(value)
    }

    // MARK: Standings

    struct Column: Sendable {
        let title: String
        /// A stat's `type` (which names one record among several) or `name`.
        let keys: [String]
    }

    static func columns(sport: String, league: String) -> [Column] {
        switch sport {
        case "soccer":
            return [.init(title: "GP", keys: ["gamesPlayed"]), .init(title: "W", keys: ["wins"]),
                    .init(title: "D", keys: ["ties"]), .init(title: "L", keys: ["losses"]),
                    .init(title: "GD", keys: ["pointDifferential"]), .init(title: "P", keys: ["points"])]
        case "hockey":
            return [.init(title: "W", keys: ["wins"]), .init(title: "L", keys: ["losses"]),
                    .init(title: "OTL", keys: ["otLosses", "overtimeLosses"]), .init(title: "PTS", keys: ["points"])]
        case "football" where league == "college-football":
            return [.init(title: "CONF", keys: ["vsconf", "vs. Conf."]), .init(title: "OVR", keys: ["total", "overall"])]
        case "football":
            return [.init(title: "W", keys: ["wins"]), .init(title: "L", keys: ["losses"]),
                    .init(title: "T", keys: ["ties"]), .init(title: "PCT", keys: ["winPercent"])]
        default:
            return [.init(title: "W", keys: ["wins"]), .init(title: "L", keys: ["losses"]),
                    .init(title: "PCT", keys: ["winPercent"]), .init(title: "GB", keys: ["gamesBehind"])]
        }
    }

    /// The table the team is in -- its division, conference or league --
    /// in the order the table stands.
    static func standings(_ data: Data, teamID: String, columns: [Column]) -> TeamPageStandings? {
        guard let root = object(data), let found = table(containing: teamID, in: root) else { return nil }
        let (group, entries) = found
        let rows = entries.map { entry -> (row: TeamPageStandings.Row, rank: Double?, seed: Double?, percent: Double) in
            let team = entry["team"] as? [String: Any] ?? [:]
            let stats = entry["stats"] as? [[String: Any]] ?? []
            let values = columns.map { column in
                column.keys.lazy.compactMap { stat($0, in: stats) }.first.flatMap { string($0["displayValue"]) } ?? "–"
            }
            func number(_ key: String) -> Double? {
                stat(key, in: stats).flatMap { stat in (stat["value"] as? NSNumber)?.doubleValue ?? string(stat["displayValue"]).flatMap(Double.init) }
            }
            return (TeamPageStandings.Row(id: string(team["id"]) ?? UUID().uuidString,
                                          name: string(team["displayName"]) ?? "",
                                          abbreviation: string(team["abbreviation"]) ?? "",
                                          logo: logo(team), values: values),
                    number("rank"), number("playoffSeed").flatMap { $0 > 0 ? $0 : nil }, number("winPercent") ?? 0)
        }
        let ordered = rows.sorted { a, b in
            if let x = a.rank, let y = b.rank, x != y { return x < y }
            if let x = a.seed, let y = b.seed, x != y { return x < y }
            return a.percent > b.percent
        }
        return TeamPageStandings(group: group, columns: columns.map(\.title), rows: ordered.map(\.row))
    }

    private static func table(containing teamID: String, in node: [String: Any]) -> (String, [[String: Any]])? {
        if let entries = (node["standings"] as? [String: Any])?["entries"] as? [[String: Any]],
           entries.contains(where: { string(($0["team"] as? [String: Any])?["id"]) == teamID }) {
            return (string(node["name"]) ?? "Standings", entries)
        }
        for child in node["children"] as? [[String: Any]] ?? [] {
            if let found = table(containing: teamID, in: child) { return found }
        }
        return nil
    }

    private static func stat(_ key: String, in stats: [[String: Any]]) -> [String: Any]? {
        let lowered = key.lowercased()
        return stats.first { string($0["type"])?.lowercased() == lowered }
            ?? stats.first { string($0["name"]) == key }
    }

    // MARK: Roster

    struct Roster: Equatable, Sendable {
        var groups: [TeamPageRosterGroup]
        var coach: String?
        /// Everyone with a reported injury, the latest report first.
        var injured: [TeamPagePlayer] {
            groups.flatMap(\.players).filter { $0.injury != nil }
                .reduce(into: [TeamPagePlayer]()) { list, player in
                    if !list.contains(where: { $0.id == player.id }) { list.append(player) }
                }
                .sorted { ($0.injuryDate ?? .distantPast) > ($1.injuryDate ?? .distantPast) }
        }
    }

    /// Football's roster comes in groups -- offense, defense, injured
    /// reserve -- and the rest as one list, grouped here by position.
    static func roster(_ data: Data) -> Roster? {
        guard let root = object(data) else { return nil }
        let athletes = root["athletes"] as? [[String: Any]] ?? []
        let coach = (root["coach"] as? [[String: Any]])?.first.map { coach in
            [string(coach["firstName"]), string(coach["lastName"])].compactMap { $0 }.joined(separator: " ")
        }
        var groups: [TeamPageRosterGroup] = []
        if athletes.contains(where: { $0["items"] != nil }) {
            for group in athletes {
                let players = (group["items"] as? [[String: Any]] ?? []).compactMap(player)
                guard !players.isEmpty else { continue }
                groups.append(.init(title: groupTitle(string(group["position"]) ?? ""), players: sortedByNumber(players)))
            }
        } else {
            var order: [String] = []
            var byPosition: [String: [TeamPagePlayer]] = [:]
            for raw in athletes {
                guard let player = player(raw) else { continue }
                let position = string((raw["position"] as? [String: Any])?["displayName"]) ?? "Players"
                if byPosition[position] == nil { order.append(position) }
                byPosition[position, default: []].append(player)
            }
            groups = order.map { .init(title: plural($0), players: sortedByNumber(byPosition[$0] ?? [])) }
        }
        return Roster(groups: groups, coach: coach.flatMap { $0.isEmpty ? nil : $0 })
    }

    private static func player(_ raw: [String: Any]) -> TeamPagePlayer? {
        guard let id = string(raw["id"]), let name = string(raw["displayName"]) ?? string(raw["fullName"]) else { return nil }
        let injury = (raw["injuries"] as? [[String: Any]])?.first
        return TeamPagePlayer(id: id, name: name, jersey: string(raw["jersey"]),
                              position: string((raw["position"] as? [String: Any])?["abbreviation"]),
                              headshot: string((raw["headshot"] as? [String: Any])?["href"]),
                              injury: injury.flatMap { string($0["status"]) },
                              injuryDate: injury.flatMap { date($0["date"]) })
    }

    private static func sortedByNumber(_ players: [TeamPagePlayer]) -> [TeamPagePlayer] {
        players.sorted { (Int($0.jersey ?? "") ?? 1000, $0.name) < (Int($1.jersey ?? "") ?? 1000, $1.name) }
    }

    private static func groupTitle(_ key: String) -> String {
        switch key {
        case "offense": return "Offense"
        case "defense": return "Defense"
        case "specialTeam": return "Special Teams"
        case "injuredReserveOrOut": return "Injured Reserve / Out"
        case "suspended": return "Suspended"
        case "practiceSquad": return "Practice Squad"
        default:
            let spaced = key.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            return spaced.prefix(1).uppercased() + spaced.dropFirst()
        }
    }

    private static func plural(_ position: String) -> String {
        if position.hasSuffix("s") || position == "Players" || position == "Defense" { return position }
        return position + "s"
    }

    // MARK: News

    static func news(_ data: Data) -> [TeamPageArticle] {
        (object(data)?["articles"] as? [[String: Any]] ?? []).compactMap { article in
            guard let headline = string(article["headline"]), !headline.isEmpty else { return nil }
            let links = article["links"] as? [String: Any]
            let web = string((links?["web"] as? [String: Any])?["href"])
                ?? string((links?["mobile"] as? [String: Any])?["href"])
            let image = (article["images"] as? [[String: Any]])?.first.flatMap { string($0["url"]) }
            return TeamPageArticle(id: string(article["id"]) ?? headline, headline: headline,
                                   summary: string(article["description"]),
                                   published: date(article["published"]),
                                   image: image, link: web.flatMap(URL.init(string:)))
        }
    }

    // MARK: Values

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    private static func logo(_ team: [String: Any]) -> String? {
        if let logos = team["logos"] as? [[String: Any]], let first = logos.first { return string(first["href"]) }
        return string(team["logo"])
    }

    private static let formats: [DateFormatter] = ["yyyy-MM-dd'T'HH:mmX", "yyyy-MM-dd'T'HH:mm:ssX",
                                                   "yyyy-MM-dd'T'HH:mm:ss.SSSX"].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = string(value) else { return nil }
        return formats.lazy.compactMap { $0.date(from: text) }.first
    }
}
