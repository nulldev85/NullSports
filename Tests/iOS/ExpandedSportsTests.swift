import XCTest
#if os(tvOS)
@testable import Lineup
#else
@testable import LineupiOS
#endif

final class ExpandedSportsTests: XCTestCase {
    func testCapturedCricketFeedPreservesRealSidesScoresAndMultiDayStatus() throws {
        let games = try CricketScheduleClient.decode(fixture("cricket-schedule"))
        XCTAssertEqual(games.count, 6)
        let test = try XCTUnwrap(games.first { $0.id == "cricket-1552530" })
        XCTAssertEqual(test.awayTeam, "India A")
        XCTAssertEqual(test.homeTeam, "New Zealand A")
        XCTAssertEqual(test.awayScore, "333/8 (99 ov)")
        XCTAssertEqual(test.homeScore, "")
        XCTAssertEqual(test.cricket?.format, "Test")
        XCTAssertTrue(test.status.contains("Day 2"))
        XCTAssertEqual(test.state, "in")
        XCTAssertTrue(test.isLive, "An ongoing Test from an earlier day must enter the Live list")
        XCTAssertEqual(test.matchupLine, "India A vs New Zealand A")
        XCTAssertNotNil(test.cricket?.end)
        XCTAssertTrue(try XCTUnwrap(test.cricket?.end) > test.start.addingTimeInterval(3 * 86_400))
        XCTAssertEqual(test.awayTeamID, "1781")
        XCTAssertTrue(test.awayLogo.hasPrefix("https://a.espncdn.com/"))
        let stumps = try XCTUnwrap(games.first { $0.id == "cricket-1544871" })
        XCTAssertTrue(stumps.status.contains("Stumps"))
        XCTAssertEqual(games.filter { $0.homeTeam.contains("Women") }.count, 2)
        let result = try XCTUnwrap(games.first { $0.id == "cricket-1550719" })
        XCTAssertEqual(result.state, "post")
        XCTAssertTrue(result.status.contains("won by 3 wkts"))
        XCTAssertEqual(CricketMatch.runs(result.homeScore), "331/7")
        XCTAssertEqual(CricketMatch.overs(result.homeScore), "48.3/50 ov, target 326")
        XCTAssertEqual(CricketMatch.runs("245 & 170/2 (35.1 ov, target 170)"), "245 & 170/2")
        XCTAssertEqual(try JSONDecoder().decode(SportsGame.self, from: JSONEncoder().encode(test)), test)
    }

    func testCricketRejectsMalformedFeedsAndAcceptsSuccessfulEmptyDays() throws {
        XCTAssertThrowsError(try CricketScheduleClient.decode(Data("{\"error\":\"outage\"}".utf8)))
        XCTAssertEqual(try CricketScheduleClient.decode(Data("{\"sports\":[{\"slug\":\"cricket\",\"leagues\":[]}]}".utf8)), [])
        XCTAssertThrowsError(try CricketScheduleClient.decode(Data("{\"sports\":[{\"slug\":\"soccer\",\"leagues\":[]}]}".utf8)))
    }

    func testCricketRequestsAreCachedDeduplicatedAndKeepTestsFromPreviousDays() async throws {
        let fixture = try fixture("cricket-schedule")
        let source = CricketFixtureTransport(data: fixture)
        let start = try XCTUnwrap(SportsScheduleClient.parseDate("2026-10-31T07:00Z"))
        let end = try XCTUnwrap(SportsScheduleClient.parseDate("2026-11-02T08:00Z"))
        let client = CricketScheduleClient(now: { start }, transport: { try await source.load($0) })
        async let first = client.games(from: start, to: end)
        async let second = client.games(from: start, to: end)
        let (a, b) = await (first, second)
        XCTAssertEqual(a.loadedLeagues, [.cricket])
        XCTAssertNil(a.errorMessage)
        XCTAssertEqual(a.games[.cricket]?.count, 6, "Repeated daily appearances must remain one match")
        XCTAssertEqual(a.games, b.games)
        XCTAssertTrue(a.games[.cricket]?.contains { $0.id == "cricket-1552530" && $0.start < start } == true)
        let requests = await source.requests
        XCTAssertEqual(Set(requests).count, requests.count, "Concurrent refreshes share each daily request")
        XCTAssertTrue(requests.allSatisfy { $0.host == "site.web.api.espn.com" && $0.query?.contains("sport=cricket") == true })
        let failed = CricketScheduleClient(transport: { _ in throw URLError(.notConnectedToInternet) })
        let failure = await failed.games(from: start, to: end)
        XCTAssertTrue(failure.loadedLeagues.isEmpty)
        XCTAssertTrue(failure.games.isEmpty, "A failed request cannot erase a previous good slate")
        XCTAssertNotNil(failure.errorMessage)
    }

