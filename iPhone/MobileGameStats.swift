import Foundation

/// Where ESPN keeps a game's live account.
enum GameStatsSource: Equatable, Sendable {
    /// The game's own summary: its plays, box score and leaders.
    case summary(sport: String, league: String)
    /// A tennis draw: one match of it, or the whole tournament.
    case tennis(tour: String, match: String?, tournament: String?)
    /// A fight night.
    case card(event: String)
    /// One session of a race weekend.
    case race(path: String, event: String, session: String)

    var isBoard: Bool { if case .summary = self { return false } else { return true } }
}

extension SportsGame {
    var statsSource: GameStatsSource? {
        guard !isNFLRedZone else { return nil }
        let raw = id.hasPrefix(league.rawValue + "-") ? String(id.dropFirst(league.rawValue.count + 1)) : id
        switch league {
        case .nfl: return .summary(sport: "football", league: "nfl")
        case .ncaaf: return .summary(sport: "football", league: "college-football")
        case .nba: return .summary(sport: "basketball", league: "nba")
        case .nhl: return .summary(sport: "hockey", league: "nhl")
        case .mlb: return .summary(sport: "baseball", league: "mlb")
        // ESPN files a match under its competition: "eng.1", "uefa.champions".
        case .soccer: return competition.map { GameStatsSource.summary(sport: "soccer", league: $0.id) }
        case .atp, .wta:
            // "tennis-185568" is a match; "tennis-event-345-2026-wta" the
            // tournament it is part of.
            if id.hasPrefix("tennis-event-") {
                let event = id.dropFirst("tennis-event-".count).dropLast(league.rawValue.count + 1)
                return event.isEmpty ? nil : GameStatsSource.tennis(tour: league.rawValue, match: nil, tournament: String(event))
            }
            guard id.hasPrefix("tennis-") else { return nil }
            return .tennis(tour: league.rawValue, match: String(id.dropFirst("tennis-".count)), tournament: nil)
        case .ufc: return raw.isEmpty || raw == id ? nil : GameStatsSource.card(event: raw)
        case .f1, .nascar:
            let parts = raw.split(separator: "-").map(String.init)
            guard raw != id, parts.count == 2 else { return nil }
            return .race(path: league == .f1 ? "f1" : "nascar-premier", event: parts[0], session: parts[1])
        }
    }
}

/// The stats for the game being watched, kept behind the picture.
///
/// It follows one game at a time, the one on screen. It fetches the game's
/// feed every few seconds from when the game is opened, whether or not the
/// stats are showing, so the history the picture needs is there when they
/// are opened. Each second it works out how far the picture has reached and
/// publishes only that.
@MainActor
final class MobileGameStats: ObservableObject {
    /// What may be shown now. Nil until the feed has answered.
    @Published private(set) var reveal: GameStatsReveal?
    /// How far the viewer's picture is behind ESPN on this channel, before
    /// any pause or rewind of their own.
    @Published private(set) var delay: TimeInterval = GameStatsDelayStore.defaultDelay
    /// The viewer has set the delay for this channel, rather than it being
    /// the default or another channel's.
    @Published private(set) var calibrated = false
    /// ESPN has no feed for this game, or the game could not be found in it.
    @Published private(set) var unavailable = false

    /// The game being followed.
    private(set) var game: SportsGame?
    private var channelID: Int?
    private var timeline = GameStatsTimeline()
    private var target: GameStatsTarget?
    private var poll: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private let store = GameStatsDelayStore(defaults: .standard)
    private let session: URLSession

    /// The picture's own distance behind live: a pause on a live channel, or
    /// a channel's recording played behind the broadcast. Read every second.
    var playerLag: () -> TimeInterval = { 0 }

    init(session: URLSession = .shared) { self.session = session }

    /// On a tennis tournament, the match the viewer says is on their
    /// screen: the one its plays and syncing keep to.
    @Published var focus: String?

