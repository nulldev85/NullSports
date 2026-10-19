import Foundation

// A live game's own feed from ESPN -- its plays as they happen, each with the
// moment it happened, its box score, its leaders and its win probability --
// and the rule that keeps all of it behind the picture.
//
// The picture is behind the game: a provider's stream trails the broadcast,
// which trails the field. ESPN is behind the game too, by less. Shown as it
// arrives, the feed would tell the viewer what is about to happen on their
// screen. So nothing here is shown when it arrives: everything is held until
// the moment the viewer's picture reaches it, and only then revealed.
//
// Foundation only, so the checks in Tests/ can compile it on its own.

/// What the feed needs to know about the game: where ESPN files it.
struct GameStatsTarget: Hashable, Sendable {
    let sport: String
    let league: String
    let eventID: String

    var summaryURL: URL {
        var parts = URLComponents(string: "https://site.api.espn.com/apis/site/v2/sports/\(sport)/\(league)/summary")!
        parts.queryItems = [URLQueryItem(name: "event", value: eventID)]
        return parts.url!
    }
}

struct GameStatsTeam: Equatable, Sendable {
    let id: String
    let abbreviation: String
    let name: String
    let logo: String?
    let color: String?
}

/// One play, with the moment it happened on the field.
struct GameStatsPlay: Identifiable, Equatable, Sendable {
    let id: String
    let sequence: Int
    let text: String
    /// "Q3", "2nd", "Top 7th".
    let period: String
    let clock: String?
    /// When it happened, by ESPN's account. Nil where ESPN doesn't say.
    let wallclock: Date?
    let scoring: Bool
    let awayScore: Int
    let homeScore: Int
    /// The team it belongs to, for its colour.
    let teamID: String?
    /// Football: the drive it was part of, "8 plays, 75 yards, 4:12".
    let drive: String?
}

/// A team total, the away side's and the home side's.
struct GameStatsLine: Equatable, Sendable {
    let label: String
    let away: String
    let home: String
}

struct GameStatsLeader: Equatable, Sendable {
    let category: String
    let athlete: String
    let teamID: String
    let value: String
}

/// The game as one fetch found it: its score, its clock and its totals.
struct GameStatsSnapshot: Equatable, Sendable {
    /// When the fetch came back.
    let receivedAt: Date
    /// "pre", "in" or "post".
    let state: String
    let period: Int
    /// ESPN's own short status: "4:52 - 1st", "Final".
    let status: String
    let clock: String?
    let awayScore: Int
    let homeScore: Int
    let lines: [GameStatsLine]
    let leaders: [GameStatsLeader]
    /// The moment on the field these totals stand for: the latest play the
    /// same fetch carried. Set as the fetch is taken in.
    var eventTime: Date? = nil
    /// When these totals may be shown, at a stream with no delay.
    var moment: Date { eventTime ?? receivedAt }
}

/// One fetch, parsed.
struct GameStatsReport: Sendable {
    let away: GameStatsTeam
    let home: GameStatsTeam
    let snapshot: GameStatsSnapshot
    let plays: [GameStatsPlay]
    /// Home's chance of winning after a play, by play.
    let winProbability: [String: Double]
}

// MARK: - Reading ESPN's summary

enum GameStatsParser {
    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let iso = ISO8601DateFormatter()

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return iso.date(from: text) ?? isoWithFraction.date(from: text)
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
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

    /// Nil unless both teams and the status are there: a reply that can't say
    /// who is playing says nothing worth showing.
    static func parse(_ data: Data, sport: String, receivedAt: Date) -> GameStatsReport? {
        guard data.count <= 8_000_000,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = root["header"] as? [String: Any],
              let competition = (header["competitions"] as? [[String: Any]])?.first,
              let competitors = competition["competitors"] as? [[String: Any]],
              let status = competition["status"] as? [String: Any] else { return nil }

        var away: (team: GameStatsTeam, score: Int)?
        var home: (team: GameStatsTeam, score: Int)?
        for competitor in competitors {
            guard let team = competitor["team"] as? [String: Any], let id = string(team["id"]) else { continue }
            let logo = string(team["logo"])
                ?? ((team["logos"] as? [[String: Any]])?.first.flatMap { string($0["href"]) })
            let parsed = GameStatsTeam(id: id,
                                       abbreviation: string(team["abbreviation"]) ?? "",
                                       name: string(team["displayName"]) ?? string(team["name"]) ?? "",
                                       logo: logo, color: string(team["color"]))
            let score = int(competitor["score"]) ?? 0
            if string(competitor["homeAway"]) == "home" { home = (parsed, score) } else { away = (parsed, score) }
        }
        guard let away, let home else { return nil }

        let type = status["type"] as? [String: Any]
        let snapshot = GameStatsSnapshot(
            receivedAt: receivedAt,
            state: string(type?["state"]) ?? "pre",
            period: int(status["period"]) ?? 0,
            status: string(type?["shortDetail"]) ?? string(type?["detail"]) ?? "",
            clock: string(status["displayClock"]),
            awayScore: away.score, homeScore: home.score,
            lines: lines(root["boxscore"] as? [String: Any], sport: sport, away: away.team.id, home: home.team.id),
            leaders: leaders(root["leaders"] as? [[String: Any]]))

        var probability: [String: Double] = [:]
        for entry in root["winprobability"] as? [[String: Any]] ?? [] {
            guard let play = string(entry["playId"]),
                  let value = (entry["homeWinPercentage"] as? NSNumber)?.doubleValue,
                  value.isFinite, value >= 0, value <= 1 else { continue }
            probability[play] = value
        }

        return GameStatsReport(away: away.team, home: home.team, snapshot: snapshot,
                               plays: plays(root, sport: sport), winProbability: probability)
    }

