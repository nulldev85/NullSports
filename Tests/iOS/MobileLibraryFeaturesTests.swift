import SwiftUI
import UIKit
import XCTest
@testable import LineupiOS

final class MobileLibraryFeaturesTests: XCTestCase {
    private func title(_ id: String = "series", type: String = "Series", imdb: String? = "tt0944947", server: UUID? = nil,
                       season: Int? = nil, episode: Int? = nil) -> MediaItem {
        MediaItem(id: id, name: "Test title", type: type, overview: nil, productionYear: nil,
            primaryImageAspectRatio: nil, childCount: nil, indexNumber: episode, parentIndexNumber: season,
            providerIDs: imdb.map { ["Imdb": $0] }, serverID: server)
    }

    private func identity() throws -> MobileIntroIdentity {
        try XCTUnwrap(MobileIntroIdentity(series: title(), episode: title("ep", type: "Episode", imdb: "tt1480055", season: 1, episode: 1)))
    }

    private var accepted: String {
        // Official /segments shape, including millisecond timestamps.
        #"{"imdb_id":"tt0944947","is_movie":false,"season":1,"episode":1,"intro":{"start_sec":437,"end_sec":531,"start_ms":437000,"end_ms":531000,"confidence":1,"submission_count":2},"recap":null,"outro":null}"#
    }

