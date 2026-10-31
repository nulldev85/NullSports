import Combine
import SwiftUI
import UIKit
import XCTest
@testable import Lineup

@MainActor
final class TVDataRefreshProgressTests: XCTestCase {
    private var observations: Set<AnyCancellable> = []

    private func expectStatus(_ progress: DataRefreshProgress, _ description: String,
                              matching condition: @escaping (DataRefreshProgress.Status?) -> Bool) -> XCTestExpectation {
        let result = expectation(description: description)
        progress.$status.filter(condition).prefix(1).sink { _ in result.fulfill() }.store(in: &observations)
        return result
    }

    func testDownloadPercentageMeasuresTheCurrentPhaseFromActualBytes() {
        let progress = DataRefreshProgress(showAfter: 0)
        progress.plan([.channels, .guide, .guideReading, .matching], profile: UUID())
        let channels = progress.start(.channels)
        let guide = progress.start(.guide)
        progress.finish(channels)
        progress.download(guide, .init(received: 50, expected: 100, finished: false))
        XCTAssertEqual(progress.status, .init(step: .guide, percent: 50))
        progress.cancel()
    }

    func testUnknownDownloadSizeAndUnmeasuredWorkNeverInventAPercentage() {
        let progress = DataRefreshProgress(showAfter: 0)
        progress.plan([.guide, .guideReading, .matching], profile: UUID())
        let guide = progress.start(.guide)
        progress.download(guide, .init(received: 90_000_000, expected: nil, finished: false))
        XCTAssertEqual(progress.status, .init(step: .guide, percent: nil))
        XCTAssertEqual(progress.status?.detail, "Loading TV Guide")
        progress.download(guide, .init(received: 90_000_000, expected: 90_000_000, finished: true))
        XCTAssertEqual(progress.status, .init(step: .guideReading, percent: nil))
        progress.finish(guide)
        let index = progress.start(.indexing)
        XCTAssertEqual(progress.status, .init(step: .indexing, percent: nil))
        progress.finish(index)
        progress.cancel()
    }

    func testDownloadedChannelsAreNamedAsReadingUntilTheirDataIsInstalled() {
        let progress = DataRefreshProgress(showAfter: 0)
        progress.plan([.channels, .matching], profile: UUID())
        let channels = progress.start(.channels)
        progress.download(channels, .init(received: 100, expected: 100, finished: true))
        XCTAssertEqual(progress.status, .init(step: .channelReading, percent: nil))
        progress.cancel()
    }

    func testMatchingPercentageCountsFinishedGamesAndResetsForANewPass() {
        let progress = DataRefreshProgress(showAfter: 0)
        progress.plan([.matching], profile: UUID())
        let old = progress.start(.matching)
        progress.advance(old, completed: 198, total: 200)
        XCTAssertEqual(progress.status?.percent, 99)
        let current = progress.start(.matching)
        progress.advance(current, completed: 3, total: 12)
        XCTAssertEqual(progress.status, .init(step: .matching, percent: 25))
        progress.advance(old, completed: 200, total: 200)
        progress.finish(old)
        XCTAssertEqual(progress.status, .init(step: .matching, percent: 25),
                       "Late callbacks from a replaced pass cannot change the current progress")
        progress.cancel()
    }

