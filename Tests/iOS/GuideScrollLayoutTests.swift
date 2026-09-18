import XCTest
import UIKit
@testable import LineupiOS

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

final class PlayerFullscreenLayoutTests: XCTestCase {
    func testFullscreenHeightIsTheSameBeforeAndAfterTheChromeHides() {
        // An 844pt screen: first with a navigation bar, tab bar and home
        // indicator in place, then mid-transition, then with all of them gone.
        // The player must be handed the same height at every step, or it grows
        // in visible stages instead of one motion.
        XCTAssertEqual(MobilePlayerLayout.fullscreenHeight(containerHeight: 652, safeAreaTop: 106, safeAreaBottom: 86), 844)
        XCTAssertEqual(MobilePlayerLayout.fullscreenHeight(containerHeight: 738, safeAreaTop: 59, safeAreaBottom: 47), 844)
        XCTAssertEqual(MobilePlayerLayout.fullscreenHeight(containerHeight: 844, safeAreaTop: 0, safeAreaBottom: 0), 844)
    }
}
