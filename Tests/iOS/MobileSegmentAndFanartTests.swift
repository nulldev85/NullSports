import SwiftUI
import XCTest
@testable import LineupiOS

final class MobileSegmentAndFanartTests: XCTestCase {
    func testIntroAndRecapAndCreditsShareTheExistingAnonymousRequest() async throws {
        let body = #"{"imdb_id":"tt0944947","is_movie":false,"season":1,"episode":2,"intro":{"start_sec":120,"end_sec":210,"confidence":1,"submission_count":2},"recap":{"start_sec":10,"end_sec":100,"confidence":1,"submission_count":2},"outro":{"start_sec":2300,"end_sec":2400,"confidence":1,"submission_count":2}}"#
        SegmentArtworkProtocol.install { request in
            XCTAssertEqual(request.url?.host, "api.introdb.app")
            XCTAssertEqual(request.url?.path, "/segments")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-API-Key"))
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.first { $0.name == "season" }?.value, "1")
            XCTAssertEqual(query.first { $0.name == "episode" }?.value, "2")
            return (200, [:], body)
        }
        let session = self.session()
        defer { session.invalidateAndCancel() }
        let client = MobileIntroDB(session: session)
        let identity = try XCTUnwrap(MobileSegmentIdentity(imdb: "tt0944947", season: 1, episode: 2))
        async let a = client.segments(for: identity)
        async let b = client.segments(for: identity)
        let (first, second) = await (a, b)
        let result = try XCTUnwrap(first)
        XCTAssertEqual(result, second)
        XCTAssertEqual(result.recap?.destination(at: 50, duration: 2400), 100)
        XCTAssertTrue(result.offersNext(at: 2300, duration: 2400, creditsEnabled: true))
        let cached = await client.segments(for: identity)
        XCTAssertEqual(cached, first)
        XCTAssertEqual(SegmentArtworkProtocol.count, 1, "New segment types must not multiply per-video API requests")
    }

    func testMovieRequestOmitsEpisodeCoordinatesAndPreservesPostCreditScenes() async throws {
        SegmentArtworkProtocol.install { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.first { $0.name == "is_movie" }?.value, "true")
            XCTAssertNil(query.first { $0.name == "season" })
            XCTAssertNil(query.first { $0.name == "episode" })
            return (200, [:], #"{"imdb_id":"tt0371746","is_movie":true,"season":0,"episode":0,"outro":{"start_sec":7140,"end_sec":7515,"confidence":1,"submission_count":2},"post_credits":{"start_sec":7515,"end_sec":7555,"confidence":1,"submission_count":2}}"#)
        }
        let session = self.session()
        defer { session.invalidateAndCancel() }
        let client = MobileIntroDB(session: session)
        let response = await client.segments(for: try XCTUnwrap(MobileSegmentIdentity(imdb: "tt0371746", isMovie: true)))
        let result = try XCTUnwrap(response)
        XCTAssertTrue(result.hasPostCreditsAhead(at: 7200, duration: 7560))
        XCTAssertFalse(result.hasPostCreditsAhead(at: 7520, duration: 7560))
        XCTAssertNil(result.intro)
        XCTAssertNil(result.recap)
    }

    func testFanartRequestsCoalesceAndCacheOnlyExactPublicLogoURLs() async throws {
        SegmentArtworkProtocol.install { request in
            XCTAssertEqual(request.url?.host, "webservice.fanart.tv")
            XCTAssertEqual(request.url?.path, "/v3.2/movies/603")
            XCTAssertEqual(request.timeoutInterval, 5)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.map(\.name), ["api_key"])
            XCTAssertEqual(query.first?.value, "fixture-project-key")
            return (200, [:], #"{"tmdb_id":"603","imdb_id":"tt0133093","hdmovielogo":[{"url":"https://assets.fanart.tv/fanart/movies/603/hdmovielogo/matrix.png","lang":"en","likes":"3","width":"800","height":"310"}]}"#)
        }
        let session = self.session()
        defer { session.invalidateAndCancel() }
        let client = MobileFanart(key: "fixture-project-key", session: session)
        let identity = try XCTUnwrap(MobileFanartIdentity(kind: .movie, id: "603"))
        async let a = client.logo(for: identity)
        async let b = client.logo(for: identity)
        let (first, second) = await (a, b)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first?.absoluteString, "https://assets.fanart.tv/fanart/movies/603/hdmovielogo/matrix.png")
        let cached = await client.logo(for: identity)
        XCTAssertEqual(cached, first)
        XCTAssertEqual(SegmentArtworkProtocol.count, 1)
        XCTAssertNil(first?.query, "The artwork loader must never receive the project key")
    }

    func testFanartMissingArtAndServiceLimitsBackOffInsteadOfBlockingBrowsing() async throws {
        let session = self.session()
        defer { session.invalidateAndCancel() }
        let movie = try XCTUnwrap(MobileFanartIdentity(kind: .movie, id: "603"))
        let show = try XCTUnwrap(MobileFanartIdentity(kind: .series, id: "121361"))
        SegmentArtworkProtocol.install { _ in (404, [:], "{}") }
        let missing = MobileFanart(key: "fixture-project-key", session: session)
        let first = await missing.logo(for: movie), cached = await missing.logo(for: movie)
        XCTAssertNil(first); XCTAssertNil(cached)
        XCTAssertEqual(SegmentArtworkProtocol.count, 1)
        for status in [429, 401, 403] {
            SegmentArtworkProtocol.install { _ in (status, ["Retry-After": "120"], "{}") }
            let limited = MobileFanart(key: "fixture-project-key", session: session)
            let a = await limited.logo(for: movie), b = await limited.logo(for: show)
            XCTAssertNil(a); XCTAssertNil(b)
            XCTAssertEqual(SegmentArtworkProtocol.count, 1, "Service-wide limits must not retry on every hero")
        }
        SegmentArtworkProtocol.install { _ in XCTFail("An unconfigured build must use text"); return (500, [:], "{}") }
        let unconfigured = MobileFanart(key: "", session: session)
        let absent = await unconfigured.logo(for: movie)
        XCTAssertNil(absent); XCTAssertEqual(SegmentArtworkProtocol.count, 0)
    }

    @MainActor
    func testTitleArtworkUsesCorrectExternalIDsAndNewSettingsPersistIndependently() throws {
        func item(_ type: String, ids: [String: String]) -> MediaItem {
            MediaItem(id: "server-local-603", name: "Title", type: type, overview: nil, productionYear: nil,
                primaryImageAspectRatio: nil, childCount: nil, providerIDs: ids)
        }
        XCTAssertEqual(MobileFanartTitle<Text>.identity(for: item("Movie", ids: ["Tmdb": "603", "Imdb": "tt0133093"]))?.id, "603")
        XCTAssertEqual(MobileFanartTitle<Text>.identity(for: item("Series", ids: ["Tmdb": "1399", "Tvdb": "121361"]))?.id, "121361")
        XCTAssertNil(MobileFanartTitle<Text>.identity(for: item("Series", ids: ["Imdb": "tt0944947"])))
        XCTAssertNil(MobileFanartTitle<Text>.identity(for: item("Episode", ids: ["Tvdb": "121361"])))
        let suite = "Lineup.segment-artwork-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let media = MediaLibrary(defaults: defaults)
        XCTAssertTrue(media.recapSkippingEnabled); XCTAssertTrue(media.creditsPromptEnabled)
        XCTAssertTrue(media.postCreditsNoticeEnabled); XCTAssertTrue(media.fanartEnabled)
        media.recapSkippingEnabled = false; media.creditsPromptEnabled = false
        media.postCreditsNoticeEnabled = false; media.fanartEnabled = false
        let restored = MediaLibrary(defaults: defaults)
        XCTAssertFalse(restored.recapSkippingEnabled); XCTAssertFalse(restored.creditsPromptEnabled)
        XCTAssertFalse(restored.postCreditsNoticeEnabled); XCTAssertFalse(restored.fanartEnabled)
        XCTAssertTrue(restored.introDBEnabled, "Each feature has its own setting")
        XCTAssertTrue(restored.localPlayback.isEmpty, "Artwork and timing settings do not mutate tracking")
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SegmentArtworkProtocol.self]
        return URLSession(configuration: config)
    }
    override func tearDown() { SegmentArtworkProtocol.install { _ in (500, [:], "{}") }; super.tearDown() }
}

private final class SegmentArtworkProtocol: URLProtocol, @unchecked Sendable {
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