    func testCricketProductionMatchingHandlesLaterTestDaysAndRejectsOtherSquads() throws {
        let games = try CricketScheduleClient.decode(fixture("cricket-schedule"))
        let game = try XCTUnwrap(games.first { $0.id == "cricket-1552530" })
        let now = game.start.addingTimeInterval(2 * 86_400)
        let listing = CurrentProgram(channelID: "cricket", title: "Live Cricket: India A vs New Zealand A", detail: "",
            start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(10800))
        func channels(_ names: [String], title: String? = nil) -> [Int] {
            let streams = names.enumerated().map { index, name in
                XtreamStream(num: index, name: name, streamType: "live", streamID: index,
                    streamIcon: nil, epgChannelID: "cricket", categoryID: nil)
            }
            let entry = title.map { CurrentProgram(channelID: "cricket", title: $0, detail: "", start: listing.start, end: listing.end) } ?? listing
            return SportsLibrary.matchingEventChannels(for: game, candidates: streams,
                programs: ["cricket": [entry]], categories: [], now: now).map(\.id)
        }
        XCTAssertEqual(channels(["Willow HD"]), [0], "A day-three guide slot is valid despite the original match start")
        XCTAssertEqual(channels(["Cricket India A vs New Zealand A"], title: "Cricket"), [0])
        XCTAssertTrue(channels(["Willow HD"], title: "India vs New Zealand").isEmpty)
        XCTAssertTrue(channels(["Willow HD"], title: "India Women vs New Zealand Women").isEmpty)
        XCTAssertTrue(channels(["Cricket T20 India A vs New Zealand A"]).isEmpty)
        XCTAssertTrue(channels(["Willow HD"], title: "India A vs New Zealand A Highlights").isEmpty)
        XCTAssertTrue(channels(["Cricket India Women vs New Zealand Women"]).isEmpty)
    }

    func testCricketDiscoveryUsesWholeWordsAndCompetitionNames() {
        for name in ["UK: Sky Sports Cricket HD", "US: WILLOW FHD", "IPL 02", "BBL", "PSL", "CPL", "ILT20", "SA20", "T20", "ODI", "The Hundred"] {
            XCTAssertTrue(SportsLeague.cricket.matches(name), name)
        }
        for name in ["Willowbrook Movies", "Display Channel", "ODISEA", "The Hundredth Episode", "NBA TV"] {
            XCTAssertFalse(SportsLeague.cricket.matches(name), name)
        }
    }

    func testCricketDecodesScoresAndWaitsForConfirmedPlay() throws {
        let payload: [String: Any] = [
            "id": "cricket-123", "league": "cricket",
            "start": Date().addingTimeInterval(-3600).timeIntervalSinceReferenceDate,
            "awayTeam": "India", "homeTeam": "Australia",
            "awayAbbreviation": "IND", "homeAbbreviation": "AUS",
            "awayLogo": "", "homeLogo": "", "awayScore": "185/4 (20)", "homeScore": "142/6 (17.2)",
            "status": "Delayed", "state": "pre", "broadcast": "Willow"
        ]
        let game = try JSONDecoder().decode(SportsGame.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(game.league, .cricket)
        XCTAssertEqual(game.awayScore, "185/4 (20)")
        XCTAssertEqual(game.homeScore, "142/6 (17.2)")
        XCTAssertFalse(game.isLive, "A delayed match cannot become live just because its scheduled time passed")
        XCTAssertTrue(game.isUpcoming)
        XCTAssertEqual(SportsLeague.cricket.shortName, "Cricket")
    }

    func testCricketPlaybackRequiresBothTeamsAndCurrentCoverage() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let game = ProfessionalChannelMatcher.Matchup(away: "India", home: "Australia",
            awayAbbreviation: "IND", homeAbbreviation: "AUS", start: start, isLive: true)
        func score(_ channel: String, title: String? = nil) -> Int? {
            let listings = title.map { [ProfessionalChannelMatcher.Listing(title: $0, detail: "",
                start: start, end: start.addingTimeInterval(14400))] } ?? []
            return ProfessionalChannelMatcher.score(channel: channel, listings: listings, game: game,
                now: start.addingTimeInterval(3600))
        }
        XCTAssertNil(score("Willow"))
        XCTAssertNil(score("Cricket India"))
        XCTAssertNotNil(score("Cricket IND vs AUS"))
        XCTAssertNotNil(score("Cricket India vs Australia", title: "Cricket"))
        XCTAssertNotNil(score("Willow", title: "India vs Australia"))
        XCTAssertNil(score("Willow", title: "India vs Australia Highlights"))
        XCTAssertNil(score("Cricket India vs Australia", title: "England vs Pakistan"))
    }

