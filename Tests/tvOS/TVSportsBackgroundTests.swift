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
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let laterToday = Date().addingTimeInterval(3600)
        let live = game("live", start: Date().addingTimeInterval(-1800), state: "in", status: "Q2")
        let tonight = game("tonight", start: laterToday, state: "pre")
        let tomorrowEarly = game("tomorrow-early", start: tomorrow.addingTimeInterval(3600 * 13), state: "pre")
        let tomorrowLate = game("tomorrow-late", start: tomorrow.addingTimeInterval(3600 * 20), state: "pre")

        let slate = TVSportsBoard.Slate([tomorrowLate, tonight, live, tomorrowEarly])

        XCTAssertEqual(slate.live.map(\.id), ["live"])
        XCTAssertEqual(slate.days.map(\.day), [calendar.startOfDay(for: laterToday), tomorrow])
        XCTAssertEqual(slate.days.last?.games.map(\.id), ["tomorrow-early", "tomorrow-late"])
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
