import XCTest
@testable import LineupiOS

final class GameStateTests: XCTestCase {
    private func game(state: String, startingIn minutes: Double) throws -> SportsGame {
        let start = Date().addingTimeInterval(minutes * 60)
        let payload: [String: Any] = [
            "id": "game-1", "league": "mlb",
            "start": start.timeIntervalSinceReferenceDate,
            "awayTeam": "Rangers", "homeTeam": "Mariners",
            "awayAbbreviation": "TEX", "homeAbbreviation": "SEA",
            "awayLogo": "", "homeLogo": "", "awayScore": "0", "homeScore": "0",
            "status": "Scheduled", "state": state, "broadcast": "MLB Network"
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(SportsGame.self, from: data)
    }

    func testAGameIsUpcomingUntilItsStartTimeArrives() throws {
        let soon = try game(state: "pre", startingIn: 20)
        XCTAssertTrue(soon.isUpcoming)
        XCTAssertFalse(soon.isLive, "A game that has not started is not on air")
    }

    // The schedule feed can lag the first pitch by minutes. While it does, a
    // game reading "pre" used to be neither live nor upcoming to anything that
    // asked: no red dot, nothing in On Air, and no rematch retry.
    func testAStartedGameIsLiveEvenWhileTheFeedStillSaysPre() throws {
        let started = try game(state: "pre", startingIn: -15)
        XCTAssertTrue(started.isLive, "The clock settles what the feed has not")
        XCTAssertFalse(started.isUpcoming, "It cannot be both")
    }

    func testTheFeedSayingInProgressIsAlwaysEnough() throws {
        XCTAssertTrue(try game(state: "in", startingIn: -5).isLive)
        // A feed that calls a game live before its listed start is believed too.
        XCTAssertTrue(try game(state: "in", startingIn: 5).isLive)
    }

    func testAFinishedGameIsNeitherLiveNorUpcoming() throws {
        let finished = try game(state: "post", startingIn: -200)
        XCTAssertFalse(finished.isLive)
        XCTAssertFalse(finished.isUpcoming)
    }

    // A status still reading "pre" long after the start is broken, not late, and
    // must not leave last night's game sitting on air for the rest of the day.
    func testAStaleScheduledStatusStopsCountingAsLive() throws {
        XCTAssertTrue(try game(state: "pre", startingIn: -5 * 60).isLive)
        XCTAssertFalse(try game(state: "pre", startingIn: -7 * 60).isLive)
    }
}

/// What a Live card says about where a game is being played, for every sport
/// the app carries -- not only the one that prompted it.
final class GamePlaceLineTests: XCTestCase {
    private func game(
        league: String,
        venue: String? = nil,
        location: String? = nil,
        eventName: String? = nil
    ) throws -> SportsGame {
        var payload: [String: Any] = [
            "id": "\(league)-1", "league": league,
            "start": Date().timeIntervalSinceReferenceDate,
            "awayTeam": "Away", "homeTeam": "Home",
            "awayAbbreviation": "AWY", "homeAbbreviation": "HME",
            "awayLogo": "", "homeLogo": "", "awayScore": "", "homeScore": "",
            "status": "Scheduled", "state": "pre", "broadcast": "ESPN"
        ]
        if let venue { payload["venue"] = venue }
        if let location { payload["location"] = location }
        if let eventName { payload["eventName"] = eventName }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(SportsGame.self, from: data)
    }

    // Every league, not just the one a tester happened to be looking at.
    func testEveryTeamSportShowsTheCity() throws {
        for league in ["nfl", "nba", "nhl", "mlb", "ncaaf"] {
            let fixture = try game(league: league, venue: "Some Field", location: "Dallas, TX")
            XCTAssertFalse(fixture.isEvent, "\(league) is a fixture, not an event")
            XCTAssertEqual(fixture.placeLine, "Dallas, TX",
                           "\(league) should name the city; the home side already named the venue")
        }
    }

    // The schedule does not always know a city. A venue still says more about
    // where the game is than an empty line does.
    func testAFixtureFallsBackToItsVenue() throws {
        XCTAssertEqual(try game(league: "nba", venue: "Madison Square Garden").placeLine,
                       "Madison Square Garden")
        XCTAssertEqual(try game(league: "nba", venue: "Madison Square Garden", location: "  ").placeLine,
                       "Madison Square Garden", "Blank is not an answer")
    }

    // A UFC card's name says nothing about where it is, so it gets both.
    func testAnEventNamesTheVenueAndTheCity() throws {
        let card = try game(league: "ufc", venue: "T-Mobile Arena", location: "Las Vegas, NV",
                            eventName: "UFC 320")
        XCTAssertTrue(card.isEvent)
        XCTAssertEqual(card.placeLine, "T-Mobile Arena \u{00B7} Las Vegas, NV")
    }

    func testAnEventWithOnlyOneOfThemDoesNotTrailASeparator() throws {
        XCTAssertEqual(try game(league: "ufc", location: "Abu Dhabi", eventName: "UFC Fight Night").placeLine,
                       "Abu Dhabi")
        XCTAssertEqual(try game(league: "ufc", venue: "Etihad Arena", eventName: "UFC Fight Night").placeLine,
                       "Etihad Arena")
    }

    // Nothing to say is said with nothing at all, rather than an empty row.
    func testACardWithNoPlaceShowsNoLine() throws {
        XCTAssertNil(try game(league: "nhl").placeLine)
        XCTAssertNil(try game(league: "nhl", venue: "", location: "").placeLine)
        XCTAssertNil(try game(league: "ufc", eventName: "UFC 321").placeLine)
    }

    // An empty or blank event name is not an event: a fixture keeps its two
    // teams and its city line.
    func testABlankEventNameLeavesAFixtureAlone() throws {
        let fixture = try game(league: "mlb", venue: "Fenway Park", location: "Boston, MA", eventName: "   ")
        XCTAssertFalse(fixture.isEvent)
        XCTAssertEqual(fixture.placeLine, "Boston, MA")
    }
}
