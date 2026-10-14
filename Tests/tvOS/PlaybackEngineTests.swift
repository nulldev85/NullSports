import XCTest
import UIKit
@testable import Lineup

@MainActor
final class PlaybackEngineTests: XCTestCase {
    func testSelectionPersistsAndUnknownValuesFallBackToVLC() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        XCTAssertEqual(TVPlaybackEngine.selected(in: fixture.defaults), .vlc)
        fixture.defaults.set("aether", forKey: TVPlaybackEngine.storageKey)
        XCTAssertEqual(TVPlaybackEngine.selected(in: fixture.defaults), .aether)
        XCTAssertEqual(TVPlaybackEngine.aether.title, "AetherEngine")
        fixture.defaults.set("missing-engine", forKey: TVPlaybackEngine.storageKey)
        XCTAssertEqual(TVPlaybackEngine.selected(in: fixture.defaults), .vlc)
    }

    func testInfoReportsActualEngineAndSettingChangesApplyToTheNextStream() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let controller = fixture.controller()
        defer { controller.stop() }
        let surface = controller.surface
        controller.start(urls: [Fixture.url])
        XCTAssertEqual(controller.engineTitle, "VLC")
        fixture.defaults.set("aether", forKey: TVPlaybackEngine.storageKey)
        XCTAssertEqual(controller.engineTitle, "VLC", "The running stream still uses VLC")
        controller.start(urls: [Fixture.url])
        XCTAssertEqual(controller.engineTitle, "AetherEngine")
        XCTAssertTrue(controller.surface === surface)
        XCTAssertTrue(surface.subviews.first === fixture.aether.surface)
        XCTAssertEqual(fixture.aether.loads.count, 1)
        XCTAssertFalse(fixture.vlc.isOpen)
        fixture.defaults.set("vlc", forKey: TVPlaybackEngine.storageKey)
        controller.start(urls: [Fixture.url])
        XCTAssertEqual(controller.engineTitle, "VLC")
        XCTAssertFalse(fixture.aether.isOpen)
    }

    func testResumeSeekPauseMuteAndCompletionUseTheSameControllerForBothEngines() throws {
        for kind in TVPlaybackEngine.allCases {
            let fixture = try Fixture(kind)
            defer { fixture.clean() }
            let controller = fixture.controller()
            defer { controller.stop() }
            controller.start(urls: [Fixture.url], initialPosition: 900, isLive: false, expectedDuration: 3_600)
            let backend = fixture.backend(kind)
            XCTAssertEqual(backend.loads.last?.startPosition, 900)
            XCTAssertEqual(backend.loads.last?.expectedDuration, 3_600)
            backend.time = 902
            controller.checkPlayback()
            XCTAssertEqual(controller.elapsed, 902)
            controller.seek(by: 10)
            XCTAssertEqual(backend.seeks.last, 912)
            controller.togglePlayback()
            XCTAssertEqual(backend.state, .paused)
            controller.togglePlayback()
            XCTAssertEqual(backend.state, .playing)
            controller.setMuted(true)
            XCTAssertTrue(backend.isMuted)
            controller.setMuted(false)
            XCTAssertFalse(backend.isMuted)
            backend.time = 3_600
            backend.state = .ended
            controller.checkPlayback()
            XCTAssertTrue(controller.finished)
            XCTAssertEqual(controller.elapsed, 3_600)
        }
    }

    func testPreviewHandoffDoesNotLoadOrChangeEnginesAgain() throws {
        let fixture = try Fixture(.aether)
        defer { fixture.clean() }
        let controller = fixture.controller()
        defer { controller.stop() }
        controller.start(urls: [Fixture.url], muted: true, channelID: 42)
        let count = fixture.aether.loads.count
        let surface = controller.surface
        controller.lentToFullScreen = true
        controller.watched = .fullScreen
        controller.setMuted(false)
        controller.lentToFullScreen = false
        XCTAssertEqual(fixture.aether.loads.count, count)
        XCTAssertTrue(controller.surface === surface)
        XCTAssertEqual(controller.engineTitle, "AetherEngine")
        XCTAssertFalse(fixture.aether.isMuted)
    }

    func testMultiviewKeepsPlayersAndAudioIndependentAndSuppressesDisplaySwitches() throws {
        let fixture = try Fixture(.aether)
        defer { fixture.clean() }
        let first = MockTVBackend(.aether)
        let second = MockTVBackend(.aether)
        let a = fixture.controller(primary: true) { _ in first }
        let b = fixture.controller(primary: false) { _ in second }
        defer { a.stop(); b.stop() }
        a.watched = .splitScreen("First")
        b.watched = .splitScreen("Second")
        a.start(urls: [Fixture.url], muted: false)
        b.start(urls: [Fixture.url], muted: true)
        XCTAssertEqual(first.loads.last?.primary, true)
        XCTAssertEqual(second.loads.last?.primary, false)
        XCTAssertEqual(first.loads.last?.matchContent, false)
        XCTAssertEqual(second.loads.last?.matchContent, false)
        a.fadeAudio(audible: false, over: 0)
        b.fadeAudio(audible: true, over: 0)
        XCTAssertTrue(first.isMuted)
        XCTAssertFalse(second.isMuted)
        XCTAssertEqual(first.volume, 0)
        XCTAssertEqual(second.volume, 100)
        a.checkPlayback(); b.checkPlayback()
        XCTAssertTrue(first.isMuted, "A monitor tick must not leak the silent tile's audio")
        XCTAssertEqual(first.loads.count, 1)
        XCTAssertEqual(second.loads.count, 1)
    }

    func testAudioAndSubtitlesIncludingNegativeAetherIDsSurviveRetry() throws {
        for kind in TVPlaybackEngine.allCases {
            let fixture = try Fixture(kind)
            defer { fixture.clean() }
            let controller = fixture.controller()
            defer { controller.stop() }
            let backend = fixture.backend(kind)
            let subtitle = PlaybackSubtitleTrack(id: "external", title: "English", engineIndex: -200)
            backend.subtitles = [.off, subtitle]
            backend.audioTracks = [.init(id: 2, title: "English"), .init(id: 3, title: "Commentary")]
            controller.start(urls: [Fixture.url], isLive: false, expectedDuration: 3_600)
            backend.time = 600
            controller.checkPlayback()
            controller.selectSubtitle(subtitle)
            controller.selectAudioTrack(backend.audioTracks[1])
            controller.retry()
            XCTAssertEqual(backend.loads.last?.startPosition, 600)
            XCTAssertEqual(backend.loads.last?.expectedDuration, 3_600)
            controller.checkPlayback()
            XCTAssertEqual(backend.selectedSubtitleIndex, -200)
            XCTAssertEqual(backend.selectedAudioIndex, 3)
            controller.selectSubtitle(.off)
            XCTAssertNil(backend.selectedSubtitleIndex)
        }
    }

    func testReconnectRetainsVODPositionAndNeverMarksADroppedStreamFinished() throws {
        for kind in TVPlaybackEngine.allCases {
            let fixture = try Fixture(kind)
            defer { fixture.clean() }
            let controller = fixture.controller()
            defer { controller.stop() }
            let backend = fixture.backend(kind)
            controller.start(urls: [Fixture.url], isLive: false, expectedDuration: 3_600)
            backend.time = 600
            controller.checkPlayback()
            fixture.now += 3
            backend.state = .error
            controller.checkPlayback()
            XCTAssertFalse(controller.finished)
            XCTAssertTrue(controller.reconnecting)
            fixture.now += 2
            controller.checkPlayback()
            XCTAssertEqual(backend.loads.last?.startPosition, 598)
            XCTAssertEqual(backend.loads.count, 2)
            XCTAssertEqual(controller.engineKind, kind)
        }
    }

    func testProviderRecordingIsNotOpenedAsAnUnboundedLiveStream() throws {
        let fixture = try Fixture(.aether)
        defer { fixture.clean() }
        let controller = fixture.controller()
        defer { controller.stop() }
        controller.start(urls: [Fixture.url], isLive: true, recording: true)
        XCTAssertEqual(fixture.aether.loads.last?.isLive, false)
    }

    @MainActor private final class Fixture {
        static let url = URL(string: "https://example.invalid/movie.mkv")!
        let suite = "PlaybackEngineTests.\(UUID())"
        let defaults: UserDefaults
        let vlc = MockTVBackend(.vlc)
        let aether = MockTVBackend(.aether)
        var now: TimeInterval = 1_000
        init(_ kind: TVPlaybackEngine = .vlc) throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set(kind.rawValue, forKey: TVPlaybackEngine.storageKey)
        }
        func clean() { defaults.removePersistentDomain(forName: suite) }
        func backend(_ kind: TVPlaybackEngine) -> MockTVBackend { kind == .vlc ? vlc : aether }
        func controller(primary: Bool = true,
                        factory: (@MainActor (TVPlaybackEngine) -> any TVPlaybackBackend)? = nil) -> TVPlaybackController {
            TVPlaybackController(defaults: defaults, primaryOutput: primary, uptime: { self.now },
                connectionCooldown: 0, backendFactory: factory ?? { self.backend($0) })
        }
    }
}

