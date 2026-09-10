import XCTest
@testable import NullSportsiOS

final class MediaServerTests: XCTestCase {
    func testDecodesJellyfinAndNullfinCatalogItems() throws {
        let data = Data(#"{"Items":[{"Id":"movie-1","Name":"Owned Movie","Type":"Movie","ProductionYear":2026,"PrimaryImageAspectRatio":0.6667},{"Id":"series-1","Name":"Addon Series","Type":"Series","ChildCount":8}]}"#.utf8)

        let response = try JSONDecoder().decode(JellyfinItemsResponse.self, from: data)

        XCTAssertEqual(response.items.map(\.name), ["Owned Movie", "Addon Series"])
        XCTAssertTrue(response.items[0].isPlayable)
        XCTAssertTrue(response.items[1].isFolder)
    }

    func testMediaURLsUseNullfinCompatibleLowercaseRoutes() throws {
        let client = try JellyfinClient(
            serverURL: "https://media.example.test/base/",
            accessToken: "secret token",
            deviceID: "device-1"
        )

        let imageURL = try XCTUnwrap(client.imageURL(itemID: "item-1", maxWidth: 720))
        XCTAssertEqual(imageURL.path, "/base/items/item-1/images/primary")
        XCTAssertEqual(URLComponents(url: imageURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "api_key" })?.value, "secret token")

        let playbackURL = try XCTUnwrap(client.playbackURL(itemID: "item-1"))
        XCTAssertEqual(playbackURL.path, "/base/videos/item-1/stream")
        XCTAssertEqual(URLComponents(url: playbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "static" })?.value, "true")
    }

    func testBuildsCatalogShelfFromServerLibrary() throws {
        let client = try JellyfinClient(
            serverURL: "https://media.example.test",
            accessToken: "token",
            deviceID: "device-1"
        )

        let catalog = MediaCatalog(
            root: MediaItem(id: "movies", name: "Movies", type: "CollectionFolder",
                overview: nil, productionYear: nil, primaryImageAspectRatio: nil, childCount: 1),
            items: [MediaItem(id: "movie", name: "Movie", type: "Movie",
                overview: nil, productionYear: 2026, primaryImageAspectRatio: 0.667, childCount: nil)]
        )
        XCTAssertEqual(catalog.title, "Movies")
        XCTAssertEqual(catalog.items.first?.name, "Movie")
        XCTAssertNotNil(client.playbackURL(itemID: "movie"))
    }

    func testSearchResultDecodesAddonMoviesAndSeries() throws {
        let data = Data(#"{"Items":[{"Id":"addon-movie","Name":"Addon Movie","Type":"Movie","Overview":"Metadata provider result"},{"Id":"addon-series","Name":"Addon Series","Type":"Series","ChildCount":3}]}"#.utf8)
        let response = try JSONDecoder().decode(JellyfinItemsResponse.self, from: data)

        XCTAssertTrue(response.items[0].isPlayable)
        XCTAssertTrue(response.items[1].isFolder)
        XCTAssertEqual(response.items[0].overview, "Metadata provider result")
    }

    func testDecodesAuthenticationResponse() throws {
        let data = Data(#"{"User":{"Id":"user-1","Name":"viewer"},"AccessToken":"token-1"}"#.utf8)
        let response = try JSONDecoder().decode(JellyfinAuthenticationResponse.self, from: data)

        XCTAssertEqual(response.user.id, "user-1")
        XCTAssertEqual(response.user.name, "viewer")
        XCTAssertEqual(response.accessToken, "token-1")
    }

    func testDecodesRankedStreamNZBPlaybackSources() throws {
        let data = Data(#"{"MediaSources":[{"Id":"source-1","Name":"StreamNZB\nMovie\nMovie.2026.2160p.REMUX\n🔍 NZBgeek • 🎯 Score: +68648","Path":"/remux/source-1/Movie","Container":"mkv","Size":21015541816,"Remux":{"ProviderInfo":{"source":"StreamNZB","filename":"🎯 SCORE +68648 🎯 • Movie.2026.2160p.REMUX","description":"Movie\nMovie.2026.2160p.REMUX\n🔍 NZBgeek • 🎯 Score: +68648"}}}]}"#.utf8)

        let response = try JSONDecoder().decode(MediaPlaybackInfo.self, from: data)
        let source = try XCTUnwrap(response.mediaSources.first)

        XCTAssertEqual(source.provider, "StreamNZB")
        XCTAssertEqual(source.releaseName, "Movie.2026.2160p.REMUX")
        XCTAssertEqual(source.score, 68648)
        XCTAssertEqual(source.quality, "4K")
        XCTAssertNotNil(source.formattedSize)
    }

    func testSelectedPlaybackURLCarriesMediaSourceID() throws {
        let client = try JellyfinClient(
            serverURL: "https://media.example.test",
            accessToken: "token",
            deviceID: "device-1"
        )

        let url = try XCTUnwrap(client.playbackURL(itemID: "movie-1", mediaSourceID: "ranked-source-2"))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "MediaSourceId" })?.value, "ranked-source-2")
        XCTAssertEqual(query?.first(where: { $0.name == "api_key" })?.value, "token")
    }
}
