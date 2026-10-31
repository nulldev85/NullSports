import Foundation
import XCTest
@testable import Lineup

@MainActor
final class TVInstantLiveTests: XCTestCase {
    func testBootstrapPublishesSavedLivePlaybackBeforeTheProviderCanAnswer() async throws {
        let now = Date()
        let game = event("saved-live", league: .nba, start: now.addingTimeInterval(-120), state: "in")
        let fixture = try Fixture(games: [game])
        defer { fixture.close() }
        let stream = fixture.streams[0], program = try XCTUnwrap(fixture.programs["nba"])
        let channels = SportsLibrary.matchingEventChannels(for: game, candidates: [stream],
            programs: ["nba": [program]], categories: fixture.categories, now: now)
        XCTAssertEqual(channels.map(\.id), [1])
        let prepared = PreparedLiveMatch(preparedAt: now.addingTimeInterval(-60), eventStart: game.start,
            identity: PreparedLiveMatch.identity(for: game), primary: stream, alternatives: channels,
            programs: ["nba": [program]], categoryNames: ["sports": "Sports"])
        PreparedLiveStore.write(.init(version: PreparedLiveSnapshot.version,
            connection: PreparedLiveSnapshot.connection(for: fixture.profile), savedAt: now, dailyPreparedAt: now,
            games: ["nba": [game]], loadedLeagues: ["nba"], matches: [game.id: prepared]),
            profileID: fixture.profile.id, directory: fixture.directory)
        let requested = expectation(description: "Provider refresh is blocked after saved playback is restored")
        let network = InstantLiveNetworkBlock(onFirstRequest: { requested.fulfill() })
        InstantLiveProtocol.block = network
        defer { Task { await network.release() } }
        let library = fixture.library(automaticRefreshes: true)
        let boot = Task { await library.bootstrap() }
        await fulfillment(of: [requested], timeout: 5)
        XCTAssertTrue(library.channelsAreSyncing)
        XCTAssertFalse(library.automaticMatchingReady)
        XCTAssertEqual(library.games(for: .nba).map(\.id), [game.id])
        XCTAssertTrue(library.eventChannelsReady(for: game), "A full provider/guide sync must not gate saved playback")
        XCTAssertEqual(library.preparedPlaybackStream(for: game)?.id, stream.id)
        XCTAssertEqual(library.preferredChannel(for: game), .play(streamID: stream.id, source: .verified))
        XCTAssertFalse(library.playbackURLs(for: stream).isEmpty)
        await network.release()
        await boot.value
    }

    func testAnEventChangingDuringMatchingCannotDiscardOtherGamesOrTheirDailyPreparation() async throws {
        let start = Date().addingTimeInterval(3600)
        let keep = event("unchanged", league: .nba, start: start)
        let changing = event("changing", league: .nfl, start: start)
        let changed = event("changing", league: .nfl, start: start, broadcast: "Prime Video, Updated")
        let fixture = try Fixture(games: [keep, changing])
        defer { fixture.close() }
        let schedule = InstantLiveSchedule(games: [keep, changing])
        let library = fixture.library(schedule: { _ in await schedule.snapshot() })
        library.refreshSchedule(showsLoading: true)
        try await wait("Initial schedule did not load") { library.gamesByLeague[.nba]?.first?.id == keep.id && !library.isScheduleLoading }
        let calculated = expectation(description: "Matching has calculated the original slate")
        let gate = InstantLivePublicationGate()
        defer { Task { await gate.releaseAll() } }
        var passes = 0
        library.beforeTVMatchPublication = {
            passes += 1
            if passes == 1 { calculated.fulfill() }
            await gate.wait()
        }
        let reload = Task { await library.reload() }
        await fulfillment(of: [calculated], timeout: 10)
        XCTAssertFalse(library.eventChannelsReady(for: keep))
        await schedule.replace([keep, changed])
        library.refreshSchedule(showsLoading: true, includeTomorrow: false)
        try await wait("Changed schedule did not publish independently of matching") {
            library.gamesByLeague[.nfl]?.first?.broadcast == changed.broadcast && !library.isScheduleLoading
        }
        await gate.releaseOne()
        try await wait("One changed event discarded the unchanged prepared game") { library.eventChannelsReady(for: keep) }
        XCTAssertEqual(library.preferredChannel(for: keep), .play(streamID: 1, source: .verified))
        XCTAssertFalse(library.eventChannelsReady(for: changed), "The obsolete event's result must not be accepted")
        library.beforeTVMatchPublication = nil
        await gate.releaseAll()
        await reload.value
    }