@MainActor
private final class MockTVBackend: TVPlaybackBackend {
    struct Load {
        let startPosition: TimeInterval?
        let isLive: Bool
        let expectedDuration: TimeInterval?
        let primary: Bool
        let matchContent: Bool
    }
    let kind: TVPlaybackEngine
    let surface = UIView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    var state = TVPlaybackState.stopped
    var errorMessage: String? { nil }
    var isPlaying: Bool { state == .playing }
    var hasVideoOut: Bool { isOpen }
    var videoSize: CGSize { CGSize(width: 1920, height: 1080) }
    var duration: TimeInterval = 3_600
    var time: TimeInterval = 0
    var frames: Int? { nil }
    var bytes: Int? { nil }
    var isSeekable = true
    var isOpen = false
    var volume: Int32 = 100
    var isMuted = false
    var subtitles: [PlaybackSubtitleTrack] = [.off]
    var selectedSubtitleIndex: Int?
    var audioTracks: [PlaybackStreamTrack] = []
    var selectedAudioIndex: Int?
    var videoTracks: [PlaybackStreamTrack] = []
    var selectedVideoIndex: Int?
    var loads: [Load] = []
    var seeks: [TimeInterval] = []
    init(_ kind: TVPlaybackEngine) { self.kind = kind }
    func load(url: URL, startPosition: TimeInterval?, isLive: Bool, expectedDuration: TimeInterval?, primary: Bool, matchContent: Bool) {
        loads.append(.init(startPosition: startPosition, isLive: isLive, expectedDuration: expectedDuration,
                           primary: primary, matchContent: matchContent))
        isOpen = true
        time = startPosition ?? 0
        selectedAudioIndex = nil
        selectedSubtitleIndex = nil
    }
    func play() { state = .playing }
    func pause() { state = .paused }
    func stop() { state = .stopped; isOpen = false }
    func seek(to seconds: TimeInterval) { seeks.append(seconds); time = seconds }
    func selectSubtitle(index: Int?) { selectedSubtitleIndex = index }
    func selectAudio(index: Int) { selectedAudioIndex = index }
    func selectVideo(index: Int) { selectedVideoIndex = index }
}
