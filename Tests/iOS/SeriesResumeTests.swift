import XCTest
#if os(tvOS)
@testable import Lineup
#else
@testable import LineupiOS
#endif

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

    func testARemoteJumpCannotSkipLocalEpisodes() {
        let records = [record(episode(1, 2), completed: true, at: 1)]
        XCTAssertEqual(target(records: records, serverNext: episode(2, 2), watched: ["s1e1", "s1e2"]), "s1e3")
    }

    func testNewManualUnwatchedOutranksOlderProgress() {
        let records = [record(episode(2, 3), position: 900, at: 1),
                       record(episode(2, 2), upNext: true, unwatched: true, at: 2)]
        XCTAssertEqual(target(records: records, serverNext: episode(2, 6), watched: []), "s2e2")
    }

    func testFinishingALaterEpisodeSupersedesOldPartialProgress() {
        let records = [record(episode(2, 1), position: 300, at: 1),
                       record(episode(2, 2), completed: true, at: 2)]
        XCTAssertEqual(target(records: records, watched: ["s2e2"]), "s2e3")
    }

    func testWatchingAheadStillWinsWhenAnEarlierEpisodeIsMarked() {
        let records = [record(episode(2, 3), position: 300, at: 1),
                       record(episode(2, 1), completed: true, at: 2)]
        XCTAssertEqual(target(records: records, watched: ["s2e1"]), "s2e3")
    }

    func testWithNothingHereTheServersWatchedStateDecides() {
        XCTAssertEqual(target(records: [], watched: ["s1e1", "s1e2"]), "s1e3")
        XCTAssertEqual(target(records: [], serverNext: episode(1, 4), watched: []), "s1e4")
    }

    func testRemoteSuggestionAndGeneratedQueueCannotSkipAnUnwatchedGapWithoutLocalCompletions() {
        let watched: Set = ["s2e1", "s2e2"]
        XCTAssertEqual(target(records: [], serverNext: episode(2, 6), watched: watched), "s2e3")
        XCTAssertEqual(target(records: [record(episode(2, 6), upNext: true, at: 1)], watched: watched), "s2e3")
    }

    func testGenuineLocalPlaybackAheadOfARemoteGapIsKept() {
        XCTAssertEqual(target(records: [record(episode(2, 6), position: 300, at: 1)],
            serverNext: episode(2, 6), watched: ["s2e1", "s2e2"]), "s2e6")
    }

    func testRemoteResumeProgressIsKeptDespiteEarlierUnwatchedEpisodes() {
        let resume = MediaItem(id: "s2e6", name: "Resume", type: "Episode", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
            indexNumber: 6, parentIndexNumber: 2, seriesName: "Show", seriesID: "show",
            userData: MediaUserData(played: false, isFavorite: false, playedPercentage: 30), serverID: server)
        XCTAssertEqual(target(records: [], serverNext: resume, watched: ["s2e1", "s2e2"]), "s2e6")
    }

    func testRemoteWatchedStateFromAnotherSeasonDoesNotResetTheSelectedSeason() {
        XCTAssertEqual(target(records: [], serverNext: episode(2, 4), watched: ["s1e1", "s1e2"]), "s2e4")
    }

    func testAFinishedShowStartsAgain() {
        let everything = Set(show.map(\.id))
        let records = [record(episode(2, 6), completed: true, at: 1)]
        XCTAssertEqual(target(records: records, watched: everything), "s1e1")
    }

    /// Finishing the newest episode of a show still airing: the viewer is
    /// waiting for the next one, not starting over and not on to the
    /// specials. Tulsa King's fourth season went back to the start, or to
    /// its specials, after each new episode.
    func testCaughtUpWithAShowStillAiringWaitsForItsNextEpisode() {
        let withSpecial = show + [episode(0, 1)]
        let everything = Set(show.map(\.id))
        let records = [record(episode(2, 6), completed: true, at: 1)]
        XCTAssertNil(SeriesResumePolicy.target(episodes: withSpecial, records: records, serverNext: nil,
                                               stillAiring: true, isWatched: { everything.contains($0.id) }))
        // Earlier episodes never watched here are no reason to go back to them.
        XCTAssertNil(SeriesResumePolicy.target(episodes: show, records: records, serverNext: nil,
                                               stillAiring: true, isWatched: { _ in false }))
    }

    func testASpecialNeverFollowsAnEpisodeOfASeason() {
        let withSpecial = show + [episode(0, 1)]
        let everything = Set(show.map(\.id))
        let records = [record(episode(2, 6), completed: true, at: 1)]
        XCTAssertEqual(SeriesResumePolicy.target(episodes: withSpecial, records: records, serverNext: nil,
                                                 isWatched: { everything.contains($0.id) })?.id, "s1e1",
                       "A finished show starts again rather than going on to its specials")
        let midway = [record(episode(1, 3), completed: true, at: 1)]
        XCTAssertEqual(SeriesResumePolicy.target(episodes: withSpecial, records: midway, serverNext: nil,
                                                 stillAiring: true, isWatched: { _ in false })?.id, "s1e4")
    }

    func testAShowIsStillAiringByItsStatusOrItsNewestEpisode() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func series(_ status: String?) -> MediaItem {
            MediaItem(id: "show", name: "Show", type: "Series", overview: nil, productionYear: nil,
                      primaryImageAspectRatio: nil, childCount: nil, status: status)
        }
        func aired(daysAgo: Double) -> MediaItem {
            let day = now.addingTimeInterval(-daysAgo * 86_400)
            let stamp = ISO8601DateFormatter().string(from: day)
            return MediaItem(id: "e", name: "E", type: "Episode", overview: nil, productionYear: nil,
                             primaryImageAspectRatio: nil, childCount: nil, premiereDate: stamp,
                             indexNumber: 2, parentIndexNumber: 4, seriesID: "show")
        }
        XCTAssertTrue(MediaLibrary.isStillAiring(series("Continuing"), episodes: [], now: now))
        XCTAssertFalse(MediaLibrary.isStillAiring(series("Ended"), episodes: [aired(daysAgo: 3)], now: now))
        XCTAssertTrue(MediaLibrary.isStillAiring(series(nil), episodes: [aired(daysAgo: 13)], now: now))
        XCTAssertFalse(MediaLibrary.isStillAiring(series(nil), episodes: [aired(daysAgo: 400)], now: now))
        XCTAssertFalse(MediaLibrary.isStillAiring(series(nil), episodes: [], now: now))
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
        XCTAssertTrue(SeriesResumePolicy.needsCheck(
            [record(episode(2, 2), completed: true, at: 2), record(episode(2, 6), upNext: true, at: 3)],
            isWatched: none))
        // Under way: already right.
        XCTAssertFalse(SeriesResumePolicy.needsCheck([record(episode(2, 4), position: 600, at: 1)],
                                                     isWatched: none))
        // Nothing finished: nothing to go on.
        XCTAssertFalse(SeriesResumePolicy.needsCheck([], isWatched: none))
    }
}
