import XCTest
@testable import LineupiOS

/// The "Refreshing Data" pop-up: which step it names, and how far through the
/// whole refresh it says the app is.
@MainActor
final class DataRefreshProgressTests: XCTestCase {
    private func store() -> UserDefaults {
        let name = "DataRefreshProgressTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func waitUntil(_ condition: () -> Bool, within seconds: TimeInterval = 4) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // A download is measured by its bytes, and the percentage is of the whole
    // refresh: the channels done and half the guide in is 42%, on the guide.
    func testTheGuideDownloadMovesThePercentageByItsBytes() {
        let progress = DataRefreshProgress(defaults: store(), showAfter: 0)
        progress.plan([.matching, .channels, .guide, .guideReading], profile: UUID())
        progress.start(.channels)
        progress.start(.guide)
        progress.finish(.channels)
        progress.download(.guide, XtreamDownloadUpdate(received: 50, expected: 100, finished: false))
        XCTAssertEqual(progress.status, DataRefreshProgress.Status(step: .guide, percent: 42))
    }

    // A server that gives no size is measured against what the same download
    // came to last time, for the same provider.
    func testAServerThatGivesNoSizeIsMeasuredAgainstTheLastDownload() {
        let defaults = store()
        let profile = UUID()
        let first = DataRefreshProgress(defaults: defaults, showAfter: 0)
        first.plan([.guide], profile: profile)
        first.start(.guide)
        first.download(.guide, XtreamDownloadUpdate(received: 400, expected: 400, finished: true))
        first.finish(.guide)

        let next = DataRefreshProgress(defaults: defaults, showAfter: 0)
        next.plan([.guide], profile: profile)
        next.start(.guide)
        next.download(.guide, XtreamDownloadUpdate(received: 100, expected: nil, finished: false))
        XCTAssertEqual(next.status?.percent, 25)
    }

    // Matching that starts over adds work, but the number on screen holds
    // rather than falling back.
    func testThePercentageNeverGoesBackwards() {
        let progress = DataRefreshProgress(defaults: store(), showAfter: 0)
        progress.plan([.channels, .matching], profile: UUID())
        progress.start(.channels)
        progress.download(.channels, XtreamDownloadUpdate(received: 90, expected: 100, finished: false))
        XCTAssertEqual(progress.status?.percent, 45)
        progress.start(.matching)
        progress.finish(.matching)
        XCTAssertEqual(progress.status?.percent, 95)
        progress.start(.matching)
        XCTAssertEqual(progress.status, DataRefreshProgress.Status(step: .channels, percent: 95))
    }

    // Matching after a score changed is not a refresh, and shows nothing.
    func testMatchingOnItsOwnShowsNothing() {
        let progress = DataRefreshProgress(defaults: store(), showAfter: 0)
        progress.start(.matching)
        XCTAssertNil(progress.status)
    }

    // A refresh over in a blink is never shown at all.
    func testNothingIsShownBeforeTheRefreshHasRunAMoment() {
        let progress = DataRefreshProgress(defaults: store(), showAfter: 60)
        progress.plan([.channels], profile: UUID())
        progress.start(.channels)
        progress.download(.channels, XtreamDownloadUpdate(received: 10, expected: 100, finished: false))
        XCTAssertNil(progress.status)
    }

    // Done, it says 100% for a moment, then goes.
    func testAFinishedRefreshSaysOneHundredThenGoes() async throws {
        let progress = DataRefreshProgress(defaults: store(), showAfter: 0)
        progress.plan([.channels], profile: UUID())
        progress.start(.channels)
        progress.finish(.channels)
        XCTAssertEqual(progress.status?.percent, 99, "Never 100 while anything could still be running")
        let saidHundred = try await waitUntil { progress.status?.percent == 100 }
        XCTAssertTrue(saidHundred)
        let went = try await waitUntil { progress.status == nil }
        XCTAssertTrue(went)
    }

    // Without bytes to count, a step moves by the clock: steadily to nine
    // tenths over the time it usually takes, then ever more slowly.
    func testTheClockPacesAStepToNineTenthsThenSlows() {
        XCTAssertEqual(DataRefreshProgress.estimate(elapsed: 0, usual: 10), 0)
        XCTAssertEqual(DataRefreshProgress.estimate(elapsed: 5, usual: 10), 0.45, accuracy: 0.0001)
        XCTAssertEqual(DataRefreshProgress.estimate(elapsed: 10, usual: 10), 0.9, accuracy: 0.0001)
        XCTAssertGreaterThan(DataRefreshProgress.estimate(elapsed: 20, usual: 10), 0.9)
        XCTAssertLessThanOrEqual(DataRefreshProgress.estimate(elapsed: 1000, usual: 10), 0.99)
    }
}
