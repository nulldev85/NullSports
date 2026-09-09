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

    func testDecodesAuthenticationResponse() throws {
        let data = Data(#"{"User":{"Id":"user-1","Name":"viewer"},"AccessToken":"token-1"}"#.utf8)
        let response = try JSONDecoder().decode(JellyfinAuthenticationResponse.self, from: data)

        XCTAssertEqual(response.user.id, "user-1")
        XCTAssertEqual(response.user.name, "viewer")
        XCTAssertEqual(response.accessToken, "token-1")
    }
}
