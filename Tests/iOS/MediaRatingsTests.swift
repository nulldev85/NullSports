import XCTest
@testable import LineupiOS

/// IMDb, TMDB and Rotten Tomatoes, read the same way from wherever a title's
/// scores come from.
final class MediaRatingsTests: XCTestCase {
    // A server's addons store every score out of a hundred.
    func testAServersScoresReadOutOfTenAndAsAPercentage() {
        let ratings = MediaRatings(metrics: [
            MediaMetric(source: "imdb", value: 80, date: "2026-10-09"),
            MediaMetric(source: "tmdb", value: 83.4, date: "2026-10-09"),
            MediaMetric(source: "rottentomatoes", value: 90, date: "2026-10-09"),
            MediaMetric(source: "trakt", value: 77, date: "2026-10-09")
        ])
        XCTAssertEqual(ratings, MediaRatings(imdb: 8.0, tmdb: 8.3, rottenTomatoes: 90))
    }

    // MDBList gives IMDb out of ten and TMDB and the Tomatometer out of a
    // hundred, with a score out of a hundred when a value is missing.
    func testMDBListsRatingsReadTheSameWay() {
        let ratings = MediaRatings(mdbList: [
            ["source": "imdb", "value": 8.0, "score": 80],
            ["source": "tmdb", "value": 83, "score": 83],
            ["source": "tomatoes", "value": 90, "score": 90],
            ["source": "metacritic", "value": 70, "score": 70]
        ] as [[String: Any]])
        XCTAssertEqual(ratings, MediaRatings(imdb: 8.0, tmdb: 8.3, rottenTomatoes: 90))

        let scoreOnly = MediaRatings(mdbList: [
            ["source": "imdb", "value": NSNull(), "score": 75]
        ] as [[String: Any]])
        XCTAssertEqual(scoreOnly.imdb, 7.5)
        XCTAssertTrue(MediaRatings(mdbList: nil).isEmpty)
    }

    // What a title carries itself: Jellyfin's community rating is TMDB's, its
    // critic rating the Tomatometer. A zero is no rating at all.
    func testATitlesOwnRatingsFillWhatTheSourcesLeaveOut() {
        let film = MediaItem(id: "f", name: "Training Day", type: "Movie", overview: nil, productionYear: 2001,
                             primaryImageAspectRatio: nil, childCount: nil,
                             communityRating: 7.8, criticRating: 91)
        XCTAssertEqual(MediaRatings(item: film), MediaRatings(tmdb: 7.8, rottenTomatoes: 91))

        let unrated = MediaItem(id: "u", name: "Unrated", type: "Movie", overview: nil, productionYear: nil,
                                primaryImageAspectRatio: nil, childCount: nil,
                                communityRating: 0, criticRating: nil)
        XCTAssertTrue(MediaRatings(item: unrated).isEmpty)

        let fromServer = MediaRatings(rottenTomatoes: 88)
        let filled = fromServer.filling(from: MediaRatings(imdb: 8.1, tmdb: 7.9, rottenTomatoes: 70))
        XCTAssertEqual(filled, MediaRatings(imdb: 8.1, tmdb: 7.9, rottenTomatoes: 88),
                       "A source asked first keeps its own score")
        XCTAssertTrue(filled.isComplete)
    }
}
