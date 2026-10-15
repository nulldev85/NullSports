import XCTest
@testable import Lineup

@MainActor
final class RemoteInteractionTests: XCTestCase {
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
}