    static func supports(_ game: SportsGame?) -> Bool { game?.statsSource != nil }

    /// What syncing keeps to: the match on screen, on a tournament of
    /// several -- the one picked, or the only one on.
    private var syncGroup: String? {
        guard case .tennis(_, nil, _)? = source else { return nil }
        if let focus { return focus }
        if case .tennis(let draw)? = reveal?.board, draw.live.count == 1 { return draw.live[0].id }
        return nil
    }
    private var source: GameStatsSource? { game?.statsSource }

    /// All the picture's lag behind ESPN, the viewer's pauses included.
    var totalDelay: TimeInterval { delay + max(0, playerLag()) }
    private var cutoff: Date { Date().addingTimeInterval(-totalDelay) }

    /// Follows the game on screen, on the channel it is on. The same game on
    /// another channel keeps what it has learned, under that channel's delay.
    func follow(_ game: SportsGame?, channelID: Int?) {
        let sameGame = game?.id == self.game?.id
        guard !sameGame || channelID != self.channelID else { return }
        self.channelID = channelID
        let saved = store.delay(forChannel: channelID)
        delay = saved.seconds
        calibrated = saved.calibrated
        guard !sameGame else { refreshReveal(); return }
        stopFeed()
        self.game = game
        guard let game, Self.supports(game) else { return }
        start(game)
    }

    func stop() {
        stopFeed()
        game = nil
        channelID = nil
    }

    private func stopFeed() {
        poll?.cancel(); poll = nil
        ticker?.cancel(); ticker = nil
        timeline = GameStatsTimeline()
        target = nil
        reveal = nil
        unavailable = false
        focus = nil
    }

    // MARK: Matching the stream

    func nudge(by seconds: TimeInterval) { setDelay(delay + seconds) }

    func setDelay(_ seconds: TimeInterval) {
        store.set(seconds, forChannel: channelID)
        delay = store.delay(forChannel: channelID).seconds
        calibrated = channelID != nil
        refreshReveal()
    }

    func resetDelay() {
        store.reset(forChannel: channelID)
        let saved = store.delay(forChannel: channelID)
        delay = saved.seconds
        calibrated = saved.calibrated
        refreshReveal()
    }

    /// The latest play the picture has reached: the one to ask the viewer
    /// about. Nil before ESPN has timed any play.
    var latestShownPlay: GameStatsPlay? { timeline.latestTimedPlay(at: cutoff, in: syncGroup) }

    /// The play after this one, if ESPN has it yet.
    func play(after play: GameStatsPlay) -> GameStatsPlay? { timeline.timedPlay(after: play, in: syncGroup) }

    /// A tournament with more than one match on and none picked yet: the
    /// viewer has to say which is on their screen before it can be synced.
    var needsFocus: Bool {
        guard case .tennis(_, nil, _)? = source, focus == nil,
              case .tennis(let draw)? = reveal?.board else { return false }
        return draw.live.count > 1
    }

    /// This play is on the viewer's screen now: the delay is how long ago it
    /// happened, less their own pauses. Exact to the second.
    func sync(to play: GameStatsPlay) {
        guard let seconds = GameStatsTimeline.delay(syncingTo: play, now: Date()) else { return }
        // On a tournament, a match's play on screen says which match is.
        if case .tennis(_, nil, _)? = source, let group = play.group { focus = group }
        setDelay(seconds - max(0, playerLag()))
    }

    /// This play isn't on the viewer's screen yet: held back until a moment
    /// after it, so it waits for them to say it is.
    func hold(before play: GameStatsPlay) {
        guard let seconds = GameStatsTimeline.delay(syncingTo: play, now: Date()) else { return }
        setDelay(seconds - max(0, playerLag()) + 3)
    }

    // MARK: Feed

