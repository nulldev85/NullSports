import XCTest
@testable import NullSportsiOS

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
