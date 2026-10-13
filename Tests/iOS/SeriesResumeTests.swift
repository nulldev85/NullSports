import XCTest
@testable import LineupiOS

/// Where a show picks up, for its page's Play button and its posters.
final class SeriesResumeTests: XCTestCase {
    private let server = UUID()

    private func episode(_ season: Int, _ number: Int) -> MediaItem {
        MediaItem(id: "s\(season)e\(number)", name: "Episode \(number)", type: "Episode", overview: nil,
                  productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
                  indexNumber: number, parentIndexNumber: season, seriesName: "Show", seriesID: "show",
                  serverID: server)
    }

    private func record(_ item: MediaItem, completed: Bool = false, position: TimeInterval = 0,
                        upNext: Bool? = nil, unwatched: Bool? = nil, at minutes: Double) -> LocalMediaPlayback {
        LocalMediaPlayback(profileID: server, item: item, position: position, duration: 3_000,
                           updatedAt: Date(timeIntervalSince1970: minutes * 60), completed: completed,
                           explicitlyUnwatched: unwatched, isUpNext: upNext)
    }

    private lazy var show: [MediaItem] = (1...6).map { episode(1, $0) } + (1...6).map { episode(2, $0) }

    private func target(records: [LocalMediaPlayback], serverNext: MediaItem? = nil,
                        watched: Set<String>) -> String? {
        SeriesResumePolicy.target(episodes: show, records: records, serverNext: serverNext,
                                  isWatched: { watched.contains($0.id) })?.id
    }

    func testAStaleServerNextUpNeverMovesTheViewerBack() {
        // Season 2's first three were watched here, from another source; the
        // show's own server still thinks the season has not been started.
        let records = [record(episode(2, 1), completed: true, at: 1),
                       record(episode(2, 2), completed: true, at: 2),
                       record(episode(2, 3), completed: true, at: 3)]
        let watched: Set = ["s1e1", "s1e2", "s1e3", "s1e4", "s1e5", "s1e6", "s2e1", "s2e2", "s2e3"]
        XCTAssertEqual(target(records: records, serverNext: episode(2, 1), watched: watched), "s2e4")
    }

    func testAnEpisodeUnderWayIsWhereTheViewerIs() {
        let records = [record(episode(2, 3), completed: true, at: 1),
                       record(episode(2, 5), position: 900, at: 2)]
        XCTAssertEqual(target(records: records, watched: ["s2e3"]), "s2e5")
    }

    func testMarkingAnEpisodeUnwatchedGoesBackToIt() {
        let records = [record(episode(2, 3), completed: true, at: 1),
                       record(episode(2, 2), upNext: true, unwatched: true, at: 2)]
        XCTAssertEqual(target(records: records, watched: ["s2e1", "s2e3"]), "s2e2")
    }

    func testFinishingAfterMarkingBackMovesOn() {
        let records = [record(episode(2, 2), upNext: true, unwatched: true, at: 1),
                       record(episode(2, 4), completed: true, at: 2)]
        XCTAssertEqual(target(records: records, watched: ["s2e1", "s2e3", "s2e4"]), "s2e5")
    }

    func testTheServerCountsWhenItIsFurtherAlong() {
        // Watched further on another device, through the server itself.
        let records = [record(episode(1, 2), completed: true, at: 1)]
        XCTAssertEqual(target(records: records, serverNext: episode(2, 2), watched: ["s1e1", "s1e2"]), "s2e2")
    }

    func testWithNothingHereTheServersWatchedStateDecides() {
        XCTAssertEqual(target(records: [], watched: ["s1e1", "s1e2"]), "s1e3")
        XCTAssertEqual(target(records: [], serverNext: episode(1, 4), watched: []), "s1e4")
    }

    func testAFinishedShowStartsAgain() {
        let everything = Set(show.map(\.id))
        let records = [record(episode(2, 6), completed: true, at: 1)]
        XCTAssertEqual(target(records: records, watched: everything), "s1e1")
    }

    func testSpecialsComeAfterTheSeasons() {
        let special = episode(0, 1)
        let ordered = SeriesResumePolicy.ordered([special, episode(1, 2), episode(1, 1)])
        XCTAssertEqual(ordered.map(\.id), ["s1e1", "s1e2", "s0e1"])
        XCTAssertEqual(SeriesResumePolicy.ordered([special]).map(\.id), ["s0e1"])
    }

    func testOnlyShowsInDoubtAreWorkedOutAgain() {
        let none: (MediaItem) -> Bool = { _ in false }
        // Up Next behind the last episode finished: the bug's own state.
        XCTAssertTrue(SeriesResumePolicy.needsCheck(
            [record(episode(2, 3), completed: true, at: 2), record(episode(2, 1), upNext: true, at: 3)],
            isWatched: none))
        // Finished, and nothing queued.
        XCTAssertTrue(SeriesResumePolicy.needsCheck([record(episode(2, 3), completed: true, at: 2)],
                                                    isWatched: none))
        // Up Next after it: already right.
        XCTAssertFalse(SeriesResumePolicy.needsCheck(
            [record(episode(2, 3), completed: true, at: 2), record(episode(2, 4), upNext: true, at: 3)],
            isWatched: none))
        // Under way: already right.
        XCTAssertFalse(SeriesResumePolicy.needsCheck([record(episode(2, 4), position: 600, at: 1)],
                                                     isWatched: none))
        // Nothing finished: nothing to go on.
        XCTAssertFalse(SeriesResumePolicy.needsCheck([], isWatched: none))
    }
}
