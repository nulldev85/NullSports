import XCTest
import UIKit
import Combine
@testable import LineupiOS

@MainActor
final class MobilePlayerPolishTests: XCTestCase {
    private let version = "11111111111111111111111111111111"
    private var info: MobileSeekPreviewInfo {
        MobileSeekPreviewInfo(width: 160, height: 90, columns: 2, rows: 2, count: 8, interval: 1000)
    }
    private func source() throws -> MobileSeekPreviewSource {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://server.invalid/base/videos/item/trickplay/160/0.jpg?MediaSourceId=selected")))
        request.setValue("fixture-user-token", forHTTPHeaderField: "X-Emby-Token")
        return MobileSeekPreviewSource(info: info, firstTile: request)
    }
    private func sprite() throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 320, height: 180), format: format).image { context in
            for (index, color) in [UIColor.red, .green, .blue, .yellow].enumerated() {
                color.setFill()
                context.fill(CGRect(x: CGFloat(index % 2) * 160, y: CGFloat(index / 2) * 90, width: 160, height: 90))
            }
        }.pngData())
    }
    private func manifest() throws -> Data {
        let entry: [String: Int] = ["Width": 160, "Height": 90, "TileWidth": 2, "TileHeight": 2, "ThumbnailCount": 8, "Interval": 1000]
        let variants: [String: Any] = [
            version: ["160": entry, "malformed": ["Width": "bad"]] as [String: Any],
            "22222222222222222222222222222222": ["320": ["Width": 320, "Height": 180, "TileWidth": 2, "TileHeight": 2, "ThumbnailCount": 8, "Interval": 1000]]
        ]
        return try JSONSerialization.data(withJSONObject: ["Trickplay": variants])
    }
    func testSubtitlePreferencesPersistAndTimingIsBoundedPerVideo() throws {
        let suite = "Lineup.subtitle-polish." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = MobileSubtitlePreferences(defaults: defaults)
        XCTAssertEqual(preferences.scale, 1); XCTAssertEqual(preferences.language, "")
        preferences.language = "es"; preferences.scale = 1.25; preferences.background = true
        preferences.save(to: defaults)
        XCTAssertEqual(MobileSubtitlePreferences(defaults: defaults), preferences)
        XCTAssertEqual(defaults.string(forKey: "Lineup.subtitles.language.v1"), "es")
        defaults.set("not-a-language", forKey: MobileSubtitlePreferences.languageKey)
        defaults.set(Double.infinity, forKey: MobileSubtitlePreferences.sizeKey)
        XCTAssertEqual(MobileSubtitlePreferences(defaults: defaults).language, "")
        XCTAssertEqual(MobileSubtitlePreferences(defaults: defaults).scale, 1)
        XCTAssertEqual(MobileSubtitlePreferences.delay(31), 30)
        XCTAssertEqual(MobileSubtitlePreferences.delay(-31), -30)
        XCTAssertEqual(MobileSubtitlePreferences.delay(0.26), 0.25)
        XCTAssertEqual(MobileSubtitlePreferences.delay(.nan), 0)
        XCTAssertTrue(MobileSubtitlePreferences.matches("eng", preferred: "en"))
        XCTAssertTrue(MobileSubtitlePreferences.matches("pt_BR", preferred: "pt-br"))
        XCTAssertFalse(MobileSubtitlePreferences.matches("pt-pt", preferred: "pt-br"))
        XCTAssertFalse(MobileSubtitlePreferences.matches(nil, preferred: "en"))
        let controller = MobilePlaybackController(defaults: defaults)
        controller.setSubtitleDelay(1.25)
        XCTAssertEqual(controller.subtitleDelaySeconds, 1.25)
        controller.stop()
        XCTAssertEqual(controller.subtitleDelaySeconds, 0)
    }

    func testPreviewUsesExactVersionAndMillisecondsAndRejectsMalformedGeometry() throws {
        let chosen = try XCTUnwrap(MobileSeekPreviewSource.select(try manifest(), mediaSourceID: "11111111-1111-1111-1111-111111111111"))
        XCTAssertEqual(chosen.1, info)
        XCTAssertNil(MobileSeekPreviewSource.select(try manifest(), mediaSourceID: "33333333333333333333333333333333"),
                     "Never substitute a storyboard from another cut/version")
        XCTAssertNil(MobileSeekPreviewSource.select(Data("{}".utf8), mediaSourceID: version))
        XCTAssertNil(MobileSeekPreviewSource.versionKey("../another/source"))
        XCTAssertEqual(info.index(at: 2.99), 2)
        XCTAssertEqual(info.index(at: 100), 7)
        XCTAssertNil(info.index(at: .nan)); XCTAssertNil(info.index(at: -1))
        XCTAssertEqual(info.sheet(for: 5), 1)
        XCTAssertEqual(info.rect(for: 5), CGRect(x: 160, y: 0, width: 160, height: 90))
        let invalid = MobileSeekPreviewInfo(width: Int.max, height: 1, columns: 20, rows: 20, count: 8, interval: 0)
        XCTAssertFalse(invalid.valid); XCTAssertNil(invalid.index(at: 1))
        let request = try XCTUnwrap(try source().request(sheet: 1))
        XCTAssertEqual(request.url?.path, "/base/videos/item/trickplay/160/1.jpg")
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "selected")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Emby-Token"), "fixture-user-token")
        XCTAssertNil(try source().request(sheet: 2))
    }

    func testSpritesCropCorrectCellAndCacheWithoutAnotherRequestPerPosition() async throws {
        let data = try sprite(), source = try self.source()
        let counter = PreviewRequestCounter()
        let images = MobileSeekPreviewImages(source: source) { request in
            await counter.record()
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let rendered = try await images.frame(at: 2)
        let blue = try XCTUnwrap(rendered)
        let bytes = try XCTUnwrap(blue.image.dataProvider?.data)
        let pointer = try XCTUnwrap(CFDataGetBytePtr(bytes))
        let offset = (blue.image.height / 2) * blue.image.bytesPerRow + (blue.image.width / 2) * 4
        XCTAssertLessThan(pointer[offset], 10); XCTAssertLessThan(pointer[offset + 1], 10)
        XCTAssertGreaterThan(pointer[offset + 2], 240)
        XCTAssertEqual(blue.image.width, 160); XCTAssertEqual(blue.image.height, 90)
        _ = try await images.frame(at: 3)
        _ = try await images.frame(at: 0)
        let count = await counter.count
        XCTAssertEqual(count, 1, "A storyboard supplies many positions without another network request")
        let wrong = MobileSeekPreviewInfo(width: 320, height: 90, columns: 2, rows: 2, count: 8, interval: 1000)
        XCTAssertNil(MobileSeekPreviewImages.decode(data, info: wrong))
        XCTAssertNil(MobileSeekPreviewImages.decode(Data("not an image".utf8), info: info))
    }

    func testMissingPreviewBacksOffWithoutInterruptingSeeking() async throws {
        let source = try self.source(), counter = PreviewRequestCounter()
        let images = MobileSeekPreviewImages(source: source) { request in
            await counter.record()
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        let first = try await images.frame(at: 0), next = try await images.frame(at: 2)
        XCTAssertNil(first); XCTAssertNil(next)
        let count = await counter.count
        XCTAssertEqual(count, 1)
    }

    func testPreviewFramesDoNotInvalidateTheFullscreenVideoOwner() async throws {
        let session = MobileSeekPreviewSession()
        let data = try sprite(), source = try self.source()
        var invalidatedVideoOwner = false
        let owner = session.objectWillChange.sink { invalidatedVideoOwner = true }
        let published = expectation(description: "the small preview view receives its frame")
        let frames = session.store.$frame.compactMap { $0 }.first { $0.index == 1 }.sink { _ in published.fulfill() }
        defer { owner.cancel(); frames.cancel(); session.store.cancel() }
        session.store.configure(source) { request in
            (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        session.store.request(at: 1)
        await fulfillment(of: [published], timeout: 5)
        XCTAssertFalse(invalidatedVideoOwner, "Thumbnail updates must not redraw the fullscreen player/video surface")
    }

    func testNewestPositionWinsWhileObsoleteNetworkResponseIsStillPending() async throws {
        let data = try sprite(), source = try self.source()
        let began = expectation(description: "old storyboard request actually started")
        let finished = expectation(description: "old storyboard request actually returned")
        let gate = PreviewResponseGate()
        let store = MobileSeekPreviewStore()
        store.configure(source) { request in
            if request.url?.lastPathComponent == "0.jpg" {
                await gate.wait { began.fulfill() }
                finished.fulfill()
            }
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let newest = expectation(description: "newest requested preview publishes")
        let subscription = store.$frame.compactMap { $0 }.first { $0.index == 4 }.sink { _ in newest.fulfill() }
        defer { subscription.cancel(); store.cancel() }
        store.request(at: 0)
        await fulfillment(of: [began], timeout: 5)
        for seconds in [0.1, 1.1, 2.1, 4.1] { store.request(at: seconds) }
        await gate.release()
        await fulfillment(of: [finished, newest], timeout: 5)
        XCTAssertEqual(store.frame?.index, 4)
        store.cancel()
        XCTAssertNil(store.frame)
    }

    func testJellyfinRequestsOnlyTrickplayForTheSelectedSourceWithExistingAuthentication() async throws {
        let data = try manifest()
        PreviewMetadataProtocol.body = data
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PreviewMetadataProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = try JellyfinClient(serverURL: "https://server.invalid/base", accessToken: "fixture-token",
            deviceID: "fixture", session: session)
        let preview = try await client.seekPreview(userID: "user", itemID: version, mediaSourceID: version)
        let source = try XCTUnwrap(preview), request = try XCTUnwrap(source.request(sheet: 1))
        XCTAssertEqual(source.info, info)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Emby-Token"), "fixture-token")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("fixture-token") == true)
        XCTAssertTrue(request.url?.path.hasSuffix("/trickplay/160/1.jpg") == true)
        let skipped = try await client.seekPreview(userID: "user", itemID: "packed-aiostreams-id", mediaSourceID: "addon-release-id")
        XCTAssertNil(skipped)
    }
}

private actor PreviewRequestCounter {
    private(set) var count = 0
    func record() { count += 1 }
}
private actor PreviewResponseGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait(started: @Sendable () -> Void) async {
        if released { started(); return }
        await withCheckedContinuation { continuation in self.continuation = continuation; started() }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private final class PreviewMetadataProtocol: URLProtocol, @unchecked Sendable {
    static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "Fields" }?.value, "Trickplay")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Emby-Token"), "fixture-token")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
