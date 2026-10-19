import Foundation

// The sports whose ESPN feed is a scoreboard and nothing more -- a tennis
// draw, a fight card, a race -- read into boards, and what changed from one
// fetch to the next told as plays.
//
// These feeds carry no play-by-play and no times, only how things stand
// when asked. So what happened is worked out by comparing a fetch with the
// one before it, and placed between the two: after the earlier, by the
// later. That window is what keeps it behind the picture. A change is shown
// no sooner than the later fetch, under the viewer's delay, and syncing to
// one reckons from the earlier; so a change can come a few seconds after
// the picture shows it, and never before.
//
// Foundation only, so the checks in Tests/ can compile it on its own.

enum GameStatsSide: String, Equatable, Sendable {
    case away, home
    var other: GameStatsSide { self == .away ? .home : .away }
}

/// A board: everything a scoreboard-only feed said in one fetch.
enum GameStatsBoard: Equatable, Sendable {
    case tennis(GameStatsTennisBoard)
    case card(GameStatsFightCard)
    case race(GameStatsRaceBoard)

    var tennis: GameStatsTennisBoard? { if case .tennis(let draw) = self { return draw } else { return nil } }
    var card: GameStatsFightCard? { if case .card(let card) = self { return card } else { return nil } }
    var race: GameStatsRaceBoard? { if case .race(let race) = self { return race } else { return nil } }
}

// MARK: - Tennis

struct GameStatsTennisMatch: Identifiable, Equatable, Sendable {
    struct SetScore: Equatable, Sendable {
        let away: Int
        let home: Int
        var awayTiebreak: Int? = nil
        var homeTiebreak: Int? = nil
        /// Who took it, once it is over.
        var winner: GameStatsSide? = nil
    }

    let id: String
    let round: String
    let court: String?
    /// The first player, as the schedule lists them, and the second.
    let away: GameStatsTeam
    let home: GameStatsTeam
    var awaySeed: Int? = nil
    var homeSeed: Int? = nil
    let sets: [SetScore]
    /// Three sets, or five.
    var bestOf = 3
    /// Who is serving, where ESPN says or it can be told.
    var serving: GameStatsSide?
    let state: String
    /// ESPN's own word for it: "2nd", "Final", "Retired".
    let detail: String
    let winner: GameStatsSide?
    let start: Date?

    var awaySets: Int { sets.filter { $0.winner == .away }.count }
    /// Every game so far, a tiebreak counting as one.
    var gamesPlayed: Int { sets.reduce(0) { $0 + $1.away + $1.home } }
    var homeSets: Int { sets.filter { $0.winner == .home }.count }
    /// The set being played, if one is.
    var current: SetScore? { state == "in" ? sets.last.flatMap { $0.winner == nil ? $0 : nil } : nil }
    var retired: Bool { detail.lowercased().contains("ret") }

    /// "7-5 4-2", "6-7(6) 6-3": the loser's tiebreak points, the way a
    /// scoreboard prints them.
    var line: String {
        sets.map { set in
            var text = "\(set.away)-\(set.home)"
            if let away = set.awayTiebreak, let home = set.homeTiebreak { text += "(\(min(away, home)))" }
            return text
        }.joined(separator: " ")
    }

    var title: String { "\(away.abbreviation) vs \(home.abbreviation)" }

    /// "Set 2 · 4-2" while it is played, "Final · 7-5 6-4" after.
    var status: String {
        switch state {
        case "in":
            guard let current else { return sets.isEmpty ? "Under way" : "Between sets" }
            return "Set \(sets.count) \u{00B7} \(current.away)-\(current.home)"
        case "post": return sets.isEmpty ? detail : "\(detail) \u{00B7} \(line)"
        default: return detail
        }
    }
}

struct GameStatsTennisBoard: Equatable, Sendable {
    let tournament: String
    /// The match the viewer opened, where they opened a match rather than
    /// the tournament.
    let focus: String?
    /// The day's singles in the draw, in the order they are scheduled.
    var matches: [GameStatsTennisMatch]

    var focused: GameStatsTennisMatch? { focus.flatMap { id in matches.first { $0.id == id } } }
    var live: [GameStatsTennisMatch] { matches.filter { $0.state == "in" } }
}

