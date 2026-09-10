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

    // Each test below passes the multi-line Name a Nullfin addon actually returns,
    // so the parsing is pinned to real payloads rather than to the tokens it seeks.
    private func source(name: String, container: String? = nil,
        size: Int64? = nil, bitrate: Int64? = nil) throws -> MediaPlaybackSource {
        var payload: [String: Any] = ["Id": "source-1", "Name": name]
        if let container { payload["Container"] = container }
        if let size { payload["Size"] = size }
        if let bitrate { payload["Bitrate"] = bitrate }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(MediaPlaybackSource.self, from: data)
    }

    func testReadsEveryStreamDetailFromAnAddonResult() throws {
        let stream = try source(name: """
            StreamNZB
            Reacher
            Reacher (2022) S04E04 (2160p AMZN WEB-DL Hybrid H265 DV HDR10+ DDP Atmos 5.1 English - HONE)
            hevc Main 10 2160p 10-bit HDR10 eac3
            \u{1F50D} StreamNZB Library - altHUB \u{2022} \u{1F3AF} Score: +70494
            """, container: "matroska", size: 62_700_000_000, bitrate: 24_400_000)

        XCTAssertEqual(stream.quality, "4K")
        XCTAssertEqual(stream.dynamicRangeTags, ["DV", "HDR10+"])
        XCTAssertEqual(stream.videoCodec, "H.265")
        XCTAssertEqual(stream.bitDepth, "10-bit")
        XCTAssertEqual(stream.audioCodec, "DD+")
        XCTAssertTrue(stream.hasAtmos)
        XCTAssertEqual(stream.audioChannels, "5.1")
        XCTAssertEqual(stream.sourceTag, "WEB-DL")
        XCTAssertEqual(stream.containerLabel, "MKV")
        XCTAssertEqual(stream.indexer, "altHUB")
        XCTAssertEqual(stream.score, 70494)
        XCTAssertEqual(stream.provider, "StreamNZB")
        XCTAssertEqual(stream.facts.count, 4)
        XCTAssertEqual(Array(stream.facts.dropFirst()), ["24 Mbps", "MKV", "altHUB"])
    }

    // "DDP5 1" and "H 265" lose their separators in some indexers and keep them in
    // others, and the release name outranks a probe line that reports the width.
    func testReadsDetailsWhenSeparatorsAreMissingOrTheProbeDisagrees() throws {
        let stream = try source(name: """
            StreamNZB
            Reacher
            Reacher S04E04 Karambits and Pieces 2160p AMZN WEB-DL DDP5 1 Atmos DV HDR10Plus H 265-Kitsune
            hevc Main 10 1920p 10-bit HDR10 eac3
            \u{1F50D} StreamNZB Library - NinjaCentral \u{2022} \u{1F3AF} Score: +70173
            """)

        XCTAssertEqual(stream.quality, "4K")
        XCTAssertEqual(stream.dynamicRangeTags, ["DV", "HDR10+"])
        XCTAssertEqual(stream.videoCodec, "H.265")
        XCTAssertEqual(stream.audioChannels, "5.1")
        XCTAssertEqual(stream.indexer, "NinjaCentral")
    }

    // A result with no probe line still has to yield its badges, and an indexer
    // that only repeats the addon name is not worth a second mention.
    func testReadsDottedReleaseNamesAndDropsARedundantIndexer() throws {
        let stream = try source(name: """
            StreamNZB
            Reacher
            Reacher.S04E04.Karambits.and.Pieces.2160p.AMZN.WEB-DL.DDP5.1.Atmos.DoVi.HDR.H.265-playWEB
            \u{1F50D} NZBgeek \u{2022} \u{1F3AF} Score: +69263
            """)

        XCTAssertEqual(stream.dynamicRangeTags, ["DV", "HDR"])
        XCTAssertEqual(stream.videoCodec, "H.265")
        XCTAssertEqual(stream.audioChannels, "5.1")
        XCTAssertEqual(stream.indexer, "NZBgeek")

        let sameName = try source(name: "StreamNZB\nReacher\nRelease\n\u{1F50D} StreamNZB \u{2022} \u{1F3AF} Score: +1")
        XCTAssertNil(sameName.indexer)
    }

    // A year, an episode number and a score are all digits either side of a
    // separator, and none of them describe a surround layout.
    func testPlainReleaseReportsNoDynamicRangeAndNoInventedChannels() throws {
        let stream = try source(name: """
            AIOStreams
            Movie
            Movie (2022) 1080p BluRay x264 AAC
            \u{1F50D} AIOStreams \u{2022} \u{1F3AF} Score: +2075
            """, container: "quicktime")

        XCTAssertEqual(stream.quality, "1080p")
        XCTAssertTrue(stream.dynamicRangeTags.isEmpty)
        XCTAssertEqual(stream.videoCodec, "H.264")
        XCTAssertEqual(stream.audioCodec, "AAC")
        XCTAssertFalse(stream.hasAtmos)
        XCTAssertNil(stream.audioChannels)
        XCTAssertEqual(stream.sourceTag, "BluRay")
        XCTAssertEqual(stream.containerLabel, "MP4")
        XCTAssertEqual(stream.badges, ["H.264", "AAC", "BluRay"])
    }

    func testBitrateReadsInMbpsAndIsOmittedWhenTheServerReportsNone() throws {
        XCTAssertEqual(try source(name: "A", bitrate: 24_400_000).formattedBitrate, "24 Mbps")
        XCTAssertEqual(try source(name: "A", bitrate: 7_400_000).formattedBitrate, "7.4 Mbps")
        XCTAssertNil(try source(name: "A", bitrate: 0).formattedBitrate)
        XCTAssertNil(try source(name: "A").formattedBitrate)
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
