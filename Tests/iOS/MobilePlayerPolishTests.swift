import XCTest
import SwiftUI
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

    func testSkipActionCapturesDestinationAndSuppressesEarlyKeyframeBounceBack() {
        let segments = MobilePlaybackSegments(
            intro: MobileIntroSegment(start: 30, end: 115),
            recap: MobileIntroSegment(start: 0, end: 25)
        )
        let recap = MobileSkipAction.active(segments: segments, position: 10, duration: 2400,
                                            introEnabled: true, recapEnabled: true, recentlySkipped: nil)
        XCTAssertEqual(recap, MobileSkipAction(kind: .recap, destination: 25))
        XCTAssertEqual(recap?.title, "Skip Recap")

        let intro = MobileSkipAction.active(segments: segments, position: 45, duration: 2400,
                                            introEnabled: true, recapEnabled: true, recentlySkipped: nil)
        XCTAssertEqual(intro, MobileSkipAction(kind: .intro, destination: 115))
        XCTAssertEqual(intro?.title, "Skip Intro")

        // If a decoder keyframe lands just shy of the intro end, do not flash Skip Intro back.
        let nearEnd = MobileSkipAction.active(segments: segments, position: 113, duration: 2400,
                                              introEnabled: true, recapEnabled: true, recentlySkipped: intro)
        XCTAssertNil(nearEnd)

        // If the viewer deliberately rewinds well back into the intro, offer Skip Intro again.
        let rewound = MobileSkipAction.active(segments: segments, position: 50, duration: 2400,
                                              introEnabled: true, recapEnabled: true, recentlySkipped: intro)
        XCTAssertEqual(rewound, intro)
    }

    func testVideoHostIsNonInteractiveAndTracksAttachmentCleanly() {
        let controller = MobilePlaybackController()
        let host = MobileVideoHost(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        XCTAssertFalse(host.isUserInteractionEnabled, "Video host must never intercept SwiftUI player control touches")
        XCTAssertFalse(controller.isVideoAttached(host))
        controller.attachVideo(host)
        XCTAssertTrue(controller.isVideoAttached(host))
        controller.shutdown()
    }

    func testPlaybackOptionsPanelRendersCleanlyInLandscapeAndPortrait() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let parent = UIViewController()
        window.rootViewController = parent
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }

        let sampleRows: (PlaybackOptionsTab) -> [PlaybackOptionRow] = { tab in
            switch tab {
            case .info:
                return [
                    PlaybackOptionRow(title: "The Bear", detail: "S02E07 · Forks", section: "Now Playing", symbol: "play.rectangle.fill"),
                    PlaybackOptionRow(title: "Richie spends a week staging at an acclaimed restaurant.", key: "overview", section: "Now Playing", style: .overview),
                    PlaybackOptionRow(title: "Playback engine", detail: "AetherEngine", section: "Details", symbol: "cpu"),
                    PlaybackOptionRow(title: "Audio", detail: "English · EAC3", section: "Details", symbol: "waveform")
                ]
            case .stats:
                return [
                    PlaybackOptionRow(title: "Playback", detail: "Playing", symbol: "play.circle.fill"),
                    PlaybackOptionRow(title: "Engine", detail: "AetherEngine", symbol: "cpu"),
                    PlaybackOptionRow(title: "Resolution", detail: "3840 × 2160", symbol: "sparkles.tv"),
                    PlaybackOptionRow(title: "Source bitrate", detail: "18.4 Mbps", symbol: "gauge.with.dots.needle.67percent"),
                    PlaybackOptionRow(title: "Formats", detail: "Dolby Vision · Dolby Atmos · HEVC", symbol: "rectangle.badge.checkmark")
                ] + PlaybackOptionRow.metrics(buffer: 14.2, dropped: 0, network: 24.8)
            case .video:
                return PlaybackOptionRow.speedRows(1.0) { _ in } + [
                    PlaybackOptionRow(title: "Fit picture", selected: true, section: "Aspect Ratio", symbol: "arrow.down.right.and.arrow.up.left", action: {}),
                    PlaybackOptionRow(title: "Auto-play next", detail: "On", section: "Up Next", symbol: "forward.end.fill", style: .toggle, action: {})
                ]
            case .audio:
                return [
                    PlaybackOptionRow(title: "English · 5.1 EAC3", selected: true, key: "a1", section: "Audio Track", symbol: "waveform", action: {}),
                    PlaybackOptionRow(title: "Codec", detail: "EAC3", section: "Stream Details", symbol: "speaker.wave.2")
                ]
            case .subtitles:
                return [
                    PlaybackOptionRow(title: "English (SDH)", selected: true, key: "s1", section: "Subtitle Track", symbol: "captions.bubble", action: {}),
                    PlaybackOptionRow(title: "Find subtitles online", section: "Online", symbol: "magnifyingglass", style: .action, action: {})
                ] + PlaybackOptionRow.subtitleTiming(0) { _ in }
            case .chapters:
                return PlaybackOptionRow.chapterRows([PlaybackChapter(start: 0, title: "Cold Open"), PlaybackChapter(start: 180, title: "Intro")], position: 10, clock: MobilePlaybackProgress.timecode) { _ in }
            }
        }

        let panel = PlaybackOptionsPanel(tabs: PlaybackOptionsTab.allCases, close: {}, rows: sampleRows)
            .frame(maxWidth: 620)
            .padding(16)
            .background(Color.black)
        let host = UIHostingController(rootView: panel.preferredColorScheme(.dark))
        parent.addChild(host)
        host.view.frame = CGRect(x: 0, y: 0, width: 660, height: 420)
        parent.view.addSubview(host.view)
        host.didMove(toParent: parent)
        try await Task.sleep(for: .milliseconds(250))
        host.view.layoutIfNeeded()
        XCTAssertGreaterThan(host.view.bounds.height, 0)
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "PlaybackOptionsPanel-Redesigned"
        attachment.lifetime = .keepAlways
        add(attachment)
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
    }

    func testSportsTabCrunchBadgeAndFeaturedGamePicker() {
        func makeGame(id: String, league: SportsLeague = .nba, awayScore: String, homeScore: String,
                      status: String, state: String = "in", soccer: SoccerScore? = nil) -> SportsGame {
            SportsGame(
                id: id, league: league, start: Date().addingTimeInterval(-3600),
                awayTeam: "Away \(id)", homeTeam: "Home \(id)",
                awayAbbreviation: "AWY", homeAbbreviation: "HME",
                awayLogo: "", homeLogo: "",
                awayScore: awayScore, homeScore: homeScore,
                awayColor: nil, homeColor: nil, awayRecord: nil, homeRecord: nil,
                venue: nil, location: nil, status: status, state: state,
                broadcast: "ESPN", eventName: nil, soccer: soccer
            )
        }

        let nbaOT = makeGame(id: "ot", awayScore: "112", homeScore: "110", status: "OT 2:14")
        let nbaClose = makeGame(id: "close", awayScore: "106", homeScore: "104", status: "4th 1:42")
        let nbaBlowout = makeGame(id: "blowout", awayScore: "58", homeScore: "37", status: "2nd 6:20")
        let nbaTightEarly = makeGame(id: "early", awayScore: "42", homeScore: "41", status: "2nd 5:00")
        let nbaFinal = makeGame(id: "final", awayScore: "110", homeScore: "108", status: "Final", state: "post")
        let mlbExtras = makeGame(id: "mlb", league: .mlb, awayScore: "4", homeScore: "4", status: "Top 10th")
        let soccerET = makeGame(
            id: "soc", league: .soccer, awayScore: "2", homeScore: "2", status: "95'",
            soccer: SoccerScore(awayPenalties: nil, homePenalties: nil, awayAggregate: nil, homeAggregate: nil, period: 3, clockSeconds: 95 * 60)
        )

        XCTAssertEqual(MobileGameCrunchBadge.badge(for: nbaOT), .overtime("OT"))
        XCTAssertEqual(MobileGameCrunchBadge.badge(for: mlbExtras), .overtime("EXTRAS"))
        XCTAssertEqual(MobileGameCrunchBadge.badge(for: soccerET), .overtime("ET"))
        XCTAssertEqual(MobileGameCrunchBadge.badge(for: nbaClose), .close)
        XCTAssertNil(MobileGameCrunchBadge.badge(for: nbaBlowout))
        XCTAssertNil(MobileGameCrunchBadge.badge(for: nbaFinal))

        XCTAssertNil(MobileFeaturedGamePicker.pick(from: [], isFollowing: { _ in false }))
        XCTAssertEqual(
            MobileFeaturedGamePicker.pick(from: [nbaBlowout, nbaClose, nbaOT], isFollowing: { _ in false })?.id,
            "ot"
        )
        XCTAssertEqual(
            MobileFeaturedGamePicker.pick(from: [nbaBlowout, nbaClose, nbaOT], isFollowing: { $0.id == "close" })?.id,
            "close"
        )
        XCTAssertEqual(
            MobileFeaturedGamePicker.pick(from: [nbaBlowout, nbaTightEarly], isFollowing: { $0.id == "blowout" })?.id,
            "blowout"
        )
        XCTAssertEqual(
            MobileFeaturedGamePicker.pick(from: [nbaBlowout, nbaTightEarly], isFollowing: { _ in false })?.id,
            "early"
        )
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
