import XCTest
@testable import Lineup

@MainActor
final class TabBarVisibilityTests: XCTestCase {
    func testRepeatedAppearancesOfOnePageCannotLeaveTheBarHiddenAfterReturning() {
        let state = TVTabBarState()
        let page = UUID()
        state.pageAppeared(page)
        state.pageAppeared(page)
        XCTAssertTrue(state.hidden)
        state.pageDisappeared(page)
        XCTAssertFalse(state.hidden)
        state.pageDisappeared(page)
        XCTAssertFalse(state.hidden)
    }

    func testNestedPagesAndLateCallbacksCannotTakeOwnershipFromTheCurrentPage() {
        let state = TVTabBarState()
        let first = UUID(), second = UUID(), current = UUID()
        state.pageAppeared(first)
        state.pageAppeared(second)
        state.pageDisappeared(first)
        XCTAssertTrue(state.hidden)
        state.pageDisappeared(first)
        XCTAssertTrue(state.hidden)
        state.reset()
        XCTAssertFalse(state.hidden)
        state.pageAppeared(current)
        state.pageDisappeared(second)
        XCTAssertTrue(state.hidden)
        state.pageDisappeared(current)
        XCTAssertFalse(state.hidden)
    }
}
