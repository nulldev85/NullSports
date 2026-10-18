import XCTest
@testable import LineupiOS

@MainActor
final class MobileReplaySeekingTests: XCTestCase {
    func testMinuteOnlyProviderDoesNotRestartOnAShortForwardDrag() throws {
        let suite = "ReplaySeeking.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MobilePlaybackController(defaults: defaults)
        defer { controller.shutdown() }
        let start = CatchUpPolicy.minute(Date().addingTimeInterval(-7200))
        let end = start.addingTimeInterval(600)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:1/replay.ts"))
        var requests: [Date] = []
        controller.catchUpSource = CatchUpSource(stream: stream(), liveURLs: [url], addresses: { begin, _ in
            requests.append(begin)
            return [url]
        }, programme: { _ in nil })
        XCTAssertTrue(controller.playRecording(of: .init(streamID: 7, title: "Game replay", detail: "",
                                                        start: start, end: end)))
        // No asynchronous engine readiness has occurred. This exercises the
        // provider-only path without making any network request.
        XCTAssertEqual(requests, [start])
        controller.beginScrubbing()
        XCTAssertTrue(controller.isScrubbing)
        controller.previewScrubbing(at: 10)
        XCTAssertEqual(requests.count, 1, "Moving a finger must not reopen a provider stream")
        controller.endScrubbing(at: 10)
        XCTAssertEqual(requests.count, 1, "A forward jump cannot round back and reopen the same minute")
        XCTAssertEqual(controller.catchUp?.streamStart, start)
        XCTAssertEqual(controller.recordingProgress?.position, 0)
        XCTAssertNotNil(controller.failoverNotice, "Explain the provider precision limit instead of silently restarting")

        controller.beginScrubbing()
        controller.previewScrubbing(at: 200)
        controller.previewScrubbing(at: 140)
        controller.endScrubbing(at: 130)
        XCTAssertEqual(requests, [start, start.addingTimeInterval(120)],
                       "Release opens only the final supported minute, never an obsolete preview")
        XCTAssertEqual(controller.catchUp?.streamStart, start.addingTimeInterval(120))
        XCTAssertEqual(controller.recordingProgress?.position, 120,
                       "The UI must report the minute actually opened, not the unachievable draft")
        controller.beginScrubbing()
        controller.previewScrubbing(at: 400)
        controller.finishScrubbing(resume: false)
        XCTAssertFalse(controller.isScrubbing)
        XCTAssertEqual(requests.count, 2, "Dismissing the view cancels an uncommitted provider seek")
    }

    func testStopAndRetuneDiscardReplayDraftAndKeepLibrarySeekEntrySeparate() throws {
        let suite = "ReplayRetune.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MobilePlaybackController(defaults: defaults)
        defer { controller.shutdown() }
        controller.isLive = true
        controller.beginScrubbing()
        XCTAssertFalse(controller.isScrubbing, "A live channel without a recording has no scrub timeline")
        let start = CatchUpPolicy.minute(Date().addingTimeInterval(-7200))
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:1/replay.ts"))
        var requests = 0
        controller.catchUpSource = CatchUpSource(stream: stream(), liveURLs: [url],
            addresses: { _, _ in requests += 1; return [url] }, programme: { _ in nil })
        XCTAssertTrue(controller.playRecording(of: .init(streamID: 7, title: "Game", detail: "",
            start: start.addingTimeInterval(5), end: start.addingTimeInterval(600))))
        XCTAssertEqual(controller.recordingProgress?.position, 0, "Provider minute padding is outside the program")
        controller.beginScrubbing()
        controller.previewScrubbing(at: 200)
        controller.stop()
        controller.endScrubbing(at: 200)
        XCTAssertNil(controller.recordingProgress)
        XCTAssertFalse(controller.isScrubbing)
        XCTAssertEqual(requests, 1, "A retired gesture must not reopen its source")
    }

    private func stream() -> XtreamStream {
        .init(num: nil, name: "Replay fixture", streamType: "live", streamID: 7, streamIcon: nil,
              epgChannelID: nil, categoryID: nil, tvArchive: true, archiveDays: 7)
    }
}
