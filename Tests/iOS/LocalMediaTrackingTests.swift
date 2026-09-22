import XCTest
@testable import Lineup

final class LocalMediaTrackingTests: XCTestCase {
    private func record(position: TimeInterval, duration: TimeInterval,
                        completed: Bool = false) -> LocalMediaPlayback {
        LocalMediaPlayback(
            profileID: UUID(),
            item: MediaItem(id: "movie-1", name: "Movie", type: "Movie",
                overview: nil, productionYear: nil, primaryImageAspectRatio: nil,
                childCount: nil),
            position: position,
            duration: duration,
            updatedAt: Date(timeIntervalSince1970: 1),
            completed: completed
        )
    }

    func testResumeRequiresMeaningfulProgressAndRoomToWatch() {
        XCTAssertNil(LocalMediaTrackingPolicy.resumePosition(for: record(position: 9, duration: 3600)))
        XCTAssertEqual(LocalMediaTrackingPolicy.resumePosition(for: record(position: 900, duration: 3600)), 900)
        XCTAssertNil(LocalMediaTrackingPolicy.resumePosition(for: record(position: 3580, duration: 3600)))
        XCTAssertNil(LocalMediaTrackingPolicy.resumePosition(for: record(position: 900, duration: 3600, completed: true)))
    }

    func testCompletionUsesPercentageOrShortRemainingTail() {
        XCTAssertFalse(LocalMediaTrackingPolicy.isComplete(position: 5400, duration: 6000))
        XCTAssertTrue(LocalMediaTrackingPolicy.isComplete(position: 5520, duration: 6000))
        XCTAssertTrue(LocalMediaTrackingPolicy.isComplete(position: 3500, duration: 3600))
        XCTAssertFalse(LocalMediaTrackingPolicy.isComplete(position: 30, duration: 100))
    }
}