    private func wait(_ message: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), message)
    }

    private func event(_ id: String, league: SportsLeague, start: Date, state: String = "pre", broadcast: String? = nil) -> SportsGame {
        let football = league == .nfl
        return SportsGame(id: id, league: league, start: start,
            awayTeam: football ? "Buffalo Bills" : "Orlando Magic", homeTeam: football ? "Miami Dolphins" : "Miami Heat",
            awayAbbreviation: football ? "BUF" : "ORL", homeAbbreviation: "MIA", awayLogo: "", homeLogo: "",
            awayScore: "0", homeScore: "0", awayColor: nil, homeColor: nil, awayRecord: nil, homeRecord: nil,
            venue: nil, location: nil, status: state == "in" ? "Live" : "Scheduled", state: state,
            broadcast: broadcast ?? (football ? "Prime Video" : "ABC"), eventName: nil)
    }

    @MainActor private final class Fixture {
        let suite = "TVInstantLive.\(UUID())"
        let profile = XtreamProfile(name: "Fixture", serverURL: "https://instant-live.invalid", username: "viewer")
        let defaults: UserDefaults
        let directory: URL
        let session: URLSession
        let games: [SportsGame]
        let categories = [XtreamCategory(categoryID: "sports", categoryName: "Sports")]
        let streams = [
            XtreamStream(num: 1, name: "US: ABC Miami FHD", streamType: "live", streamID: 1, streamIcon: nil, epgChannelID: "nba", categoryID: "sports"),
            XtreamStream(num: 2, name: "US: Prime Video FHD", streamType: "live", streamID: 2, streamIcon: nil, epgChannelID: "nfl", categoryID: "sports")
        ]
        let programs: [String: CurrentProgram]
        init(games: [SportsGame]) throws {
            self.games = games
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            defaults.set(try JSONEncoder().encode([profile]), forKey: "NullSports.profiles")
            defaults.set(profile.id.uuidString, forKey: "NullSports.activeProfile")
            programs = Dictionary(uniqueKeysWithValues: games.map {
                ($0.league.rawValue, CurrentProgram(channelID: $0.league.rawValue,
                    title: $0.league == .nba ? "NBA Basketball: Orlando Magic at Miami Heat" : "NFL Football: Buffalo Bills at Miami Dolphins",
                    detail: "", start: $0.start.addingTimeInterval(-60), end: $0.start.addingTimeInterval(7200)))
            })
            let date = DateFormatter()
            date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0)
            date.dateFormat = "yyyyMMddHHmmss Z"
            let xml = "<tv>" + programs.values.map {
                "<programme channel=\"\($0.channelID)\" start=\"\(date.string(from: $0.start))\" stop=\"\(date.string(from: $0.end))\"><title>\($0.title)</title></programme>"
            }.joined() + "</tv>"
            InstantLiveProtocol.responses = ["get_live_categories": try JSONEncoder().encode(categories),
                "get_live_streams": try JSONEncoder().encode(streams), "xmltv.php": Data(xml.utf8)]
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [InstantLiveProtocol.self]
            session = URLSession(configuration: configuration)
        }
        func library(automaticRefreshes: Bool = false,
                     schedule: (@Sendable (Bool) async -> SportsScheduleClient.Snapshot)? = nil) -> SportsLibrary {
            let games = games
            return SportsLibrary(profileDefaults: defaults,
                credentials: .init(password: { _ in "fixture-secret" }, save: { _, _ in }, delete: { _ in }),
                preparedCacheDirectory: directory, automaticRefreshes: automaticRefreshes, providerSession: session,
                scheduleCacheLocation: directory.appendingPathComponent("schedule.json"),
                scheduleFetcher: schedule ?? { _ in .init(games: Dictionary(grouping: games, by: \.league),
                    loadedLeagues: Set(games.map(\.league)), errorMessage: nil) })
        }
        func close() {
            if let block = InstantLiveProtocol.block { Task { await block.release() } }
            session.invalidateAndCancel()
            InstantLiveProtocol.block = nil
            InstantLiveProtocol.responses = [:]
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            for suffix in ["channels", "guide", "state"] {
                try? FileManager.default.removeItem(at: cache.appendingPathComponent("lineup-\(profile.id)-\(suffix).json"))
            }
        }
    }
}

private actor InstantLiveSchedule {
    var games: [SportsGame]
    init(games: [SportsGame]) { self.games = games }
    func replace(_ games: [SportsGame]) { self.games = games }
    func snapshot() -> SportsScheduleClient.Snapshot {
        .init(games: Dictionary(grouping: games, by: \.league), loadedLeagues: Set(games.map(\.league)), errorMessage: nil)
    }
}

private actor InstantLivePublicationGate {
    var open = false
    var permits = 0
    var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        if permits > 0 { permits -= 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func releaseOne() {
        if waiting.isEmpty { permits += 1 } else { waiting.removeFirst().resume() }
    }
    func releaseAll() { open = true; let pending = waiting; waiting = []; for waiter in pending { waiter.resume() } }
}

private actor InstantLiveNetworkBlock {
    let onFirstRequest: @Sendable () -> Void
    private var didEnter = false
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(onFirstRequest: @escaping @Sendable () -> Void) { self.onFirstRequest = onFirstRequest }
    func wait() async {
        if !didEnter { didEnter = true; onFirstRequest() }
        if open { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() { open = true; let pending = waiting; waiting = []; for waiter in pending { waiter.resume() } }
}

private final class InstantLiveProtocol: URLProtocol {
    static var responses: [String: Data] = [:]
    static var block: InstantLiveNetworkBlock?
    private var blockedTask: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let block = Self.block {
            blockedTask = Task { [weak self] in
                await block.wait()
                guard let self, !Task.isCancelled else { return }
                self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
            return
        }
        guard let url = request.url else { return }
        let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "action" }?.value
        let key = url.lastPathComponent == "xmltv.php" ? "xmltv.php" : action ?? ""
        guard let data = Self.responses[key], let response = HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Length": String(data.count)]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { blockedTask?.cancel(); blockedTask = nil }
}
