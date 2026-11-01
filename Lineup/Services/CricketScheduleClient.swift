import Foundation

/// ESPN's Cricket header feed includes international and domestic competitions,
/// both sides' innings strings, and Tests that began on an earlier day.
/// The normal Cricket scoreboard's league 0 endpoint does not provide this feed.
actor CricketScheduleClient {
    static let shared = CricketScheduleClient()
    typealias Transport = @Sendable (URL) async throws -> Data
    private struct Cached { let games: [SportsGame]; let until: Date }
    // Swift 6.4 can destroy a group early when a child returns a String tuple
    // from do/catch under -O (swiftlang/swift#93208). Use a named result.
    private struct DayResult: Sendable { let date: String; let games: [SportsGame]? }
    private var cache: [String: Cached] = [:]
    private var pending: [String: Task<[SportsGame], Error>] = [:]
    private let transport: Transport
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() },
         transport: @escaping Transport = { url in
             var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
             request.setValue("application/json", forHTTPHeaderField: "Accept")
             let (data, response) = try await URLSession.shared.data(for: request)
             guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CricketFeedError.invalidResponse }
             return data
         }) {
        self.now = now
        self.transport = transport
    }

    func games(from start: Date, to end: Date) async -> SportsScheduleClient.Snapshot {
        guard start < end else {
            return .init(games: [:], loadedLeagues: [], errorMessage: "Invalid Cricket date range.")
        }
        // Feed dates are match-calendar days. Pad the UTC window on both sides
        // so a New Zealand morning and a late Caribbean match both survive;
        // actual timestamps below decide which local window they belong to.
        let dates = Self.feedDates(from: start.addingTimeInterval(-86_400), to: end.addingTimeInterval(86_400))
        let slates = await withTaskGroup(of: DayResult.self) { group in
            for date in dates {
                group.addTask {
                    let games = try? await self.day(date)
                    return DayResult(date: date, games: games)
                }
            }
            var result: [String: [SportsGame]] = [:]
            for await slate in group { if let games = slate.games { result[slate.date] = games } }
            return result
        }
        guard !slates.isEmpty else {
            return .init(games: [:], loadedLeagues: [], errorMessage: "Cricket schedule unavailable.")
        }
        var unique: [String: SportsGame] = [:]
        // Prefer the later day's appearance of a multi-day Test, independent
        // of network completion order.
        for date in slates.keys.sorted() {
            for game in slates[date] ?? [] where game.start < end {
                guard game.start >= start || (game.cricket?.end ?? game.start) > start else { continue }
                unique[game.id] = game
            }
        }
        let complete = slates.count == dates.count
        return .init(games: [.cricket: unique.values.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }],
                     loadedLeagues: complete ? [.cricket] : [],
                     errorMessage: complete ? nil : "Some Cricket fixtures could not be refreshed.",
                     partialLeagues: complete ? [] : [.cricket])
    }

    private func day(_ day: String) async throws -> [SportsGame] {
        if let saved = cache[day], now() < saved.until { return saved.games }
        if let work = pending[day] { return try await work.value }
        let transport = self.transport
        let work = Task<[SportsGame], Error> {
            let url = URL(string: "https://site.web.api.espn.com/apis/personalized/v2/scoreboard/header?sport=cricket&region=us&lang=en&contentorigin=espn&limit=1000&dates=\(day)")!
            return try Self.decode(try await transport(url))
        }
        pending[day] = work
        defer { pending[day] = nil }
        let games = try await work.value
        let time = now()
        let changesSoon = games.contains { $0.state == "in" || ($0.state == "pre" && $0.start < time.addingTimeInterval(600)) }
        cache[day] = Cached(games: games, until: time.addingTimeInterval(changesSoon ? 20 : 300))
        cache = cache.filter { $0.value.until > time.addingTimeInterval(-86_400) }
        return games
    }

    static func feedDates(from start: Date, to end: Date) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyyMMdd"
        var day = calendar.startOfDay(for: start), result: [String] = []
        while day < end {
            result.append(formatter.string(from: day))
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return result
    }

    static func decode(_ data: Data) throws -> [SportsGame] {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.sports.allSatisfy({ $0.slug == "cricket" }) else { throw CricketFeedError.invalidResponse }
        return try envelope.sports.flatMap { sport in
            try sport.leagues.flatMap { competition in
                try competition.events.compactMap { event -> SportsGame? in
                    guard event.timeValid != false else { return nil }
                    guard !event.id.isEmpty, let start = SportsScheduleClient.parseDate(event.date),
                          ["pre", "in", "post"].contains(event.status), event.competitors.count == 2,
                          let away = event.competitors.first(where: { $0.homeAway == "away" }),
                          let home = event.competitors.first(where: { $0.homeAway == "home" }),
                          !away.displayName.isEmpty, !home.displayName.isEmpty else { throw CricketFeedError.invalidResponse }
                    if [away, home].contains(where: { ["tba", "tbc", "tbd"].contains($0.displayName.lowercased()) }) { return nil }
                    let full = event.fullStatus
                    // Preserve session / rain / stumps / result wording instead
                    // of replacing every in-progress Test with just "Live".
                    let label = [full?.session, full?.type?.description, full?.summary]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                    var game = SportsGame(id: "cricket-\(event.id)", league: .cricket, start: start,
                        awayTeam: away.displayName, homeTeam: home.displayName,
                        awayAbbreviation: away.abbreviation ?? "", homeAbbreviation: home.abbreviation ?? "",
                        awayLogo: away.logo ?? "", homeLogo: home.logo ?? "",
                        awayScore: away.score ?? "", homeScore: home.score ?? "",
                        awayColor: away.color, homeColor: home.color, awayRecord: nil, homeRecord: nil,
                        venue: event.location, location: nil,
                        status: label.isEmpty ? (event.summary ?? event.status) : label,
                        state: event.status, broadcast: "", eventName: nil)
                    game.cricket = CricketMatch(end: event.endDate.flatMap(SportsScheduleClient.parseDate) ?? start.addingTimeInterval(6 * 86_400),
                                                format: event.classification?.eventType ?? "")
                    game.competition = SportsCompetition(id: competition.id, feedID: competition.id,
                        name: competition.name, shortName: competition.abbreviation.flatMap { $0.isEmpty ? nil : $0 } ?? competition.name, logo: "")
                    game.awayTeamID = away.id
                    game.homeTeamID = home.id
                    return game
                }
            }
        }
    }

    private struct Envelope: Decodable { let sports: [Sport] }
    private struct Sport: Decodable { let slug: String; let leagues: [Competition] }
    private struct Competition: Decodable {
        let id: String; let name: String; let abbreviation: String?; let events: [Event]
    }
    private struct Event: Decodable {
        let id: String; let date: String; let endDate: String?; let timeValid: Bool?
        let status: String; let summary: String?; let fullStatus: Status?; let competitors: [Side]
        let location: String?; let classification: Classification?
        enum CodingKeys: String, CodingKey {
            case id, date, endDate, timeValid, status, summary, fullStatus, competitors, location
            case classification = "class"
        }
    }
    private struct Side: Decodable {
        let id: String; let displayName: String; let homeAway: String; let abbreviation: String?
        let score: String?; let logo: String?; let color: String?
    }
    private struct Status: Decodable { let session: String?; let summary: String?; let type: StatusType? }
    private struct StatusType: Decodable { let description: String? }
    private struct Classification: Decodable { let eventType: String? }
}

private enum CricketFeedError: Error { case invalidResponse }
