import XCTest
@testable import LineupiOS

/// The provider's films and shows are read however its panel writes them.
final class XtreamVODTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testAFilmReadsWhicheverWayItsFieldsAreWritten() throws {
        let films = try decode([Lenient<XtreamVODStream>].self, #"""
        [
          {"num":1,"name":"Dune: Part Two (2024)","stream_type":"movie","stream_id":"12345",
           "stream_icon":"https://img/dune.jpg","rating":"8.3","category_id":23,
           "container_extension":"mkv","tmdb":"693134"},
          {"name":"Arrival","stream_id":678,"rating":"","year":"2016","tmdb_id":329865,"container_extension":"mp4"},
          {"name":"No id at all"},
          {"name":"Old Panel","stream_id":9,"releasedate":"1999-03-31","tmdb":"0"}
        ]
        """#).compactMap(\.value)

        XCTAssertEqual(films.map(\.streamID), [12345, 678, 9], "An entry with no id is dropped, not the list")
        XCTAssertEqual(films[0].tmdbID, "693134")
        XCTAssertEqual(films[0].year, 2024, "The year a provider writes into the title")
        XCTAssertEqual(films[0].rating, 8.3)
        XCTAssertEqual(films[0].categoryID, "23")
        XCTAssertEqual(films[1].tmdbID, "329865")
        XCTAssertEqual(films[1].year, 2016)
        XCTAssertNil(films[1].rating, "An empty rating is no rating")
        XCTAssertNil(films[2].tmdbID, "A TMDB id of 0 is no id")
        XCTAssertEqual(films[2].year, 1999)
    }

    func testAShowReadsItsBackdropAsAListOrASingleOne() throws {
        let shows = try decode([Lenient<XtreamSeries>].self, #"""
        [
          {"name":"Breaking Bad","series_id":123,"cover":"https://img/bb.jpg","releaseDate":"2008-01-20",
           "rating":"9","backdrop_path":["","https://img/bb-wide.jpg"],"category_id":"5","tmdb":"1396"},
          {"name":"Severance","series_id":"456","backdrop_path":"https://img/sev.jpg","release_date":"2022-02-18"}
        ]
        """#).compactMap(\.value)

        XCTAssertEqual(shows.map(\.seriesID), [123, 456])
        XCTAssertEqual(shows[0].backdrop, "https://img/bb-wide.jpg")
        XCTAssertEqual(shows[0].year, 2008)
        XCTAssertEqual(shows[0].tmdbID, "1396")
        XCTAssertEqual(shows[1].backdrop, "https://img/sev.jpg")
        XCTAssertEqual(shows[1].year, 2022)
    }

    // Keyed by season on most panels; the season comes from the list when an
    // episode does not say its own.
    func testAShowsEpisodesComeInSeasonOrder() throws {
        let info = try decode(XtreamSeriesInfo.self, #"""
        {"seasons":[],"info":{},"episodes":{
          "2":[{"id":"9002","episode_num":"1","title":"S02E01","container_extension":"mkv",
                "info":{"duration_secs":3480,"movie_image":"https://img/s2e1.jpg","plot":"Two"}}],
          "1":[{"id":9001,"episode_num":2,"season":1,"title":"S01E02","container_extension":"mkv"},
               {"id":"9000","episode_num":1,"season":"1","title":"S01E01","container_extension":"mkv"},
               {"title":"No id"}]
        }}
        """#)

        XCTAssertEqual(info.episodes.map(\.id), ["9000", "9001", "9002"])
        XCTAssertEqual(info.episodes.map(\.season), [1, 1, 2])
        XCTAssertEqual(info.episodes.last?.durationSeconds, 3480)
        XCTAssertEqual(info.episodes.last?.image, "https://img/s2e1.jpg")
    }

    func testAFlatEpisodeListAlsoReads() throws {
        let info = try decode(XtreamSeriesInfo.self, #"""
        {"episodes":[{"id":"7","episode_num":3,"season":2,"title":"Three"}]}
        """#)
        XCTAssertEqual(info.episodes.first?.season, 2)
        XCTAssertEqual(info.episodes.first?.episodeNumber, 3)
    }

    // MARK: Finding a Library title among the provider's

    func testAProvidersDecorationIsNotPartOfTheName() {
        func keys(_ name: String) -> [String] { ProviderTitle.filings(for: name).map(\.key) }
        XCTAssertEqual(keys("EN - Dune: Part Two (2024) [4K]"), ["duneparttwo"])
        XCTAssertEqual(ProviderTitle.filings(for: "EN - Dune: Part Two (2024) [4K]").first?.year, 2024)
        XCTAssertEqual(keys("|FR| Dune"), ["dune"])
        XCTAssertEqual(keys("4K-EN - Dune"), ["dune"])
        XCTAssertEqual(keys("AMZ - The Boys"), ["theboys"])
        XCTAssertEqual(keys("TRON: Legacy"), ["tronlegacy"], "A colon after a word that is no code is the title's")
        XCTAssertEqual(keys("X-Men"), ["xmen"])
        XCTAssertEqual(keys("1917"), ["1917"], "A title that is a year keeps it")
    }

    // Filed with the number and without it, each meaning a different year.
    func testANameEndingInAYearIsFiledBothWays() {
        let dune = ProviderTitle.filings(for: "Dune Part Two 2024 MULTI")
        XCTAssertEqual(dune, [ProviderTitle.Filed(key: "duneparttwo2024", year: nil),
                              ProviderTitle.Filed(key: "duneparttwo", year: 2024)])
        let runner = ProviderTitle.filings(for: "Blade Runner 2049")
        XCTAssertEqual(runner.first, ProviderTitle.Filed(key: "bladerunner2049", year: nil))
    }

    func testATitleIsFoundByItsTMDBIDOrItsNameAndYear() {
        let catalog = ProviderVOD.Catalog(profileID: UUID(), films: [
            XtreamVODStream(streamID: 1, name: "EN - Dune: Part Two [4K]", tmdbID: "693134"),
            XtreamVODStream(streamID: 2, name: "Dune: Part Two (2024) FHD"),
            XtreamVODStream(streamID: 3, name: "Dune (1984)"),
            XtreamVODStream(streamID: 4, name: "Dune: Part Two", tmdbID: "1"),
            XtreamVODStream(streamID: 5, name: "Blade Runner 2049"),
            XtreamVODStream(streamID: 6, name: "Blade Runner", year: 1982)
        ], shows: [], fetchedAt: Date())
        let index = ProviderVOD.Index(catalog)
        func found(_ item: MediaItem) -> [Int] { index.films(for: item, in: catalog).map(\.streamID) }
        func film(_ name: String, _ year: Int?, tmdb: String? = nil) -> MediaItem {
            MediaItem(id: name, name: name, type: "Movie", overview: nil, productionYear: year,
                      primaryImageAspectRatio: nil, childCount: nil, providerIDs: tmdb.map { ["Tmdb": $0] })
        }

        XCTAssertEqual(found(film("Dune: Part Two", 2024, tmdb: "693134")), [1, 2],
                       "Every copy of the film, and none filed under another film's id")
        XCTAssertEqual(found(film("Dune", 2021)), [], "A remake is another film")
        XCTAssertEqual(found(film("Dune", 1984)), [3])
        XCTAssertEqual(found(film("Blade Runner 2049", 2017)), [5])
        XCTAssertEqual(found(film("Blade Runner", 1982)), [6], "Blade Runner 2049 is not Blade Runner from 2049")
    }

    func testFilmsAndEpisodesPlayFromTheProvidersOwnPaths() throws {
        let client = XtreamClient(profile: XtreamProfile(name: "Provider", serverURL: "http://tv.example:8080",
                                                         username: "user"), password: "secret")
        let film = XtreamVODStream(streamID: 12345, name: "Dune", containerExtension: "MKV")
        XCTAssertEqual(client.movieURL(for: film)?.absoluteString, "http://tv.example:8080/movie/user/secret/12345.mkv")
        let episode = XtreamEpisode(id: "9000", season: 1, episodeNumber: 1, title: "Pilot", containerExtension: "mp4")
        XCTAssertEqual(client.episodeURL(for: episode)?.absoluteString, "http://tv.example:8080/series/user/secret/9000.mp4")
    }
}
