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

    func testACategoryReadsItsNumberAsTextOrNumber() throws {
        let categories = try decode([Lenient<XtreamCategory>].self, #"""
        [{"category_id":"23","category_name":"New Releases"},{"category_id":24,"category_name":" Kids "},
         {"category_id":25,"category_name":""},{"category_name":"No number"}]
        """#).compactMap(\.value)

        XCTAssertEqual(categories.map(\.categoryID), ["23", "24", "25"])
        XCTAssertEqual(categories.map(\.categoryName), ["New Releases", "Kids", "25"])
    }

    func testAFilmsInfoReadsWhatThePanelSays() throws {
        let info = try decode(XtreamVODInfo.self, #"""
        {"info":{"description":"Paul joins the Fremen.","genre":"Science Fiction / Adventure",
                 "backdrop_path":["https://img/dune-wide.jpg"],"duration_secs":"9960",
                 "releasedate":"2024-02-27","tmdb_id":693134,"actors":"Timothée Chalamet, Zendaya",
                 "director":"Denis Villeneuve"},"movie_data":{"stream_id":12345}}
        """#)
        XCTAssertEqual(info.plot, "Paul joins the Fremen.")
        XCTAssertEqual(info.backdrop, "https://img/dune-wide.jpg")
        XCTAssertEqual(info.durationSeconds, 9960)
        XCTAssertEqual(info.tmdbID, "693134")
        XCTAssertEqual(info.cast.map(ProviderVOD.list(in:)), ["Timothée Chalamet", "Zendaya"])
        XCTAssertEqual(info.genre.map(ProviderVOD.list(in:)), ["Science Fiction", "Adventure"])

        let empty = try decode(XtreamVODInfo.self, #"{"info":[],"movie_data":[]}"#)
        XCTAssertNil(empty.plot, "A panel with nothing to say answers with an empty list")
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

    // MARK: The provider's titles in the Library

    func testAProviderItemSaysWhatItIs() {
        let places: [ProviderItem] = [.film(streamID: 12), .series(seriesID: 7), .season(seriesID: 7, number: 0),
                                      .episode(seriesID: 7, episodeID: "9001"), .filmCategory("23"),
                                      .seriesCategory("5")]
        for place in places { XCTAssertEqual(ProviderItem(id: place.id), place) }
        XCTAssertEqual(ProviderItem.film(streamID: 12).id, "iptv:film:12")
        XCTAssertNil(ProviderItem(id: "12"), "A media server's id is not the provider's")
        XCTAssertNil(ProviderItem(id: "iptv:film:twelve"))
        XCTAssertNil(ProviderItem(id: "mdblist:7"))
    }

    func testAProvidersTitleIsShownWithoutItsDecoration() {
        XCTAssertEqual(ProviderTitle.displayName(for: "EN - Dune: Part Two (2024) [4K]"), "Dune: Part Two")
        XCTAssertEqual(ProviderTitle.displayName(for: "|FR| Amélie"), "Amélie")
        XCTAssertEqual(ProviderTitle.displayName(for: "TRON: Legacy"), "TRON: Legacy")
        XCTAssertEqual(ProviderTitle.episodeName("Breaking Bad - S01E01 - Pilot", number: 1), "Pilot")
        XCTAssertEqual(ProviderTitle.episodeName("S02E10", number: 10), "Episode 10")
        XCTAssertEqual(ProviderTitle.episodeName("Ozymandias", number: 14), "Ozymandias")
    }

    func testCategoriesAndSearchReadTheProvidersList() {
        let provider = UUID()
        let catalog = ProviderVOD.Catalog(profileID: provider, films: [
            XtreamVODStream(streamID: 1, name: "EN - Dune: Part Two", categoryID: "23"),
            XtreamVODStream(streamID: 2, name: "Dune (1984)", categoryID: "24"),
            XtreamVODStream(streamID: 3, name: "Arrival", categoryID: "23"),
            XtreamVODStream(streamID: 4, name: "Paul and Dune Friends", categoryID: "24")
        ], shows: [XtreamSeries(seriesID: 9, name: "Dune: Prophecy", categoryID: "5")],
           filmCategories: [XtreamCategory(categoryID: "23", categoryName: "New")],
           fetchedAt: Date())
        let index = ProviderVOD.Index(catalog)
        XCTAssertEqual(index.films(inCategory: "23", in: catalog).map(\.streamID), [1, 3])
        XCTAssertEqual(index.film(streamID: 3, in: catalog)?.name, "Arrival")
        XCTAssertNil(index.film(streamID: 99, in: catalog))
        let found = index.search("dune", in: catalog)
        XCTAssertEqual(found.films.map(\.streamID), [2, 1, 4], "The name itself, then names starting with it")
        XCTAssertEqual(found.shows.map(\.seriesID), [9])
        XCTAssertEqual(index.search("   ", in: catalog).films, [])

        let film = ProviderVOD.item(for: catalog.films[0], provider: provider)
        XCTAssertEqual(film.name, "Dune: Part Two")
        XCTAssertEqual(film.type, "Movie")
        XCTAssertEqual(film.serverID, provider)
        XCTAssertTrue(film.isProviderTitle)
    }

    // The copy kept on the device carries each title's filings, so a launch
    // reads the list back without cleaning tens of thousands of names again.
    func testTheListKeptOnTheDeviceReadsBackFiledAsItWasWritten() throws {
        let provider = UUID()
        let catalog = ProviderVOD.Catalog(profileID: provider, films: [
            XtreamVODStream(streamID: 1, name: "EN - Dune: Part Two (2024) [4K]", icon: "https://img/dune.jpg",
                            categoryID: "23", containerExtension: "mkv", rating: 8.3, tmdbID: "693134", year: 2024),
            XtreamVODStream(streamID: 2, name: "Blade Runner 2049", categoryID: "24")
        ], shows: [XtreamSeries(seriesID: 9, name: "Dune: Prophecy", cover: "https://img/prophecy.jpg",
                                plot: "Two sisters.\nA\ttab, a \\ and\r\nmore lines.", genre: "Drama",
                                rating: 7.1, backdrop: "https://img/wide.jpg", categoryID: "5", tmdbID: "90228",
                                year: 2024)],
           filmCategories: [XtreamCategory(categoryID: "23", categoryName: "New\tReleases")],
           showCategories: [XtreamCategory(categoryID: "5", categoryName: "Drama")],
           fetchedAt: Date(timeIntervalSinceReferenceDate: 721_692_800.25))
        let url = try XCTUnwrap(ProviderVOD.cacheURL(profileID: provider))
        defer { try? FileManager.default.removeItem(at: url) }

        ProviderVOD.writeCache(ProviderVODFile.Contents(
            catalog: catalog, filmFilings: catalog.films.map { ProviderTitle.filings(for: $0.name) },
            showFilings: catalog.shows.map { ProviderTitle.filings(for: $0.name) }))
        let read = try XCTUnwrap(ProviderVOD.readCache(profileID: provider))

        XCTAssertEqual(read.catalog.films, catalog.films)
        XCTAssertEqual(read.catalog.shows, catalog.shows, "A plot's line breaks, tabs and backslashes survive")
        XCTAssertEqual(read.catalog.filmCategories, catalog.filmCategories)
        XCTAssertEqual(read.catalog.showCategories, catalog.showCategories)
        XCTAssertEqual(read.catalog.fetchedAt, catalog.fetchedAt)
        let fresh = ProviderVOD.Index(catalog)
        for (name, year) in [("Blade Runner 2049", 2017), ("Blade Runner", 2049), ("Dune: Part Two", 2024)] {
            let title = MediaItem(id: "server", name: name, type: "Movie", overview: nil, productionYear: year,
                                  primaryImageAspectRatio: nil, childCount: nil)
            XCTAssertEqual(read.index.films(for: title, in: read.catalog).map(\.streamID),
                           fresh.films(for: title, in: catalog).map(\.streamID), name)
        }
        XCTAssertEqual(read.index.search("dune", in: read.catalog).films.map(\.streamID), [1])
        XCTAssertEqual(read.index.shows(inCategory: "5", in: read.catalog).map(\.seriesID), [9])
        XCTAssertNil(ProviderVOD.readCache(profileID: UUID()), "Another provider's copy is not this one's")
    }

    // A file this build did not write reads as nothing, to be downloaded
    // afresh; a line that will not read loses only itself.
    func testOnlyAListThisBuildWroteReadsBackAndABadLineLosesOnlyItself() throws {
        let provider = UUID()
        let header = "lineup-provider-vod\t3\t\(provider.uuidString)\t721692800\n"
        let lines = header + "f\tnot-a-number\tBroken\t\t\t\t\t\t\t\n"
            + "f\t7\tArrival\t\t\tmp4\t\t329865\t2016\tarrival\t2016\n"
            + "x\ta kind a later build writes\n"
        let contents = try XCTUnwrap(ProviderVODFile.decode(Data(lines.utf8), profileID: provider))
        XCTAssertEqual(contents.catalog.films.map(\.streamID), [7])
        XCTAssertEqual(contents.catalog.films.first?.containerExtension, "mp4")
        XCTAssertEqual(contents.catalog.films.first?.tmdbID, "329865")
        XCTAssertNil(contents.catalog.films.first?.icon, "An empty field is no value")
        XCTAssertEqual(contents.filmFilings, [[ProviderTitle.Filed(key: "arrival", year: 2016)]])

        XCTAssertNil(ProviderVODFile.decode(Data(lines.utf8), profileID: UUID()))
        XCTAssertNil(ProviderVODFile.decode(Data(lines.replacingOccurrences(of: "\t3\t", with: "\t9\t").utf8),
                                            profileID: provider))
        XCTAssertNil(ProviderVODFile.decode(Data(#"{"version":2}"#.utf8), profileID: provider))
        XCTAssertNil(ProviderVODFile.decode(Data(), profileID: provider))
    }

    // Updating the app does not mean downloading the whole list again: the
    // copy the previous builds kept is read once, filings and all, and
    // removed -- with the first builds' copy, which is no longer read.
    func testTheListThePreviousBuildsKeptIsReadOnceAndRemoved() throws {
        let provider = UUID()
        let url = try XCTUnwrap(ProviderVOD.earlierCacheURL(profileID: provider))
        let first = try XCTUnwrap(ProviderVOD.firstCacheURL(profileID: provider))
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: first)
        }
        let kept = #"{"version":2,"profileID":"\#(provider.uuidString)","fetchedAt":721692800,"#
            + #""films":[{"i":1,"n":"Dune (2021)","x":"mkv","t":"438631","y":2021,"f":[{"k":"dune","y":2021}]}],"#
            + #""shows":[],"filmCategories":[{"category_id":"23","category_name":"New"}],"showCategories":[]}"#
        try Data(kept.utf8).write(to: url)
        try Data("[]".utf8).write(to: first)

        let earlier = try XCTUnwrap(ProviderVOD.readEarlierCache(profileID: provider))
        XCTAssertEqual(earlier.catalog.films.map(\.streamID), [1])
        XCTAssertEqual(earlier.catalog.films.first?.tmdbID, "438631")
        XCTAssertEqual(earlier.catalog.filmCategories.map(\.categoryID), ["23"])
        XCTAssertEqual(earlier.filmFilings, [[ProviderTitle.Filed(key: "dune", year: 2021)]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Read once, then removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))

        try Data(kept.replacingOccurrences(of: #""version":2"#, with: #""version":1"#).utf8).write(to: url)
        XCTAssertNil(ProviderVOD.readEarlierCache(profileID: provider), "Not a layout this build knows")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAShowsSeasonsAreTheSeasonsItsEpisodesNumber() {
        let show = XtreamSeries(seriesID: 7, name: "Breaking Bad", cover: "https://img/bb.jpg")
        let episodes = [XtreamEpisode(id: "1", season: 1, episodeNumber: 1, title: "Pilot"),
                        XtreamEpisode(id: "2", season: 1, episodeNumber: 2, title: "Cat's in the Bag"),
                        XtreamEpisode(id: "3", season: 0, episodeNumber: 1, title: "Minisode")]
        let seasons = ProviderVOD.seasons(of: show, episodes: episodes, provider: UUID())
        XCTAssertEqual(seasons.map(\.name), ["Specials", "Season 1"])
        XCTAssertEqual(seasons.map(\.indexNumber), [0, 1])
        XCTAssertEqual(seasons.last?.childCount, 2)
        let episode = ProviderVOD.item(for: episodes[1], of: show, provider: UUID())
        XCTAssertEqual(episode.episodeCode, "S01E02")
        XCTAssertEqual(episode.seriesName, "Breaking Bad")
        XCTAssertEqual(ProviderItem(id: episode.id), .episode(seriesID: 7, episodeID: "2"))
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