    private func start(_ game: SportsGame) {
        guard let source = game.statsSource else { return }
        if case .tennis(_, let match?, _) = source { focus = match }
        poll = Task { [weak self] in
            guard let self else { return }
            if source.isBoard {
                await self.followBoard(source)
                return
            }
            guard let target = await self.resolve(game) else {
                if !Task.isCancelled { self.unavailable = true }
                return
            }
            self.target = target
            while !Task.isCancelled {
                await self.fetch(target)
                // A game on now every ten seconds -- ESPN's own refresh is
                // five -- and one not yet started or finished once a minute.
                let live = self.timeline.snapshots.last?.state == "in" || (self.game?.isLive ?? false)
                do { try await Task.sleep(for: .seconds(live ? 10 : 60)) } catch { return }
            }
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshReveal()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func refreshReveal() {
        let next = timeline.reveal(at: cutoff)
        if next != reveal { reveal = next }
    }

    private func fetch(_ target: GameStatsTarget) async {
        guard let report = await report(for: target) else { return }
        guard !Task.isCancelled, self.target == target else { return }
        timeline.ingest(report)
        refreshReveal()
    }

    private func report(for target: GameStatsTarget) async -> GameStatsReport? {
        var request = URLRequest(url: target.summaryURL, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        // Stamped as it lands, before the work of reading it: the totals in
        // it are as of then.
        let received = Date()
        let sport = target.sport
        return await Task.detached(priority: .utility) {
            GameStatsParser.parse(data, sport: sport, receivedAt: received)
        }.value
    }

    // MARK: Boards

    /// A tennis draw, a fight card or a race: the scoreboard, again and
    /// again, each answer held against the one before it.
    private func followBoard(_ source: GameStatsSource) async {
        var found = false
        while !Task.isCancelled {
            if let report = await board(source) {
                guard !Task.isCancelled, self.source == source else { return }
                found = true
                timeline.ingest(report)
                refreshReveal()
            } else if !found {
                // The first answer has to find the game; later ones may fail
                // and be tried again.
                if !Task.isCancelled { unavailable = true }
                return
            }
            // Live, as often as ESPN refreshes it: a tennis scoreboard every
            // ten seconds, a fight card or a race every five.
            let live = timeline.snapshots.last?.state == "in" || (game?.isLive ?? false)
            var pace: TimeInterval = 60
            if live { if case .tennis = source { pace = 10 } else { pace = 5 } }
            do { try await Task.sleep(for: .seconds(pace)) } catch { return }
        }
    }

    private func board(_ source: GameStatsSource) async -> GameStatsReport? {
        guard let url = boardURL(source) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let received = Date()
        let league = game?.league.rawValue ?? ""
        return await Task.detached(priority: .utility) { () -> GameStatsReport? in
            let board: GameStatsBoard?
            switch source {
            case .tennis(let tour, let match, let tournament):
                board = GameStatsBoardParser.tennis(data, tour: tour, match: match, tournament: tournament,
                                                    receivedAt: received)
            case .card(let event):
                board = GameStatsBoardParser.card(data, event: event)
            case .race(_, let event, let session):
                board = GameStatsBoardParser.race(data, event: event, session: session, league: league)
            case .summary:
                board = nil
            }
            return board.map { GameStatsReport(board: $0, receivedAt: received) }
        }.value
    }

    private func boardURL(_ source: GameStatsSource) -> URL? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        let start = game?.start ?? Date()
        var parts: URLComponents
        switch source {
        case .tennis(let tour, _, _):
            // The current scoreboard holds the week's tournaments whole.
            parts = URLComponents(string: "https://site.api.espn.com/apis/site/v2/sports/tennis/\(tour)/scoreboard")!
        case .card:
            parts = URLComponents(string: "https://site.api.espn.com/apis/site/v2/sports/mma/ufc/scoreboard")!
            parts.queryItems = [URLQueryItem(name: "dates", value: formatter.string(from: start))]
        case .race(let path, _, _):
            // A weekend is filed under its first practice, so the week
            // around the session is asked for.
            parts = URLComponents(string: "https://site.api.espn.com/apis/site/v2/sports/racing/\(path)/scoreboard")!
            let range = formatter.string(from: start.addingTimeInterval(-7 * 86_400)) + "-"
                + formatter.string(from: start.addingTimeInterval(86_400))
            parts.queryItems = [URLQueryItem(name: "dates", value: range)]
        case .summary:
            return nil
        }
        return parts.url
    }

    // MARK: Summaries

    /// ESPN's own id for the game. The schedule's id is usually it, behind
    /// the league's prefix; when it isn't, or the game it names is another
    /// one, the day's scoreboard is searched for the two teams.
    private func resolve(_ game: SportsGame) async -> GameStatsTarget? {
        guard case .summary(let sport, let league)? = game.statsSource else { return nil }
        let path = (sport: sport, league: league)
        let prefix = game.league.rawValue + "-"
        let raw = game.id.hasPrefix(prefix) ? String(game.id.dropFirst(prefix.count)) : game.id
        if !raw.isEmpty, raw.allSatisfy(\.isNumber) {
            let target = GameStatsTarget(sport: path.sport, league: path.league, eventID: raw)
            if let report = await report(for: target), Self.matches(report, game) {
                self.target = target
                timeline.ingest(report)
                refreshReveal()
                return target
            }
        }
        guard !Task.isCancelled else { return nil }
        return await search(game, sport: path.sport, league: path.league)
    }

    private func search(_ game: SportsGame, sport: String, league: String) async -> GameStatsTarget? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        let day = calendar.dateComponents([.year, .month, .day], from: game.start)
        guard let year = day.year, let month = day.month, let date = day.day else { return nil }
        var parts = URLComponents(string: "https://site.api.espn.com/apis/site/v2/sports/\(sport)/\(league)/scoreboard")!
        parts.queryItems = [URLQueryItem(name: "dates", value: String(format: "%04d%02d%02d", year, month, date))]
        if sport == "football", league == "college-football" {
            parts.queryItems! += [URLQueryItem(name: "groups", value: "80"), URLQueryItem(name: "limit", value: "400")]
        }
        guard let url = parts.url,
              let (data, response) = try? await session.data(for: URLRequest(url: url, timeoutInterval: 8)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [[String: Any]] else { return nil }
        for event in events {
            guard let id = event["id"] as? String,
                  let competition = (event["competitions"] as? [[String: Any]])?.first,
                  let competitors = competition["competitors"] as? [[String: Any]] else { continue }
            var away: (abbreviation: String, name: String)?
            var home: (abbreviation: String, name: String)?
            for competitor in competitors {
                let team = competitor["team"] as? [String: Any]
                let side = (team?["abbreviation"] as? String ?? "", team?["displayName"] as? String ?? "")
                if competitor["homeAway"] as? String == "home" { home = side } else { away = side }
            }
            guard let away, let home,
                  Self.same(away.abbreviation, away.name, as: game.awayAbbreviation, game.awayTeam),
                  Self.same(home.abbreviation, home.name, as: game.homeAbbreviation, game.homeTeam) else { continue }
            return GameStatsTarget(sport: sport, league: league, eventID: id)
        }
        return nil
    }

    /// The reply is about this game: the same two teams, the right way round.
    private static func matches(_ report: GameStatsReport, _ game: SportsGame) -> Bool {
        same(report.away.abbreviation, report.away.name, as: game.awayAbbreviation, game.awayTeam)
            && same(report.home.abbreviation, report.home.name, as: game.homeAbbreviation, game.homeTeam)
    }

    private static func same(_ abbreviation: String, _ name: String, as gameAbbreviation: String, _ gameName: String) -> Bool {
        let a = abbreviation.lowercased(), b = gameAbbreviation.lowercased()
        if !a.isEmpty, a == b { return true }
        let left = name.lowercased(), right = gameName.lowercased()
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right || left.contains(right) || right.contains(left)
    }
}

extension MobileGameStats {
    /// The game as the rest of the screen should show it: the one being
    /// watched with its score held behind the picture, every other as it is.
    /// Until the feed has answered, the watched game's score is withheld
    /// rather than shown ahead.
    func shield(_ game: SportsGame) -> SportsGame {
        guard game.id == self.game?.id, !unavailable else { return game }
        return game.revealed(by: reveal)
    }
}

extension SportsGame {
    /// This game as far as the picture has got: its score and status held
    /// back with the stats, so nothing on screen says what the picture is
    /// still to show. Nil withholds the score altogether -- a tennis
    /// match's sets and a race's order with it.
    func revealed(by reveal: GameStatsReveal?) -> SportsGame {
        guard let reveal else {
            return replacing(awayScore: "–", homeScore: "–", status: "Syncing",
                             state: state == "post" ? "in" : state, tennis: nil,
                             race: race.map { $0.ordered(nil) })
        }
        var awayScore = String(reveal.awayScore), homeScore = String(reveal.homeScore)
        var sets = tennis
        var order = race
        switch reveal.board {
        case .tennis(let draw)?:
            if let match = draw.focused {
                sets = match.sets.isEmpty ? nil : match.score
            } else {
                // A tournament's card has no score of its own.
                awayScore = self.awayScore; homeScore = self.homeScore
            }
        case .card?:
            awayScore = self.awayScore; homeScore = self.homeScore
        case .race(let board)?:
            awayScore = self.awayScore; homeScore = self.homeScore
            order = race.map { $0.ordered(board.state == "post" ? board : nil) }
        case nil:
            break
        }
        return replacing(awayScore: awayScore, homeScore: homeScore,
                         status: reveal.status.isEmpty ? status : reveal.status,
                         // Still on, as far as the picture knows, until the
                         // picture shows the final whistle.
                         state: reveal.state == "post" ? "post" : (state == "post" ? "in" : state),
                         tennis: sets, race: order)
    }

    private func replacing(awayScore: String, homeScore: String, status: String, state: String,
                           tennis: TennisScore?, race: RacingSession?) -> SportsGame {
        SportsGame(id: id, league: league, start: start, awayTeam: awayTeam, homeTeam: homeTeam,
                   awayAbbreviation: awayAbbreviation, homeAbbreviation: homeAbbreviation,
                   awayLogo: awayLogo, homeLogo: homeLogo, awayScore: awayScore, homeScore: homeScore,
                   awayColor: awayColor, homeColor: homeColor, awayRecord: awayRecord, homeRecord: homeRecord,
                   venue: venue, location: location, status: status, state: state, broadcast: broadcast,
                   eventName: eventName, awayRank: awayRank, homeRank: homeRank, tennis: tennis,
                   competition: competition, awayTeamID: awayTeamID, homeTeamID: homeTeamID,
                   soccer: soccer, race: race)
    }
}

extension GameStatsTennisMatch {
    /// The sets as the rest of the app draws them.
    var score: TennisScore {
        TennisScore(sets: sets.map { set in
            TennisScore.SetGames(away: set.away, home: set.home,
                                 awayTiebreak: set.awayTiebreak, homeTiebreak: set.homeTiebreak,
                                 awayWon: set.winner.map { $0 == .away })
        }, bestOf: bestOf)
    }
}

extension RacingSession {
    /// The session with its finishing order as the picture has shown it,
    /// or none: the order is the result.
    func ordered(_ board: GameStatsRaceBoard?) -> RacingSession {
        let places = Dictionary((board?.entrants ?? []).map { ($0.id, $0.position) }, uniquingKeysWith: { first, _ in first })
        return RacingSession(eventID: eventID, kind: kind, title: title, circuit: circuit,
                             entrants: entrants.map { .init(id: $0.id, name: $0.name, flag: $0.flag, position: places[$0.id]) })
    }
}