    func testCurrentResultsFinishWithoutWaitingForAnObsoleteMatchingPass() async {
        let progress = DataRefreshProgress(showAfter: 0)
        progress.plan([.channels, .guide, .guideReading, .matching], profile: UUID())
        let channels = progress.start(.channels)
        let guide = progress.start(.guide)
        progress.finish(channels)
        let oldIndex = progress.start(.indexing)
        progress.finish(guide)
        let currentIndex = progress.start(.indexing)
        progress.finish(currentIndex)
        let matching = progress.start(.matching)
        progress.advance(matching, completed: 12, total: 12)
        let ready = expectStatus(progress, "current results are ready") { $0?.completed == true }
        progress.finish(matching)
        // oldIndex is deliberately still running. Its result is already stale.
        await fulfillment(of: [ready], timeout: 4)
        XCTAssertEqual(progress.status?.detail, "Up to Date · 100%")
        progress.finish(oldIndex)
        XCTAssertEqual(progress.status?.completed, true)
        let background = progress.start(.matching)
        progress.advance(background, completed: 1, total: 10)
        XCTAssertEqual(progress.status?.completed, true, "A score poll cannot reopen a finished refresh")
        let dismissed = expectStatus(progress, "finished indicator dismisses") { $0 == nil }
        await fulfillment(of: [dismissed], timeout: 4)
        progress.finish(background)
        XCTAssertNil(progress.status)
    }

    func testANewIndexRetiresTheOldMatchWithoutLettingItsCallbacksFinishTheNewWork() {
        let progress = DataRefreshProgress(showAfter: 0)
        progress.plan([.matching], profile: UUID())
        let oldMatch = progress.start(.matching)
        let index = progress.start(.indexing)
        progress.advance(oldMatch, completed: 99, total: 100)
        progress.finish(oldMatch)
        XCTAssertEqual(progress.status, .init(step: .indexing, percent: nil))
        progress.finish(index)
        let current = progress.start(.matching)
        progress.advance(current, completed: 1, total: 10)
        XCTAssertEqual(progress.status, .init(step: .matching, percent: 10))
        progress.cancel()
    }

    func testCompletedCalculationWaitsForTheResultToBeAppliedBeforeSayingOneHundred() {
        let progress = DataRefreshProgress(showAfter: 0)
        progress.plan([.matching], profile: UUID())
        let matching = progress.start(.matching)
        progress.advance(matching, completed: 100, total: 100)
        XCTAssertEqual(progress.status, .init(step: .applying, percent: nil))
        XCTAssertFalse(progress.status?.completed ?? true)
        progress.cancel()
    }

    func testUnchangedDataWithNoMatchingNeededStillCompletes() async {
        let progress = DataRefreshProgress(showAfter: 0)
        progress.plan([.channels, .guide, .guideReading, .matching], profile: UUID())
        let channels = progress.start(.channels)
        let guide = progress.start(.guide)
        progress.finish(channels)
        let ready = expectStatus(progress, "unchanged input completes without a matching pass") { $0?.completed == true }
        progress.finish(guide)
        await fulfillment(of: [ready], timeout: 4)
        progress.cancel()
    }

    func testADownloadStillInFlightDoesNotAnnounceAllDataReady() async {
        let progress = DataRefreshProgress(showAfter: 0)
        progress.plan([.channels, .guide, .matching], profile: UUID())
        let guide = progress.start(.guide)
        let matching = progress.start(.matching)
        progress.finish(matching)
        XCTAssertEqual(progress.status?.step, .guide)
        XCTAssertEqual(progress.status?.completed, false)
        let ready = expectStatus(progress, "guide input finishes") { $0?.completed == true }
        progress.finish(guide)
        await fulfillment(of: [ready], timeout: 4)
        progress.cancel()
    }

    func testFailedRefreshDismissesWithoutFalselyAnnouncingSuccess() async {
        let progress = DataRefreshProgress(showAfter: 0)
        progress.plan([.channels, .guide, .matching], profile: UUID())
        let channels = progress.start(.channels)
        let guide = progress.start(.guide)
        var announcedSuccess = false
        progress.$status.sink { if $0?.completed == true { announcedSuccess = true } }.store(in: &observations)
        progress.fail(guide)
        let dismissed = expectStatus(progress, "failed refresh retires") { $0 == nil }
        progress.finish(channels)
        await fulfillment(of: [dismissed], timeout: 4)
        XCTAssertFalse(announcedSuccess)
    }

