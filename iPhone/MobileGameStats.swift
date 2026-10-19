import Foundation

extension SportsLeague {
    /// Where ESPN files this league's games, for the ones its game feed
    /// covers play by play.
    var statsPath: (sport: String, league: String)? {
        switch self {
        case .nfl: ("football", "nfl")
        case .ncaaf: ("football", "college-football")
        case .nba: ("basketball", "nba")
        case .nhl: ("hockey", "nhl")
        case .mlb: ("baseball", "mlb")
        default: nil
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

    static func supports(_ game: SportsGame?) -> Bool {
        guard let game else { return false }
        return game.league.statsPath != nil && !game.isNFLRedZone
    }

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

    /// The viewer has just seen a score on their screen: the delay is how
    /// long ago the feed first had it, less their own pauses. False when no
    /// score has changed in the last few minutes to go by.
    @discardableResult
    func syncToLatestScore() -> Bool {
        let now = Date()
        guard let change = timeline.lastScoreChange(within: 300, now: now) else { return false }
        setDelay(now.timeIntervalSince(change) - max(0, playerLag()))
        return true
    }

    /// The game clock as the picture has it, for matching by eye.
    var clockText: String? { timeline.clock(at: cutoff) }

    // MARK: Feed

    private func start(_ game: SportsGame) {
        poll = Task { [weak self] in
            guard let self else { return }
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

    /// ESPN's own id for the game. The schedule's id is usually it, behind
    /// the league's prefix; when it isn't, or the game it names is another
    /// one, the day's scoreboard is searched for the two teams.
    private func resolve(_ game: SportsGame) async -> GameStatsTarget? {
        guard let path = game.league.statsPath else { return nil }
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
    /// still to show. Nil withholds the score altogether.
    func revealed(by reveal: GameStatsReveal?) -> SportsGame {
        guard let reveal else {
            return SportsGame(id: id, league: league, start: start, awayTeam: awayTeam, homeTeam: homeTeam,
                              awayAbbreviation: awayAbbreviation, homeAbbreviation: homeAbbreviation,
                              awayLogo: awayLogo, homeLogo: homeLogo, awayScore: "–", homeScore: "–",
                              awayColor: awayColor, homeColor: homeColor, awayRecord: awayRecord, homeRecord: homeRecord,
                              venue: venue, location: location, status: "Syncing",
                              state: state == "post" ? "in" : state, broadcast: broadcast, eventName: eventName,
                              awayRank: awayRank, homeRank: homeRank, tennis: tennis, competition: competition,
                              awayTeamID: awayTeamID, homeTeamID: homeTeamID, soccer: soccer, race: race)
        }
        return SportsGame(id: id, league: league, start: start, awayTeam: awayTeam, homeTeam: homeTeam,
                          awayAbbreviation: awayAbbreviation, homeAbbreviation: homeAbbreviation,
                          awayLogo: awayLogo, homeLogo: homeLogo,
                          awayScore: String(reveal.awayScore), homeScore: String(reveal.homeScore),
                          awayColor: awayColor, homeColor: homeColor, awayRecord: awayRecord, homeRecord: homeRecord,
                          venue: venue, location: location,
                          status: reveal.status.isEmpty ? status : reveal.status,
                          // Still on, as far as the picture knows, until the
                          // picture shows the final whistle.
                          state: reveal.state == "post" ? "post" : (state == "post" ? "in" : state),
                          broadcast: broadcast, eventName: eventName,
                          awayRank: awayRank, homeRank: homeRank, tennis: tennis, competition: competition,
                          awayTeamID: awayTeamID, homeTeamID: homeTeamID, soccer: soccer, race: race)
    }
}