// MARK: - A fight card

struct GameStatsBout: Identifiable, Equatable, Sendable {
    /// One thing ESPN logs during a fight: a round starting, a takedown.
    struct Moment: Equatable, Sendable {
        let id: String
        let kind: String
    }

    let id: String
    /// Its place on the card, the first fight of the night first.
    let order: Int
    let weightClass: String
    let away: GameStatsTeam
    let home: GameStatsTeam
    let awayRecord: String?
    let homeRecord: String?
    let state: String
    let round: Int
    let clock: String?
    /// Three rounds, or five.
    let rounds: Int
    let winner: GameStatsSide?
    /// "KO/TKO", "Submission", "Decision", once ESPN says.
    let method: String?
    let moments: [Moment]
    let start: Date?

    var title: String { "\(away.abbreviation) vs. \(home.abbreviation)" }
    var winnerName: String? { winner.map { $0 == .away ? away.name : home.name } }
    var loserName: String? { winner.map { $0 == .away ? home.name : away.name } }

    /// "KO/TKO · R2 2:32", once it is over.
    var result: String? {
        guard state == "post" else { return nil }
        let when = round > 0 ? "R\(round)" + (clock.map { " \($0)" } ?? "") : nil
        return [method, when].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }
}

struct GameStatsFightCard: Equatable, Sendable {
    let name: String
    /// The first fight of the night first, the main event last.
    let bouts: [GameStatsBout]

    var live: GameStatsBout? { bouts.first { $0.state == "in" } }
    var next: GameStatsBout? { bouts.first { $0.state == "pre" } }
    var mainEvent: GameStatsBout? { bouts.last }
    /// The fight to lead with: the one on now, else the next one, else the
    /// main event.
    var headline: GameStatsBout? { live ?? next ?? mainEvent }
    var finished: Int { bouts.filter { $0.state == "post" }.count }

    var status: String {
        if let live {
            let place = (bouts.firstIndex(of: live) ?? 0) + 1
            return "Fight \(place) of \(bouts.count) \u{00B7} R\(max(live.round, 1))"
        }
        if bouts.allSatisfy({ $0.state == "post" }), !bouts.isEmpty { return "Final" }
        if finished > 0 { return "\(finished) of \(bouts.count) fights done" }
        return ""
    }
}

// MARK: - A race

struct GameStatsRaceBoard: Equatable, Sendable {
    struct Entrant: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let shortName: String
        let flag: String?
        let position: Int
    }

    /// "Race", "Qualifying", "Practice 1".
    let session: String
    /// A race rather than practice or qualifying: laps and a winner.
    let isRace: Bool
    let lap: Int?
    let state: String
    let detail: String
    /// By position.
    let entrants: [Entrant]

    var leader: Entrant? { entrants.first }

    var status: String {
        switch state {
        case "in": return isRace ? (lap.map { "Lap \($0)" } ?? "Under way") : "\(session) \u{00B7} Live"
        case "post": return detail.isEmpty ? "Final" : detail
        default: return detail
        }
    }
}

// MARK: - Reading ESPN's scoreboards

