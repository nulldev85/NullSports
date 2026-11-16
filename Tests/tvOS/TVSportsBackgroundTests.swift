import XCTest
import SwiftUI
import UIKit
@testable import Lineup

/// The Sports tab is the phone's list at the television's size: what is on
/// now, then each day ahead, on the app's plain ground.
@MainActor
final class TVSportsBackgroundTests: XCTestCase {
    private func game(_ id: String, start: Date, state: String, status: String = "") -> SportsGame {
        SportsGame(id: id, league: .nba, start: start,
            awayTeam: "Orlando Magic", homeTeam: "Miami Heat", awayAbbreviation: "ORL", homeAbbreviation: "MIA",
            awayLogo: "", homeLogo: "", awayScore: "10", homeScore: "12", awayColor: "FF0000", homeColor: "0000FF",
            awayRecord: nil, homeRecord: nil, venue: nil, location: nil, status: status, state: state,
            broadcast: "ABC", eventName: nil)
    }

    func testLiveGamesComeFirstThenEachDayInOrder() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        // Days are counted from midnight, so the test reads the same at any
        // hour it runs.
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let dayAfter = calendar.date(byAdding: .day, value: 2, to: today)!
        let live = game("live", start: Date().addingTimeInterval(-1800), state: "in", status: "Q2")
        let tomorrowNight = game("tomorrow-night", start: tomorrow.addingTimeInterval(3600 * 19), state: "pre")
        let laterEarly = game("later-early", start: dayAfter.addingTimeInterval(3600 * 13), state: "pre")
        let laterLate = game("later-late", start: dayAfter.addingTimeInterval(3600 * 20), state: "pre")

        let slate = TVSportsBoard.Slate([laterLate, tomorrowNight, live, laterEarly])

        XCTAssertEqual(slate.live.map(\.id), ["live"])
        XCTAssertEqual(slate.days.map(\.day), [tomorrow, dayAfter])
        XCTAssertEqual(slate.days.first?.games.map(\.id), ["tomorrow-night"])
        XCTAssertEqual(slate.days.last?.games.map(\.id), ["later-early", "later-late"])
        XCTAssertEqual(slate.ordered.map(\.id).first, "live", "Back counts cards in the order they are drawn")
        XCTAssertEqual(slate.ordered.count, 4)
    }

    func testAFinishedGameIsNeitherOnNowNorAhead() {
        let over = game("over", start: Date().addingTimeInterval(-7200), state: "post", status: "Final")
        let slate = TVSportsBoard.Slate([over])
        XCTAssertTrue(slate.live.isEmpty)
        XCTAssertTrue(slate.days.isEmpty)
    }

    /// Cards are laid three to a line, and each line is an item of the list
    /// of its own, so a long day of games is made a line at a time.
    func testASectionsCardsAreCutIntoLinesOfThree() {
        let start = Date().addingTimeInterval(3600)
        let games = (1...7).map { game("g\($0)", start: start, state: "pre") }
        let rows = TVSportsBoard.Row.rows(games, section: "day-1")
        XCTAssertEqual(rows.map { $0.games.map(\.id) }, [["g1", "g2", "g3"], ["g4", "g5", "g6"], ["g7"]])
        XCTAssertEqual(rows.map(\.id), ["day-1-0", "day-1-1", "day-1-2"], "A line keeps its place as scores change")
        XCTAssertEqual(rows.map(\.isFirst), [true, false, false])
        XCTAssertTrue(TVSportsBoard.Row.rows([], section: "live").isEmpty)
    }

    func testACardIsOnlyDrawnAgainWhenItsGameChanges() {
        let start = Date().addingTimeInterval(3600)
        let first = game("g1", start: start, state: "in", status: "Q2")
        var scored = first
        scored.awayRank = 4
        let card = TVGameCard(game: first)
        let same = TVGameCard(game: first)
        let moved = TVGameCard(game: scored)
        let marked = TVGameCard(game: first, isFirstOfMultiview: true)
        XCTAssertTrue(card == same)
        XCTAssertFalse(card == moved)
        XCTAssertFalse(card == marked)
    }
}
