import XCTest
@testable import LineupiOS

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

    func testGuideChannelArtRailMatchesReferenceProportionsAcrossPhoneWidths() {
        XCTAssertEqual(MobileGuideLayoutMetrics.channelLogoRailWidth(for: 320), 108)
        XCTAssertEqual(MobileGuideLayoutMetrics.channelLogoRailWidth(for: 393), 124)
        XCTAssertEqual(MobileGuideLayoutMetrics.channelLogoRailWidth(for: 500), 124)
        XCTAssertEqual(MobileGuideLayoutMetrics.gridFirstRowTopInset, 8)
        XCTAssertEqual(MobileGuideLayoutMetrics.listFirstRowTopInset, 24)
        XCTAssertEqual(MobileGuideLayoutMetrics.logoPanelOverlayOpacity, 0.035)
    }

    func testLiveProgramOverlayFillTracksElapsedTimeAndStaysInsideItsCard() {
        XCTAssertEqual(MobileGuideLayoutMetrics.liveProgressWidth(cardWidth: 200, progress: 0.25), 50)
        XCTAssertEqual(MobileGuideLayoutMetrics.liveProgressWidth(cardWidth: 200, progress: -1), 0)
        XCTAssertEqual(MobileGuideLayoutMetrics.liveProgressWidth(cardWidth: 200, progress: 2), 200)
        XCTAssertEqual(MobileGuideLayoutMetrics.liveProgressWidth(cardWidth: 200, progress: .nan), 0)
        XCTAssertEqual(MobileGuideLayoutMetrics.liveProgressOverlayOpacity, 0.26)
    }

    func testGuideSearchClosesOnEmptySubmitAndKeepsNonemptyResults() {
        XCTAssertTrue(MobileGuideSearchPolicy.shouldCloseAfterSubmission(""))
        XCTAssertTrue(MobileGuideSearchPolicy.shouldCloseAfterSubmission("   \n"))
        XCTAssertFalse(MobileGuideSearchPolicy.shouldCloseAfterSubmission("ESPN"))
    }
}