enum GameStatsBoardParser {
    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) ?? Double(text).map { Int($0) } }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// Scoreboards write their times to the minute, "2026-10-19T02:35Z",
    /// which an internet-date reader alone turns down.
    private static let minutes: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mmX"
        return formatter
    }()

    static func date(_ value: Any?) -> Date? {
        GameStatsParser.date(value) ?? (value as? String).flatMap { minutes.date(from: $0) }
    }

    private static func events(_ data: Data) -> [[String: Any]]? {
        guard data.count <= 12_000_000,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root["events"] as? [[String: Any]]
    }

    private static func status(_ value: Any?) -> (state: String, detail: String, period: Int, clock: String?) {
        let status = value as? [String: Any] ?? [:]
        let type = status["type"] as? [String: Any] ?? [:]
        return (string(type["state"]) ?? "pre",
                string(type["shortDetail"]) ?? string(type["detail"]) ?? string(type["description"]) ?? "",
                int(status["period"]) ?? 0,
                string(status["displayClock"]))
    }

    /// A player, fighter or driver as a side: their surname where a team's
    /// code would go, their flag where its logo would.
    private static func athlete(_ competitor: [String: Any]) -> GameStatsTeam? {
        guard let athlete = competitor["athlete"] as? [String: Any],
              let name = string(athlete["displayName"]) ?? string(athlete["fullName"]) else { return nil }
        let short = string(athlete["shortName"])
        var surname = name.split(separator: " ").last.map(String.init) ?? name
        // "J. Sinner" is "SINNER"; "A. de Minaur" is "DE MINAUR".
        if let short, let space = short.firstIndex(of: " "), short[..<space].hasSuffix(".") {
            surname = String(short[short.index(after: space)...])
        }
        return GameStatsTeam(id: string(competitor["id"]) ?? name, abbreviation: surname, name: name,
                             logo: string((athlete["flag"] as? [String: Any])?["href"]), color: nil)
    }

    private static func known(_ team: GameStatsTeam) -> Bool {
        !["TBD", "TBA", "BYE"].contains(team.name.uppercased())
    }

    // MARK: Tennis

    /// The draw the viewer opened: one match of it, or the whole tournament.
    /// `tour` is "atp" or "wta": a major is on both scoreboards with both
    /// draws in it, and each tour has its own.
    static func tennis(_ data: Data, tour: String, match: String?, tournament: String?,
                       receivedAt: Date) -> GameStatsBoard? {
        guard let events = events(data) else { return nil }
        let women = tour == "wta"
        for event in events {
            let groups: [(slug: String?, competitions: [[String: Any]])] =
                (event["groupings"] as? [[String: Any]] ?? []).map {
                    (string(($0["grouping"] as? [String: Any])?["slug"]), $0["competitions"] as? [[String: Any]] ?? [])
                } + [(nil, event["competitions"] as? [[String: Any]] ?? [])]
            let all = groups.flatMap { group in group.competitions.map { (group.slug, $0) } }
            if let match, !all.contains(where: { string($0.1["id"]) == match }) { continue }
            if match == nil, let tournament, string(event["id"]) != tournament { continue }

            var matches: [GameStatsTennisMatch] = []
            for (slug, competition) in all {
                let kind = (string((competition["type"] as? [String: Any])?["slug"]) ?? slug ?? "").lowercased()
                // "womens-singles" holds "mens-singles", so women first. The
                // match opened is kept whichever draw it is filed in.
                let ownTour = kind.contains("women") == women || !kind.contains("men")
                guard kind.contains("singles"), ownTour || string(competition["id"]) == match else { continue }
                if let parsed = tennisMatch(competition) { matches.append(parsed) }
            }
            // The day's tennis: what is on, what has just finished, and
            // what is coming up next. The rest of the fortnight is not.
            let day: TimeInterval = 18 * 60 * 60
            matches = matches.filter { found in
                if found.id == match { return true }
                switch found.state {
                case "in": return true
                case "post": return found.start.map { receivedAt.timeIntervalSince($0) < day } ?? false
                default:
                    return known(found.away) && known(found.home)
                        && (found.start.map { $0.timeIntervalSince(receivedAt) < day } ?? false)
                }
            }
            return .tennis(GameStatsTennisBoard(tournament: string(event["name"]) ?? "", focus: match,
                                                matches: matches.sorted { ($0.start ?? .distantFuture, $0.id) < ($1.start ?? .distantFuture, $1.id) }))
        }
        return nil
    }

    private static func tennisMatch(_ competition: [String: Any]) -> GameStatsTennisMatch? {
        guard let id = string(competition["id"]) else { return nil }
        let round = string((competition["round"] as? [String: Any])?["displayName"]) ?? ""
        guard !round.lowercased().contains("qualif") else { return nil }
        // The schedule lists the players by ESPN's order, and so does this.
        let players = (competition["competitors"] as? [[String: Any]] ?? []).sorted { (int($0["order"]) ?? 9) < (int($1["order"]) ?? 9) }
        guard players.count == 2, let away = athlete(players[0]), let home = athlete(players[1]) else { return nil }
        let status = status(competition["status"])
        let awayLines = players[0]["linescores"] as? [[String: Any]] ?? []
        let homeLines = players[1]["linescores"] as? [[String: Any]] ?? []
        let sets = zip(awayLines, homeLines).map { awaySet, homeSet in
            let awayGames = int(awaySet["value"]) ?? 0, homeGames = int(homeSet["value"]) ?? 0
            var winner: GameStatsSide? = (awaySet["winner"] as? Bool) == true ? .away
                : ((homeSet["winner"] as? Bool) == true ? .home : nil)
            // The mark can trail the games by a refresh: a set the games
            // have settled -- six with a two-game lead, or seven -- is over.
            if winner == nil { winner = settled(awayGames, homeGames) }
            return GameStatsTennisMatch.SetScore(away: awayGames, home: homeGames,
                                                 awayTiebreak: int(awaySet["tiebreak"]), homeTiebreak: int(homeSet["tiebreak"]),
                                                 winner: winner)
        }
        let serving: GameStatsSide? = (players[0]["possession"] as? Bool) == true ? .away
            : ((players[1]["possession"] as? Bool) == true ? .home : nil)
        let winner: GameStatsSide? = (players[0]["winner"] as? Bool) == true ? .away
            : ((players[1]["winner"] as? Bool) == true ? .home : nil)
        let seed = { (competitor: [String: Any]) in int((competitor["curatedRank"] as? [String: Any])?["current"]) }
        let bestOf = int(((competition["format"] as? [String: Any])?["regulation"] as? [String: Any])?["periods"])
        return GameStatsTennisMatch(
            id: id, round: round, court: string((competition["venue"] as? [String: Any])?["court"]),
            away: away, home: home, awaySeed: seed(players[0]), homeSeed: seed(players[1]),
            sets: sets, bestOf: bestOf == 5 ? 5 : 3, serving: status.state == "in" ? serving : nil, state: status.state,
            detail: status.detail, winner: status.state == "post" ? winner : nil,
            start: date(competition["date"]))
    }

    /// Who has taken a set on its games alone, or nil while it is open.
    static func settled(_ away: Int, _ home: Int) -> GameStatsSide? {
        if away == 7 || (away >= 6 && away - home >= 2) { return .away }
        if home == 7 || (home >= 6 && home - away >= 2) { return .home }
        return nil
    }

    // MARK: A fight card

    static func card(_ data: Data, event id: String) -> GameStatsBoard? {
        guard let event = events(data)?.first(where: { string($0["id"]) == id }) else { return nil }
        let competitions = event["competitions"] as? [[String: Any]] ?? []
        let bouts: [GameStatsBout] = competitions.enumerated().compactMap { index, competition in
            guard let boutID = string(competition["id"]) else { return nil }
            // The schedule takes the first fighter listed as the first side.
            let fighters = competition["competitors"] as? [[String: Any]] ?? []
            guard fighters.count == 2, let away = athlete(fighters[0]), let home = athlete(fighters[1]) else { return nil }
            let status = status(competition["status"])
            let moments: [GameStatsBout.Moment] = (competition["details"] as? [[String: Any]] ?? []).compactMap { detail in
                guard let id = string(detail["id"]),
                      let kind = string((detail["type"] as? [String: Any])?["text"]) else { return nil }
                return .init(id: id, kind: kind)
            }.sorted { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }
            let winner: GameStatsSide? = (fighters[0]["winner"] as? Bool) == true ? .away
                : ((fighters[1]["winner"] as? Bool) == true ? .home : nil)
            let record = { (fighter: [String: Any]) in
                string(((fighter["records"] as? [[String: Any]])?.first)?["summary"])
            }
            let rounds = int(((competition["format"] as? [String: Any])?["regulation"] as? [String: Any])?["periods"]) ?? 3
            return GameStatsBout(
                id: boutID, order: int(competition["matchNumber"]).map { -$0 } ?? index,
                weightClass: string((competition["type"] as? [String: Any])?["abbreviation"]) ?? "",
                away: away, home: home, awayRecord: record(fighters[0]), homeRecord: record(fighters[1]),
                state: status.state, round: status.period,
                clock: status.state == "pre" ? nil : status.clock, rounds: rounds,
                winner: status.state == "post" ? winner : nil,
                method: status.state == "post" ? method(moments) : nil,
                moments: moments, start: date(competition["date"]))
        }
        guard !bouts.isEmpty else { return nil }
        // ESPN numbers the main event 1; where it does, the card runs from
        // the highest number down. Where it doesn't, its own order stands.
        return .card(GameStatsFightCard(name: string(event["name"]) ?? "", bouts: bouts.sorted { $0.order < $1.order }))
    }

    /// "Unofficial Winner Kotko" is a knockout; the rest say what they are.
    static func method(_ moments: [GameStatsBout.Moment]) -> String? {
        guard let kind = moments.last(where: { $0.kind.lowercased().hasPrefix("unofficial winner") })?.kind else { return nil }
        let how = kind.dropFirst("unofficial winner".count).trimmingCharacters(in: .whitespaces)
        switch how.lowercased() {
        case "kotko", "ko/tko", "ko", "tko": return "KO/TKO"
        case "": return nil
        default: return how.capitalized
        }
    }

    // MARK: A race

    static func race(_ data: Data, event id: String, session: String, league: String) -> GameStatsBoard? {
        guard let event = events(data)?.first(where: { string($0["id"]) == id }),
              let competition = (event["competitions"] as? [[String: Any]])?.first(where: { string($0["id"]) == session })
        else { return nil }
        let status = status(competition["status"])
        let code = string((competition["type"] as? [String: Any])?["abbreviation"]) ?? ""
        let title = sessionTitle(code, league: league)
        let isRace = title.hasSuffix("Race") || title == "Sprint"
        var entrants: [GameStatsRaceBoard.Entrant] = []
        for (index, entry) in (competition["competitors"] as? [[String: Any]] ?? []).enumerated() {
            guard let driver = athlete(entry) else { continue }
            let athlete = entry["athlete"] as? [String: Any]
            entrants.append(.init(id: driver.id, name: driver.name,
                                  shortName: string(athlete?["shortName"]) ?? driver.name,
                                  flag: driver.logo, position: int(entry["order"]) ?? index + 1))
        }
        // Before the start, ESPN's order is only the entry list.
        if status.state == "pre" { entrants = [] }
        return .race(GameStatsRaceBoard(session: title, isRace: isRace,
                                        lap: status.state == "pre" || status.period == 0 ? nil : status.period,
                                        state: status.state, detail: status.detail,
                                        entrants: entrants.sorted { $0.position < $1.position }))
    }

    static func sessionTitle(_ code: String, league: String) -> String {
        switch code.lowercased() {
        case "fp1", "p1": "Practice 1"
        case "fp2", "p2": "Practice 2"
        case "fp3", "p3": "Practice 3"
        case "qual", "q", "qualifying": "Qualifying"
        case "sq", "ss", "sprint qual", "sprint qualifying", "sprint shootout": "Sprint Qualifying"
        case "sprint", "s", "sr": "Sprint"
        case "race", "r", "": league == "nascar" ? "Cup Series Race" : "Race"
        default: code
        }
    }
}

