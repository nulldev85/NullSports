import SwiftUI
import UIKit
import XCTest
import Combine
#if os(tvOS)
@testable import Lineup
#else
@testable import LineupiOS
#endif

@MainActor
final class TitleArtworkTests: XCTestCase {
    func testFastLogoPublishesBeforePreferredCatalogFinishesOnBothPlatforms() async {
        let model = LineupTitleArtwork()
        let fast = UIImage(systemName: "star")!, preferred = UIImage(systemName: "film")!
        let url = URL(string: "https://example.test/logo.png")!
        let preferredURL = URL(string: "https://example.test/preferred.png")!
        let pending = expectation(description: "Preferred catalog pending")
        let painted = expectation(description: "Fast logo is visible")
        var continuation: CheckedContinuation<URL?, Never>?
        var reported = false
        let observation = model.objectWillChange.sink {
            Task { @MainActor in
                if !reported, model.image(for: "title") === fast { reported = true; painted.fulfill() }
            }
        }
        defer { observation.cancel() }
        let task = Task {
            await model.load(key: "title", pixels: 1280, server: nil,
                fanart: { await withCheckedContinuation { continuation = $0; pending.fulfill() } },
                tmdb: { url }, fetch: { source, _ in source == url ? fast : preferred })
        }
        await fulfillment(of: [pending, painted], timeout: 5)
        continuation?.resume(returning: preferredURL)
        await task.value
        // A successful preferred source upgrades the same view.
        XCTAssertTrue(model.image(for: "title") === preferred)
    }

    func testDecodedHeroLogoIsReadyForANewDetailViewAndSurvivesMetadataEnrichment() async {
        let profile = UUID()
        let raw = item(profile: profile)
        let enriched = raw.withMetadata(LibraryMetadata(source: .tmdb, title: "Resolved title", externalIDs: ["tmdb": "603"]))
        let key = LineupTitleArtwork.cacheKey(for: raw, catalogEnabled: true)
        XCTAssertEqual(key, LineupTitleArtwork.cacheKey(for: enriched, catalogEnabled: true))
        XCTAssertNotEqual(key, LineupTitleArtwork.cacheKey(for: item(profile: UUID()), catalogEnabled: true))
        XCTAssertNotEqual(key, LineupTitleArtwork.cacheKey(for: raw, catalogEnabled: false))
        let image = UIImage(systemName: "film")!
        let url = URL(string: "https://example.test/\(UUID()).png")!
        let hero = LineupTitleArtwork()
        await hero.load(key: "hero", pixels: LineupTitleArtwork.pixels, server: nil, cacheKey: key,
            fanart: { nil }, tmdb: { url }, fetch: { _, pixels in
                XCTAssertEqual(pixels, 1280); return image
            })
        XCTAssertTrue(LineupTitleArtwork.ready(for: key) === image,
                      "A destination can draw this synchronously, before starting its task")
        let detail = LineupTitleArtwork()
        let started = expectation(description: "New metadata request pending")
        var reply: CheckedContinuation<URL?, Never>?
        let task = Task {
            await detail.load(key: "detail-with-new-ids", pixels: LineupTitleArtwork.pixels,
                server: nil, cacheKey: key,
                fanart: { await withCheckedContinuation { reply = $0; started.fulfill() } },
                tmdb: { nil }, fetch: { _, _ in XCTFail("No second image fetch is needed"); return nil })
        }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertTrue(detail.image(for: "detail-with-new-ids") === image)
        reply?.resume(returning: nil)
        await task.value
        XCTAssertTrue(detail.image(for: "detail-with-new-ids") === image)
    }

    func testFanartURLSurvivesClientRecreationWithoutAnotherAPIRequest() async throws {
        let path = cachePath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let session = session()
        defer { session.invalidateAndCancel(); LogoProtocol.install(nil) }
        LogoProtocol.install { request in
            XCTAssertEqual(request.url?.path, "/v3.2/movies/603")
            return #"{"tmdb_id":"603","hdmovielogo":[{"url":"https://assets.fanart.tv/fanart/movies/603/hdmovielogo/exact.png","lang":"en"}]}"#
        }
        let identity = try XCTUnwrap(MobileFanartIdentity(kind: .movie, id: "603"))
        let first = MobileFanart(key: "fixture-key", session: session, logoCache: TitleLogoURLCache(cacheURL: path))
        let original = await first.logo(for: identity)
        let second = MobileFanart(key: "fixture-key", session: session, logoCache: TitleLogoURLCache(cacheURL: path))
        let restored = await second.logo(for: identity)
        XCTAssertEqual(original, restored)
        XCTAssertNotNil(restored)
        XCTAssertEqual(LogoProtocol.count, 1)
        let saved = try String(contentsOf: path, encoding: .utf8)
        XCTAssertFalse(saved.contains("fixture-key"))
        XCTAssertFalse(saved.contains("api_key"))
    }

    func testTMDBReusesResolvedIdentityAndPersistsLogoForNextResolver() async throws {
        let path = cachePath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let session = session()
        defer { session.invalidateAndCancel(); LogoProtocol.install(nil) }
        LogoProtocol.install { request in
            XCTAssertEqual(request.url?.path, "/3/movie/603/images", "Resolved metadata must not be discarded and searched again")
            return #"{"id":603,"logos":[{"file_path":"/exact.png","iso_639_1":"en","width":800,"height":300}]}"#
        }
        let title = item(profile: UUID()).withMetadata(
            LibraryMetadata(source: .tmdb, title: "Resolved title", externalIDs: ["tmdb": "603"]))
        let first = LibraryMetadataResolver(credentials: .init(tmdb: "fixture-token", tvdb: ""), session: session, cacheURL: path)
        async let one = first.titleLogo(for: title)
        async let two = first.titleLogo(for: title)
        let (a, b) = await (one, two)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a?.lastPathComponent, "exact.png")
        let reopened = LibraryMetadataResolver(credentials: .init(tmdb: "fixture-token", tvdb: ""), session: session, cacheURL: path)
        let restored = await reopened.titleLogo(for: title)
        XCTAssertEqual(restored, a)
        XCTAssertEqual(LogoProtocol.count, 1, "Navigation and a new resolver must reuse the exact verified logo URL")
    }

    func testLogoIndexRejectsPrivateAndCredentialBearingURLs() async throws {
        let path = cachePath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let cache = TitleLogoURLCache(cacheURL: path)
        for address in ["http://image.tmdb.org/t/p/w1280/logo.png",
                        "https://image.tmdb.org/t/p/w1280/logo.png?api_key=fixture",
                        "https://user:password@image.tmdb.org/t/p/w1280/logo.png",
                        "https://example.test/private/logo.png"] {
            await cache.remember(try XCTUnwrap(URL(string: address)), for: address)
            let value = await cache.logo(for: address)
            XCTAssertNil(value)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    private func item(profile: UUID) -> MediaItem {
        MediaItem(id: "local-title", name: "Original title", type: "Movie", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil, serverID: profile)
    }
    private func cachePath() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TitleArtworkTests-\(UUID())")
            .appendingPathComponent("logos.json")
    }
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LogoProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class LogoProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> String)?
    private static var requests = 0
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    static func install(_ value: ((URLRequest) throws -> String)?) {
        lock.lock(); defer { lock.unlock() }; handler = value; requests = 0
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handler; Self.requests += 1; Self.lock.unlock()
        do {
            let body = try handler?(request) ?? "{}"
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
