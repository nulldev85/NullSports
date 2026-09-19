
/// When a game starts, as a list that is not grouped by day has to say it.
final class GameStartLabelTests: XCTestCase {
    private let calendar = Calendar.current

    // Today carries no qualifier: a time with nothing beside it is today, and
    // saying so would be noise on most of the rows.
    func testTodayIsJustTheTime() {
        let noon = calendar.date(bySettingHour: 12, minute: 5, second: 0, of: Date())!
        XCTAssertEqual(SportsGame.startLabel(for: noon),
                       noon.formatted(.dateTime.hour().minute()))
    }

    // The case that sent this back: My Teams holds tonight and tomorrow night
    // in one list, where both read as the same bare time.
    func testTomorrowSaysSo() {
        let then = calendar.date(byAdding: .day, value: 1, to: Date())!
        XCTAssertTrue(SportsGame.startLabel(for: then).hasPrefix("Tomorrow "),
                      "A time alone cannot tell tonight from tomorrow night")
    }

    func testFurtherOutNamesTheDay() {
        let then = calendar.date(byAdding: .day, value: 3, to: Date())!
        let label = SportsGame.startLabel(for: then)
        XCTAssertFalse(label.hasPrefix("Tomorrow"))
        XCTAssertTrue(label.contains(then.formatted(.dateTime.weekday(.abbreviated))))
    }
}
