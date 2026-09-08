import XCTest
import UIKit
@testable import NullSportsiOS

final class GuideScrollLayoutTests: XCTestCase {
    @MainActor
    func testGuideDoesNotDoubleApplyNavigationInsets() {
        let vertical = UIScrollView()
        MobileGuideScrollConfiguration.configure(vertical, horizontal: false)
        XCTAssertEqual(vertical.contentInsetAdjustmentBehavior, .never)
        XCTAssertTrue(vertical.bounces)
        XCTAssertTrue(vertical.isDirectionalLockEnabled)
        let horizontal = UIScrollView()
        MobileGuideScrollConfiguration.configure(horizontal, horizontal: true)
        XCTAssertEqual(horizontal.contentInsetAdjustmentBehavior, .never)
        XCTAssertFalse(horizontal.bounces)
    }
}
