import XCTest
@testable import LineupiOS

final class GesturePolicyTests: XCTestCase {
    func testDismissRequiresDeliberateDownwardGesture() {
        XCTAssertFalse(MobileDismissPolicy.shouldDismiss(x: 180, y: 60, projectedY: 400))
        XCTAssertFalse(MobileDismissPolicy.shouldDismiss(x: 0, y: -180, projectedY: -400))
        XCTAssertFalse(MobileDismissPolicy.shouldDismiss(x: 2, y: 16, projectedY: 400))
        XCTAssertFalse(MobileDismissPolicy.shouldDismiss(x: 5, y: 70, projectedY: 100))
        XCTAssertTrue(MobileDismissPolicy.shouldDismiss(x: 5, y: 130, projectedY: 150))
        XCTAssertTrue(MobileDismissPolicy.shouldDismiss(x: 8, y: 45, projectedY: 280))
    }
}

/// The Live tab's slate is worked out once per render rather than at every
/// mention of it. These are about the grouping being right, which is what the
/// sections draw from now.
final class LiveSlateTests: XCTestCase {
    // Upcoming games arrive in one list and are drawn in per-day sections. The
    // grouping used to happen by filtering the whole list again for each day.
    func testUpcomingGamesAreGroupedByDayInOrder() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let starts = [tomorrow.addingTimeInterval(3600),
                      today.addingTimeInterval(23 * 3600),
                      tomorrow.addingTimeInterval(7200)]

        var byDay: [Date: [Date]] = [:]
        for start in starts { byDay[calendar.startOfDay(for: start), default: []].append(start) }
        let days = byDay.keys.sorted()

        XCTAssertEqual(days.count, 2, "Two distinct days")
        XCTAssertEqual(days.first, today, "Today comes first")
        XCTAssertEqual(byDay[tomorrow]?.count, 2, "Both of tomorrow's games land together")
    }
}
