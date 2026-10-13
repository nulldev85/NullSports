import Foundation

/// Something in one of the viewer's teams' games worth breaking into the
/// picture for: it has started, it is close at the end, or it has gone to
/// overtime.
struct GameAlert: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case started, closeLate, overtime
    }

    let game: SportsGame
    let kind: Kind

    var id: String { game.id + "|" + kind.rawValue }

    /// What happened, in a few words: "Underway", "Close game", "Overtime".
    var headline: String {
        switch kind {
        case .started: "Underway"
        // Tennis has no clock to run down: what a viewer is told is that one
        // set will settle it, and that one tiebreak will.
        case .closeLate: game.league == .tennis ? "Deciding set" : "Close game"
        case .overtime: game.league == .tennis ? "Final-set tiebreak" : "Overtime"
        }
    }
}

/// When a game is worth an alert, read from the score and the status line
/// the schedule gives -- "Q4 2:31", "4th 1:12", "3rd 08:40", "Bot 9th",
/// "OT 3:12", "2OT", "SO" -- however a league writes it.
enum GameAlertRules {
    /// The game's period and, where there is one, the time left in it.
    struct Moment: Equatable {
        var period: Int?
        var clockSeconds: Int?
        var overtime = false
    }

    static func moment(of status: String) -> Moment {
        let text = status.uppercased()
        var moment = Moment()
        // "OT", "2OT", "OT 3:12", "1ST OT", "SO": past regulation.
        if text.range(of: #"(^|[^A-Z])\d*OT\b"#, options: .regularExpression) != nil
            || text.range(of: #"\bOVERTIME\b"#, options: .regularExpression) != nil
            || text.range(of: #"(^|\s)SO($|\s)"#, options: .regularExpression) != nil {
            moment.overtime = true
        }
        if let match = text.range(of: #"Q(\d)"#, options: .regularExpression) {
            moment.period = Int(text[match].dropFirst())
        } else if let match = text.range(of: #"\b(\d{1,2})(ST|ND|RD|TH)\b"#, options: .regularExpression) {
            moment.period = Int(text[match].prefix { $0.isNumber })
        }
        if let match = text.range(of: #"\b(\d{1,2}):(\d{2})\b"#, options: .regularExpression) {
            let parts = text[match].split(separator: ":")
            if parts.count == 2, let minutes = Int(parts[0]), let seconds = Int(parts[1]) {
                moment.clockSeconds = minutes * 60 + seconds
            }
        }
        return moment
    }

    /// The gap between the two scores, when both are numbers.
    static func margin(of game: SportsGame) -> Int? {
        guard let away = Int(game.awayScore), let home = Int(game.homeScore) else { return nil }
        return abs(away - home)
    }

    /// Past regulation: overtime, a shootout, or extra innings.
    static func isOvertime(_ game: SportsGame) -> Bool {
        guard game.isLive, !game.isEvent else { return false }
        if game.league == .tennis {
            guard let score = game.tennis, score.isDecidingSet, let set = score.current else { return false }
            return set.away >= 6 && set.home >= 6
        }
        let moment = moment(of: game.status)
        if game.league == .mlb { return (moment.period ?? 0) >= 10 }
        return moment.overtime
    }

    /// Late, and within a score or two: the last five minutes of a fourth
    /// quarter within a possession or so, a third period within a goal, the
    /// eighth inning on within two runs.
    static func isCloseLate(_ game: SportsGame) -> Bool {
        guard game.isLive, !game.isEvent else { return false }
        if game.league == .tennis { return game.tennis?.isDecidingSet ?? false }
        guard let margin = margin(of: game) else { return false }
        let moment = moment(of: game.status)
        guard !moment.overtime, let period = moment.period else { return false }
        let late = moment.clockSeconds.map { $0 <= 5 * 60 } ?? false
        switch game.league {
        case .nba: return period >= 4 && late && margin <= 6
        case .nfl, .ncaaf: return period >= 4 && late && margin <= 8
        case .nhl: return period >= 3 && (moment.clockSeconds.map { $0 <= 10 * 60 } ?? false) && margin <= 1
        case .mlb: return period >= 8 && margin <= 2
        case .ufc, .tennis: return false
        }
    }

    /// What has happened in a game since it was last seen, most important
    /// first. A game seen for the first time says nothing: it was already
    /// whatever it is before anyone was watching for it.
    static func alerts(from previous: SportsGame?, to current: SportsGame) -> [GameAlert.Kind] {
        guard let previous else { return [] }
        var kinds: [GameAlert.Kind] = []
        if isOvertime(current) && !isOvertime(previous) { kinds.append(.overtime) }
        if isCloseLate(current) && !isCloseLate(previous) { kinds.append(.closeLate) }
        if current.isLive && current.state == "in" && previous.state == "pre" { kinds.append(.started) }
        return kinds
    }
}

/// Watches the viewer's teams' games as the schedule refreshes, and holds
/// the latest alert for a player to show over the picture.
///
/// Each kind of alert is given once a game: a close game that swings back
/// and forth is announced the first time it is close, not every time.
@MainActor
final class GameAlertCenter: ObservableObject {
    static let shared = GameAlertCenter()

    /// The alert to show, until it is dismissed or times out.
    @Published private(set) var current: GameAlert?

    private var lastSeen: [String: SportsGame] = [:]
    private var announced: Set<String> = []
    private var expiry: Task<Void, Never>?

    /// How long an alert stays up.
    static let showsFor: Duration = .seconds(12)

    /// Every game the schedule holds, after a refresh. Only the viewer's
    /// teams' games are watched.
    func observe(_ games: [SportsGame], isFollowing: (SportsGame) -> Bool) {
        var seen: [String: SportsGame] = [:]
        var fresh: [GameAlert] = []
        for game in games where isFollowing(game) {
            seen[game.id] = game
            for kind in GameAlertRules.alerts(from: lastSeen[game.id], to: game) {
                let alert = GameAlert(game: game, kind: kind)
                if announced.insert(alert.id).inserted { fresh.append(alert) }
            }
        }
        lastSeen = seen
        // The most important of what just happened, if anything did.
        guard let alert = fresh.first else {
            // A shown alert keeps its game's latest score.
            if let current, let updated = seen[current.game.id], updated != current.game {
                self.current = GameAlert(game: updated, kind: current.kind)
            }
            return
        }
        show(alert)
    }

    func dismiss() {
        expiry?.cancel()
        current = nil
    }

    private func show(_ alert: GameAlert) {
        current = alert
        expiry?.cancel()
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: Self.showsFor) } catch { return }
            guard let self, self.current?.id == alert.id else { return }
            self.current = nil
        }
    }
}
