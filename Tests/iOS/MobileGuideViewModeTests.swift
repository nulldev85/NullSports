import XCTest
@testable import Lineup

final class MobileGuideViewModeTests: XCTestCase {
    func testGuideIsTheDefaultAndUnknownValuesRecoverSafely() {
        XCTAssertEqual(MobileGuideViewMode.restored(nil), .tvGuide)
        XCTAssertEqual(MobileGuideViewMode.restored("removedMode"), .tvGuide)
    }

    func testBothReferenceModesHaveStableSettingsLabels() {
        XCTAssertEqual(MobileGuideViewMode.allCases.map(\.title), ["TV Guide", "List"])
        XCTAssertEqual(MobileGuideViewMode.restored("list"), .list)
        XCTAssertEqual(MobileGuideViewMode.restored("tvGuide"), .tvGuide)
        XCTAssertEqual(MobileGuideViewMode.list.symbol, "list.bullet")
        XCTAssertEqual(MobileGuideViewMode.tvGuide.symbol, "rectangle.grid.1x2")
    }
}