    func testProviderSwitchDiscardsCallbacksFromThePreviousProvider() {
        let progress = DataRefreshProgress(showAfter: 0)
        progress.plan([.guide], profile: UUID())
        let oldGuide = progress.start(.guide)
        progress.plan([.channels], profile: UUID())
        let current = progress.start(.channels)
        progress.download(current, .init(received: 1, expected: 10, finished: false))
        progress.download(oldGuide, .init(received: 100, expected: 100, finished: true))
        progress.fail(oldGuide)
        progress.finish(oldGuide)
        XCTAssertEqual(progress.status, .init(step: .channels, percent: 10))
        progress.cancel()
    }

    func testBackgroundMatchingAloneNeverOpensTheIndicator() {
        let progress = DataRefreshProgress(showAfter: 0)
        let matching = progress.start(.matching)
        progress.advance(matching, completed: 3, total: 4)
        progress.finish(matching)
        XCTAssertNil(progress.status)
    }

    func testBriefRefreshDoesNotFlickerAndCancellationClearsImmediately() {
        let progress = DataRefreshProgress(showAfter: 60)
        progress.plan([.channels], profile: UUID())
        let channels = progress.start(.channels)
        progress.download(channels, .init(received: 10, expected: 100, finished: false))
        progress.finish(channels)
        XCTAssertNil(progress.status)
        progress.cancel()
        progress.download(channels, .init(received: 100, expected: 100, finished: true))
        XCTAssertNil(progress.status)
    }

    func testOneWholeRefreshBarHoldsAcrossUnknownPhasesInsteadOfResetting() {
        let progress = DataRefreshProgress(showAfter: 0)
        progress.plan([.channels, .guide, .guideReading, .matching], profile: UUID())
        let channels = progress.start(.channels)
        let guide = progress.start(.guide)
        progress.finish(channels)
        progress.download(guide, .init(received: 50, expected: 100, finished: false))
        XCTAssertEqual(progress.fraction, 0.425, accuracy: 0.0001)
        progress.download(guide, .init(received: 60, expected: nil, finished: false))
        XCTAssertEqual(progress.fraction, 0.425, accuracy: 0.0001, "Unknown work holds the measured position")
        progress.download(guide, .init(received: 100, expected: 100, finished: true))
        XCTAssertEqual(progress.fraction, 0.65, accuracy: 0.0001)
        progress.finish(guide)
        XCTAssertEqual(progress.fraction, 0.8, accuracy: 0.0001)
        let index = progress.start(.indexing)
        XCTAssertEqual(progress.fraction, 0.8, accuracy: 0.0001)
        progress.finish(index)
        let matching = progress.start(.matching)
        progress.advance(matching, completed: 1, total: 4)
        XCTAssertEqual(progress.fraction, 0.925, accuracy: 0.0001)
        progress.start(.indexing)
        XCTAssertEqual(progress.fraction, 0.925, accuracy: 0.0001, "A replacement pass cannot move the bar backwards")
        progress.cancel()
    }

    func testRefreshCapsuleKeepsTheSameSizeAcrossMeasuredAndUnknownPhases() {
        let states: [DataRefreshProgress.Status] = [
            .init(step: .guide, percent: 50), .init(step: .guideReading, percent: nil),
            .init(step: .indexing, percent: nil), .init(step: .matching, percent: 25),
            .init(step: .applying, percent: nil), .init(step: .matching, percent: 100, completed: true)
        ]
        let sizes = states.map { status in
            UIHostingController(rootView: DataRefreshCapsule(status: status, fraction: 0.65))
                .sizeThatFits(in: CGSize(width: 390, height: 200))
        }
        for size in sizes {
            XCTAssertEqual(size.width, sizes[0].width, accuracy: 0.5)
            XCTAssertEqual(size.height, sizes[0].height, accuracy: 0.5,
                "Changing phases must not swap between a spinner row and a differently sized bar")
        }
    }
}
