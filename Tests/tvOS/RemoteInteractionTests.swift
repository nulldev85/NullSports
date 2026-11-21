import XCTest
@testable import Lineup

@MainActor
final class RemoteInteractionTests: XCTestCase {
    func testChapterTimelineKeepsRealStartsAndDropsDuplicateOrOutOfRangeEntries() {
        let entries: [PlaybackChapter] = [
            .init(start: 120, title: "End"), .init(start: 30, title: "Arrival"),
            .init(start: 0, title: nil), .init(start: -1, title: nil),
            .init(start: .infinity, title: nil), .init(start: 30, title: "Duplicate")
        ]
        let chapters = PlaybackChapter.ordered(entries, duration: 120)
        XCTAssertEqual(chapters.map(\.start), [0, 30])
        XCTAssertEqual(chapters.first?.label(at: 0), "Chapter 1")
        XCTAssertEqual(chapters.last?.label(at: 1), "Arrival")
    }

    func testFirstHoldHasItsTitleAndActionsInTheSamePresentation() throws {
        var performed: [String] = []
        let first = try XCTUnwrap(TVHoldMenuPresentation(title: "ESPN", symbol: "tv", message: "Live", items: [
            TVChoice("Add to Favorites", symbol: "star") { performed.append("ESPN") }
        ]))
        let second = try XCTUnwrap(TVHoldMenuPresentation(title: "HBO", symbol: "tv", message: nil, items: [
            TVChoice("Remove Favorite", symbol: "star.slash") { performed.append("HBO") }
        ]))
        XCTAssertEqual(first.title, "ESPN")
        XCTAssertEqual(first.items.map(\.title), ["Add to Favorites"])
        XCTAssertEqual(second.title, "HBO")
        XCTAssertNotEqual(first.id, second.id, "Each hold gets a fresh sheet identity")
        first.items[0].action()
        second.items[0].action()
        XCTAssertEqual(performed, ["ESPN", "HBO"])
        XCTAssertNil(TVHoldMenuPresentation(title: "ESPN", symbol: "tv", message: nil, items: []),
                     "A held menu can never open as a header with no actions")
    }

    func testHeldDirectionsRepeatWithoutFocusCommandsAndStopExactlyOnce() {
        let session = TVSeekPressSession()
        var began: [Double] = []
        var frames: [(Double, Double, Double)] = []
        var ended = 0
        session.onBegin = { began.append($0) }
        session.onFrame = { frames.append(($0, $1, $2)) }
        session.onEnd = { ended += 1 }
        session.begin(1, at: 10)
        let firstID = session.id
        session.frame(at: 10.016)
        session.begin(1, at: 10.1)
        session.frame(at: 11)
        XCTAssertEqual(began, [1], "System press repeats must not restart the held gesture")
        XCTAssertEqual(frames.last?.1, 1)
        XCTAssertLessThanOrEqual(frames.last?.2 ?? 1, 0.1, "A dropped display frame must not produce a huge jump")
        session.begin(-1, at: 12)
        XCTAssertNotEqual(session.id, firstID)
        XCTAssertEqual(ended, 1)
        session.end(1)
        XCTAssertEqual(session.direction, -1, "Releasing the old direction must not stop a new opposite press")
        session.end(-1)
        session.end()
        XCTAssertEqual(ended, 2)
        let count = frames.count
        session.frame(at: 13)
        XCTAssertEqual(frames.count, count)
    }

    func testDirectionalRemoteStepsAreFifteenSecondsAndClampAtDuration() {
        XCTAssertEqual(PlaybackSeekPolicy.remoteTapSkip, 60)
        XCTAssertEqual(PlaybackSeekPolicy.remoteCommandTarget(from: 120, direction: -1, duration: 300), 60)
        XCTAssertEqual(PlaybackSeekPolicy.remoteCommandTarget(from: 120, direction: 1, duration: 300), 180)
        XCTAssertEqual(PlaybackSeekPolicy.remoteCommandTarget(from: 5, direction: -1, duration: 300), 0)
        XCTAssertEqual(PlaybackSeekPolicy.remoteCommandTarget(from: 295, direction: 1, duration: 300), 299)
    }

    func testTVSkipActionCapturesDestinationAndSuppressesEarlyKeyframeBounceBack() {
        let segments = MobilePlaybackSegments(
            intro: MobileIntroSegment(start: 30, end: 115),
            recap: MobileIntroSegment(start: 0, end: 25)
        )
        let recap = TVSkipAction.active(segments: segments, position: 12, duration: 2400,
                                        introEnabled: true, recapEnabled: true, recentlySkipped: nil)
        XCTAssertEqual(recap, TVSkipAction(kind: .recap, destination: 25))
        XCTAssertEqual(recap?.title, "Skip Recap")

        let intro = TVSkipAction.active(segments: segments, position: 45, duration: 2400,
                                        introEnabled: true, recapEnabled: true, recentlySkipped: nil)
        XCTAssertEqual(intro, TVSkipAction(kind: .intro, destination: 115))
        XCTAssertEqual(intro?.title, "Skip Intro")

        let nearEnd = TVSkipAction.active(segments: segments, position: 113, duration: 2400,
                                          introEnabled: true, recapEnabled: true, recentlySkipped: intro)
        XCTAssertNil(nearEnd, "An early-landing keyframe just before intro end must not flash Skip Intro back")

        let rewound = TVSkipAction.active(segments: segments, position: 50, duration: 2400,
                                          introEnabled: true, recapEnabled: true, recentlySkipped: intro)
        XCTAssertEqual(rewound, intro, "Rewinding well back into the intro should offer Skip Intro again")
    }
}
