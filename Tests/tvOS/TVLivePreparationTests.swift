import XCTest
import Observation
@testable import Lineup

@MainActor
final class TVLivePreparationTests: XCTestCase {
    private func event(_ id: String, league: SportsLeague, start: Date, state: String = "in") -> SportsGame {
        let football = league == .nfl
        return SportsGame(id: id, league: league, start: start,
            awayTeam: football ? "Buffalo Bills" : "Orlando Magic",
            homeTeam: football ? "Miami Dolphins" : "Miami Heat",
            awayAbbreviation: football ? "BUF" : "ORL", homeAbbreviation: football ? "MIA" : "MIA",
            awayLogo: "", homeLogo: "", awayScore: "7", homeScore: "10", awayColor: nil, homeColor: nil,
            awayRecord: nil, homeRecord: nil, venue: nil, location: nil,
            status: state == "in" ? "Live" : "Scheduled", state: state,
            broadcast: football ? "Prime Video" : "ABC", eventName: nil)
    }

    func testNewThursdayFootballFeedPlaysBeforeTheRestOfTheSlateFinishes() async throws {
        try await checkNewLiveResult(footballTitle: "Thursday Night Football: Buffalo Bills at Miami Dolphins",
                                    expectedStream: 2)
    }

    func testUnrelatedFootballListingSettlesWithoutAnEndlessSyncMessageOrWrongFeed() async throws {
        try await checkNewLiveResult(footballTitle: "Thursday Night Football: Dallas Cowboys at Philadelphia Eagles",
                                    expectedStream: nil)
    }