    /// Team totals, side by side. Baseball files its totals in groups with
    /// no labels of their own, so a few are picked out and named.
    private static func lines(_ box: [String: Any]?, sport: String, away: String, home: String) -> [GameStatsLine] {
        guard let teams = box?["teams"] as? [[String: Any]] else { return [] }
        func totals(_ id: String) -> [(label: String, value: String)] {
            guard let entry = teams.first(where: { string(($0["team"] as? [String: Any])?["id"]) == id }),
                  let statistics = entry["statistics"] as? [[String: Any]] else { return [] }
            if sport == "baseball" {
                let wanted: [(group: String, name: String, label: String)] = [
                    ("batting", "hits", "Hits"), ("batting", "homeRuns", "Home Runs"),
                    ("batting", "RBIs", "RBI"), ("batting", "walks", "Walks"),
                    ("batting", "strikeouts", "Strikeouts"), ("fielding", "errors", "Errors"),
                    ("pitching", "pitches", "Pitches")]
                return wanted.compactMap { want in
                    guard let group = statistics.first(where: { string($0["name"]) == want.group }),
                          let stat = (group["stats"] as? [[String: Any]])?.first(where: { string($0["name"]) == want.name }),
                          let value = string(stat["displayValue"]) else { return nil }
                    return (want.label, value)
                }
            }
            return statistics.compactMap { stat in
                guard let label = string(stat["label"]) ?? string(stat["displayName"]),
                      let value = string(stat["displayValue"]) else { return nil }
                return (label, value)
            }
        }
        let awayTotals = totals(away)
        let homeTotals = Dictionary(totals(home).map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
        return awayTotals.compactMap { total in
            homeTotals[total.label].map { GameStatsLine(label: total.label, away: total.value, home: $0) }
        }
    }

    private static func leaders(_ teams: [[String: Any]]?) -> [GameStatsLeader] {
        var found: [GameStatsLeader] = []
        for team in teams ?? [] {
            guard let teamID = string((team["team"] as? [String: Any])?["id"]) else { continue }
            for category in team["leaders"] as? [[String: Any]] ?? [] {
                guard let name = string(category["displayName"]),
                      let top = (category["leaders"] as? [[String: Any]])?.first,
                      let athlete = top["athlete"] as? [String: Any],
                      let who = string(athlete["shortName"]) ?? string(athlete["displayName"]),
                      let value = string(top["displayValue"]) else { continue }
                found.append(GameStatsLeader(category: name, athlete: who, teamID: teamID, value: value))
            }
        }
        return found
    }

    static func periodLabel(sport: String, number: Int, half: String?) -> String {
        guard number > 0 else { return "" }
        func ordinal(_ n: Int) -> String {
            switch n % 100 {
            case 11, 12, 13: return "\(n)th"
            default:
                switch n % 10 {
                case 1: return "\(n)st"
                case 2: return "\(n)nd"
                case 3: return "\(n)rd"
                default: return "\(n)th"
                }
            }
        }
        switch sport {
        case "football", "basketball": return number > 4 ? (number == 5 ? "OT" : "\(number - 4)OT") : "Q\(number)"
        case "hockey": return number > 3 ? (number == 4 ? "OT" : "SO") : ordinal(number)
        case "baseball":
            let side = half?.lowercased()
            let prefix = side == "top" ? "Top " : side == "bottom" ? "Bot " : side == "end" ? "End " : side == "middle" ? "Mid " : ""
            return prefix + ordinal(number)
        default: return ordinal(number)
        }
    }

    /// Every play, oldest first. Football's sit inside its drives; baseball's
    /// are pitch by pitch, of which only each at-bat's outcome is kept.
    private static func plays(_ root: [String: Any], sport: String) -> [GameStatsPlay] {
        var result: [GameStatsPlay] = []
        func play(_ raw: [String: Any], team fallbackTeam: String? = nil, drive: String? = nil) -> GameStatsPlay? {
            guard let id = string(raw["id"]), let text = string(raw["text"]) else { return nil }
            let period = raw["period"] as? [String: Any]
            let clock = (raw["clock"] as? [String: Any]).flatMap { string($0["displayValue"]) }
            return GameStatsPlay(
                id: id,
                sequence: int(raw["sequenceNumber"]) ?? Int(id.suffix(9)) ?? 0,
                text: text,
                period: periodLabel(sport: sport, number: int(period?["number"]) ?? 0, half: string(period?["type"])),
                clock: sport == "baseball" ? nil : clock,
                wallclock: date(raw["wallclock"]),
                scoring: raw["scoringPlay"] as? Bool ?? false,
                awayScore: int(raw["awayScore"]) ?? 0,
                homeScore: int(raw["homeScore"]) ?? 0,
                teamID: string((raw["team"] as? [String: Any])?["id"]) ?? fallbackTeam,
                drive: drive)
        }
        if let drives = root["drives"] as? [String: Any] {
            var all = drives["previous"] as? [[String: Any]] ?? []
            if let current = drives["current"] as? [String: Any] { all.append(current) }
            var seen = Set<String>()
            for drive in all {
                let team = string((drive["team"] as? [String: Any])?["id"])
                let description = string(drive["description"])
                for raw in drive["plays"] as? [[String: Any]] ?? [] {
                    guard let parsed = play(raw, team: team, drive: description), seen.insert(parsed.id).inserted else { continue }
                    result.append(parsed)
                }
            }
        } else {
            for raw in root["plays"] as? [[String: Any]] ?? [] {
                if sport == "baseball" {
                    let kind = string((raw["type"] as? [String: Any])?["type"]) ?? ""
                    let scoring = raw["scoringPlay"] as? Bool ?? false
                    guard scoring || ["play-result", "end-inning", "stolen-base"].contains(kind) else { continue }
                }
                if sport == "basketball",
                   (string((raw["type"] as? [String: Any])?["text"]) ?? "").lowercased().contains("substitution") { continue }
                if let parsed = play(raw) { result.append(parsed) }
            }
        }
        return result.sorted { $0.sequence < $1.sequence }
    }
}

// MARK: - Holding it back

/// What the viewer's picture has reached, and so what may be shown.
struct GameStatsReveal: Equatable, Sendable {
    var away: GameStatsTeam
    var home: GameStatsTeam
    var awayScore: Int
    var homeScore: Int
    var state: String
    var status: String
    /// Newest first.
    var plays: [GameStatsPlay]
    var lines: [GameStatsLine]
    var leaders: [GameStatsLeader]
    var homeWinProbability: Double?
    /// No totals the picture has reached yet: every one fetched so far is
    /// still ahead of it.
    var catchingUp: Bool
}

/// Everything the feed has said, each held to the moment on the field it
/// describes.
///
/// A play happened when ESPN says it did. The viewer's picture shows it
/// that long after, by however far the stream is behind live; so a play is
/// shown once now, less that delay, has passed the moment it happened.
/// Totals go with the plays they arrived with: a fetch's box score stands
/// for the moment of the latest play in the same fetch, and is shown when
/// that play is.
///
/// One delay for everything, in real seconds behind live, is what makes
/// syncing a single tap: the viewer says which play is on their screen
/// now, and the delay is how long ago that play happened.
struct GameStatsTimeline: Sendable {
    /// Long enough to reach back across a long pause.
    static let retention: TimeInterval = 3 * 60 * 60

