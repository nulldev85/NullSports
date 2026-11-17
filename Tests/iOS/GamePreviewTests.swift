import XCTest
@testable import LineupiOS

/// The page a game still to come opens: its day, and each side's form.
final class GamePreviewTests: XCTestCase {
    private func game(_ day: Int, _ state: String, _ outcome: TeamPageGame.Outcome?) -> TeamPageGame {
        TeamPageGame(id: "\(day)", date: Date(timeIntervalSince1970: TimeInterval(day) * 86_400),
                     opponent: "Them", opponentAbbreviation: "THM", opponentLogo: nil, isHome: true,
                     state: state, teamScore: nil, opponentScore: nil, outcome: outcome, status: "",
                     broadcast: nil, label: nil)
    }

    func testFormIsTheLastFiveGamesPlayedOldestFirst() {
        let games = [game(7, "post", .win), game(1, "post", .loss), game(3, "post", .win), game(2, "post", .win),
                     game(5, "post", .loss), game(6, "post", .win), game(9, "pre", nil), game(4, "post", .tie)]
        XCTAssertEqual(MobileGamePreview.lastResults(games), [.win, .tie, .loss, .win, .win])
        XCTAssertEqual(MobileGamePreview.lastResults(games).count, 5, "A game still to come is not form")
        XCTAssertEqual(MobileGamePreview.lastResults(games).last, .win, "The most recent is last")
        XCTAssertEqual(MobileGamePreview.lastResults([game(1, "post", .loss)]), [.loss])
    }

    func testTheDayIsSaidThePlainestWay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 9)))
        func later(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }
        XCTAssertEqual(MobileGamePreview.day(of: later(2), now: now, calendar: calendar), "Today")
        XCTAssertEqual(MobileGamePreview.day(of: later(26), now: now, calendar: calendar), "Tomorrow")
        XCTAssertNotEqual(MobileGamePreview.day(of: later(72), now: now, calendar: calendar), "Tomorrow")
    }
}
