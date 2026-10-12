import XCTest
@testable import LineupiOS

/// When one of the viewer's teams' games is worth breaking into the picture
/// for, read from the score and the status line however a league writes it.
final class GameAlertTests: XCTestCase {
    private func game(_ league: SportsLeague, _ status: String, away: String, home: String,
                      state: String = "in") -> SportsGame {
        SportsGame(id: "g", league: league, start: Date().addingTimeInterval(-3600),
                   awayTeam: "Away", homeTeam: "Home", awayAbbreviation: "AWY", homeAbbreviation: "HME",
                   awayLogo: "", homeLogo: "", awayScore: away, homeScore: home,
                   awayColor: nil, homeColor: nil, awayRecord: nil, homeRecord: nil, venue: nil,
                   location: nil, status: status, state: state, broadcast: "ESPN", eventName: nil)
    }

    func testThePeriodAndClockAreReadHoweverALeagueWritesThem() {
        XCTAssertEqual(GameAlertRules.moment(of: "Q4 2:31"),
                       GameAlertRules.Moment(period: 4, clockSeconds: 151, overtime: false))
        XCTAssertEqual(GameAlertRules.moment(of: "4th 1:12").period, 4)
        XCTAssertEqual(GameAlertRules.moment(of: "3rd 08:40"),
                       GameAlertRules.Moment(period: 3, clockSeconds: 520, overtime: false))
        XCTAssertEqual(GameAlertRules.moment(of: "Bot 9th"),
                       GameAlertRules.Moment(period: 9, clockSeconds: nil, overtime: false))
        XCTAssertTrue(GameAlertRules.moment(of: "OT 3:12").overtime)
        XCTAssertTrue(GameAlertRules.moment(of: "2OT").overtime)
        XCTAssertTrue(GameAlertRules.moment(of: "SO").overtime)
        XCTAssertNil(GameAlertRules.moment(of: "Halftime").period)
    }

    func testAGameIsCloseLateOnlyLateAndClose() {
        XCTAssertTrue(GameAlertRules.isCloseLate(game(.nba, "Q4 2:31", away: "100", home: "97")))
        XCTAssertFalse(GameAlertRules.isCloseLate(game(.nba, "Q4 2:31", away: "110", home: "97")))
        XCTAssertFalse(GameAlertRules.isCloseLate(game(.nba, "Q3 2:31", away: "100", home: "97")))
        XCTAssertFalse(GameAlertRules.isCloseLate(game(.nba, "Q4 9:00", away: "100", home: "97")))
        XCTAssertTrue(GameAlertRules.isCloseLate(game(.nfl, "4th 3:05", away: "21", home: "17")))
        XCTAssertTrue(GameAlertRules.isCloseLate(game(.nhl, "3rd 05:00", away: "2", home: "1")))
        XCTAssertFalse(GameAlertRules.isCloseLate(game(.nhl, "3rd 05:00", away: "3", home: "1")))
        XCTAssertTrue(GameAlertRules.isCloseLate(game(.mlb, "Top 8th", away: "3", home: "2")))
        XCTAssertFalse(GameAlertRules.isCloseLate(game(.mlb, "Top 6th", away: "3", home: "2")))
    }

    func testOvertimeIsPastRegulationInEveryLeague() {
        XCTAssertTrue(GameAlertRules.isOvertime(game(.nba, "OT 3:12", away: "110", home: "110")))
        XCTAssertTrue(GameAlertRules.isOvertime(game(.mlb, "Top 10th", away: "4", home: "4")))
        XCTAssertFalse(GameAlertRules.isOvertime(game(.mlb, "Bot 9th", away: "4", home: "3")))
        XCTAssertFalse(GameAlertRules.isOvertime(game(.nba, "Q4 0:30", away: "100", home: "100")))
        // A finished game is no news.
        XCTAssertFalse(GameAlertRules.isOvertime(game(.nba, "Final/OT", away: "110", home: "108", state: "post")))
    }

    func testOnlyAChangeSinceTheLastLookIsAnAlert() {
        let before = game(.nba, "7:30 PM", away: "", home: "", state: "pre")
        let started = game(.nba, "Q1 11:40", away: "2", home: "0")
        XCTAssertEqual(GameAlertRules.alerts(from: before, to: started), [.started])
        // Seen for the first time, a game says nothing about what it already is.
        XCTAssertEqual(GameAlertRules.alerts(from: nil, to: started), [])
        let close = game(.nba, "Q4 1:30", away: "101", home: "100")
        XCTAssertEqual(GameAlertRules.alerts(from: started, to: close), [.closeLate])
        XCTAssertEqual(GameAlertRules.alerts(from: close, to: close), [])
        let overtime = game(.nba, "OT 5:00", away: "104", home: "104")
        XCTAssertEqual(GameAlertRules.alerts(from: close, to: overtime), [.overtime])
    }
}
