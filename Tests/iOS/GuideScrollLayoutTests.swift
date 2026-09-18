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

/// The summary panel and the transport controls share the bottom half of a
/// landscape screen, and a tester found the summary printed across the
/// skip-back button. These pin the clearance rather than the width: what
/// matters is that the panel stops before the controls start.
final class PlayerSynopsisWidthTests: XCTestCase {
    /// Where the centred cluster begins, in the same space the panel lays out
    /// in. The panel starts at zero, so this is the line it must not cross.
    private func clusterStart(available: CGFloat) -> CGFloat {
        (available - MobilePlayerLayout.transportClusterWidth) / 2
    }

    // Every iPhone landscape width the app runs at, from the smallest screen
    // to the largest, safe-area insets and the player's own padding removed.
    func testTheSummaryStopsBeforeTheControlsOnEveryScreen() {
        for available in stride(from: 520.0, through: 860.0, by: 10.0) {
            let width = MobilePlayerLayout.synopsisWidth(available: available, compactHeight: true)
            XCTAssertLessThan(width, clusterStart(available: available),
                              "A \(available)pt landscape leaves the summary across the controls")
        }
    }

    // The screenshot that prompted this: a 956pt screen, 59pt of safe area on
    // each side, 16pt of padding on each side.
    func testTheCaseFromTheReport() {
        let available = 956.0 - 118 - 32
        let width = MobilePlayerLayout.synopsisWidth(available: available, compactHeight: true)
        XCTAssertEqual(width, 283)
        XCTAssertEqual(clusterStart(available: available) - width, 16,
                       "The gap is the one that was asked for, not whatever is left over")
    }

    // Portrait has the height to keep them apart, so the panel is not punished
    // for a problem it does not have there.
    func testPortraitKeepsTheFullWidth() {
        XCTAssertEqual(MobilePlayerLayout.synopsisWidth(available: 361, compactHeight: false), 420)
        XCTAssertEqual(MobilePlayerLayout.synopsisWidth(available: 806, compactHeight: false), 420)
    }

    // A screen wide enough for both takes the panel's natural width rather
    // than stretching it to fill the clearance.
    func testAWideScreenDoesNotStretchThePanel() {
        XCTAssertEqual(MobilePlayerLayout.synopsisWidth(available: 2000, compactHeight: true), 420)
    }
}
