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
}
