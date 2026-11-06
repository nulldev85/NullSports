import XCTest
@testable import LineupiOS

/// A late game out West is filed under the day it started in the East, so
/// after midnight it is yesterday's -- and still on.
final class SportsOvernightTests: XCTestCase {
    private func game(_ id: String, league: SportsLeague = .nba, state: String, start: Date) -> SportsGame {
        SportsGame(id: id, league: league, start: start,
            awayTeam: "Miami Heat", homeTeam: "Golden State Warriors", awayAbbreviation: "MIA", homeAbbreviation: "GS",
            awayLogo: "", homeLogo: "", awayScore: "88", homeScore: "90", awayColor: nil, homeColor: nil,
            awayRecord: nil, homeRecord: nil, venue: nil, location: nil, status: "Q4", state: state,
            broadcast: "ESPN", eventName: nil)
    }

    func testYesterdayIsAskedForOnlyInTheSmallHours() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let afterMidnight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 0, minute: 20)))
        let yesterday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 5)))
        XCTAssertEqual(SportsScheduleClient.overnightDay(for: afterMidnight, calendar: calendar), yesterday)
        let midday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 13)))
        XCTAssertNil(SportsScheduleClient.overnightDay(for: midday, calendar: calendar))
    }

    func testOnlyYesterdaysLiveGamesJoinToday() {
        let started = Date().addingTimeInterval(-2 * 3600)
        let live = game("nba-live", state: "in", start: started)
        let over = game("nba-over", state: "post", start: started.addingTimeInterval(-3600))
        let tonight = game("nba-tonight", state: "pre", start: Date().addingTimeInterval(18 * 3600))
        let yesterday = SportsScheduleClient.Snapshot(games: [.nba: [live, over], .nhl: [game("nhl-live", league: .nhl, state: "in", start: started)]],
                                                      loadedLeagues: [.nba, .nhl], errorMessage: nil)
        let today = SportsScheduleClient.Snapshot(games: [.nba: [tonight, live]], loadedLeagues: [.nba], errorMessage: nil)
        let merged = SportsScheduleClient.addingOvernight(yesterday, to: today)
        XCTAssertEqual(merged.games[.nba]?.map(\.id), ["nba-live", "nba-tonight"],
                       "The live game once, the finished one not at all")
        XCTAssertNil(merged.games[.nhl], "A league today's fetch did not load is left as it was")
        XCTAssertEqual(SportsScheduleClient.addingOvernight(nil, to: today).games[.nba]?.count, 2)
    }
}