// MARK: - What changed

/// Plays worked out from two boards, for the window between the fetches
/// that brought them.
enum GameStatsBoardChanges {
    /// A play before it is numbered and placed.
    struct Change: Equatable {
        let id: String
        let text: String
        let period: String
        var clock: String? = nil
        /// What the play's highlight says: "5–4", "KO/TKO", "P1".
        var badge: String? = nil
        var scoring = false
        var away = 0
        var home = 0
        var team: String? = nil
        /// The match or fight it belongs to.
        var group: String? = nil
        /// Where else it needs saying which match or fight it was.
        var context: String? = nil
    }

    static func plays(from old: GameStatsBoard?, to new: GameStatsBoard,
                      between window: ClosedRange<Date>, sequence: Int) -> [GameStatsPlay] {
        changes(from: old, to: new, sequence: sequence).enumerated().map { offset, change in
            var play = GameStatsPlay(id: change.id, sequence: sequence + offset, text: change.text,
                                     period: change.period, clock: change.clock, wallclock: nil,
                                     scoring: change.scoring, awayScore: change.away, homeScore: change.home,
                                     teamID: change.team, drive: change.context)
            play.seen = window
            play.badge = change.badge
            play.group = change.group
            return play
        }
    }

    /// ESPN leaves out who is serving now and then, often just after a
    /// game. The serve changes hands every game, a tiebreak counting as
    /// one, so the last server known says who serves now.
    static func carryingServe(from old: GameStatsBoard?, into new: GameStatsBoard) -> GameStatsBoard {
        guard case .tennis(let before)? = old, case .tennis(var after) = new else { return new }
        let earlier = Dictionary(before.matches.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        after.matches = after.matches.map { match in
            guard match.state == "in", match.serving == nil, let was = earlier[match.id], let server = was.serving
            else { return match }
            let played = match.gamesPlayed - was.gamesPlayed
            guard played >= 0 else { return match }
            var carried = match
            carried.serving = played % 2 == 0 ? server : server.other
            return carried
        }
        return .tennis(after)
    }

    static func changes(from old: GameStatsBoard?, to new: GameStatsBoard, sequence: Int = 0) -> [Change] {
        switch (old, new) {
        case (.tennis(let before)?, .tennis(let after)):
            let earlier = Dictionary(before.matches.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // A tournament's plays say which match; a match's own need not.
            return after.matches.flatMap { match in
                earlier[match.id].map { tennis($0, match, named: after.focus == nil) } ?? []
            }
        case (.card(let before)?, .card(let after)):
            let earlier = Dictionary(before.bouts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return after.bouts.flatMap { bout in earlier[bout.id].map { fight($0, bout) } ?? [] }
        case (.race(let before)?, .race(let after)):
            return race(before, after, sequence: sequence)
        default:
            return []
        }
    }

    static func tennis(_ was: GameStatsTennisMatch, _ now: GameStatsTennisMatch, named: Bool) -> [Change] {
        var found: [Change] = []
        let context = named ? [now.title, now.court].compactMap { $0 }.joined(separator: " \u{00B7} ") : nil
        func name(_ side: GameStatsSide) -> String { (side == .away ? now.away : now.home).abbreviation }
        func team(_ side: GameStatsSide) -> String { (side == .away ? now.away : now.home).id }
        func add(_ id: String, _ text: String, _ period: String, badge: String? = nil, scoring: Bool = false,
                 team: String? = nil) {
            found.append(Change(id: "t\(now.id)-\(id)", text: text, period: period, badge: badge, scoring: scoring,
                                away: now.awaySets, home: now.homeSets, team: team, group: now.id, context: context))
        }
        if was.state == "pre", now.state != "pre" { add("on", "\(now.title) is under way", "Set 1") }
        for (index, set) in now.sets.enumerated() {
            let before = index < was.sets.count ? was.sets[index] : GameStatsTennisMatch.SetScore(away: 0, home: 0)
            let period = "Set \(index + 1)"
            let gained = (away: set.away - before.away, home: set.home - before.home)
            // A tiebreak is told by the set it wins, not as a game.
            let tiebreakWon = before.away == 6 && before.home == 6
            if !tiebreakWon, gained.away >= 0, gained.home >= 0, gained.away + gained.home > 0 {
                // One game: who served it says hold or break. More than one
                // since the last look, and it can't be told which was which.
                let single = gained.away + gained.home == 1
                var games = (away: before.away, home: before.home)
                func game(_ side: GameStatsSide) {
                    if side == .away { games.away += 1 } else { games.home += 1 }
                    let text: String
                    if single, let server = was.serving {
                        text = server == side ? "\(name(side)) holds serve" : "Break of serve \u{2014} \(name(side))"
                    } else {
                        text = "Game, \(name(side))"
                    }
                    add("s\(index)-\(games.away)-\(games.home)", text, period,
                        badge: "\(games.away)\u{2013}\(games.home)", team: team(side))
                }
                for _ in 0..<gained.away { game(.away) }
                for _ in 0..<gained.home { game(.home) }
                if set.away == 6, set.home == 6, set.winner == nil {
                    add("s\(index)-tb", "Tiebreak", period, badge: "6\u{2013}6")
                }
            }
            if before.winner == nil, let winner = set.winner, now.winner == nil {
                add("s\(index)-won", "Set \(index + 1) to \(name(winner))", period,
                    badge: "\(set.away)\u{2013}\(set.home)", scoring: true, team: team(winner))
            }
        }
        if was.winner == nil, let winner = now.winner {
            let loser: GameStatsSide = winner == .away ? .home : .away
            let text = now.retired ? "\(name(loser)) retires \u{2014} \(name(winner)) goes through"
                                   : "Game, set and match \(name(winner))"
            add("won", text, "Final", badge: now.line.isEmpty ? nil : now.line, scoring: true, team: team(winner))
        }
        return found
    }

    static func fight(_ was: GameStatsBout, _ now: GameStatsBout) -> [Change] {
        var found: [Change] = []
        let context = [now.title, now.weightClass].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
        func add(_ id: String, _ text: String, _ period: String, clock: String? = nil, badge: String? = nil,
                 scoring: Bool = false, team: String? = nil) {
            found.append(Change(id: "b\(now.id)-\(id)", text: text, period: period, clock: clock, badge: badge,
                                scoring: scoring, team: team, group: now.id, context: context))
        }
        let round = "R\(max(now.round, 1))"
        if now.state == "in", now.round > 0, was.state == "pre" || now.round > was.round {
            add("r\(now.round)", now.round == 1 ? "\(now.title) is under way" : "Round \(now.round)", "R\(now.round)")
        }
        let seen = Set(was.moments.map(\.id))
        for moment in now.moments where !seen.contains(moment.id) {
            let text: String
            switch moment.kind.lowercased() {
            case "takedown": text = "Takedown"
            case "knockdown": text = "Knockdown"
            case "submission attempt": text = "Submission attempt"
            case "round end": text = "End of round \(max(now.round, 1))"
            case "fight over": text = "The fight is over"
            case "walkout": text = "The fighters walk out"
            default: continue
            }
            add("m\(moment.id)", text, round, clock: now.clock)
        }
        if was.winner == nil, now.state == "post", let side = now.winner,
           let winner = now.winnerName, let loser = now.loserName {
            add("won", "\(winner) defeats \(loser)", round, clock: now.clock, badge: now.method ?? "Final",
                scoring: true, team: (side == .away ? now.away : now.home).id)
        }
        return found
    }

    static func race(_ was: GameStatsRaceBoard, _ now: GameStatsRaceBoard, sequence: Int) -> [Change] {
        var found: [Change] = []
        let period = now.lap.map { "Lap \($0)" } ?? now.session
        if was.state == "pre", now.state == "in" {
            found.append(Change(id: "race-on", text: now.isRace ? "The race is under way" : "\(now.session) is under way",
                                period: period))
        }
        if was.state != "post", now.state == "post", let leader = now.leader {
            let podium = now.entrants.prefix(3).map(\.shortName).joined(separator: ", ")
            found.append(Change(id: "race-won", text: now.isRace ? "\(leader.name) wins" : "\(leader.name) is fastest",
                                period: now.isRace ? "Finish" : now.session, badge: "P1", scoring: true,
                                team: leader.id, context: now.isRace ? "Podium: \(podium)" : nil))
            return found
        }
        guard now.state == "in", !was.entrants.isEmpty, !now.entrants.isEmpty else { return found }
        let earlier = Dictionary(was.entrants.map { ($0.id, $0.position) }, uniquingKeysWith: { first, _ in first })
        if let leader = now.leader, was.leader?.id != leader.id {
            found.append(Change(id: "race-lead-\(sequence)-\(leader.id)", text: "\(leader.name) takes the lead",
                                period: period, badge: "P1", scoring: true, team: leader.id))
        }
        for entrant in now.entrants where (2...3).contains(entrant.position) {
            guard let before = earlier[entrant.id], before > entrant.position else { continue }
            found.append(Change(id: "race-p\(entrant.position)-\(sequence)-\(entrant.id)",
                                text: "\(entrant.name) up to P\(entrant.position)", period: period,
                                badge: "P\(entrant.position)", team: entrant.id))
        }
        return found
    }
}