    private(set) var away: GameStatsTeam?
    private(set) var home: GameStatsTeam?
    private(set) var snapshots: [GameStatsSnapshot] = []
    private var plays: [String: (play: GameStatsPlay, firstSeen: Date)] = [:]
    private var winProbability: [String: Double] = [:]

    var isEmpty: Bool { snapshots.isEmpty }

    mutating func ingest(_ report: GameStatsReport) {
        away = report.away
        home = report.home
        let received = report.snapshot.receivedAt
        if let last = snapshots.last, last.receivedAt >= received {
            // Out of order: a slow reply overtaken by a faster one.
        } else {
            var snapshot = report.snapshot
            let latest = report.plays.compactMap(\.wallclock).filter { $0 <= received }.max()
            // Never earlier than the totals before it: the plays it carried
            // can't take the game backwards.
            snapshot.eventTime = max(latest ?? received, snapshots.last?.moment ?? .distantPast)
            snapshots.append(snapshot)
        }
        for play in report.plays {
            if let known = plays[play.id] {
                // ESPN corrects a play's text after the fact; it keeps the
                // moment it was first seen.
                plays[play.id] = (play, known.firstSeen)
            } else {
                plays[play.id] = (play, received)
            }
        }
        winProbability.merge(report.winProbability) { _, new in new }
        let oldest = received.addingTimeInterval(-Self.retention)
        if let first = snapshots.first, first.receivedAt < oldest {
            snapshots.removeAll { $0.receivedAt < oldest }
        }
    }

