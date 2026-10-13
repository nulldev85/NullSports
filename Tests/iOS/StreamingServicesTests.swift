import XCTest
@testable import LineupiOS

/// The Streaming Services row: reading MDBList's public lists, keeping only
/// what the viewer's sources can play, and the orders a service's titles
/// can be put in.
final class StreamingServicesTests: XCTestCase {
    private let server = UUID()

    private func entry(_ title: String, _ type: String = "movie", year: Int? = 2026,
                       imdb: String? = nil, tmdb: String? = nil) -> MDBListCatalogItem {
        MDBListCatalogItem(title: title, mediaType: type, releaseYear: year, imdbID: imdb,
                           tmdbID: tmdb, tvdbID: nil, rank: nil)
    }

    private func item(_ id: String, _ name: String, type: String = "Movie", year: Int? = 2026,
                      ids: [String: String]? = nil) -> MediaItem {
        MediaItem(id: id, name: name, type: type, overview: nil, productionYear: year,
                  primaryImageAspectRatio: nil, childCount: nil, providerIDs: ids).servedBy(server)
    }

    func testPublicListReadsInItsOwnOrderWithTMDBIDs() throws {
        let json = """
        [{"id": 808, "rank": 1000, "adult": 0, "title": "Shrek", "tvdbid": 325, "imdb_id": "tt0126029",
          "mediatype": "movie", "release_year": 2001},
         {"id": 9, "rank": 1500, "adult": 1, "title": "Left Out", "imdb_id": "tt1", "mediatype": "movie"},
         {"id": 1396, "rank": 3000, "adult": 0, "title": "Breaking Bad", "tvdbid": null, "imdb_id": "",
          "mediatype": "show", "release_year": 2008}]
        """
        let items = try MDBListPublicList.parse(Data(json.utf8))
        XCTAssertEqual(items.map(\.title), ["Shrek", "Breaking Bad"])
        XCTAssertEqual(items.map(\.rank), [1, 2])
        XCTAssertEqual(items[0].tmdbID, "808")
        XCTAssertEqual(items[0].imdbID, "tt0126029")
        XCTAssertEqual(items[0].tvdbID, "325")
        XCTAssertEqual(items[1].mediaType, "show")
        XCTAssertNil(items[1].imdbID)
        XCTAssertNil(items[1].tvdbID)
    }

    func testMalformedListIsAnError() {
        XCTAssertThrowsError(try MDBListPublicList.parse(Data("{\"error\": 1}".utf8)))
    }

    func testOnlyPlayableTitlesAreKeptWithBothPlaces() {
        let library = [
            item("a", "Animals", ids: ["Imdb": "tt100"]),
            item("b", "Go Team!"),
            item("c", "The Breadwinner", ids: ["Tmdb": "55"])
        ]
        let index = MDBListCatalogMatcher.Index(library)
        let popular = [entry("Animals", imdb: "tt100"), entry("Not Here", imdb: "tt999"),
                       entry("The Breadwinner", tmdb: "55")]
        let latest = [entry("Go Team!"), entry("Animals", imdb: "tt100")]
        let titles = StreamingCatalogBuilder.titles(popular: popular, latest: latest, resolve: index.match)

        XCTAssertEqual(titles.map(\.item.id), ["a", "c", "b"])
        XCTAssertEqual(titles[0].popularRank, 1)
        XCTAssertEqual(titles[0].latestRank, 2)
        // A place is the place on the list, counting what could not be played.
        XCTAssertEqual(titles[1].popularRank, 3)
        XCTAssertNil(titles[1].latestRank)
        XCTAssertEqual(titles[2].latestRank, 1)
        XCTAssertNil(titles[2].popularRank)
    }

    func testAShowIsNeverMatchedToAFilm() {
        let index = MDBListCatalogMatcher.Index([item("f", "Lanterns")])
        XCTAssertNil(index.match(entry("Lanterns", "show")))
        XCTAssertEqual(index.match(entry("Lanterns"))?.id, "f")
    }

    func testListsAreReadOnlyAsDeepAsWorthAndByKind() {
        let mixed = (1...80).map { entry("Film \($0)") } + [entry("A Show", "show")]
        XCTAssertEqual(StreamingCatalogBuilder.entries(of: mixed, chart: .popular, kind: .movie).count,
                       StreamingService.popularDepth)
        XCTAssertEqual(StreamingCatalogBuilder.entries(of: mixed, chart: .latest, kind: .movie).count,
                       StreamingService.latestDepth)
        XCTAssertEqual(StreamingCatalogBuilder.entries(of: mixed, chart: .latest, kind: .show).map(\.title),
                       ["A Show"])
    }

    func testOneEntryHasOneKeyAcrossLists() {
        XCTAssertEqual(StreamingCatalogBuilder.key(of: entry("Dune", imdb: "tt1160419")),
                       StreamingCatalogBuilder.key(of: entry("Dune: Part One", imdb: "tt1160419")))
        XCTAssertNotEqual(StreamingCatalogBuilder.key(of: entry("Dune", imdb: "tt1160419")),
                          StreamingCatalogBuilder.key(of: entry("Dune", "show", imdb: "tt1160419")))
    }

