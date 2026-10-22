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
        XCTAssertEqual(MobileGuideGridMetrics.channelLogoRailWidth(for: 320), 108)
        XCTAssertEqual(MobileGuideGridMetrics.channelLogoRailWidth(for: 393), 124)
        XCTAssertEqual(MobileGuideGridMetrics.channelLogoRailWidth(for: 500), 124)
        XCTAssertEqual(MobileGuideGridMetrics.firstRowTopInset, 8)
    }

    func testLiveProgramOverlayFillTracksElapsedTimeAndStaysInsideItsCard() {
        XCTAssertEqual(MobileGuideGridMetrics.liveProgressWidth(cardWidth: 200, progress: 0.25), 50)
        XCTAssertEqual(MobileGuideGridMetrics.liveProgressWidth(cardWidth: 200, progress: -1), 0)
        XCTAssertEqual(MobileGuideGridMetrics.liveProgressWidth(cardWidth: 200, progress: 2), 200)
        XCTAssertEqual(MobileGuideGridMetrics.liveProgressWidth(cardWidth: 200, progress: .nan), 0)
    }
}
