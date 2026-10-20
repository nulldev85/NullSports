import Foundation

/// A team's page, read from ESPN a part at a time as its tabs are opened,
/// and kept for a few minutes so moving between tabs and teams reads
/// nothing twice. A part that fails is retried the next time it is asked for.
actor MobileTeamPageClient {
    static let shared = MobileTeamPageClient()

    typealias Transport = @Sendable (URL) async throws -> Data

    private let transport: Transport
    private var cache: [URL: (data: Data, expires: Date)] = [:]
    private var pending: [URL: Task<Data, Error>] = [:]
    private static let lifetime: TimeInterval = 5 * 60

    init(transport: @escaping Transport = { url in
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }) {
        self.transport = transport
    }

    func info(_ path: TeamPagePath) async -> TeamPageInfo? {
        guard let url = path.team, let data = try? await read(url) else { return nil }
        return TeamPageParser.info(data)
    }

    func schedule(_ path: TeamPagePath) async -> [TeamPageGame]? {
        var lists: [Data] = []
        for url in path.schedules {
            if let data = try? await read(url) { lists.append(data) }
        }
        return lists.isEmpty ? nil : TeamPageParser.schedule(lists, teamID: path.teamID)
    }

    func standings(_ path: TeamPagePath) async -> TeamPageStandings? {
        guard let url = path.standings, let data = try? await read(url) else { return nil }
        return TeamPageParser.standings(data, teamID: path.teamID,
                                        columns: TeamPageParser.columns(sport: path.sport, league: path.league))
    }

    func roster(_ path: TeamPagePath) async -> TeamPageParser.Roster? {
        guard let url = path.roster, let data = try? await read(url) else { return nil }
        return TeamPageParser.roster(data)
    }

    func news(_ path: TeamPagePath) async -> [TeamPageArticle]? {
        guard let url = path.news, let data = try? await read(url) else { return nil }
        return TeamPageParser.news(data)
    }

    private func read(_ url: URL) async throws -> Data {
        let now = Date()
        if let cached = cache[url], cached.expires > now { return cached.data }
        if let running = pending[url] { return try await running.value }
        let transport = self.transport
        let task = Task { try await transport(url) }
        pending[url] = task
        defer { pending[url] = nil }
        let data = try await task.value
        cache = cache.filter { $0.value.expires > now }
        cache[url] = (data, now.addingTimeInterval(Self.lifetime))
        return data
    }
}
