import XCTest
import UIKit
import SwiftUI
import LineupAetherPlayback
@testable import Lineup

@MainActor
final class PlaybackEngineTests: XCTestCase {
    func testSettingsEngineChoicesExposeTheirPinnedVersions() {
        XCTAssertEqual(TVPlaybackEngine.aether.version, "7.45.0")
        XCTAssertEqual(TVPlaybackEngine.vlc.version, "3.6.0")
        XCTAssertEqual(TVPlaybackEngine.mpv.version, "1.1.0-n9.0.2")
    }

    func testPlayerViewReportsNormalRuntimeProgressAcrossAnEpisodeIDRefreshAndClose() async throws {
        for kind in TVPlaybackEngine.allCases {
            let fixture = try Fixture(kind)
            defer { fixture.clean() }
            let controller = fixture.controller()
            defer { controller.stop() }
            let profile = MediaServerProfile(name: "Jellyfin", serverURL: "https://server.invalid",
                username: "viewer", userID: "user")
            fixture.defaults.set(try JSONEncoder().encode([profile]), forKey: "NullSports.mediaServers")
            let media = MediaLibrary(defaults: fixture.defaults)
            func episode(_ id: String) -> MediaItem {
                MediaItem(id: id, name: "Episode 1", type: "Episode", overview: nil,
                    productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
                    runTimeTicks: 36_000_000_000, indexNumber: 1, parentIndexNumber: 1,
                    seriesName: "The Wire", seriesID: "wire").servedBy(profile.id)
            }
            let old = episode("cached-episode")
            let current = episode("current-episode")
            media.trackPlayback(of: old, position: 600, duration: 3_600)
            let session = UUID()
            media.beginPlaybackSession(for: old, id: session)
            defer { media.endPlaybackSession(session) }
            let appeared = expectation(description: "\(kind.title) PlayerView opened the backend")
            let reported = expectation(description: "\(kind.title) actual player clock reached tracking")
            let closed = expectation(description: "\(kind.title) PlayerView reported its final position")
            var didAppear = false
            var didReport = false
            var didClose = false
            let backend = fixture.backend(kind)
            backend.onLoad = { if !didAppear { didAppear = true; appeared.fulfill() } }
            let player = PlayerView(urls: [Fixture.url], title: "The Wire", isLive: false,
                initialPosition: media.resumePosition(for: current), expectedDuration: 3_600,
                onProgress: { position, duration in
                    media.trackPlayback(of: current, position: position, duration: duration, sessionID: session)
                    if position == 615, !didReport { didReport = true; reported.fulfill() }
                    if position == 617, !didClose { didClose = true; closed.fulfill() }
                }, playbackController: controller)
                .environment(SportsLibrary(profileDefaults: fixture.defaults))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            let host = UIHostingController(rootView: AnyView(player))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKey()
            }
            await fulfillment(of: [appeared], timeout: 5)
            XCTAssertEqual(backend.loads.last?.startPosition, 600)
            backend.time = 615
            controller.checkPlayback()
            await fulfillment(of: [reported], timeout: 5)
            XCTAssertEqual(media.resumePosition(for: current), 615)
            // This final two-second advance is below the ordinary reporting
            // interval; the actual view's disappearance must still flush it.
            backend.time = 617
            controller.checkPlayback()
            host.rootView = AnyView(Color.clear)
            await fulfillment(of: [closed], timeout: 5)
            media.endPlaybackSession(session)
            let restored = MediaLibrary(defaults: fixture.defaults)
            XCTAssertEqual(restored.resumePosition(for: current), 617)
            XCTAssertEqual(restored.continueWatching.first?.position, 617)
            XCTAssertFalse(restored.isWatched(current))
            controller.start(urls: [Fixture.url], initialPosition: restored.resumePosition(for: current),
                isLive: false, expectedDuration: 3_600)
            XCTAssertEqual(backend.loads.last?.startPosition, 617)
            controller.checkPlayback()
            XCTAssertEqual(controller.elapsed, 617)
        }
    }

    func testFormatLabelsFollowTheCurrentStreamAndClearOnRetuneOrStop() throws {
        for kind in TVPlaybackEngine.allCases {
            let fixture = try Fixture(kind)
            defer { fixture.clean() }
            let controller = fixture.controller()
            defer { controller.stop() }
            controller.start(urls: [Fixture.url])
            let backend = fixture.backend(kind)
            backend.mediaInfo = PlaybackMediaInfo(dynamicRange: "HDR10", audioCodec: "eac3", isDolbyAtmos: true)
            controller.checkPlayback()
            XCTAssertEqual(controller.mediaInfo.badges, ["HDR10", "Dolby Atmos"])
            controller.togglePlayback()
            backend.mediaInfo = PlaybackMediaInfo(audioCodec: "aac", audioChannels: 2)
            controller.checkPlayback()
            XCTAssertEqual(controller.mediaInfo.badges, ["AAC", "Stereo"], "Audio changes replace old attributes while paused")
            controller.togglePlayback()
            controller.start(urls: [URL(string: "https://example.invalid/another-channel.m3u8")!])
            XCTAssertTrue(controller.mediaInfo.badges.isEmpty)
            backend.mediaInfo = PlaybackMediaInfo(dynamicRange: "HLG")
            controller.checkPlayback()
            XCTAssertEqual(controller.mediaInfo.badges, ["HLG"])
            controller.stop()
            XCTAssertTrue(controller.mediaInfo.badges.isEmpty)
        }
    }
    func testSelectionPersistsAndUnknownValuesFallBackToVLC() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        XCTAssertEqual(TVPlaybackEngine.selected(in: fixture.defaults), .vlc)
        fixture.defaults.set("aether", forKey: TVPlaybackEngine.storageKey)
        XCTAssertEqual(TVPlaybackEngine.selected(in: fixture.defaults), .aether)
        XCTAssertEqual(TVPlaybackEngine.aether.title, "AetherEngine")
        fixture.defaults.set("mpv", forKey: TVPlaybackEngine.storageKey)
        XCTAssertEqual(TVPlaybackEngine.selected(in: fixture.defaults), .mpv)
        XCTAssertEqual(TVPlaybackEngine.mpv.title, "MPVKit (Trial)")
        fixture.defaults.set("missing-engine", forKey: TVPlaybackEngine.storageKey)
        XCTAssertEqual(TVPlaybackEngine.selected(in: fixture.defaults), .vlc)
    }

    func testEachTabKeepsItsOwnEngineAndOtherwiseUsesTheSharedOne() throws {
        let fixture = try Fixture(.aether)
        defer { fixture.clean() }
        XCTAssertEqual(TVPlaybackEngine.selected(for: .library, in: fixture.defaults), .aether)
        fixture.defaults.set("vlc", forKey: TVPlaybackPlace.library.storageKey)
        XCTAssertEqual(TVPlaybackEngine.selected(for: .library, in: fixture.defaults), .vlc)
        XCTAssertEqual(TVPlaybackEngine.selected(for: .sports, in: fixture.defaults), .aether)
        XCTAssertEqual(TVPlaybackEngine.selected(for: nil, in: fixture.defaults), .aether)

        // A player opens each stream with its own tab's engine.
        let controller = fixture.controller()
        defer { controller.stop() }
        controller.place = .library
        controller.start(urls: [Fixture.url])
        XCTAssertEqual(controller.engineTitle, "VLC")
        controller.place = .sports
        controller.start(urls: [Fixture.url])
        XCTAssertEqual(controller.engineTitle, "AetherEngine")

        fixture.defaults.set("missing-engine", forKey: TVPlaybackPlace.library.storageKey)
        XCTAssertEqual(TVPlaybackEngine.selected(for: .library, in: fixture.defaults), .aether)
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

    func testMPVTrialFailureFallsBackToVLCAndKeepsTheResumePosition() throws {
        let fixture = try Fixture(.mpv)
        defer { fixture.clean() }
        let controller = fixture.controller()
        defer { controller.stop() }
        controller.start(urls: [Fixture.url], initialPosition: 600, isLive: false, expectedDuration: 3_600)
        let mpv = fixture.backend(.mpv)
        XCTAssertEqual(controller.engineTitle, "MPVKit (Trial)")
        mpv.time = 600
        controller.checkPlayback()

        mpv.state = .error
        controller.checkPlayback()

        XCTAssertEqual(controller.engineTitle, "VLC")
        XCTAssertEqual(fixture.vlc.loads.last?.startPosition, 598)
        XCTAssertTrue(fixture.vlc.isOpen)
        XCTAssertTrue(controller.failoverNotice?.contains("Switched to VLC") == true)
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
            // Deliver the seek's clock sample before jumping to the movie's end.
            controller.checkPlayback()
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

    func testInteractiveSeekingKeepsPreviewsOutOfTrackingAndRestoresPlayPause() throws {
        for kind in TVPlaybackEngine.allCases {
            let fixture = try Fixture(kind)
            defer { fixture.clean() }
            let controller = fixture.controller()
            defer { controller.stop() }
            controller.start(urls: [Fixture.url], isLive: false, expectedDuration: 3_600)
            let backend = fixture.backend(kind)
            backend.time = 300
            controller.checkPlayback()
            controller.beginScrubbing()
            XCTAssertTrue(controller.isScrubbing)
            XCTAssertEqual(backend.state, .paused)
            controller.previewScrubbing(at: 3_500)
            controller.checkPlayback()
            XCTAssertEqual(controller.elapsed, 300, "A preview near the end must not be saved as watched progress")
            XCTAssertFalse(controller.finished)
            controller.previewScrubbing(at: 2_000)
            controller.endScrubbing(at: 450)
            XCTAssertEqual(backend.seeks.last, 450)
            XCTAssertEqual(controller.elapsed, 450)
            XCTAssertEqual(backend.state, .playing)
            backend.time = 3_500
            backend.state = .ended
            controller.checkPlayback()
            XCTAssertEqual(controller.elapsed, 450, "A late preview sample cannot pull the committed bar forward")
            XCTAssertFalse(controller.finished, "An old preview's EOF must not mark the actual episode watched")
            backend.state = .playing
            backend.time = 450
            controller.checkPlayback()
            controller.togglePlayback()
            controller.beginScrubbing()
            controller.previewScrubbing(at: 700)
            controller.endScrubbing(at: 800)
            XCTAssertEqual(backend.state, .paused, "Seeking while paused must remain paused")
            XCTAssertEqual(controller.elapsed, 800)
        }
    }

    func testStoppingDuringAHoldCannotSeekTheNextSource() async throws {
        let fixture = try Fixture(.aether)
        defer { fixture.clean() }
        let controller = fixture.controller()
        defer { controller.stop() }
        controller.start(urls: [Fixture.url], isLive: false, expectedDuration: 3_600)
        controller.beginScrubbing()
        controller.previewScrubbing(at: 100)
        controller.previewScrubbing(at: 2_000)
        controller.start(urls: [Fixture.url], isLive: false, expectedDuration: 3_600)
        let count = fixture.aether.seeks.count
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(fixture.aether.seeks.count, count)
        XCTAssertFalse(controller.isScrubbing)
        XCTAssertNotEqual(fixture.aether.seeks.last, 2_000)
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

    func testSiloRetryOwnsReconnectionWhileThePreviousInputHasFailed() async throws {
        let fixture = try Fixture(.aether)
        defer { fixture.clean() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TVSiloRetryProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel(); TVSiloRetryProtocol.reset() }
        TVSiloRetryProtocol.reset()
        let client = try SiloClient(address: "https://tvos-silo-retry.test", credential: .init(accessToken: "fixture"),
            profileID: "profile:1", deviceID: "fixture", session: transport)
        let silo = SiloPlaybackSession()
        let asset = try await silo.open(client: client, fileID: "file:42", position: 600, defaults: fixture.defaults)
        let controller = fixture.controller()
        defer { controller.stop() }
        controller.configureSiloPlayback(silo)
        controller.start(urls: [asset.url], initialPosition: asset.lease.playerStart, isLive: false, expectedDuration: asset.duration)
        silo.finalPosition(625)
        controller.retry()
        XCTAssertTrue(silo.isReplanning)
        XCTAssertTrue(controller.reconnecting)
        fixture.aether.state = .error
        fixture.now += 60
        controller.checkPlayback()
        fixture.now += 2
        controller.checkPlayback()
        XCTAssertEqual(fixture.aether.loads.count, 1, "A stale decoder failure must not reopen the old signed URL during server planning")
        XCTAssertTrue(controller.reconnecting)
        XCTAssertFalse(controller.finished)
        let deadline = Date().addingTimeInterval(4)
        while controller.error == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(controller.error, "A rejected fresh plan must show the retry error")
        XCTAssertFalse(controller.reconnecting)
        XCTAssertEqual(fixture.aether.loads.count, 1, "Failed planning cannot silently revive an expired lease")
        XCTAssertEqual(TVSiloRetryProtocol.startCount, 2)
        await silo.stop()
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
            if kind == .mpv {
                // MPV is a trial backend. An error intentionally retries the
                // same VOD position on VLC instead of reopening MPV forever.
                XCTAssertEqual(backend.loads.count, 1)
                XCTAssertEqual(fixture.vlc.loads.last?.startPosition, 598)
                XCTAssertEqual(fixture.vlc.loads.count, 1)
                XCTAssertEqual(controller.engineKind, .vlc)
            } else {
                XCTAssertEqual(backend.loads.last?.startPosition, 598)
                XCTAssertEqual(backend.loads.count, 2)
                XCTAssertEqual(controller.engineKind, kind)
            }
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

    /// The sound chosen for a show is kept, and its next episode opens on
    /// that language and is put on that track once the tracks are known.
    func testAShowsChosenSoundIsPutBackOnItsNextEpisode() throws {
        let fixture = try Fixture(.vlc)
        defer { fixture.clean() }
        let controller = fixture.controller()
        defer { controller.stop() }
        let backend = fixture.backend(.vlc)
        let tracks = [PlaybackStreamTrack(id: 1, title: "English · AC3 5.1"), PlaybackStreamTrack(id: 2, title: "Spanish · AAC")]
        controller.remembersTracks(forShow: "the show")
        controller.start(urls: [Fixture.url], isLive: false, expectedDuration: 3_600)
        XCTAssertEqual(backend.openingLanguages, PlaybackLanguages())
        backend.audioTracks = tracks
        backend.selectedAudioIndex = 1
        controller.checkPlayback()
        controller.selectAudioTrack(tracks[1])
        XCTAssertEqual(MobileTrackMemory.load("the show", defaults: fixture.defaults)?.audio?.title, "Spanish · AAC")

        controller.remembersTracks(forShow: "the show")
        controller.start(urls: [Fixture.url], isLive: false, expectedDuration: 3_600)
        XCTAssertEqual(backend.openingLanguages.audio, ["es"])
        backend.audioTracks = tracks
        backend.selectedAudioIndex = 1
        controller.checkPlayback()
        XCTAssertEqual(backend.selectedAudioIndex, 2, "The kept track, found by its name")
    }

    /// Subtitle timing goes to the engine at once, in quarter seconds, and
    /// starts again at zero for the next title.
    func testSubtitleTimingIsTheTitlesOwn() throws {
        let fixture = try Fixture(.aether)
        defer { fixture.clean() }
        let controller = fixture.controller()
        defer { controller.stop() }
        let backend = fixture.backend(.aether)
        controller.start(urls: [Fixture.url], isLive: false, expectedDuration: 3_600)
        controller.setSubtitleDelay(1.3)
        XCTAssertEqual(controller.subtitleDelaySeconds, 1.25)
        XCTAssertEqual(backend.subtitleStyle.delay, 1.25)
        controller.start(urls: [Fixture.url], isLive: false, expectedDuration: 3_600)
        XCTAssertEqual(controller.subtitleDelaySeconds, 0)
        XCTAssertEqual(backend.subtitleStyle.delay, 0)
    }

    /// The live stats hold back by the viewer's own pauses: a live channel
    /// paused and played on from its buffer stays that far behind, until it
    /// goes live again.
    func testAPauseOnALiveChannelHoldsTheStatsBackUntilItGoesLive() throws {
        let fixture = try Fixture(.vlc)
        defer { fixture.clean() }
        let controller = fixture.controller()
        defer { controller.stop() }
        controller.start(urls: [Fixture.url], isLive: true)
        XCTAssertEqual(controller.secondsBehindLive, 0)
        controller.togglePlayback()
        Thread.sleep(forTimeInterval: 0.05)
        let paused = controller.secondsBehindLive
        XCTAssertGreaterThanOrEqual(paused, 0.05)
        controller.togglePlayback()
        XCTAssertGreaterThanOrEqual(controller.secondsBehindLive, paused)
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertLessThan(controller.secondsBehindLive, paused + 0.04, "Playing, it falls no further behind")
        controller.goLive()
        XCTAssertEqual(controller.secondsBehindLive, 0)
    }

    @MainActor private final class Fixture {
        static let url = URL(string: "https://example.invalid/movie.mkv")!
        let suite = "PlaybackEngineTests.\(UUID())"
        let defaults: UserDefaults
        let vlc = MockTVBackend(.vlc)
        let aether = MockTVBackend(.aether)
        let mpv = MockTVBackend(.mpv)
        var now: TimeInterval = 1_000
        init(_ kind: TVPlaybackEngine = .vlc) throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set(kind.rawValue, forKey: TVPlaybackEngine.storageKey)
        }
        func clean() { defaults.removePersistentDomain(forName: suite) }
        func backend(_ kind: TVPlaybackEngine) -> MockTVBackend {
            switch kind {
            case .vlc: vlc
            case .aether: aether
            case .mpv: mpv
            }
        }
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
    var mediaInfo = PlaybackMediaInfo()
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
    var onLoad: (() -> Void)?
    var seeks: [TimeInterval] = []
    init(_ kind: TVPlaybackEngine) { self.kind = kind }
    func load(url: URL, startPosition: TimeInterval?, isLive: Bool, expectedDuration: TimeInterval?, primary: Bool, matchContent: Bool) {
        mediaInfo = PlaybackMediaInfo()
        loads.append(.init(startPosition: startPosition, isLive: isLive, expectedDuration: expectedDuration,
                           primary: primary, matchContent: matchContent))
        isOpen = true
        time = startPosition ?? 0
        selectedAudioIndex = nil
        selectedSubtitleIndex = nil
        onLoad?()
    }
    func play() { state = .playing }
    func pause() { state = .paused }
    func stop() { state = .stopped; isOpen = false }
    func seek(to seconds: TimeInterval) { seeks.append(seconds); time = seconds }
    func selectSubtitle(index: Int?) { selectedSubtitleIndex = index }
    func selectAudio(index: Int) { selectedAudioIndex = index }
    func selectVideo(index: Int) { selectedVideoIndex = index }
    func captureFrame() async -> CapturedVideoFrame? { nil }
    func releaseFrameOutput() {}
    var openingLanguages = PlaybackLanguages()
    var subtitleStyle = PlaybackSubtitleStyle()
    var addedSubtitles: [URL] = []
    func setOpeningLanguages(_ languages: PlaybackLanguages) { openingLanguages = languages }
    func styleSubtitles(_ style: PlaybackSubtitleStyle) { subtitleStyle = style }
    func addSubtitle(file: URL, title: String, language: String) -> Bool { addedSubtitles.append(file); return true }
}

private final class TVSiloRetryProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var starts = 0
    static var startCount: Int { lock.lock(); defer { lock.unlock() }; return starts }
    static func reset() { lock.lock(); defer { lock.unlock() }; starts = 0 }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "tvos-silo-retry.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let body: String
        var status = 200
        if path.hasSuffix("/capabilities") {
            body = #"{"protocol_versions":[3],"features":["playback_plan_v3","seek_reanchor_v1"],"deliveries":["server_remux_hls"],"installation_id":"installation:1","state":"available","allowed":true}"#
        } else if path.hasSuffix("/start") {
            Self.lock.lock(); Self.starts += 1; let number = Self.starts; Self.lock.unlock()
            if number == 1 {
                status = 201
                body = #"{"protocol_version":3,"outcome":"playable","session_id":"session:1","playback_plan":{"plan_id":"plan:1","plan_attempt_key":"v3:fixture","delivery":"server_remux_hls","stream":{"url":"/api/v2/playback/transcode/session:1/master.m3u8","headers":{},"header_refresh":"none"},"timeline":{"source_start_seconds":600,"player_start_seconds":2,"timeline_offset_seconds":598,"can_seek_anywhere":false},"selected_tracks":{},"source":{"duration_seconds":3600}}}"#
            } else { status = 503; body = "{}" }
        } else if request.httpMethod == "DELETE" { body = #"{"outcome":"stopped"}"# }
        else { status = 404; body = "{}" }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
