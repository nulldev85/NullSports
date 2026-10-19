import XCTest
@testable import LineupiOS

/// A show's next episode when its server does not have it yet: TVmaze's
/// schedule, and the air dates a card reads.
final class UpcomingEpisodeTests: XCTestCase {
    private func scheduled(_ id: Int, season: Int, number: Int?) -> TVMazeSchedule.Episode {
        TVMazeSchedule.Episode(id: id, name: "Episode \(id)", season: season, number: number,
                               airstamp: nil, image: nil, summary: nil)
    }

    func testTheNextEpisodeIsTheOneAfterInAiringOrder() {
        let episodes = [scheduled(5, season: 2, number: 2), scheduled(1, season: 1, number: 9),
                        scheduled(4, season: 2, number: 1), scheduled(3, season: 1, number: 10)]
        XCTAssertEqual(TVMazeSchedule.following(season: 1, number: 9, in: episodes)?.id, 3)
        // A finale leads into the next season.
        XCTAssertEqual(TVMazeSchedule.following(season: 1, number: 10, in: episodes)?.id, 4)
        XCTAssertNil(TVMazeSchedule.following(season: 2, number: 2, in: episodes))
    }

    func testSpecialsArePassedOver() {
        let episodes = [scheduled(1, season: 1, number: 3), scheduled(2, season: 1, number: nil),
                        scheduled(3, season: 0, number: 1), scheduled(4, season: 1, number: 4)]
        XCTAssertEqual(TVMazeSchedule.following(season: 1, number: 3, in: episodes)?.id, 4)
    }

    func testSummariesLoseTheirMarkup() {
        XCTAssertEqual(TVMazeSchedule.plainText("<p>The <b>crew</b> returns.</p>"), "The crew returns.")
    }

    private func episode(premiere: String?, id: String = "e1") -> MediaItem {
        MediaItem(id: id, name: "Pilot", type: "Episode", overview: nil, productionYear: nil,
                  primaryImageAspectRatio: nil, childCount: nil, premiereDate: premiere)
    }

    func testAirDatesAreReadFromEveryServer() {
        // Jellyfin's seven-digit fractions, TVmaze's offset, and Plex's day.
        XCTAssertNotNil(episode(premiere: "2026-08-11T00:00:00.0000000Z").premiereDay)
        XCTAssertNotNil(episode(premiere: "2026-08-11T01:00:00+00:00").premiereDay)
        XCTAssertNotNil(episode(premiere: "2026-08-11").premiereDay)
        XCTAssertNil(episode(premiere: nil).premiereDay)
    }

    func testOnlyAnEpisodeNotYetOnTheAirIsLabelled() {
        XCTAssertNil(episode(premiere: "2001-01-01T00:00:00Z").upcomingLabel)
        XCTAssertNotNil(episode(premiere: "2999-01-01T00:00:00Z").upcomingLabel)
        XCTAssertTrue(episode(premiere: "2999-01-01T00:00:00Z").isUnaired)
        // A placeholder with no date still says it is on its way.
        XCTAssertEqual(episode(premiere: nil, id: MediaItem.upcomingPrefix + "7").upcomingLabel, "COMING SOON")
        let film = MediaItem(id: "f", name: "Film", type: "Movie", overview: nil, productionYear: nil,
                             primaryImageAspectRatio: nil, childCount: nil, premiereDate: "2999-01-01")
        XCTAssertNil(film.upcomingLabel)
    }
}
