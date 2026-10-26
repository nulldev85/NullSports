import XCTest
@testable import LineupiOS

/// The Library's Trending and streaming-service rows before any media server
/// can play from them: cards from the public charts, described by TMDB.
@MainActor
final class LibraryChartRowsTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let name = "LibraryChartRowsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testAChartEntryBecomesACardKnownOnlyByItsIDs() throws {
        let show = try XCTUnwrap(MediaLibrary.catalogItem(MDBListCatalogItem(title: "Severance", mediaType: "show",
            releaseYear: 2022, imdbID: "tt11280740", tmdbID: "95396", tvdbID: "371980", rank: 1)))
        XCTAssertEqual(show.id, "catalog|series|95396")
        XCTAssertEqual(show.type, "Series")
        XCTAssertEqual(show.name, "Severance")
        XCTAssertEqual(show.productionYear, 2022)
        XCTAssertEqual(show.providerIDs, ["tmdb": "95396", "imdb": "tt11280740", "tvdb": "371980"])
        XCTAssertNil(show.serverID, "No server holds a chart title")

        let film = try XCTUnwrap(MediaLibrary.catalogItem(MDBListCatalogItem(title: "Sinners", mediaType: "movie",
            releaseYear: 2025, imdbID: nil, tmdbID: "1233413", tvdbID: nil, rank: 2)))
        XCTAssertEqual(film.id, "catalog|movie|1233413")
        XCTAssertEqual(film.type, "Movie")
        XCTAssertEqual(film.providerIDs, ["tmdb": "1233413"])

        XCTAssertNil(MediaLibrary.catalogItem(MDBListCatalogItem(title: "Unknown", mediaType: "movie",
            releaseYear: nil, imdbID: "tt0000001", tmdbID: nil, tvdbID: nil, rank: 3)),
            "Without a TMDB id there is no poster or page to show")
    }

    func testWithNothingConnectedTheRowsStandOnTheChartsAndTMDBDescribesThem() throws {
        let library = MediaLibrary(defaults: try defaults(), metadataCredentials: .init(tmdb: "", tvdb: ""))
        XCTAssertFalse(library.canPlayAnything)
        XCTAssertTrue(library.showsCatalogRows)
        let chart = try XCTUnwrap(MediaLibrary.catalogItem(MDBListCatalogItem(title: "Severance", mediaType: "show",
            releaseYear: 2022, imdbID: nil, tmdbID: "95396", tvdbID: nil, rank: 1)))
        let owned = MediaItem(id: "server-item", name: "Owned", type: "Series", overview: nil, productionYear: nil,
                              primaryImageAspectRatio: nil, childCount: nil)
        XCTAssertTrue(library.isCatalogOnly(chart))
        XCTAssertFalse(library.isCatalogOnly(owned))

        // Whatever describes the Library's own titles, a chart title has no
        // server to describe it, so it is always TMDB's.
        library.setMetadataSource(.provider)
        XCTAssertTrue(library.metadataRequestKey(for: chart).hasPrefix("tmdb|"))
        XCTAssertTrue(library.metadataRequestKey(for: owned).hasPrefix("provider|"))
    }
}
