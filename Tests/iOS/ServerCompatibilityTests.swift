import XCTest
#if os(tvOS)
@testable import Lineup
#else
@testable import LineupiOS
#endif

final class ServerCompatibilityTests: XCTestCase {
    func testRequiredGenreCatalogUsesItsAdvertisedAllValueOrFirstAvailableGenre() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompatibilityProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); CompatibilityProtocol.install(nil) }
        let client = try JellyfinClient(serverURL: "https://example.test/jellyfin",
            accessToken: "test-token", deviceID: "test-device", session: session)
        let root = try JSONDecoder().decode(MediaItem.self, from: Data(#"""
        {"Id":"catalog-1","Name":"Popular","Type":"CollectionFolder","aiostreams":{"genreRequired":true}}
        """#.utf8))
        for hasAll in [true, false] {
            CompatibilityProtocol.install { request in
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                XCTAssertEqual(query.first { $0.name == "ParentId" }?.value, "catalog-1")
                if request.url?.path.hasSuffix("/genres") == true {
                    return hasAll
                        ? #"{"Items":[{"Id":"action","Name":"Action","Type":"Genre"},{"Id":"none","Name":"None","Type":"Genre"}]}"#
                        : #"{"Items":[{"Id":"action","Name":"Action","Type":"Genre"}]}"#
                }
                XCTAssertEqual(query.first { $0.name == "GenreIds" }?.value, hasAll ? "none" : "action")
                return #"{"Items":[{"Id":"movie-1","Name":"Movie","Type":"Movie"}]}"#
            }
            let items = try await client.items(userID: "user-1", parent: root, sortBy: "SortName", limit: 40)
            XCTAssertEqual(items.map(\.id), ["movie-1"])
        }
    }

    func testActualClientKeepsBrowsingLazyAndRequestsFreshVersionsOnlyAtPlay() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompatibilityProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); CompatibilityProtocol.install(nil) }
        let client = try JellyfinClient(serverURL: "https://example.test/jellyfin/u/test-alias",
            accessToken: "test-token", deviceID: "test-device", session: session)
        CompatibilityProtocol.install { request in
            XCTAssertEqual(request.url?.path, "/jellyfin/u/test-alias/users/user-1/items")
            let fields = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "Fields" }?.value ?? ""
            XCTAssertFalse(fields.contains("MediaSources"), "Opening a page must not run the stream addons")
            return #"{"Items":[{"Id":"item-1","Name":"Movie","Type":"Movie"}]}"#
        }
        let items = try await client.items(userID: "user-1", ids: ["item-1"])
        XCTAssertEqual(items.first?.name, "Movie")
        CompatibilityProtocol.install { request in
            XCTAssertEqual(request.url?.path, "/jellyfin/u/test-alias/users/user-1/items/item-1")
            XCTAssertEqual(request.httpMethod, "GET")
            let value = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "Fields" }?.value
            // Nullfin defaults a missing Fields query to resolving streams.
            // Make that expensive branch fail: details must work without it.
            guard let value, !value.split(separator: ",").contains("MediaSources") else {
                XCTFail("Opening details must not require stream addons or their probes")
                throw URLError(.timedOut)
            }
            let fields = Set(value.split(separator: ",").map(String.init))
            XCTAssertTrue(fields.isSuperset(of: ["People", "ProviderIds", "RunTimeTicks",
                                                 "Genres", "RemoteTrailers", "Overview"]))
            return #"""
            {"Id":"item-1","Name":"Movie","Type":"Movie",
             "Overview":"Full details without stream resolution","RunTimeTicks":72000000000,
             "Genres":["Comedy"],"ProviderIds":{"Tmdb":"603","Imdb":"tt0133093"},
             "People":[{"Id":"person-1","Name":"Actor","Type":"Actor","PrimaryImageTag":"portrait"}],
             "RemoteTrailers":[{"Name":"Trailer","Url":"https://example.test/trailer"}],
             "ImageTags":{"Primary":"poster","Logo":"title-logo"},
             "UserData":{"Played":false,"IsFavorite":true,"PlayedPercentage":50}}
            """#
        }
        let detail = try await client.item(userID: "user-1", itemID: "item-1")
        XCTAssertEqual(detail.id, "item-1")
        XCTAssertEqual(detail.overview, "Full details without stream resolution")
        XCTAssertEqual(detail.runtimeMinutes, 120)
        XCTAssertEqual(detail.genres, ["Comedy"])
        XCTAssertEqual(detail.people?.first?.primaryImageTag, "portrait")
        XCTAssertEqual(detail.providerIDs?["Tmdb"], "603")
        XCTAssertEqual(detail.remoteTrailers?.first?.name, "Trailer")
        XCTAssertEqual(detail.imageTags?["Logo"], "title-logo")
        XCTAssertEqual(detail.userData?.isFavorite, true)
        XCTAssertEqual(detail.userData?.playedPercentage, 50)
        // The same client's Play request still resolves fresh versions and
        // retains the exact version/snapshot needed for reliable playback.
        CompatibilityProtocol.install { request in
            XCTAssertEqual(request.url?.path, "/jellyfin/u/test-alias/items/item-1/playbackinfo")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: CompatibilityProtocol.body(request)) as? [String: Any])
            XCTAssertEqual(body["Fresh"] as? Bool, true)
            XCTAssertNil(body["Refresh"])
            XCTAssertNil(body["EnableRequiredHttpHeaders"])
            return #"{"MediaSources":[{"Id":"item-1","aiostreams":{"id":"version-a","description":"Exact release"}}],"PlaySessionId":"snapshot-1"}"#
        }
        let response = try await client.playbackInfo(itemID: "item-1", options: MediaPlaybackRequest(fresh: true))
        XCTAssertEqual(response.mediaSources.first?.selectionID, "version-a")
        XCTAssertEqual(response.playSessionID, "snapshot-1")
    }

    // Contract fixtures follow AIOStreams v2.36.0 (ce624445): media.ts,
    // playback.ts and the documented Jellyfin extensions. No real credentials.
    func testVersionIdentityDescriptionsAndServerOrderSurviveItemIDReuse() throws {
        let info = try JSONDecoder().decode(MediaPlaybackInfo.self, from: Data(#"""
        {"PlaySessionId":"snapshot-1","MediaSources":[
          {"Id":"item-1","Name":"Fallback label","Size":"21015541816","Bitrate":12345678,
           "aiostreams":{"id":"version-a","name":"4K","description":"Release A\nHEVC HDR","bingeGroup":"group-a"}},
          {"Id":"version-b","Name":"score: +9999","aiostreams":{"id":"version-b","description":"Release B"}},
          {"Name":"No identity"},
          {"Id":"notice","Name":"No streams found","Type":"Placeholder"},
          {"Id":"version-c","Name":"Usable","Size":{},"Bitrate":[],"aiostreams":"odd extension"}
        ]}
        """#.utf8))
        XCTAssertEqual(info.playSessionID, "snapshot-1")
        XCTAssertEqual(info.mediaSources.count, 4)
        XCTAssertEqual(info.mediaSources[0].selectionID, "version-a")
        XCTAssertEqual(info.mediaSources[0].displayLines, ["4K", "Release A", "HEVC HDR"])
        XCTAssertEqual(info.mediaSources[0].size, 21015541816)
        XCTAssertEqual(info.mediaSources[0].bitrate, 12345678)
        XCTAssertEqual(info.mediaSources[0].aiostreams?.bingeGroup, "group-a")
        XCTAssertEqual(MediaPlaybackSource.ranked(info.mediaSources.filter { !$0.isPlaceholder }).map(\.selectionID), ["version-a", "version-b", "version-c"])
        XCTAssertTrue(info.mediaSources[2].isPlaceholder)
        XCTAssertNil(info.mediaSources[3].bitrate)
    }

    func testAIOPlaybackKeepsPersonalBasePathVersionAndSnapshot() throws {
        let client = try JellyfinClient(serverURL: "https://example.test/jellyfin/u/test-alias/",
            accessToken: "test-token", deviceID: "test-device")
        let url = try XCTUnwrap(client.playbackURL(itemID: "item-1", mediaSourceID: "version-a", playSessionID: "snapshot-1"))
        XCTAssertEqual(url.path, "/jellyfin/u/test-alias/videos/item-1/stream")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "MediaSourceId" }?.value, "version-a")
        XCTAssertEqual(query.first { $0.name == "PlaySessionId" }?.value, "snapshot-1")
        XCTAssertEqual(query.first { $0.name == "api_key" }?.value, "test-token")
        XCTAssertEqual(MediaPlaybackRequest(fresh: true).body["Fresh"] as? Bool, true)
        XCTAssertNil(MediaPlaybackRequest().body["Fresh"], "Plain Jellyfin/Emby do not opt into extensions")
        XCTAssertNil(MediaPlaybackRequest(fresh: true).body["EnableRequiredHttpHeaders"])
    }

    func testFeatureFlagsAreReadIndividuallyAndUnknownFlagsAreIgnored() throws {
        let info = try JSONDecoder().decode(MediaServerPublicInfo.self, from: Data(#"""
        {"ServerName":"Example","aiostreams":{"features":{"versions":1,"refreshVersions":0,"futureFeature":9}}}
        """#.utf8))
        XCTAssertEqual(info.kind, .aiostreams)
        XCTAssertEqual(info.aiostreams?.supports("versions"), true)
        XCTAssertEqual(info.aiostreams?.supports("refreshVersions"), false)
        XCTAssertEqual(info.aiostreams?.supports("absentFeature"), false)
    }

    func testMalformedOptionalMetadataRetainsIdentityEpisodeCoordinatesAndProviderIDs() throws {
        let item = try JSONDecoder().decode(MediaItem.self, from: Data(#"""
        {"Id":"episode-3","Name":"Episode Three","Type":"Episode","SeriesId":"show-1",
         "ParentIndexNumber":"2","IndexNumber":"3","ProductionYear":"2026",
         "RunTimeTicks":"26000000000","CommunityRating":{},"CriticRating":"84",
         "ProviderIds":{"Tmdb":12345,"Tvdb":"67890","Odd":{}},"Genres":{},
         "People":false,"ImageTags":{"Primary":"portrait"},
         "UserData":{"Played":false,"PlaybackPositionTicks":10000000}}
        """#.utf8))
        XCTAssertEqual(item.id, "episode-3")
        XCTAssertEqual(item.episodeCode, "S02E03")
        XCTAssertEqual(item.seriesID, "show-1")
        XCTAssertEqual(item.runTimeTicks, 26000000000)
        XCTAssertEqual(item.criticRating, 84)
        XCTAssertNil(item.communityRating)
        XCTAssertEqual(item.providerIDs?["Tmdb"], "12345")
        XCTAssertEqual(item.providerIDs?["Tvdb"], "67890")
        XCTAssertEqual(item.imageTags?["Primary"], "portrait")
        XCTAssertEqual(item.userData?.played, false)
        let restored = try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(restored, item, "Raw server snapshots remain reversible when metadata sources change")
    }

    func testExtremeNumericMetadataDoesNotTrapOrInventEpisodeNumbers() throws {
        let item = try JSONDecoder().decode(MediaItem.self, from: Data(#"""
        {"Id":"episode","Name":"Episode","Type":"Episode","IndexNumber":1e100,"ProductionYear":1e100}
        """#.utf8))
        XCTAssertNil(item.indexNumber)
        XCTAssertNil(item.productionYear)
        let fractional = try JSONDecoder().decode(MediaItem.self, from: Data(#"""
        {"Id":"episode","Name":"Episode","Type":"Episode","IndexNumber":1.9,"ParentIndexNumber":"2.5"}
        """#.utf8))
        XCTAssertNil(fractional.indexNumber)
        XCTAssertNil(fractional.parentIndexNumber)
    }
}

private final class CompatibilityProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> String)?
    static func install(_ value: ((URLRequest) throws -> String)?) {
        lock.lock(); defer { lock.unlock() }; handler = value
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
        do {
            let result = try handler?(request) ?? "{}"
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(result.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(), bytes = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { break }
            result.append(contentsOf: bytes.prefix(count))
        }
        return result
    }
}