    func testRequestedDomesticCupsDecodeRealFixturesAndKeepStrictMatchEvidence() throws {
        for slug in ["eng.league_cup", "eng.fa", "esp.copa_del_rey", "esp.super_cup"] {
            let data = try fixture("soccer-\(slug)")
            let games = try ExpandedSportsScheduleClient.soccerGames(data: data, competitions: catalog)
            XCTAssertFalse(games.isEmpty, "The captured \(slug) fixture must be accepted")
            XCTAssertTrue(games.allSatisfy { $0.competition?.id == slug })
            let game = try XCTUnwrap(games.first)
            XCTAssertFalse(try XCTUnwrap(game.awayTeamID).isEmpty)
            XCTAssertFalse(try XCTUnwrap(game.homeTeamID).isEmpty)
            let prepared = ExpandedSportsChannelMatcher.soccer(game)
            let listing = "\(game.competition!.shortName): \(game.awayTeam) vs \(game.homeTeam)"
            XCTAssertNotNil(ExpandedSportsChannelMatcher.soccerScore(
                channel: channel("Sports", listing: listing, at: game.start), prepared: prepared, game: game, now: game.start))
            XCTAssertNil(ExpandedSportsChannelMatcher.soccerScore(
                channel: channel("Sports", at: game.start), prepared: prepared, game: game, now: game.start),
                "A broadcaster name must not authorize an unrelated cup game")
            XCTAssertNil(ExpandedSportsChannelMatcher.soccerScore(
                channel: channel("Sports", listing: "Replay: \(listing)", at: game.start), prepared: prepared, game: game, now: game.start))
            XCTAssertTrue(try ExpandedSportsScheduleClient.soccerGames(data: data,
                competitions: catalog.filter { $0.id != slug }).isEmpty, "Unknown competitions remain excluded")
        }
    }

