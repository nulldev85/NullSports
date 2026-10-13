import XCTest
@testable import LineupiOS

/// Emby through the Jellyfin client, and Plex through its own: where each is
/// asked, and how Plex's answers become the Library's items.
final class PlexEmbyTests: XCTestCase {
    func testEmbyIsAskedUnderItsOwnPrefixAndJellyfinIsNot() throws {
        let emby = try JellyfinClient(serverURL: "emby.local:8096", accessToken: "token", deviceID: "device",
                                      software: .emby)
        XCTAssertEqual(emby.imageURL(itemID: "42", maxWidth: 300)?.path, "/emby/items/42/images/primary")
        XCTAssertEqual(emby.playbackURL(itemID: "42", mediaSourceID: "source")?.path, "/emby/videos/42/stream")
        let jellyfin = try JellyfinClient(serverURL: "jellyfin.local:8096", accessToken: "token", deviceID: "device")
        XCTAssertEqual(jellyfin.imageURL(itemID: "42", maxWidth: 300)?.path, "/items/42/images/primary")
    }

    func testAServerSavedBeforeEmbyAndPlexReadsAsJellyfin() throws {
        let saved = """
        {"id":"7B2B3B66-6B61-4B2C-9C2A-0B9E7A1C2D3E","name":"Home","serverURL":"http://home:8096",
         "username":"me","userID":"u1"}
        """
        let profile = try JSONDecoder().decode(MediaServerProfile.self, from: Data(saved.utf8))
        XCTAssertEqual(profile.brand, .jellyfin)
        let plex = MediaServerProfile(name: "Plex", serverURL: "http://plex:32400", username: "me",
                                      userID: "machine", software: .plex)
        let again = try JSONDecoder().decode(MediaServerProfile.self, from: JSONEncoder().encode(plex))
        XCTAssertEqual(again.brand, .plex)
    }

    private func metadata(_ json: String) throws -> [PlexMetadata] {
        try JSONDecoder().decode(PlexResponse.self, from: Data(json.utf8)).mediaContainer.metadata
    }