    /// When a play happened: ESPN's own time for it, or when it first came,
    /// which is never before it happened.
    static func moment(of play: GameStatsPlay, firstSeen: Date) -> Date {
        play.wallclock ?? firstSeen
    }

    /// The game as of `cutoff`: now, less however far the picture is behind
    /// live.
    func reveal(at cutoff: Date) -> GameStatsReveal? {
        guard let away, let home else { return nil }
        let snapshot = snapshots.last { $0.moment <= cutoff }
        let shown = plays.values
            .filter { Self.moment(of: $0.play, firstSeen: $0.firstSeen) <= cutoff }
            .map { $0.play }
            .sorted { $0.sequence > $1.sequence }
        let lastPlay = shown.first
        let probability = shown.lazy.compactMap { winProbability[$0.id] }.first
        var status = snapshot?.status ?? ""
        if snapshot == nil, let lastPlay {
            status = [lastPlay.period, lastPlay.clock].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return GameStatsReveal(
            away: away, home: home,
            awayScore: max(snapshot?.awayScore ?? 0, lastPlay?.awayScore ?? 0),
            homeScore: max(snapshot?.homeScore ?? 0, lastPlay?.homeScore ?? 0),
            state: snapshot?.state ?? (lastPlay == nil ? "pre" : "in"),
            status: status,
            plays: shown,
            lines: snapshot?.lines ?? [],
            leaders: snapshot?.leaders ?? [],
            homeWinProbability: probability,
            catchingUp: snapshot == nil)
    }

    /// Plays ESPN gives a moment for, oldest first: what syncing steps
    /// through.
    var timedPlays: [GameStatsPlay] {
        plays.values.map { $0.play }.filter { $0.wallclock != nil }
            .sorted { ($0.wallclock!, $0.sequence) < ($1.wallclock!, $1.sequence) }
    }

    /// The latest play the picture has reached.
    func latestTimedPlay(at cutoff: Date) -> GameStatsPlay? {
        timedPlays.last { $0.wallclock! <= cutoff }
    }

    /// The play after this one, if ESPN has it yet.
    func timedPlay(after play: GameStatsPlay) -> GameStatsPlay? {
        let all = timedPlays
        guard let index = all.firstIndex(where: { $0.id == play.id }), index + 1 < all.count else { return nil }
        return all[index + 1]
    }

    /// The delay that puts the picture at this play now: how long ago it
    /// happened. Nil for a play ESPN gives no moment for.
    static func delay(syncingTo play: GameStatsPlay, now: Date) -> TimeInterval? {
        play.wallclock.map { max(0, now.timeIntervalSince($0)) }
    }
}

/// How far the viewer's picture is behind live, as the viewer has set it,
/// for each channel: providers differ, and a channel's lag stays put.
struct GameStatsDelayStore {
    // Version 2 counts from the moment on the field; version 1 counted from
    // when ESPN sent it, and its values mean something else.
    static let key = "Lineup.stats.streamDelay.v2"
    static let lastKey = "Lineup.stats.streamDelay.last.v2"
    /// Unset: long enough that a typical provider's stream is not overtaken.
    static let defaultDelay: TimeInterval = 60
    static let range: ClosedRange<TimeInterval> = 0...600

    let defaults: UserDefaults

    func delay(forChannel id: Int?) -> (seconds: TimeInterval, calibrated: Bool) {
        let saved = defaults.dictionary(forKey: Self.key) as? [String: Double] ?? [:]
        if let id, let value = saved[String(id)] { return (value, true) }
        // Another channel set by hand is a better guess than none: the same
        // provider sends them all.
        if let last = defaults.object(forKey: Self.lastKey) as? Double { return (last, false) }
        return (Self.defaultDelay, false)
    }

    func set(_ seconds: TimeInterval, forChannel id: Int?) {
        let value = min(Self.range.upperBound, max(Self.range.lowerBound, seconds.rounded()))
        if let id {
            var saved = defaults.dictionary(forKey: Self.key) as? [String: Double] ?? [:]
            saved[String(id)] = value
            if saved.count > 400 { saved = [String(id): value] }
            defaults.set(saved, forKey: Self.key)
        }
        defaults.set(value, forKey: Self.lastKey)
    }

    func reset(forChannel id: Int?) {
        guard let id else { return }
        var saved = defaults.dictionary(forKey: Self.key) as? [String: Double] ?? [:]
        saved[String(id)] = nil
        defaults.set(saved, forKey: Self.key)
    }
}