    func testIntroUsesSeriesIdentityAndExactNumbersInsteadOfEpisodeIMDb() throws {
        let identity = try identity()
        let url = try XCTUnwrap(URLComponents(url: identity.url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(url.host, "api.introdb.app")
        XCTAssertEqual(url.path, "/segments")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value ?? "") }),
                       ["imdb_id": "tt0944947", "season": "1", "episode": "1"])
        XCTAssertNil(MobileIntroIdentity(series: title(imdb: nil), episode: title("ep", type: "Episode", season: 1, episode: 1)))
        XCTAssertNil(MobileIntroIdentity(series: title(), episode: title("ep", type: "Episode", season: nil, episode: 1)))
        XCTAssertNil(MobileIntroIdentity(series: title(), episode: title("ep", type: "Episode", season: 1, episode: 0)))
        XCTAssertNil(MobileIntroIdentity(series: title(type: "Movie"), episode: title("ep", type: "Episode", season: 1, episode: 1)))
        let packed = try XCTUnwrap(AIOStreamsItemID.make(.episode, provider: "imdb", value: "tt0944947", season: 0, episode: 2))
        let special = try XCTUnwrap(MobileIntroIdentity(series: title(), episode: title(packed, type: "Episode")))
        XCTAssertEqual(special.season, 0)
        XCTAssertEqual(special.episode, 2)
    }

    func testIntroParsingRejectsMismatchedAndUnsafeRows() throws {
        let identity = try identity()
        let segment = try XCTUnwrap(MobileIntroSegment.decode(Data(accepted.utf8), identity: identity))
        XCTAssertEqual(segment, MobileIntroSegment(start: 437, end: 531))
        for (from, to) in [("tt0944947", "tt0903747"), ("\"episode\":1", "\"episode\":2"),
                           ("\"is_movie\":false", "\"is_movie\":true"), ("\"confidence\":1", "\"confidence\":0.2"),
                           ("\"submission_count\":2", "\"submission_count\":0"),
                           ("\"start_ms\":437000", "\"start_ms\":-1"),
                           ("\"end_ms\":531000", "\"end_ms\":9999999")] {
            XCTAssertNil(MobileIntroSegment.decode(Data(accepted.replacingOccurrences(of: from, with: to).utf8), identity: identity))
        }
        let secondsOnly = accepted.replacingOccurrences(of: "\"start_ms\":437000,\"end_ms\":531000,", with: "")
        XCTAssertEqual(MobileIntroSegment.decode(Data(secondsOnly.utf8), identity: identity), segment)
        XCTAssertNil(MobileIntroSegment.decode(Data("{}".utf8), identity: identity))
    }

    func testSkipOnlyOffersInsideIntroAndCannotFinishAnEpisode() {
        let segment = MobileIntroSegment(start: 30, end: 90)
        XCTAssertNil(segment.destination(at: 29.99, duration: 1200))
        XCTAssertEqual(segment.destination(at: 30, duration: 1200), 90)
        XCTAssertEqual(segment.destination(at: 89.9, duration: 1200), 90)
        XCTAssertNil(segment.destination(at: 90, duration: 1200))
        XCTAssertNil(segment.destination(at: 40, duration: 90))
        XCTAssertNil(segment.destination(at: 40, duration: 0))
        XCTAssertNil(segment.destination(at: .nan, duration: 1200))
        XCTAssertNil(segment.destination(at: 40, duration: .infinity))
        // Rewinding back into the intro may offer it again; no automatic seek.
        XCTAssertEqual(segment.destination(at: 45, duration: 1200), 90)
    }

    func testPublicIntroRequestsCoalesceAndCacheMissingSegmentsWithoutCredentials() async throws {
        let identity = try identity()
        let body = accepted
        IntroTestProtocol.install { request in
            XCTAssertEqual(request.url, identity.url)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-API-Key"))
            XCTAssertEqual(request.timeoutInterval, 5)
            return (200, [:], body)
        }
        let client = introClient()
        async let a = client.intro(for: identity)
        async let b = client.intro(for: identity)
        let (first, second) = await (a, b)
        XCTAssertEqual(first, second)
        XCTAssertNotNil(first)
        let cached = await client.intro(for: identity)
        XCTAssertEqual(cached, first)
        XCTAssertEqual(IntroTestProtocol.count, 1)
        IntroTestProtocol.install { _ in (200, [:], #"{"imdb_id":"tt0944947","is_movie":false,"season":1,"episode":1,"intro":null}"#) }
        let emptyClient = introClient()
        let empty = await emptyClient.intro(for: identity)
        let cachedEmpty = await emptyClient.intro(for: identity)
        XCTAssertNil(empty)
        XCTAssertNil(cachedEmpty)
        XCTAssertEqual(IntroTestProtocol.count, 1)
    }

    func testIntroRateLimitBacksOffAcrossEpisodes() async throws {
        IntroTestProtocol.install { _ in (429, ["Retry-After": "120"], "{}") }
        let client = introClient()
        let first = await client.intro(for: try identity())
        let secondID = try XCTUnwrap(MobileIntroIdentity(series: title(), episode: title("ep2", type: "Episode", season: 1, episode: 2)))
        let second = await client.intro(for: secondID)
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(IntroTestProtocol.count, 1)
    }

    func testBetterPostersUsesOfficialImagePatternsAndOnlyPortraitTitles() {
        XCTAssertTrue(MobileBetterPosters.validTemplate(MobileBetterPosters.defaultTemplate))
        let styled = "https://btttr.cc/poster-ra/imdb/poster-default/{imdb_id}.jpg?tag=none&lang=es&rs=imdb"
        XCTAssertTrue(MobileBetterPosters.validTemplate(styled))
        XCTAssertEqual(MobileBetterPosters.url(for: title(), template: styled)?.absoluteString,
                       "https://btttr.cc/poster-ra/imdb/poster-default/tt0944947.jpg?tag=none&lang=es&rs=imdb")
        for template in ["https://btttr.cc/manifest.json", "https://other.test/poster/imdb/poster-default/{imdb_id}.jpg",
                         "http://btttr.cc/poster/imdb/poster-default/{imdb_id}.jpg",
                         "https://user:secret@btttr.cc/poster/imdb/poster-default/{imdb_id}.jpg",
                         "https://btttr.cc/poster/imdb/poster-default/{imdb_id}.jpg?token=secret"] {
            XCTAssertFalse(MobileBetterPosters.validTemplate(template))
        }
        XCTAssertNil(MobileBetterPosters.url(for: title(imdb: nil), template: styled))
        XCTAssertNil(MobileBetterPosters.url(for: title(type: "Episode"), template: styled))
        XCTAssertNil(MobileBetterPosters.url(for: title(type: "BoxSet"), template: styled))
    }

    @MainActor
    func testPersonalCollectionsPersistSourceIdentityAndDoNotChangeWatchState() throws {
        let domain = "MobileLibraryFeaturesTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let media = MediaLibrary(defaults: defaults)
        let sourceA = title("same-id", server: UUID())
        let sourceB = title("same-id", server: UUID())
        XCTAssertNil(media.createCollection(named: "   "))
        let id = try XCTUnwrap(media.createCollection(named: "  Weekend TV  ", adding: sourceA))
        media.personalCollections[0].add(sourceA)
        media.personalCollections[0].add(sourceB)
        media.personalCollections[0].add(title("episode", type: "Episode"))
        XCTAssertEqual(media.personalCollections[0].items.map(\.libraryKey), [sourceA.libraryKey, sourceB.libraryKey])
        XCTAssertEqual(media.personalCollections[0].name, "Weekend TV")
        XCTAssertTrue(media.localPlayback.isEmpty)
        let restored = MediaLibrary(defaults: defaults)
        XCTAssertEqual(restored.personalCollections, media.personalCollections)
        XCTAssertEqual(restored.personalCollections[0].id, id)
        restored.personalCollections[0].name = "Renamed"
        restored.personalCollections[0].items.removeAll { $0.libraryKey == sourceA.libraryKey }
        XCTAssertEqual(MediaLibrary(defaults: defaults).personalCollections[0].items, [sourceB])
        restored.personalCollections.removeAll()
        XCTAssertTrue(MediaLibrary(defaults: defaults).personalCollections.isEmpty)
        XCTAssertTrue(restored.localPlayback.isEmpty)
    }

    @MainActor
    func testCollectionsMenuRoutesCurrentTitleAndPreferencesPersist() throws {
        let domain = "MobileLibraryMenuTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let media = MediaLibrary(defaults: defaults)
        let movie = title("movie", type: "Movie", server: UUID())
        let action = try XCTUnwrap(media.cardMenuItems(for: movie).first { $0.title == "Collections" })
        action.action()
        XCTAssertEqual(media.collectionSelectionItem, movie)
        XCTAssertNil(media.collectionMenu(for: title("ep", type: "Episode")))
        media.betterPostersEnabled = true
        media.introDBEnabled = false
        media.betterPostersTemplate = "https://btttr.cc/poster-r/imdb/poster-default/{imdb_id}.jpg?tag=none"
        let restored = MediaLibrary(defaults: defaults)
        XCTAssertTrue(restored.betterPostersEnabled)
        XCTAssertFalse(restored.introDBEnabled)
        XCTAssertEqual(restored.betterPostersTemplate, media.betterPostersTemplate)
        XCTAssertNotNil(restored.betterPosterURL(for: movie))
        restored.betterPostersEnabled = false
        XCTAssertNil(restored.betterPosterURL(for: movie))
    }

    private func introClient() -> MobileIntroDB {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IntroTestProtocol.self]
        return MobileIntroDB(session: URLSession(configuration: configuration))
    }

    override func tearDown() { IntroTestProtocol.install { _ in (500, [:], "{}") }; super.tearDown() }
}

private final class IntroTestProtocol: URLProtocol {
    typealias Handler = (URLRequest) -> (Int, [String: String], String)
    private static let lock = NSLock()
    private static var handler: Handler?
    private static var requests = 0
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    static func install(_ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }; self.handler = handler; requests = 0
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handler; Self.requests += 1; Self.lock.unlock()
        let (status, headers, body) = handler?(request) ?? (500, [:], "{}")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