    func testAPlexFilmBecomesALibraryFilm() throws {
        let json = """
        {"MediaContainer":{"size":1,"Metadata":[{"ratingKey":"1201","type":"movie","title":"Dune: Part Two",
          "summary":"Paul unites with the Fremen.","year":2024,"thumb":"/library/metadata/1201/thumb/1",
          "art":"/library/metadata/1201/art/1","duration":9960000,"viewOffset":4980000,"contentRating":"gb/12A",
          "audienceRating":9.0,"rating":9.2,"ratingImage":"rottentomatoes://image.rating.ripe",
          "Genre":[{"id":1,"tag":"Science Fiction"}],"Role":[{"tag":"Timothée Chalamet","role":"Paul",
            "thumb":"https://metadata-static.plex.tv/people/5d7768.jpg"}],
          "Director":[{"tag":"Denis Villeneuve"}],
          "Guid":[{"id":"imdb://tt15239678"},{"id":"tmdb://693134"},{"id":"tvdb://1"}],
          "Image":[{"type":"clearLogo","url":"/library/metadata/1201/clearLogo/1"}],
          "Media":[{"bitrate":24000,"container":"mkv","videoCodec":"hevc","videoResolution":"4k",
            "videoDynamicRange":"HDR10","audioCodec":"truehd","audioChannels":8,
            "Part":[{"id":9,"key":"/library/parts/9/1700000000/file.mkv","file":"/media/Dune.Part.Two.mkv",
              "size":28000000000,"container":"mkv"}]}]}]}}
        """
        let item = PlexClient.mediaItem(try XCTUnwrap(metadata(json).first))
        XCTAssertEqual(item.id, "1201")
        XCTAssertEqual(item.type, "Movie")
        XCTAssertEqual(item.productionYear, 2024)
        XCTAssertEqual(item.runtimeMinutes, 166)
        XCTAssertEqual(item.genres, ["Science Fiction"])
        XCTAssertEqual(item.criticRating, 92)
        XCTAssertEqual(item.communityRating, 9.0)
        XCTAssertEqual(item.providerIDs, ["Imdb": "tt15239678", "Tmdb": "693134", "Tvdb": "1"])
        XCTAssertTrue(item.hasBackdrop)
        XCTAssertTrue(item.hasLogo)
        XCTAssertEqual(try XCTUnwrap(item.userData?.playedPercentage), 50, accuracy: 0.01)
        XCTAssertEqual(item.people?.map(\.name), ["Timothée Chalamet", "Denis Villeneuve"])
        XCTAssertEqual(item.officialRating, "12A")
        // The title's own art paths are kept, and are what Plex is asked for.
        XCTAssertEqual(item.imageTags?["Primary"], "/library/metadata/1201/thumb/1")
        XCTAssertEqual(item.imageTags?["Logo"], "/library/metadata/1201/clearLogo/1")
        XCTAssertEqual(item.backdropImageTags, ["/library/metadata/1201/art/1"])
        let client = try PlexClient(serverURL: "http://plex.local:32400", token: "secret", clientID: "device")
        XCTAssertEqual(query(of: client.artworkURL(for: item, type: "primary", maxWidth: 300))["url"],
                       "/library/metadata/1201/thumb/1")
        XCTAssertEqual(query(of: client.artworkURL(for: item, type: "backdrop", maxWidth: 1280))["url"],
                       "/library/metadata/1201/art/1")
        // A logo is fitted inside its box, never stretched to fill it, and
        // stays a PNG so its edges stay clear.
        let logo = query(of: client.artworkURL(for: item, type: "logo", maxWidth: 800))
        XCTAssertEqual(logo["url"], "/library/metadata/1201/clearLogo/1")
        XCTAssertEqual(logo["format"], "png")
        XCTAssertNil(logo["minSize"])
        // A cast photo is Plex's own address for it, asked for as it is.
        let actor = try XCTUnwrap(item.people?.first)
        XCTAssertEqual(actor.primaryImageTag, "plex")
        XCTAssertEqual(client.imageURL(itemID: try XCTUnwrap(actor.personID), type: "primary", maxWidth: 300),
                       URL(string: "https://metadata-static.plex.tv/people/5d7768.jpg"))
        XCTAssertNil(item.people?.last?.primaryImageTag)
        let media = try XCTUnwrap(metadata(json).first?.media?.first)
        XCTAssertEqual(PlexClient.describe(media), "4K · HEVC · HDR10 · TRUEHD 7.1")
    }

    func testAPlexEpisodeKnowsItsShowAndPlace() throws {
        let json = """
        {"MediaContainer":{"Metadata":[{"ratingKey":"501","type":"episode","title":"Pilot","index":1,
          "parentIndex":1,"grandparentTitle":"Severance","grandparentRatingKey":"400","viewCount":1,
          "originallyAvailableAt":"2022-02-18","thumb":"/library/metadata/501/thumb/9",
          "grandparentThumb":"/library/metadata/400/thumb/3","grandparentArt":"/library/metadata/400/art/3"},
          {"ratingKey":"400","type":"show","title":"Severance","childCount":2,"leafCount":19,
           "viewedLeafCount":19},
          {"ratingKey":"77","type":"collection","title":"Marvel","childCount":30}]}}
        """
        let items = try metadata(json).map(PlexClient.mediaItem)
        XCTAssertEqual(items[0].type, "Episode")
        XCTAssertEqual(items[0].seriesID, "400")
        XCTAssertEqual(items[0].seriesName, "Severance")
        XCTAssertEqual(items[0].parentIndexNumber, 1)
        XCTAssertEqual(items[0].productionYear, 2022)
        XCTAssertTrue(items[0].isPlayed)
        // An episode's still is its own; its background and its poster in a
        // row of posters are its show's.
        XCTAssertEqual(items[0].imageTags?["Primary"], "/library/metadata/501/thumb/9")
        XCTAssertEqual(items[0].backdropImageTags, ["/library/metadata/400/art/3"])
        let client = try PlexClient(serverURL: "http://plex.local:32400", token: "secret", clientID: "device")
        let poster = query(of: client.seriesPosterURL(for: items[0], maxWidth: 300))
        XCTAssertEqual(poster["url"], "/library/metadata/400/thumb/3")
        XCTAssertEqual(poster["height"], "450")
        XCTAssertEqual(query(of: client.artworkURL(for: items[0], type: "primary", maxWidth: 320))["height"], "180")
        XCTAssertEqual(items[1].type, "Series")
        XCTAssertTrue(items[1].isPlayed)
        XCTAssertEqual(items[2].type, "BoxSet")
        XCTAssertEqual(items[2].id, "plex-collection:77")
    }