    private func checkNewLiveResult(footballTitle: String, expectedStream: Int?) async throws {
        let now = Date()
        let nba = event("saved-nba", league: .nba, start: now.addingTimeInterval(-900))
        let nfl = event("new-tnf", league: .nfl, start: now.addingTimeInterval(-600))
        let upcoming = event("later-nfl", league: .nfl, start: now.addingTimeInterval(3600), state: "pre")
        let profile = XtreamProfile(name: "TV test", serverURL: "https://tv-live.invalid", username: "viewer")
        let suite = "TVLivePreparation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(try JSONEncoder().encode([profile]), forKey: "NullSports.profiles")
        defaults.set(profile.id.uuidString, forKey: "NullSports.activeProfile")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            for suffix in ["channels", "guide", "state"] {
                try? FileManager.default.removeItem(at: cache.appendingPathComponent("lineup-\(profile.id)-\(suffix).json"))
            }
        }
        let categories = [XtreamCategory(categoryID: "sports", categoryName: "Sports")]
        let streams = [("US: ABC Miami FHD", "nba"), ("US: Prime Video FHD", "nfl")].enumerated().map { index, entry in
            XtreamStream(num: nil, name: entry.0, streamType: "live", streamID: index + 1,
                streamIcon: nil, epgChannelID: entry.1, categoryID: "sports")
        }
        let nbaProgram = CurrentProgram(channelID: "nba", title: "NBA Basketball: Orlando Magic at Miami Heat",
            detail: "", start: now.addingTimeInterval(-1800), end: now.addingTimeInterval(7200))
        let nbaChannels = SportsLibrary.matchingEventChannels(for: nba, candidates: [streams[0]],
            programs: ["nba": [nbaProgram]], categories: categories, now: now)
        XCTAssertEqual(nbaChannels.map(\.id), [1])
        let saved = PreparedLiveMatch(preparedAt: now.addingTimeInterval(-60), eventStart: nba.start,
            identity: PreparedLiveMatch.identity(for: nba), primary: streams[0], alternatives: nbaChannels,
            programs: ["nba": [nbaProgram]], categoryNames: ["sports": "Sports"])
        // The other live event already works; only TNF lacks a prepared result.
        let snapshot = PreparedLiveSnapshot(version: PreparedLiveSnapshot.version,
            connection: PreparedLiveSnapshot.connection(for: profile), savedAt: now, dailyPreparedAt: now,
            games: ["nba": [nba], "nfl": [nfl, upcoming]], loadedLeagues: ["nba", "nfl"],
            matches: [nba.id: saved])
        PreparedLiveStore.write(snapshot, profileID: profile.id, directory: directory)

        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.timeZone = TimeZone(secondsFromGMT: 0)
        date.dateFormat = "yyyyMMddHHmmss Z"
        let start = date.string(from: nbaProgram.start), end = date.string(from: nbaProgram.end)
        let xml = """
        <tv>
          <programme channel="nba" start="\(start)" stop="\(end)"><title>\(nbaProgram.title)</title></programme>
          <programme channel="nfl" start="\(start)" stop="\(end)"><title>\(footballTitle)</title></programme>
        </tv>
        """
        TVLivePreparationProtocol.responses = [
            "get_live_categories": try JSONEncoder().encode(categories),
            "get_live_streams": try JSONEncoder().encode(streams),
            "xmltv.php": Data(xml.utf8)
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TVLivePreparationProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); TVLivePreparationProtocol.responses = [:] }
        let library = SportsLibrary(profileDefaults: defaults,
            credentials: .init(password: { _ in "test-only-secret" }, save: { _, _ in }, delete: { _ in }),
            preparedCacheDirectory: directory, automaticRefreshes: false, providerSession: session,
            scheduleCacheLocation: directory.appendingPathComponent("schedule.json"))
        _ = await library.restorePreparedMatches()
        XCTAssertEqual(library.preparedPlaybackStream(for: nba)?.id, 1)
        XCTAssertFalse(library.eventChannelsReady(for: nfl))

        let ready = expectation(description: "TNF settles independently of the upcoming slate")
        let observation = TVLivePreparationObservation(library: library, game: nfl) {
            XCTAssertTrue(library.channelsAreSyncing, "The wider refresh is still running")
            XCTAssertFalse(library.automaticMatchingReady, "The full matching pass has not finished")
            XCTAssertFalse(library.eventChannelsReady(for: upcoming), "Future events do not gate this live game")
            XCTAssertEqual(library.preparedPlaybackStream(for: nba)?.id, 1)
            if let expectedStream {
                XCTAssertEqual(library.preparedPlaybackStream(for: nfl)?.id, expectedStream)
                XCTAssertEqual(library.preferredChannel(for: nfl), .play(streamID: expectedStream, source: .verified))
            } else {
                XCTAssertNil(library.preparedPlaybackStream(for: nfl))
                XCTAssertEqual(library.preferredChannel(for: nfl), .pick,
                               "A completed no-match result must not pretend to keep syncing")
            }
            ready.fulfill()
        }
        observation.check()
        let refresh = Task { await library.reload() }
        await fulfillment(of: [ready], timeout: 10)
        observation.stop()
        await refresh.value
        XCTAssertEqual(library.preparedPlaybackStream(for: nfl)?.id, expectedStream)
    }
}

@MainActor
private final class TVLivePreparationObservation {
    let library: SportsLibrary
    let game: SportsGame
    let onReady: () -> Void
    private var active = true

    init(library: SportsLibrary, game: SportsGame, onReady: @escaping () -> Void) {
        self.library = library; self.game = game; self.onReady = onReady
    }
    func stop() { active = false }
    func check() {
        guard active else { return }
        if library.eventChannelsReady(for: game) {
            active = false
            onReady()
            return
        }
        withObservationTracking { _ = library.eventChannelsInputs } onChange: { [weak self] in
            Task { @MainActor in self?.check() }
        }
    }
}

private final class TVLivePreparationProtocol: URLProtocol {
    static var responses: [String: Data] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "action" }?.value
        let key = url.lastPathComponent == "xmltv.php" ? "xmltv.php" : action ?? ""
        guard let data = Self.responses[key], let response = HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Length": String(data.count)]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
