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

    func testCategoryStyleMapsCommonIPTVCategoriesAndFallsBackCleanly() {
        XCTAssertEqual(MobileGuideCategoryStyle.symbol(for: "US | NFL & NBA Sports"), "sportscourt.fill")
        XCTAssertEqual(MobileGuideCategoryStyle.symbol(for: "4K UHD 60FPS"), "sparkles.tv.fill")
        XCTAssertEqual(MobileGuideCategoryStyle.symbol(for: "HBO & Cinema Movies"), "film.fill")
        XCTAssertEqual(MobileGuideCategoryStyle.symbol(for: "Breaking News & Weather"), "newspaper.fill")
        XCTAssertEqual(MobileGuideCategoryStyle.symbol(for: "US Local Broadcasts"), "antenna.radiowaves.left.and.right")
        XCTAssertEqual(MobileGuideCategoryStyle.symbol(for: "Kids & Family"), "sparkles")
        XCTAssertEqual(MobileGuideCategoryStyle.symbol(for: "24/7 Classics"), "play.circle.fill")
        XCTAssertEqual(MobileGuideCategoryStyle.symbol(for: "MTV Music"), "music.note")
        XCTAssertEqual(MobileGuideCategoryStyle.symbol(for: "Discovery Documentary"), "globe.americas.fill")
        XCTAssertEqual(MobileGuideCategoryStyle.symbol(for: "US Entertainment"), "tv.fill")
        XCTAssertEqual(MobileGuideCategoryStyle.symbol(for: "Miscellaneous Channels"), "rectangle.stack.fill")
    }

    func testLiveProgramProgressComputesClampedFractionAndRemainingLabel() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(3600)
        XCTAssertEqual(MobileGuideProgramProgress.fraction(start: start, end: end, now: start.addingTimeInterval(900)) ?? -1, 0.25, accuracy: 0.001)
        XCTAssertEqual(MobileGuideProgramProgress.fraction(start: start, end: end, now: start.addingTimeInterval(-60)), 0)
        XCTAssertEqual(MobileGuideProgramProgress.fraction(start: start, end: end, now: end.addingTimeInterval(60)), 1)
        XCTAssertNil(MobileGuideProgramProgress.fraction(start: start, end: start, now: start))

        XCTAssertEqual(MobileGuideProgramProgress.remainingLabel(end: end, now: start.addingTimeInterval(41 * 60)), "19m left")
        XCTAssertEqual(MobileGuideProgramProgress.remainingLabel(end: end, now: start), "1h left")
        XCTAssertEqual(MobileGuideProgramProgress.remainingLabel(end: start.addingTimeInterval(95 * 60), now: start), "1h 35m left")
        XCTAssertNil(MobileGuideProgramProgress.remainingLabel(end: end, now: end))
    }
}
