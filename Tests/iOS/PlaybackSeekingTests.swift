import XCTest
#if os(tvOS)
@testable import Lineup
#else
@testable import LineupiOS
#endif

final class PlaybackSeekingTests: XCTestCase {
    func testFingerPositionsClampAtBothEndsAndRejectInvalidGeometry() {
        XCTAssertEqual(PlaybackSeekPolicy.position(x: 150, width: 300, duration: 3_600), 1_800)
        XCTAssertEqual(PlaybackSeekPolicy.position(x: -40, width: 300, duration: 3_600), 0)
        XCTAssertEqual(PlaybackSeekPolicy.position(x: 500, width: 300, duration: 3_600), 3_599)
        XCTAssertEqual(PlaybackSeekPolicy.position(x: .nan, width: 300, duration: 3_600), 0)
        XCTAssertEqual(PlaybackSeekPolicy.position(x: 100, width: 0, duration: 3_600), 0)
        XCTAssertEqual(PlaybackSeekPolicy.clamped(100, duration: .infinity), 0)
    }

    func testHeldRemoteHasATapWindowThenAcceleratesWithABoundedRate() {
        XCTAssertEqual(PlaybackSeekPolicy.rate(heldFor: 0.2), 0)
        XCTAssertGreaterThan(PlaybackSeekPolicy.rate(heldFor: 0.5), 0)
        XCTAssertGreaterThan(PlaybackSeekPolicy.rate(heldFor: 3), PlaybackSeekPolicy.rate(heldFor: 1))
        XCTAssertLessThanOrEqual(PlaybackSeekPolicy.rate(heldFor: 60), 240)
    }

    func testLateDecoderSamplesCannotPullTheCommittedBarBackwards() {
        var landing = PlaybackSeekLanding()
        landing.expect(900, now: 10)
        XCTAssertFalse(landing.accepts(120, now: 11))
        landing.expect(450, now: 11)
        XCTAssertFalse(landing.accepts(900, now: 12), "An older seek landing must not replace the new destination")
        XCTAssertTrue(landing.accepts(451, now: 12))
        XCTAssertTrue(landing.accepts(452, now: 13))
        landing.expect(700, now: 20)
        XCTAssertFalse(landing.accepts(.nan, now: 21))
        XCTAssertTrue(landing.accepts(300, now: 25), "A failed seek must not freeze the clock forever")
        landing.expect(900, now: 30)
        landing.reset()
        XCTAssertTrue(landing.accepts(0, now: 30), "A new source starts with a clean clock")
    }

    @MainActor
    func testFastPreviewsKeepOnlyTheLatestQueuedDestination() async throws {
        let coalescer = PlaybackSeekCoalescer(interval: 0.04)
        var requests: [Double] = []
        coalescer.preview(10) { requests.append($0) }
        for target in 11...200 { coalescer.preview(Double(target)) { requests.append($0) } }
        XCTAssertEqual(requests, [10])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(requests, [10, 200])
        coalescer.commit(200) { requests.append($0) }
        XCTAssertEqual(requests, [10, 200], "Release must not restart a seek already sent to the decoder")
        coalescer.commit(200) { requests.append($0) }
        XCTAssertEqual(requests.last, 200)
        XCTAssertEqual(requests.count, 3, "A later deliberate seek is a new operation")
    }

    @MainActor
    func testReleaseFlushesImmediatelyAndOldPreviewsCannotRunAfterwards() async throws {
        let coalescer = PlaybackSeekCoalescer(interval: 0.04)
        var requests: [Double] = []
        coalescer.preview(10) { requests.append($0) }
        coalescer.preview(900) { requests.append($0) }
        coalescer.commit(450) { requests.append($0) }
        XCTAssertEqual(requests, [10, 450])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(requests, [10, 450])
        coalescer.preview(700) { requests.append($0) }
        coalescer.cancel()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(requests, [10, 450, 700])
        coalescer.preview(1) { requests.append($0) }
        coalescer.preview(2) { requests.append($0) }
        coalescer.cancel()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(requests.last, 1, "Stopping or changing media cancels queued decoder work")
    }
}