    func testPlexArtworkIsResizedByTheServerAndStreamsReadStraightFromTheFile() throws {
        let client = try PlexClient(serverURL: "http://plex.local:32400", token: "secret", clientID: "device")
        let poster = try XCTUnwrap(client.imageURL(itemID: "1201", type: "primary", maxWidth: 300))
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: poster, resolvingAgainstBaseURL: false)?
            .queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(poster.path, "/photo/:/transcode")
        XCTAssertEqual(query["url"], "/library/metadata/1201/thumb")
        XCTAssertEqual(query["width"], "300")
        XCTAssertEqual(query["X-Plex-Token"], "secret")
        let collection = try XCTUnwrap(client.imageURL(itemID: "plex-collection:77", type: "backdrop", maxWidth: 1280))
        XCTAssertTrue(collection.absoluteString.contains("%2Flibrary%2Fmetadata%2F77%2Fart")
                      || collection.absoluteString.contains("/library/metadata/77/art"))
        XCTAssertNil(client.imageURL(itemID: "plex-section:1", type: "primary", maxWidth: 300))
        let stream = try XCTUnwrap(client.playbackURL(itemID: "1201", mediaSourceID: "/library/parts/9/1700000000/file.mkv"))
        XCTAssertEqual(stream.path, "/library/parts/9/1700000000/file.mkv")
        XCTAssertTrue(stream.absoluteString.contains("X-Plex-Token=secret"))
    }

    func testAPlexServerShowsTheAddressItsCertificateNameSpells() {
        let plex = MediaServerProfile(name: "Basement", serverURL: "https://192-168-1-50.abc123.plex.direct:32400",
                                      username: "me", userID: "abc", software: .plex)
        XCTAssertEqual(plex.displayHost, "192.168.1.50")
        let relay = MediaServerProfile(name: "Basement", serverURL: "https://relay-1.abc123.plex.direct:8443",
                                       username: "me", userID: "abc", software: .plex)
        XCTAssertEqual(relay.displayHost, "relay-1.abc123.plex.direct")
        let jellyfin = MediaServerProfile(name: "Home", serverURL: "http://jellyfin.local:8096",
                                          username: "me", userID: "u1")
        XCTAssertEqual(jellyfin.displayHost, "jellyfin.local")
    }

    private func query(of url: URL?) -> [String: String] {
        guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    func testAPlexServerIsTriedNearestFirstAndItsRelayLast() throws {
        let json = """
        {"name":"Basement","clientIdentifier":"abc","accessToken":"t","owned":true,"provides":"server",
         "connections":[{"uri":"https://relay.plex.direct:8443","local":false,"relay":true},
                        {"uri":"https://1-2-3-4.abc.plex.direct:32400","local":false,"relay":false},
                        {"uri":"https://192-168-1-50.abc.plex.direct:32400","local":true,"relay":false}]}
        """
        let server = try JSONDecoder().decode(PlexAccount.Server.self, from: Data(json.utf8))
        XCTAssertEqual(server.addressesToTry.map(\.host), ["192-168-1-50.abc.plex.direct",
                                                          "1-2-3-4.abc.plex.direct", "relay.plex.direct"])
    }
}
