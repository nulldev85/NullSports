import Foundation

/// Soccer's all-competition feed and racing weekends are shared across every
/// screen. Coalescing + short live/long idle caches avoid a request per club,
/// competition, card, or preview. A failed sport never replaces its good slate.
actor ExpandedSportsScheduleClient {
    static let shared = ExpandedSportsScheduleClient()
    typealias Transport = @Sendable (URL) async throws -> Data
    private struct Feed: Sendable { let games: [SportsGame]; let count: Int }
    private struct Cached { let feed: Feed; let until: Date }
    private let competitions: [SportsCompetition]
    private let transport: Transport
    private let now: @Sendable () -> Date
    private var cache: [URL: Cached] = [:]
    private var pending: [URL: Task<Feed, Error>] = [:]

    init(competitions: [SportsCompetition] = SportsCompetitionCatalog.bundled.competitions,
         now: @escaping @Sendable () -> Date = { Date() },
         transport: @escaping Transport = { url in
             var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
             request.setValue("application/json", forHTTPHeaderField: "Accept")
             let (data, response) = try await URLSession.shared.data(for: request)
             guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                 throw ExpandedSportsError.invalidResponse
             }
             return data
         }) {
        self.competitions = competitions
        self.transport = transport
        self.now = now
    }

    func games(from start: Date, to end: Date, racingTo: Date? = nil) async -> SportsScheduleClient.Snapshot {
        guard start < end else { return .init(games: [:], loadedLeagues: [], errorMessage: "Invalid sports date range.") }
        // ESPN's daily feed boundaries are US Eastern, as verified against its
        // event timestamps. Convert the requested local interval to feed days,
        // then filter actual UTC timestamps; overseas and midnight games survive.
        let lookback = start.addingTimeInterval(-12 * 60 * 60)
        let dates = Self.feedDates(from: lookback, to: end)
        return await withTaskGroup(of: (SportsLeague, Result<[SportsGame], Error>).self) { group in
            for league in [SportsLeague.soccer, .f1, .nascar] {
                group.addTask {
                    do {
                        let sportEnd = league.isRacing ? max(end, racingTo ?? end) : end
                        var games: [SportsGame] = []
                        if league == .soccer {
                            games = try await withThrowingTaskGroup(of: [SportsGame].self) { days in
                                for day in dates { days.addTask { try await self.soccer(day: day) } }
                                var combined: [SportsGame] = []
                                for try await slate in days { combined += slate }
                                return combined
                            }
                        } else {
                            // A weekend is keyed by its first practice. Asking
                            // only for Sunday can miss its race; load the whole
                            // surrounding weekend, then cut out the local window.
                            let path = league == .f1 ? "f1" : "nascar-premier"
                            let range = Self.feedDates(from: start.addingTimeInterval(-7 * 86_400), to: sportEnd)
                            let query = "\(range.first!)-\(range.last!)"
                            games = try await self.feed(path: "racing/\(path)", day: query, league: league).games
                        }
                        let unique = Dictionary(grouping: games.filter {
                            $0.start < sportEnd && ($0.start >= start || ($0.state == "in" && $0.start >= lookback))
                        }, by: \.id)
                            .values.compactMap(\.first).sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
                        return (league, .success(unique))
                    } catch { return (league, .failure(error)) }
                }
            }
            var games: [SportsLeague: [SportsGame]] = [:]
            var loaded: Set<SportsLeague> = []
            var failed: [String] = []
            for await (league, result) in group {
                switch result {
                case .success(let slate): games[league] = slate; loaded.insert(league)
                case .failure: failed.append(league.shortName)
                }
            }
            return .init(games: games, loadedLeagues: loaded,
                         errorMessage: failed.isEmpty ? nil : "Schedule unavailable: \(failed.sorted().joined(separator: ", ")).")
        }
    }

    static func feedDates(from start: Date, to end: Date) -> [String] {
        guard start < end else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyyMMdd"
        var day = calendar.startOfDay(for: start)
        var result: [String] = []
        while day < end {
            result.append(formatter.string(from: day))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }
        return result
    }

    private func soccer(day: String) async throws -> [SportsGame] {
        guard !competitions.isEmpty else { throw ExpandedSportsError.invalidResponse }
        let all = try await feed(path: "soccer/all", day: day, league: .soccer)
        guard all.count >= 1_000 else { return all.games }
        // Never silently truncate a busy Saturday. If the global page reaches
        // its cap, request each supported competition, four at a time.
        var result: [SportsGame] = []
        for first in stride(from: 0, to: competitions.count, by: 4) {
            let batch = Array(competitions[first..<min(first + 4, competitions.count)])
            result += try await withThrowingTaskGroup(of: [SportsGame].self) { group in
                for competition in batch {
                    group.addTask {
                        let feed = try await self.feed(path: "soccer/\(competition.id)", day: day, league: .soccer,
                                                       competition: competition)
                        guard feed.count < 1_000 else { throw ExpandedSportsError.incompleteCoverage }
                        return feed.games
                    }
                }
                var games: [SportsGame] = []
                for try await slate in group { games += slate }
                return games
            }
        }
        return result
    }

    private func feed(path: String, day: String, league: SportsLeague,
                      competition: SportsCompetition? = nil) async throws -> Feed {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(path)/scoreboard?dates=\(day)&limit=1000") else {
            throw ExpandedSportsError.invalidResponse
        }
        if let saved = cache[url], now() < saved.until { return saved.feed }
        if let work = pending[url] { return try await work.value }
        let transport = self.transport, catalog = self.competitions
        let work = Task<Feed, Error> {
            let data = try await transport(url)
            let root = try Self.events(in: data)
            let games = league == .soccer
                ? Self.soccerGames(events: root, competitions: catalog, competition: competition)
                : Self.racingGames(events: root, league: league)
            return Feed(games: games, count: root.count)
        }
        pending[url] = work
        defer { pending[url] = nil }
        let result = try await work.value
        let time = now()
        let changesSoon = result.games.contains {
            $0.state == "in" || ($0.state == "pre" && $0.start < time.addingTimeInterval(600)
                && $0.start > time.addingTimeInterval(-12 * 3600))
        }
        cache[url] = Cached(feed: result, until: time.addingTimeInterval(changesSoon ? 20 : 300))
        cache = cache.filter { $0.value.until > time.addingTimeInterval(-86_400) }
        return result
    }

    private static func events(in data: Data) throws -> [[String: Any]] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [Any] else { throw ExpandedSportsError.invalidResponse }
        return events.compactMap { $0 as? [String: Any] }
    }

    static func soccerGames(data: Data, competitions: [SportsCompetition]) throws -> [SportsGame] {
        soccerGames(events: try events(in: data), competitions: competitions)
    }

    private static func soccerGames(events: [[String: Any]], competitions: [SportsCompetition],
                                     competition: SportsCompetition? = nil) -> [SportsGame] {
        let catalog = Dictionary(uniqueKeysWithValues: competitions.map { ($0.feedID, $0) })
        return events.compactMap { event in
            let uid = text(event["uid"])
            let feedID = uid.components(separatedBy: "~l:").dropFirst().first?.components(separatedBy: "~").first
            guard let source = competition ?? feedID.flatMap({ catalog[$0] }),
                  feedID == nil || feedID == source.feedID,
                  let contest = (event["competitions"] as? [[String: Any]])?.first,
                  contest["timeValid"] as? Bool != false,
                  let start = SportsScheduleClient.parseDate(text(contest["date"] ?? event["date"])),
                  !text(event["id"]).isEmpty,
                  let sides = contest["competitors"] as? [[String: Any]],
                  let away = sides.first(where: { text($0["homeAway"]) == "away" }),
                  let home = sides.first(where: { text($0["homeAway"]) == "home" }),
                  let awayTeam = away["team"] as? [String: Any], let homeTeam = home["team"] as? [String: Any],
                  knownTeam(awayTeam), knownTeam(homeTeam) else { return nil }
            let status = Self.status(contest["status"] ?? event["status"])
            let venue = contest["venue"] as? [String: Any] ?? [:]
            var game = SportsGame(id: "soccer-\(text(event["id"]))", league: .soccer, start: start,
                awayTeam: text(awayTeam["displayName"]), homeTeam: text(homeTeam["displayName"]),
                awayAbbreviation: text(awayTeam["abbreviation"]), homeAbbreviation: text(homeTeam["abbreviation"]),
                awayLogo: text(awayTeam["logo"]), homeLogo: text(homeTeam["logo"]),
                awayScore: text(away["score"]), homeScore: text(home["score"]),
                awayColor: optionalText(awayTeam["color"]), homeColor: optionalText(homeTeam["color"]),
                awayRecord: record(away), homeRecord: record(home), venue: optionalText(venue["fullName"]),
                location: address(venue["address"]), status: status.label, state: status.state,
                broadcast: broadcasts(contest), eventName: nil)
            game.competition = source
            game.awayTeamID = text(awayTeam["id"]); game.homeTeamID = text(homeTeam["id"])
            let clock = (contest["status"] ?? event["status"]) as? [String: Any] ?? [:]
            game.soccer = SoccerScore(awayPenalties: optionalText(away["shootoutScore"]),
                homePenalties: optionalText(home["shootoutScore"]), awayAggregate: optionalText(away["aggregateScore"]),
                homeAggregate: optionalText(home["aggregateScore"]), period: clock["period"] as? Int,
                clockSeconds: clock["clock"] as? Double)
            return game
        }
    }

    static func racingGames(data: Data, league: SportsLeague) throws -> [SportsGame] {
        racingGames(events: try events(in: data), league: league)
    }

    private static func racingGames(events: [[String: Any]], league: SportsLeague) -> [SportsGame] {
        guard league.isRacing else { return [] }
        return events.flatMap { event -> [SportsGame] in
            let eventID = text(event["id"]), name = text(event["name"])
            guard !eventID.isEmpty, !name.isEmpty else { return [] }
            let circuit = event["circuit"] as? [String: Any] ?? [:]
            return (event["competitions"] as? [[String: Any]] ?? []).compactMap { contest in
                guard contest["timeValid"] as? Bool != false,
                      let start = SportsScheduleClient.parseDate(text(contest["date"] ?? event["date"])) else { return nil }
                let kind = text((contest["type"] as? [String: Any])?["abbreviation"])
                let session = sessionTitle(kind, league: league)
                let id = text(contest["id"])
                guard !id.isEmpty else { return nil }
                let current = status(contest["status"] ?? event["status"])
                let entrants: [RacingSession.Entrant] = (contest["competitors"] as? [[String: Any]] ?? []).compactMap { entry in
                    guard let athlete = entry["athlete"] as? [String: Any], !text(entry["id"]).isEmpty,
                          !text(athlete["displayName"]).isEmpty else { return nil }
                    return .init(id: text(entry["id"]), name: text(athlete["displayName"]),
                        flag: optionalText((athlete["flag"] as? [String: Any])?["href"]),
                        position: current.state == "post" ? entry["order"] as? Int : nil)
                }
                var game = SportsGame(id: "\(league.rawValue)-\(eventID)-\(id)", league: league, start: start,
                    awayTeam: "", homeTeam: "", awayAbbreviation: "", homeAbbreviation: "", awayLogo: "", homeLogo: "",
                    awayScore: "", homeScore: "", awayColor: nil, homeColor: nil, awayRecord: nil, homeRecord: nil,
                    venue: optionalText(circuit["fullName"]), location: address(circuit["address"]),
                    status: current.label, state: current.state, broadcast: broadcasts(contest), eventName: name)
                game.race = RacingSession(eventID: eventID, kind: kind.isEmpty ? "Race" : kind, title: session,
                    circuit: optionalText(circuit["fullName"]), entrants: entrants)
                return game
            }
        }
    }

    static func sessionTitle(_ code: String, league: SportsLeague) -> String {
        switch code.lowercased() {
        case "fp1", "p1": "Practice 1"
        case "fp2", "p2": "Practice 2"
        case "fp3", "p3": "Practice 3"
        case "qual", "q", "qualifying": "Qualifying"
        case "sq", "ss", "sprint qual", "sprint qualifying", "sprint shootout": "Sprint Qualifying"
        case "sprint", "s": "Sprint"
        case "race", "r": "Race"
        case "": league == .nascar ? "Cup Series Race" : "Race"
        default: code
        }
    }

    private static func text(_ value: Any?) -> String {
        if let string = value as? String { return string.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }
    private static func optionalText(_ value: Any?) -> String? { let value = text(value); return value.isEmpty ? nil : value }
    private static func knownTeam(_ team: [String: Any]) -> Bool {
        let name = text(team["displayName"]).uppercased()
        return !text(team["id"]).isEmpty && !name.isEmpty && !["TBD", "TBA", "WINNER", "LOSER"].contains(name)
    }
    private static func status(_ value: Any?) -> (label: String, state: String) {
        let record = value as? [String: Any] ?? [:], type = record["type"] as? [String: Any] ?? [:]
        let name = text(type["name"]).uppercased()
        let blocked = ["POSTPONED", "CANCELED", "CANCELLED", "ABANDONED", "SUSPENDED", "DELAYED"]
        let state = blocked.contains(where: name.contains) ? "unavailable" : text(type["state"])
        return (text(type["shortDetail"] ?? type["description"]), state)
    }
    private static func record(_ side: [String: Any]) -> String? {
        let records = side["records"] as? [[String: Any]] ?? []
        return optionalText((records.first { text($0["type"]) == "total" } ?? records.first)?["summary"])
    }
    private static func address(_ value: Any?) -> String? {
        guard let place = value as? [String: Any] else { return nil }
        let words = ["city", "state", "country"].compactMap { optionalText(place[$0]) }
        return words.isEmpty ? nil : Array(NSOrderedSet(array: words)).compactMap { $0 as? String }.joined(separator: ", ")
    }
    private static func broadcasts(_ contest: [String: Any]) -> String {
        var names: [String] = (contest["broadcasts"] as? [[String: Any]] ?? []).flatMap { $0["names"] as? [String] ?? [] }
        if names.isEmpty {
            names = (contest["geoBroadcasts"] as? [[String: Any]] ?? []).compactMap { optionalText(($0["media"] as? [String: Any])?["shortName"]) }
        }
        if names.isEmpty, let name = optionalText(contest["broadcast"]) { names = [name] }
        var seen: Set<String> = []
        return names.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ", ")
    }
}

private enum ExpandedSportsError: Error { case invalidResponse, incompleteCoverage }