    private var catalog: [SportsCompetition] { SportsCompetitionCatalog.bundled.competitions }
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }
    private func changingSoccer(_ change: (inout [String: Any]) -> Void) throws -> Data {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("soccer-schedule")) as? [String: Any])
        change(&root)
        return try JSONSerialization.data(withJSONObject: root)
    }
    private func soccer(_ data: Data? = nil) throws -> SportsGame {
        try XCTUnwrap(ExpandedSportsScheduleClient.soccerGames(data: data ?? fixture("soccer-schedule"), competitions: catalog).first)
    }
    private func channel(_ name: String, listing: String? = nil, at start: Date) -> ProfessionalChannelMatcher.PreparedChannel {
        let listings = listing.map { [ProfessionalChannelMatcher.Listing(title: $0, detail: "",
            start: start.addingTimeInterval(-900), end: start.addingTimeInterval(3 * 3600))] } ?? []
        return ProfessionalChannelMatcher.prepare(channel: name, listings: ProfessionalChannelMatcher.prepare(listings))
    }

    func testSoccerHasOfficialCompetitionCrestsAndStableClubIDs() throws {
        let game = try soccer()
        XCTAssertEqual(game.id, "soccer-401878771")
        XCTAssertEqual(game.competition?.id, "eng.1")
        XCTAssertEqual(game.competition?.name, "Premier League")
        XCTAssertEqual(game.awayTeam, "Chelsea")
        XCTAssertEqual(game.homeTeam, "Everton")
        XCTAssertEqual(game.awayTeamID, "363")
        XCTAssertEqual(game.homeTeamID, "368")
        XCTAssertEqual(game.awayScore, "0")
        XCTAssertEqual(game.homeScore, "0")
        XCTAssertEqual(URL(string: game.homeLogo)?.host, "a.espncdn.com")
        XCTAssertEqual(game.broadcast, "USA Net, Universo")
        XCTAssertEqual(game.matchupLine, "Chelsea vs Everton")
        XCTAssertFalse(game.isEvent)
    }

    func testMalformedAndUnsupportedSoccerEventsCannotBecomeFakeFixtures() throws {
        let data = try changingSoccer { root in
            var events = root["events"] as! [[String: Any]]
            var foreign = events[0]
            foreign["uid"] = "s:600~l:999999~e:123"
            events.append(foreign)
            events.append(["id": "broken", "uid": "s:600~l:700~e:broken"])
            root["events"] = events
        }
        XCTAssertEqual(try ExpandedSportsScheduleClient.soccerGames(data: data, competitions: catalog).count, 1)
        XCTAssertThrowsError(try ExpandedSportsScheduleClient.soccerGames(data: Data("{\"error\":\"outage\"}".utf8), competitions: catalog))
    }

    func testDelayedKickoffDoesNotInventALiveScoreAndPostponementsAreNotPlayable() throws {
        let data = try changingSoccer { root in
            var events = root["events"] as! [[String: Any]]
            var contests = events[0]["competitions"] as! [[String: Any]]
            contests[0]["date"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-300))
            contests[0]["status"] = ["type": ["state": "pre", "name": "STATUS_SCHEDULED", "shortDetail": "Delayed"]]
            events[0]["competitions"] = contests
            root["events"] = events
        }
        let delayed = try soccer(data)
        XCTAssertFalse(delayed.isLive)
        XCTAssertTrue(delayed.isUpcoming)
        let postponed = try changingSoccer { root in
            var events = root["events"] as! [[String: Any]]
            var contests = events[0]["competitions"] as! [[String: Any]]
            contests[0]["status"] = ["type": ["state": "pre", "name": "STATUS_POSTPONED", "shortDetail": "Postponed"]]
            events[0]["competitions"] = contests; root["events"] = events
        }
        XCTAssertFalse(try soccer(postponed).isLive)
        XCTAssertFalse(try soccer(postponed).isUpcoming)
    }

    func testSoccerPenaltyAndAggregateScoresDoNotReplaceTheMatchScore() throws {
        let data = try changingSoccer { root in
            var events = root["events"] as! [[String: Any]]
            var contests = events[0]["competitions"] as! [[String: Any]]
            var sides = contests[0]["competitors"] as! [[String: Any]]
            for index in sides.indices {
                sides[index]["score"] = 1
                sides[index]["shootoutScore"] = sides[index]["homeAway"] as? String == "away" ? "4" : "3"
            }
            contests[0]["competitors"] = sides; events[0]["competitions"] = contests; root["events"] = events
        }
        let game = try soccer(data)
        XCTAssertEqual(game.awayScore, "1")
        XCTAssertEqual(game.homeScore, "1")
        XCTAssertEqual(game.soccer?.detail, "Penalties 4–3")
        XCTAssertNil(SoccerScore(awayPenalties: "0", homePenalties: "0", awayAggregate: nil, homeAggregate: nil).detail)
        XCTAssertEqual(SoccerScore(awayPenalties: nil, homePenalties: nil, awayAggregate: "2", homeAggregate: "2").detail, "Aggregate 2–2")
    }

    func testSoccerRequiresBothTeamsAndRejectsReplaysAndWrongFixtures() throws {
        let game = try soccer(), prepared = ExpandedSportsChannelMatcher.soccer(try soccer())
        func score(_ name: String, _ listing: String? = nil) -> Int? {
            ExpandedSportsChannelMatcher.soccerScore(channel: channel(name, listing: listing, at: game.start),
                prepared: prepared, game: game, now: game.start)
        }
        XCTAssertEqual(score("EPL 01: Chelsea vs Everton"), 400)
        XCTAssertEqual(score("USA Network", "Premier League: Chelsea v Everton"), 300)
        XCTAssertNil(score("USA Network"))
        XCTAssertNil(score("Chelsea TV"))
        XCTAssertNil(score("EPL 01 Chelsea vs Everton", "Arsenal vs Liverpool"))
        XCTAssertNil(score("USA Network", "Classic 2025: Chelsea vs Everton"))
        XCTAssertNil(score("Chelsea vs Everton Highlights"))
        XCTAssertNil(score("2025 Chelsea vs Everton"))
        XCTAssertNil(score("Chelsea vs Everton", "Chelsea Women vs Everton Women"))
        XCTAssertNil(score("USA Network", "Chelsea U21 vs Everton U21"))
        let other = SportsGame(id: "derby", league: .soccer, start: game.start,
            awayTeam: "Manchester United", homeTeam: "Leeds United", awayAbbreviation: "MUN", homeAbbreviation: "LEE",
            awayLogo: "", homeLogo: "", awayScore: "", homeScore: "", awayColor: nil, homeColor: nil,
            awayRecord: nil, homeRecord: nil, venue: nil, location: nil, status: "Scheduled", state: "pre", broadcast: "", eventName: nil)
        XCTAssertNil(ExpandedSportsChannelMatcher.soccerScore(channel: channel("United TV", at: game.start),
            prepared: ExpandedSportsChannelMatcher.soccer(other), game: other, now: game.start))
    }

    func testNationalTeamMatchesDistinguishTheMensAndWomensCompetitions() throws {
        let data = try changingSoccer { root in
            var events = root["events"] as! [[String: Any]]
            var contests = events[0]["competitions"] as! [[String: Any]]
            var sides = contests[0]["competitors"] as! [[String: Any]]
            for index in sides.indices {
                let away = sides[index]["homeAway"] as? String == "away"
                sides[index]["team"] = ["id": away ? "448" : "481", "displayName": away ? "England" : "Germany",
                                        "abbreviation": away ? "ENG" : "GER"]
            }
            contests[0]["competitors"] = sides; events[0]["competitions"] = contests; root["events"] = events
        }
        var game = try soccer(data)
        let prepared = ExpandedSportsChannelMatcher.soccer(game)
        func score(_ title: String) -> Int? {
            ExpandedSportsChannelMatcher.soccerScore(channel: channel("Sports", listing: title, at: game.start),
                prepared: prepared, game: game, now: game.start)
        }
        game.competition = catalog.first { $0.id == "fifa.wwc" }
        XCTAssertNil(score("FIFA World Cup England vs Germany"))
        XCTAssertEqual(score("FIFA Women's World Cup England vs Germany"), 300)
        game.competition = catalog.first { $0.id == "fifa.world" }
        XCTAssertNil(score("FIFA Women's World Cup England vs Germany"))
        XCTAssertEqual(score("FIFA World Cup England vs Germany"), 300)
    }

    func testSoccerAlertsUseTheActualMatchPeriodAndElapsedClock() throws {
        let source = try soccer()
        func gameWithState(_ state: String) -> SportsGame {
            SportsGame(id: source.id, league: .soccer, start: source.start,
                awayTeam: source.awayTeam, homeTeam: source.homeTeam, awayAbbreviation: "CHE", homeAbbreviation: "EVE",
                awayLogo: "", homeLogo: "", awayScore: "1", homeScore: "1", awayColor: nil, homeColor: nil,
                awayRecord: nil, homeRecord: nil, venue: nil, location: nil, status: "80'", state: state, broadcast: "", eventName: nil)
        }
        var game = gameWithState("in")
        game.soccer = SoccerScore(awayPenalties: nil, homePenalties: nil, awayAggregate: nil, homeAggregate: nil,
                                 period: 2, clockSeconds: 80 * 60)
        XCTAssertTrue(GameAlertRules.isCloseLate(game))
        XCTAssertFalse(GameAlertRules.isOvertime(game))
        game.soccer?.clockSeconds = 30 * 60
        XCTAssertFalse(GameAlertRules.isCloseLate(game))
        game.soccer?.period = 3
        XCTAssertTrue(GameAlertRules.isOvertime(game))
        var final = gameWithState("post")
        final.soccer = game.soccer
        XCTAssertFalse(GameAlertRules.isOvertime(final))
    }

    func testRacingUsesEachSessionsActualTimeAndPreservesOfficialDriverData() throws {
        let weekend = try ExpandedSportsScheduleClient.racingGames(data: fixture("f1-weekend"), league: .f1)
        XCTAssertEqual(weekend.count, 5)
        XCTAssertEqual(Set(weekend.map(\.id)).count, 5)
        XCTAssertEqual(weekend.compactMap { $0.race?.title }, ["Practice 1", "Practice 2", "Practice 3", "Qualifying", "Race"])
        XCTAssertEqual(weekend.last?.start, SportsScheduleClient.parseDate("2026-10-25T20:00Z"))
        XCTAssertEqual(weekend.first?.race?.circuit, "Circuit of the Americas")
        XCTAssertTrue(weekend.allSatisfy { $0.isEvent && $0.awayScore.isEmpty && $0.homeScore.isEmpty })
        XCTAssertTrue(weekend[3].matchupLine.contains("Qualifying"))
        let results = try ExpandedSportsScheduleClient.racingGames(data: fixture("f1-result"), league: .f1)
        let race = try XCTUnwrap(results.first { $0.race?.title == "Race" })
        XCTAssertEqual(race.race?.entrants.count, 22)
        XCTAssertEqual(race.race?.entrants.first?.name, "Max Verstappen")
        XCTAssertEqual(race.race?.entrants.first?.position, 1)
        XCTAssertEqual(URL(string: try XCTUnwrap(race.race?.entrants.first?.flag))?.host, "a.espncdn.com")
        let nascar = try XCTUnwrap(ExpandedSportsScheduleClient.racingGames(data: fixture("nascar-schedule"), league: .nascar).first)
        XCTAssertEqual(nascar.race?.title, "Cup Series Race")
        XCTAssertTrue(nascar.matchupLine.contains("Phoenix"))
        XCTAssertEqual(nascar.broadcast, "USA Net, HBO Max")
        XCTAssertEqual(ExpandedSportsScheduleClient.sessionTitle("SQ", league: .f1), "Sprint Qualifying")
        XCTAssertEqual(ExpandedSportsScheduleClient.sessionTitle("Sprint", league: .f1), "Sprint")
    }

    func testRaceMatchingCannotConfuseQualifyingPracticeSeriesOrArchiveCoverage() throws {
        let weekend = try ExpandedSportsScheduleClient.racingGames(data: fixture("f1-weekend"), league: .f1)
        let race = try XCTUnwrap(weekend.last), qualifying = weekend[3], practice = weekend[0]
        func score(_ game: SportsGame, _ title: String, listing: String? = nil) -> Int? {
            ExpandedSportsChannelMatcher.racingScore(channel: channel(title, listing: listing, at: game.start), game: game, now: game.start)
        }
        XCTAssertEqual(score(race, "F1 United States Grand Prix"), 400)
        XCTAssertEqual(score(qualifying, "Sky Sports F1", listing: "Formula 1 United States GP Qualifying"), 300)
        XCTAssertEqual(score(practice, "F1 Austin Practice 1"), 400)
        XCTAssertNil(score(race, "Sky Sports F1"))
        XCTAssertNil(score(race, "F1 Austin Qualifying"))
        XCTAssertNil(score(qualifying, "F1 Austin Sprint Qualifying"))
        XCTAssertNil(score(practice, "F1 Austin Practice 2"))
        XCTAssertNil(score(race, "F1 Austin Pre-Race"))
        XCTAssertNil(score(race, "F1 Austin", listing: "2025 Formula 1 United States Grand Prix Replay"))
        let nascar = try XCTUnwrap(ExpandedSportsScheduleClient.racingGames(data: fixture("nascar-schedule"), league: .nascar).first)
        XCTAssertEqual(score(nascar, "NASCAR Cup Series at Phoenix"), 400)
        XCTAssertNil(score(nascar, "NASCAR Xfinity at Phoenix"))
        XCTAssertNil(score(nascar, "NASCAR Cup Series at Daytona"))
    }

    func testFeedDaysRespectEasternMidnightAndDaylightSavingBoundaries() throws {
        func date(_ value: String) throws -> Date { try XCTUnwrap(SportsScheduleClient.parseDate(value)) }
        XCTAssertEqual(ExpandedSportsScheduleClient.feedDates(from: try date("2026-10-17T03:30Z"), to: try date("2026-10-17T04:30Z")), ["20261016", "20261017"])
        XCTAssertEqual(ExpandedSportsScheduleClient.feedDates(from: try date("2026-11-01T03:30Z"), to: try date("2026-11-02T05:00Z")), ["20261031", "20261101"])
    }

    func testSportsOutagesAreIsolatedAndRepeatedRefreshesReuseTheSameFeed() async throws {
        let source = FixtureTransport(soccer: try fixture("soccer-schedule"), f1: try fixture("f1-weekend"), nascar: try fixture("nascar-schedule"), failNASCAR: true)
        let start = try XCTUnwrap(SportsScheduleClient.parseDate("2026-10-17T04:00Z")), end = start.addingTimeInterval(2 * 86_400)
        let client = ExpandedSportsScheduleClient(competitions: catalog, now: { start }, transport: { try await source.load($0) })
        let first = await client.games(from: start, to: end, racingTo: end.addingTimeInterval(14 * 86_400))
        XCTAssertEqual(first.loadedLeagues, [.soccer, .f1])
        XCTAssertEqual(first.games[.soccer]?.count, 1, "A match returned on multiple feed days must appear once")
        XCTAssertEqual(first.games[.f1]?.count, 5, "The racing window must include the next weekend")
        XCTAssertTrue(first.errorMessage?.contains("NASCAR") == true)
        let previous = (await source.requests).filter { !$0.path.contains("nascar") }.count
        _ = await client.games(from: start, to: end, racingTo: end.addingTimeInterval(14 * 86_400))
        let after = (await source.requests).filter { !$0.path.contains("nascar") }.count
        XCTAssertEqual(after, previous)
    }

    func testGlobalSoccerPageAtItsLimitFallsBackToEachCompetition() async throws {
        let original = try fixture("soccer-schedule")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        let event = try XCTUnwrap((root["events"] as? [[String: Any]])?.first)
        let capped = try JSONSerialization.data(withJSONObject: ["events": Array(repeating: event, count: 1000)])
        let source = FixtureTransport(soccer: original, f1: try fixture("f1-weekend"), nascar: try fixture("nascar-schedule"), capped: capped)
        let start = try XCTUnwrap(SportsScheduleClient.parseDate("2026-10-17T04:00Z"))
        let client = ExpandedSportsScheduleClient(competitions: catalog.filter { $0.id == "eng.1" }, now: { start }, transport: { try await source.load($0) })
        let result = await client.games(from: start, to: start.addingTimeInterval(86_400))
        XCTAssertTrue(result.loadedLeagues.contains(.soccer))
        let requests = await source.requests
        XCTAssertTrue(requests.contains { $0.path.contains("soccer/eng.1/") })
        XCTAssertEqual(result.games[.soccer]?.count, 1)
    }
}

private actor FixtureTransport {
    let soccer: Data
    let f1: Data
    let nascar: Data
    let failNASCAR: Bool
    let capped: Data?
    private(set) var requests: [URL] = []
    init(soccer: Data, f1: Data, nascar: Data, failNASCAR: Bool = false, capped: Data? = nil) {
        self.soccer = soccer; self.f1 = f1; self.nascar = nascar
        self.failNASCAR = failNASCAR; self.capped = capped
    }
    func load(_ url: URL) throws -> Data {
        requests.append(url)
        if url.path.contains("nascar") {
            if failNASCAR { throw URLError(.cannotConnectToHost) }
            return nascar
        }
        if url.path.contains("racing/f1") { return f1 }
        return url.path.contains("soccer/all/") ? (capped ?? soccer) : soccer
    }
}

private actor CricketFixtureTransport {
    let data: Data
    private(set) var requests: [URL] = []
    init(data: Data) { self.data = data }
    func load(_ url: URL) -> Data { requests.append(url); return data }
}