    func testSorts() {
        func title(_ name: String, popular: Int?, latest: Int?, year: Int?) -> StreamingTitle {
            StreamingTitle(item: item(name, name, year: nil), popularRank: popular, latestRank: latest, year: year)
        }
        let titles = [
            title("Charlie", popular: nil, latest: 1, year: 2026),
            title("Alpha", popular: 2, latest: nil, year: 2019),
            title("Bravo", popular: 1, latest: 3, year: 2024),
            title("Delta", popular: nil, latest: nil, year: nil)
        ]
        XCTAssertEqual(StreamingSort.popular.sorted(titles).map(\.item.name), ["Bravo", "Alpha", "Charlie", "Delta"])
        XCTAssertEqual(StreamingSort.latest.sorted(titles).map(\.item.name), ["Charlie", "Bravo", "Alpha", "Delta"])
        XCTAssertEqual(StreamingSort.newest.sorted(titles).map(\.item.name), ["Charlie", "Bravo", "Alpha", "Delta"])
        XCTAssertEqual(StreamingSort.title.sorted(titles).map(\.item.name), ["Alpha", "Bravo", "Charlie", "Delta"])
    }

    func testTitlesFromARemovedSourceLeave() {
        let other = UUID()
        let kept = StreamingTitle(item: item("a", "Animals"))
        let gone = StreamingTitle(item: item("b", "Gone").servedBy(other))
        let titles = StreamingServiceTitles(movies: [kept, gone], shows: [])
        XCTAssertEqual(titles.held(by: [server]).movies.map(\.item.id), ["a"])
        XCTAssertTrue(titles.held(by: []).isEmpty)
    }

    func testServicePostersRoundTrip() {
        for service in StreamingService.all {
            let poster = service.item(titles: 3)
            XCTAssertEqual(StreamingService.service(for: poster), service)
            XCTAssertTrue(poster.opensPage)
            XCTAssertFalse(service.lists.isEmpty)
        }
        XCTAssertNil(StreamingService.service(for: item("streaming:netflix", "Netflix")))
        XCTAssertEqual(Set(StreamingService.all.map(\.id)).count, StreamingService.all.count)
    }

    func testCardOnlyKeepsWhatAPosterAndItsStreamsNeed() {
        let full = MediaItem(id: "x", name: "Dune", type: "Movie", overview: "Sand.", productionYear: 2021,
                             primaryImageAspectRatio: 0.67, childCount: nil,
                             imageTags: ["Primary": "tag"], tags: ["4K", "Atmos"],
                             providerIDs: ["Imdb": "tt1160419"]).servedBy(server)
        let slim = full.cardOnly
        XCTAssertNil(slim.tags)
        XCTAssertEqual(slim.libraryKey, full.libraryKey)
        XCTAssertEqual(slim.providerIDs, full.providerIDs)
        XCTAssertEqual(slim.imageTags, full.imageTags)
        XCTAssertEqual(slim.productionYear, 2021)
    }

    func testTrendingRowKeepsTheChartOrderAndOnlyWhatPlays() {
        let index = MDBListCatalogMatcher.Index([item("b", "Bravo", ids: ["Imdb": "tt2"]),
                                                 item("a", "Alpha", ids: ["Imdb": "tt1"]),
                                                 item("s", "Show", type: "Series", ids: ["Imdb": "tt9"])])
        let chart = [entry("Alpha", imdb: "tt1"), entry("Missing", imdb: "tt5"), entry("Bravo", imdb: "tt2"),
                     entry("Show", "show", imdb: "tt9"), entry("Alpha again", imdb: "tt1")]
        XCTAssertEqual(LibraryTrendingRow.titles(from: chart, kind: .movie, resolve: index.match).map(\.id),
                       ["a", "b"])
        XCTAssertEqual(LibraryTrendingRow.titles(from: chart, kind: .show, resolve: index.match).map(\.id), ["s"])
        XCTAssertEqual(LibraryTrendingRow.all.map(\.id), ["builtin:trending-movies", "builtin:trending-shows"])
    }

    func testSnapshotRoundTrips() throws {
        let snapshot = StreamingServicesSnapshot(
            builtAt: Date(timeIntervalSince1970: 1_000), sources: [server.uuidString],
            services: ["netflix": StreamingServiceTitles(movies: [StreamingTitle(item: item("a", "Animals"),
                                                                                 popularRank: 1)])])
        let decoded = try JSONDecoder().decode(StreamingServicesSnapshot.self,
                                               from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.services["netflix"]?.movies.first?.item.id, "a")
        XCTAssertEqual(decoded.services["netflix"]?.movies.first?.popularRank, 1)
        XCTAssertEqual(decoded.sources, [server.uuidString])
    }
}
