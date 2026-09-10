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
