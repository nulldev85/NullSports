import XCTest
#if os(tvOS)
@testable import Lineup
#else
@testable import LineupiOS
#endif

final class LibraryMetadataTests: XCTestCase {
    private func item(_ name: String = "tt0133093", id: String = "server-film", type: String = "Movie",
                      ids: [String: String]? = nil, year: Int? = nil) -> MediaItem {
        MediaItem(id: id, name: name, type: type, overview: "Provider summary", productionYear: year,
                  primaryImageAspectRatio: nil, childCount: nil, providerIDs: ids, serverID: UUID())
    }

    private func resolver(cache: URL? = nil,
                          credentials: LibraryMetadataCredentials = .init(tmdb: "test-read-token", tvdb: "test-project-key")) -> LibraryMetadataResolver {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataTestProtocol.self]
        return LibraryMetadataResolver(credentials: credentials,
                                       session: URLSession(configuration: configuration), cacheURL: cache)
    }

    override func tearDown() {
        MetadataTestProtocol.reset()
        super.tearDown()
    }

    func testProviderJSONAndPlaybackHistoryRetainOriginalData() throws {
        let raw = MediaItem(id: "ep", name: "Provider name", type: "Episode", overview: "Provider summary",
            productionYear: 2024, primaryImageAspectRatio: nil, childCount: nil,
            runTimeTicks: 120_000_000_000, indexNumber: 2, parentIndexNumber: 2,
            seriesName: "Provider series", seriesID: "series", providerIDs: ["Imdb": "tt0133093"],
            posterURL: "https://provider.test/still.jpg", serverID: UUID())
        let overlay = LibraryMetadata(source: .tvdb, title: "Resolved episode", overview: "New summary",
            year: 2025, poster: "https://artworks.thetvdb.com/new.jpg", externalIDs: ["tvdb": "10"])
        let display = raw.withMetadata(overlay)
        XCTAssertEqual(display.name, "Resolved episode")
        XCTAssertEqual(display.libraryKey, raw.libraryKey)
        XCTAssertEqual(display.seriesID, raw.seriesID)
        XCTAssertEqual(display.indexNumber, 2)
        XCTAssertEqual(display.parentIndexNumber, 2)
        XCTAssertEqual(display.runTimeTicks, raw.runTimeTicks)
        XCTAssertEqual(display.withMetadata(nil), raw)
        let encoded = try JSONEncoder().encode(display)
        XCTAssertEqual(try JSONDecoder().decode(MediaItem.self, from: encoded), raw)
        let record = LocalMediaPlayback(profileID: raw.serverID!, item: display, position: 375,
            duration: 1200, updatedAt: Date(), completed: false)
        let restored = try JSONDecoder().decode(LocalMediaPlayback.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored.item, raw)
        XCTAssertEqual(restored.position, 375)
        XCTAssertEqual(restored.duration, 1200)
        XCTAssertFalse(restored.completed)
        let oldJSON = Data(#"{"Id":"old","Name":"Old movie","Type":"Movie"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(MediaItem.self, from: oldJSON).name, "Old movie")
    }

    func testOnlyExplicitExternalIDsAndValidatedPackedIDsAreRecognized() throws {
        XCTAssertEqual(LibraryMetadataIdentity.ids(item())["imdb"], "tt0133093")
        XCTAssertEqual(LibraryMetadataIdentity.ids(item("tmdb:603"))["tmdb"], "603")
        XCTAssertTrue(LibraryMetadataIdentity.ids(item("12345", id: "67890")).isEmpty)
        XCTAssertNil(LibraryMetadataIdentity.positiveID("tmdb", "0"))
        let packed = try XCTUnwrap(AIOStreamsItemID.make(.movie, provider: "imdb", value: "tt0133093"))
        let movie = item("tt0133093", id: packed)
        XCTAssertEqual(LibraryMetadataIdentity.packed(movie)?.value, "tt0133093")
        XCTAssertNil(LibraryMetadataIdentity.packed(item(id: packed, type: "Series")))
        XCTAssertNil(LibraryMetadataIdentity.packed(item(id: String(packed.dropLast()) + "1")))
        let episodeID = try XCTUnwrap(AIOStreamsItemID.make(.episode, provider: "tvdb", value: "73244", season: 0, episode: 1))
        let episode = item(id: episodeID, type: "Episode")
        XCTAssertEqual(LibraryMetadataIdentity.packed(episode)?.season, 0)
        XCTAssertEqual(LibraryMetadataIdentity.packed(episode)?.episode, 1)
        XCTAssertNil(LibraryMetadataIdentity.ids(episode)["tvdb"], "An encoded episode contains a series ID")
    }

    func testNameMatchingRejectsAmbiguousRemakesAndIDLikeNames() {
        struct Match { let title: String; let year: Int }
        let candidates = [Match(title: "The Thing", year: 1982), Match(title: "The Thing", year: 2011)]
        let match = LibraryMetadataIdentity.uniqueMatch(candidates, item: item("The Thing", year: 1982),
            title: { $0.title }, year: { $0.year })
        XCTAssertEqual(match?.year, 1982)
        XCTAssertNil(LibraryMetadataIdentity.uniqueMatch(candidates, item: item("The Thing"), title: { $0.title }, year: { $0.year }))
        XCTAssertNil(LibraryMetadataIdentity.searchableTitle(item("783482")))
        XCTAssertNil(LibraryMetadataIdentity.searchableTitle(item("tt0133093")))
        XCTAssertEqual(LibraryMetadataIdentity.searchableTitle(item("Bad")), "Bad")
    }

    func testTMDBResolvesIMDbInsteadOfSearchingForTheIDAsATitle() async throws {
        MetadataTestProtocol.install { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-read-token")
            switch request.url!.path {
            case "/3/find/tt0133093":
                XCTAssertTrue(request.url!.query!.contains("external_source=imdb_id"))
                return (200, #"{"movie_results":[{"id":603}],"tv_results":[]}"#)
            case "/3/movie/603":
                return (200, #"{"id":603,"title":"The Matrix","overview":"Resolved summary","release_date":"1999-03-31","poster_path":"/matrix.jpg","genres":[{"name":"Science Fiction"}],"external_ids":{"imdb_id":"tt0133093"}}"#)
            default: XCTFail("Unexpected metadata request"); return (404, "{}")
            }
        }
        let service = resolver()
        let raw = item()
        async let first = service.resolve(raw, source: .tmdb)
        async let second = service.resolve(raw, source: .tmdb)
        let (a, b) = await (first, second)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a?.title, "The Matrix")
        XCTAssertEqual(a?.year, 1999)
        XCTAssertEqual(a?.poster, "https://image.tmdb.org/t/p/w500/matrix.jpg")
        XCTAssertEqual(a?.genres, ["Science Fiction"])
        let cached = await service.resolve(raw, source: .tmdb)
        XCTAssertEqual(cached, a)
        XCTAssertEqual(MetadataTestProtocol.requestCount, 2, "Simultaneous and repeated lookups share their results")
    }

    func testTVDBEpisodeUsesParentSeriesAndExactAiredNumbers() async {
        MetadataTestProtocol.install { request in
            if request.url!.path == "/v4/login" {
                let body = try JSONSerialization.jsonObject(with: request.httpBody ?? request.metadataBody) as? [String: String]
                XCTAssertEqual(body, ["apikey": "test-project-key"], "Project keys do not send a subscriber PIN")
                return (200, #"{"data":{"token":"test-bearer"}}"#)
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-bearer")
            XCTAssertEqual(request.url!.path, "/v4/series/73244/episodes/official")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertTrue(query.contains(URLQueryItem(name: "season", value: "2")))
            XCTAssertTrue(query.contains(URLQueryItem(name: "episodeNumber", value: "2")))
            return (200, #"{"data":{"episodes":[{"id":900,"name":"Correct episode","seasonNumber":2,"number":2,"seriesId":73244,"image":"https://artworks.thetvdb.com/still.jpg"},{"id":901,"name":"Wrong order","seasonNumber":2,"number":10,"seriesId":73244}]}}"#)
        }
        let episode = MediaItem(id: "internal-ep", name: "Episode 2", type: "Episode", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil, indexNumber: 2,
            parentIndexNumber: 2, seriesID: "parent", providerIDs: ["Tvdb": "999999"])
        let parent = item("The Office", id: "parent", type: "Series", ids: ["Tvdb": "73244"])
        let result = await resolver().resolve(episode, source: .tvdb, parent: parent)
        XCTAssertEqual(result?.title, "Correct episode")
        XCTAssertEqual(result?.attributionURL, "https://www.thetvdb.com/dereferrer/episode/900")
        XCTAssertEqual(MetadataTestProtocol.requestCount, 2)
    }

    func testTVDB401RenewsTokenOnceAndMovieRecordDecodes() async {
        MetadataTestProtocol.install { request in
            if request.url!.path == "/v4/login" { return (200, #"{"data":{"token":"test-bearer"}}"#) }
            if MetadataTestProtocol.requestCount == 2 { return (401, "{}") }
            return (200, #"{"data":{"id":244,"name":"Movie title","first_release":{"date":"1999-03-31"},"remoteIds":[{"id":"tt0133093","sourceName":"IMDB"}]}}"#)
        }
        let result = await resolver().resolve(item("tvdb:244"), source: .tvdb)
        XCTAssertEqual(result?.title, "Movie title")
        XCTAssertEqual(result?.year, 1999)
        XCTAssertEqual(result?.externalIDs["imdb"], "tt0133093")
        XCTAssertEqual(MetadataTestProtocol.requestCount, 4)
    }

    func testFailuresUnmatchedEpisodesAndProviderChoiceKeepProviderData() async {
        MetadataTestProtocol.install { _ in (503, "{}") }
        let service = resolver()
        let raw = item()
        let failed = await service.resolve(raw, source: .tmdb)
        XCTAssertNil(failed)
        let fallback = raw.withMetadata(failed)
        XCTAssertEqual(fallback.name, "tt0133093")
        XCTAssertEqual(fallback.overview, "Provider summary")
        let provider = await service.resolve(raw, source: .provider)
        XCTAssertNil(provider)
        let noParent = await service.resolve(item(type: "Episode"), source: .tvdb)
        XCTAssertNil(noParent)
        XCTAssertEqual(MetadataTestProtocol.requestCount, 1)
    }

    func testTMDBEpisodeKeepsSeasonZeroAndRejectsTheWrongEpisode() async {
        MetadataTestProtocol.install { request in
            XCTAssertEqual(request.url!.path, "/3/tv/2316/season/0/episode/1")
            return (200, #"{"id":5,"name":"Another episode","season_number":0,"episode_number":2}"#)
        }
        let raw = MediaItem(id: "special", name: "Provider special", type: "Episode", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
            indexNumber: 1, parentIndexNumber: 0)
        let parent = item("The Office", type: "Series", ids: ["Tmdb": "2316"])
        let result = await resolver().resolve(raw, source: .tmdb, parent: parent)
        XCTAssertNil(result)
        XCTAssertEqual(MetadataTestProtocol.requestCount, 1)
    }

    func testTVDBDoesNotAcceptTheSameEpisodeNumbersFromAnotherSeries() async {
        MetadataTestProtocol.install { request in
            if request.url!.path == "/v4/login" { return (200, #"{"data":{"token":"test-bearer"}}"#) }
            return (200, #"{"data":{"episodes":[{"id":900,"name":"Wrong show","seasonNumber":2,"number":2,"seriesId":999}]}}"#)
        }
        let raw = MediaItem(id: "ep", name: "Provider episode", type: "Episode", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
            indexNumber: 2, parentIndexNumber: 2)
        let parent = item("The Office", type: "Series", ids: ["Tvdb": "73244"])
        let result = await resolver().resolve(raw, source: .tvdb, parent: parent)
        XCTAssertNil(result)
    }

    func testMissingCredentialsDoNotMakeNetworkRequests() async {
        MetadataTestProtocol.install { _ in XCTFail("No credential must mean no request"); return (500, "{}") }
        let service = resolver(credentials: .init(tmdb: "", tvdb: ""))
        let movie = await service.resolve(item(), source: .tmdb)
        let show = await service.resolve(item(type: "Series"), source: .tvdb)
        XCTAssertNil(movie)
        XCTAssertNil(show)
        XCTAssertEqual(MetadataTestProtocol.requestCount, 0)
    }

    func testRateLimitedServiceBacksOffAcrossDifferentItems() async {
        MetadataTestProtocol.install { _ in (429, "{}") }
        let service = resolver()
        let first = await service.resolve(item("tmdb:603"), source: .tmdb)
        let second = await service.resolve(item("tmdb:604", id: "another"), source: .tmdb)
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(MetadataTestProtocol.requestCount, 1)
    }

    @MainActor
    func testSettingsAreIndependentPersistAndRestoreProviderImmediately() async throws {
        let suite = "LibraryMetadataTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        MetadataTestProtocol.install { _ in (200, #"{"id":603,"title":"The Matrix"}"#) }
        let media = MediaLibrary(defaults: defaults, metadataCredentials: .init(tmdb: "test", tvdb: "test"), metadataResolver: resolver())
        XCTAssertEqual(media.metadataSource, .tmdb)
        XCTAssertEqual(media.episodeDataSource, .tvdb)
        media.setMetadataSource(.tmdb)
        media.setMetadataSource(.tvdb, episodes: true)
        let raw = item("tmdb:603")
        await media.resolveMetadata(for: raw)
        XCTAssertEqual(media.displayItem(raw).name, "The Matrix")
        media.setMetadataSource(.provider)
        XCTAssertEqual(media.displayItem(raw).name, "tmdb:603")
        XCTAssertEqual(media.episodeDataSource, .tvdb)
        let restored = MediaLibrary(defaults: defaults)
        XCTAssertEqual(restored.metadataSource, .provider)
        XCTAssertEqual(restored.episodeDataSource, .tvdb)
    }
}

private final class MetadataTestProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (Int, String)
    private static let lock = NSLock()
    private static var handler: Handler?
    private static var count = 0
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func install(_ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler; count = 0
    }
    static func reset() { lock.lock(); defer { lock.unlock() }; handler = nil; count = 0 }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        let handler = Self.handler
        Self.lock.unlock()
        do {
            let (status, body) = try handler?(request) ?? (500, "{}")
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private extension URLRequest {
    var metadataBody: Data {
        guard let stream = httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&bytes, maxLength: bytes.count)
            guard read > 0 else { break }
            data.append(contentsOf: bytes.prefix(read))
        }
        return data
    }
}
