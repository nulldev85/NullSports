import XCTest
import AVFoundation
import UIKit
@testable import LineupiOS

/// The lifecycle rules that used to live as a `scenePhase` branch in each of the
/// three player surfaces. Pulling them into `MobileBackgroundPolicy` is what
/// makes them checkable without a device.
final class PlaybackPolicyTests: XCTestCase {
    func testLiveKeepsAConfirmedTransportFirstWhileLibraryStillUsesItsExistingPiPOrder() {
        let ts = URL(string: "https://example.test/confirmed.ts")!
        let hls = URL(string: "https://example.test/other.m3u8")!
        XCTAssertEqual(MobileEngineSelection.ordered([ts, hls], live: true), [ts, hls])
        XCTAssertEqual(MobileEngineSelection.ordered([hls, ts], live: true), [hls, ts])
        XCTAssertEqual(MobileEngineSelection.ordered([ts, hls]), [hls, ts])
    }
    func testSlowMovieOpeningIsNotAStoppedStreamBeforeTheStartupBudget() {
        for age in [0.0, 2, 8, 29.9] {
            XCTAssertFalse(MobilePlaybackOpeningPolicy.stoppedIsFailure(isLive: false, hasShownPicture: false, age: age))
        }
        XCTAssertTrue(MobilePlaybackOpeningPolicy.stoppedIsFailure(isLive: false, hasShownPicture: false, age: 30))
        XCTAssertFalse(MobilePlaybackOpeningPolicy.stoppedIsFailure(isLive: true, hasShownPicture: false, age: 7.9))
        XCTAssertTrue(MobilePlaybackOpeningPolicy.stoppedIsFailure(isLive: true, hasShownPicture: false, age: 8))
        XCTAssertTrue(MobilePlaybackOpeningPolicy.stoppedIsFailure(isLive: false, hasShownPicture: true, age: 2))
    }

    func testVLCStartupNeedsAnActualPictureEvenAfterTheShapeDeadline() {
        XCTAssertFalse(StartTogether.canRevealVLC(displayedPictures: 0, settled: false, outputAge: 30))
        XCTAssertFalse(StartTogether.canRevealVLC(displayedPictures: 0, settled: true, outputAge: 30))
        XCTAssertFalse(StartTogether.canRevealVLC(displayedPictures: 1, settled: false, outputAge: 0.4))
        XCTAssertTrue(StartTogether.canRevealVLC(displayedPictures: 1, settled: false, outputAge: 2.1))
        XCTAssertTrue(StartTogether.canRevealVLC(displayedPictures: 4, settled: true, outputAge: 0.4))
    }

    func testAudioOnlyFallbackCannotReleaseSoundForAKnownVideoTrack() {
        XCTAssertFalse(StartTogether.canReleaseAudioOnly(heldFor: 20, hasAudio: true, hasVideo: true))
        XCTAssertFalse(StartTogether.canReleaseAudioOnly(heldFor: 20, hasAudio: false, hasVideo: false))
        XCTAssertFalse(StartTogether.canReleaseAudioOnly(heldFor: 5, hasAudio: true, hasVideo: false))
        XCTAssertTrue(StartTogether.canReleaseAudioOnly(heldFor: 6, hasAudio: true, hasVideo: false))
    }

    func testBufferingAndRecoveryLabelsRetainTheCurrentTitlesPresentationHistory() {
        var state = MobilePlaybackPresentation()
        XCTAssertEqual(state.loadingMessage(waitingForPicture: false), "Opening stream…")
        XCTAssertEqual(state.loadingMessage(waitingForPicture: true), "Waiting for picture…")
        state.presentedVideo()
        XCTAssertEqual(state.loadingMessage(waitingForPicture: false), "Buffering…")
        state.beganRecovery()
        XCTAssertEqual(state.loadingMessage(waitingForPicture: false), "Reconnecting…")
        state.presentedVideo()
        XCTAssertEqual(state.loadingMessage(waitingForPicture: true), "Buffering…")
        state = MobilePlaybackPresentation()
        XCTAssertEqual(state.loadingMessage(waitingForPicture: false), "Opening stream…")
    }

    func testSettingsExposeVersionsForPackagedPlaybackEngines() {
        XCTAssertNil(MobilePlaybackPreference.native.version)
        XCTAssertEqual(MobilePlaybackPreference.aether.version, "7.45.0")
        XCTAssertEqual(MobilePlaybackPreference.vlc.version, "3.6.0")
        XCTAssertEqual(MobilePlaybackPreference.mpv.version, "1.1.0-n9.0.2")
    }

    private func action(background: Bool, pip: Bool = false, paused: Bool = false,
                        backgroundAudio: Bool = true) -> MobilePlaybackPhaseAction {
        MobileBackgroundPolicy.action(enteringBackground: background,
                                      pictureInPictureActive: pip,
                                      pausedByUser: paused,
                                      backgroundAudioEnabled: backgroundAudio)
    }

    /// The regression this change exists to prevent: every surface used to call
    /// `suspend()` here, and Live tore the stream down entirely.
    func testBackgroundingAloneNeverStopsPlayback() {
        XCTAssertEqual(action(background: true), .keepPlaying)
    }

    func testPictureInPictureKeepsPlayingWhileBackgrounded() {
        XCTAssertEqual(action(background: true, pip: true), .keepPlaying)
        // PiP holds the app alive on its own, so it outranks a missing key.
        XCTAssertEqual(action(background: true, pip: true, backgroundAudio: false), .keepPlaying)
    }

    func testAManualPauseSurvivesEveryTransition() {
        XCTAssertEqual(action(background: true, paused: true), .leaveAsIs)
        XCTAssertEqual(action(background: false, paused: true), .leaveAsIs)
        XCTAssertEqual(action(background: true, pip: true, paused: true), .leaveAsIs)
    }

    func testReturningToTheAppResumes() {
        XCTAssertEqual(action(background: false), .keepPlaying)
        XCTAssertEqual(action(background: false, backgroundAudio: false), .keepPlaying)
    }

    /// Without the background mode iOS suspends the process anyway, so a clean
    /// pause beats being killed mid-buffer.
    func testMissingBackgroundModeDegradesToAPause() {
        XCTAssertEqual(action(background: true, backgroundAudio: false), .pause)
    }

    /// The shipped bundle must actually carry the key the policy depends on.
    @MainActor
    func testBundleDeclaresTheAudioBackgroundMode() {
        XCTAssertTrue(MobilePlaybackController.backgroundAudioEnabled,
                      "LineupiOS must declare UIBackgroundModes: audio or background playback silently stops")
    }

    // MARK: - System engine watchdog

    private func verdict(_ elapsed: TimeInterval, ready: Bool, video: Bool) -> SystemEngineWatchdog.Verdict {
        SystemEngineWatchdog.verdict(elapsed: elapsed, isReady: ready, hasVideo: video)
    }

    /// A working stream is never interrupted, however long it runs.
    func testAHealthyStreamIsNeverFailedOver() {
        XCTAssertEqual(verdict(0, ready: true, video: true), .wait)
        XCTAssertEqual(verdict(3600, ready: true, video: true), .wait)
    }

    /// The captured failure: a dead HLS endpoint leaves the item at `.unknown`
    /// with no error, so nothing else in the controller can notice. Eighteen
    /// seconds of that, with a good transport stream queued and never tried.
    func testAnItemThatNeverLoadsFallsOverToTheNextCandidate() {
        XCTAssertEqual(verdict(1, ready: false, video: false), .wait)
        XCTAssertEqual(verdict(7.9, ready: false, video: false), .wait)
        XCTAssertEqual(verdict(8.1, ready: false, video: false), .failOver)
        XCTAssertEqual(SystemEngineWatchdog.readyDeadline, 8)
    }

    /// Ready but blank gets longer, because the server did answer — and then
    /// still falls over, which is the 0.17.8 rule the AVPlayer path never had.
    func testReadyWithoutAPictureEventuallyFallsOverToo() {
        XCTAssertEqual(verdict(9, ready: true, video: false), .wait)
        XCTAssertEqual(verdict(12.1, ready: true, video: false), .failOver)
        XCTAssertGreaterThan(SystemEngineWatchdog.videoDeadline, SystemEngineWatchdog.readyDeadline)
    }

    // MARK: - Starting together

    /// A picture is moving once new frames keep arriving close together; one
    /// frame and then a wait is a held picture, and the count starts again.
    func testOnlyARunOfNewFramesCountsAsAMovingPicture() {
        XCTAssertEqual(StartTogether.frames(after: 0, lastFrameAt: nil, now: 10), 1)
        XCTAssertEqual(StartTogether.frames(after: 1, lastFrameAt: 10, now: 10.04), 2)
        XCTAssertEqual(StartTogether.frames(after: 2, lastFrameAt: 10, now: 10.6), 1)
        XCTAssertGreaterThanOrEqual(StartTogether.framesToStart, 2)
    }

    /// The reported case: a live game's sound running over a frozen picture.
    /// Held a moment, then the channel's other stream is tried -- but never
    /// for a title, and never with nothing else to try.
    func testAHeldLiveStartMovesOnToTheChannelsOtherStream() {
        XCTAssertFalse(StartTogether.shouldTryNext(heldFor: nil, isLive: true, hasAnotherStream: true))
        XCTAssertFalse(StartTogether.shouldTryNext(heldFor: 3.9, isLive: true, hasAnotherStream: true))
        XCTAssertTrue(StartTogether.shouldTryNext(heldFor: 4.1, isLive: true, hasAnotherStream: true))
        XCTAssertFalse(StartTogether.shouldTryNext(heldFor: 30, isLive: true, hasAnotherStream: false))
        XCTAssertFalse(StartTogether.shouldTryNext(heldFor: 30, isLive: false, hasAnotherStream: true))
        XCTAssertLessThan(StartTogether.stillPictureDeadline, SystemEngineWatchdog.videoDeadline)
    }

    // MARK: - Engine selection

    private let hls = URL(string: "http://example.com/live/u/p/1234.m3u8")!
    private let ts = URL(string: "http://example.com/live/u/p/1234.ts")!

    func testHLSGoesToAVPlayerAndOtherSourcesToAether() {
        XCTAssertEqual(MobileEngineSelection.engine(for: hls), .system)
        XCTAssertEqual(MobileEngineSelection.engine(for: ts), .aether)
        // Providers append tokens; the query string is not part of the path.
        XCTAssertEqual(MobileEngineSelection.engine(for: URL(string: "http://e.com/a/1.m3u8?t=9")!), .system)
    }

    /// The phone reverses Apple TV's transport-stream-first order so that the
    /// PiP-capable endpoint is tried first — with the transport stream still
    /// queued behind it as the fallback, which is what keeps recovery working.
    func testHLSIsPreferredButTheTransportStreamStaysAsFallback() {
        XCTAssertEqual(MobileEngineSelection.ordered([ts, hls]), [hls, ts])
        XCTAssertEqual(MobileEngineSelection.ordered([ts]), [ts])
        XCTAssertTrue(MobileEngineSelection.canPictureInPicture([ts, hls]))
        XCTAssertTrue(MobileEngineSelection.canPictureInPicture([ts]))
    }

    func testVODAndExtensionlessServerRoutesUsePiPCapablePlayback() {
        for path in ["movie.mp4", "movie.mkv", "movie.avi", "videos/123/stream", "timeshift.php?token=1"] {
            let url = URL(string: "https://server.invalid/\(path)")!
            XCTAssertEqual(MobileEngineSelection.engine(for: url), .aether)
            XCTAssertTrue(MobileEngineSelection.canPictureInPicture([url]))
        }
    }

    func testExplicitPreferencesAndFailureFallbackAreBounded() {
        XCTAssertEqual(MobileEngineSelection.engine(for: hls, preference: .aether), .aether)
        XCTAssertEqual(MobileEngineSelection.engine(for: hls, preference: .vlc), .vlc)
        XCTAssertEqual(MobileEngineSelection.engine(for: hls, preference: .mpv), .mpv)
        XCTAssertEqual(MobileEngineSelection.engine(for: ts, preference: .mpv, failed: [.mpv]), .aether)
        XCTAssertEqual(MobileEngineSelection.engine(for: ts, preference: .mpv, failed: [.mpv, .aether]), .vlc)
        XCTAssertFalse(MobileStreamEngine.mpv.supportsPictureInPicture)
        XCTAssertEqual(MobilePlaybackPreference.mpv.title, "MPVKit (Trial)")
        XCTAssertFalse(MobileEngineSelection.canPictureInPicture([ts], preference: .vlc))
        XCTAssertEqual(MobileEngineSelection.engine(for: hls, failed: [.system]), .aether)
        XCTAssertEqual(MobileEngineSelection.engine(for: hls, failed: [.system, .aether]), .vlc)
        XCTAssertNil(MobileEngineSelection.engine(for: hls, failed: [.system, .aether, .vlc]))
        XCTAssertEqual(MobileEngineSelection.engine(for: ts, failed: [.aether]), .vlc)
        XCTAssertNil(MobileEngineSelection.engine(for: ts, preference: .vlc, failed: [.vlc]))
    }

    func testPlayerPreferencePersistsAndLegacyAutomaticMigratesToNative() throws {
        let suite = "PlayerPreference.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(MobilePlaybackPreference.selected(in: defaults), .native)
        defaults.set("automatic", forKey: MobilePlaybackPreference.storageKey)
        XCTAssertEqual(MobilePlaybackPreference.selected(in: defaults), .native)
        defaults.set("mpv", forKey: MobilePlaybackPreference.storageKey)
        XCTAssertEqual(MobilePlaybackPreference.selected(in: defaults), .mpv)
        defaults.set("aether", forKey: MobilePlaybackPreference.storageKey)
        XCTAssertEqual(MobilePlaybackPreference.selected(in: defaults), .aether)
        defaults.set("old-or-unknown", forKey: MobilePlaybackPreference.storageKey)
        XCTAssertEqual(MobilePlaybackPreference.selected(in: defaults), .native)
    }

    func testNativeChoiceKeepsItsCompatibilityLayerAndMakesDecoderFallbackExplicit() throws {
        XCTAssertEqual(MobilePlaybackPreference.allCases, [.native, .aether, .vlc, .mpv])
        let hls = URL(string: "https://fixture.test/video.m3u8")!
        let mkv = URL(string: "https://fixture.test/video.mkv")!
        XCTAssertEqual(MobileEngineSelection.engine(for: hls, preference: .native), .system)
        XCTAssertEqual(MobileEngineSelection.engine(for: mkv, preference: .native), .aether)
        XCTAssertEqual(MobileEngineSelection.engine(for: hls, preference: .native, failed: [.system], nativeFallback: false), .aether)
        XCTAssertNil(MobileEngineSelection.engine(for: hls, preference: .native, failed: [.system, .aether], nativeFallback: false))
        XCTAssertEqual(MobileEngineSelection.engine(for: mkv, preference: .native, failed: [.aether], nativeFallback: true), .vlc)
        let suite = "NativeFallback." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(MobilePlaybackPreference.allowsNativeFallback(in: defaults))
        defaults.set(false, forKey: MobilePlaybackPreference.nativeFallbackKey)
        XCTAssertFalse(MobilePlaybackPreference.allowsNativeFallback(in: defaults))
        XCTAssertEqual(MobileEngineSelection.engine(for: mkv, preference: .vlc), .vlc)
    }

    // MARK: - Surface reuse

    /// Resizing, expanding, collapsing and rotating all re-run attachment. None
    /// of them may hand back a new layer: the PiP controller is built on the
    /// layer, so replacing it would drop PiP and restart the stream.
    @MainActor
    func testResizingReusesTheSamePlayerLayer() {
        let controller = MobilePlaybackController()
        let host = MobileVideoHost(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let first = host.installPlayerLayer(for: controller.systemPlayer)
        host.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        host.layoutIfNeeded()
        let second = host.installPlayerLayer(for: controller.systemPlayer)
        XCTAssertTrue(first === second, "A resize must not replace the AVPlayerLayer")
        XCTAssertTrue(second.player === controller.systemPlayer)
        XCTAssertEqual(second.frame, host.bounds, "The layer follows the host without an implicit animation")
        controller.shutdown()
    }

    /// Falling back from HLS to a transport stream swaps engines in place; the
    /// abandoned layer must not stay on screen over VLC's renderer.
    @MainActor
    func testRemovingThePlayerLayerReleasesThePlayer() {
        let controller = MobilePlaybackController()
        let host = MobileVideoHost(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        host.installPlayerLayer(for: controller.systemPlayer)
        XCTAssertNotNil(host.playerLayer)
        host.removePlayerLayer()
        XCTAssertNil(host.playerLayer)
        controller.shutdown()
    }

    @MainActor
    func testPiPHandoffKeepsTheOriginalLayerAndPlayer() {
        let controller = MobilePlaybackController()
        let original = MobileVideoHost(frame: CGRect(x: 0, y: 0, width: 390, height: 220))
        let layer = original.installPlayerLayer(for: controller.systemPlayer)
        original.releasePlayerLayerForPictureInPicture()
        XCTAssertNil(original.playerLayer)
        XCTAssertTrue(layer.player === controller.systemPlayer)
        let returned = MobileVideoHost(frame: CGRect(x: 0, y: 0, width: 700, height: 394))
        XCTAssertTrue(returned.installPlayerLayer(for: controller.systemPlayer, reusing: layer) === layer)
        original.removePlayerLayer()
        XCTAssertTrue(layer.player === controller.systemPlayer)
        XCTAssertTrue(layer.superlayer === returned.layer)
        controller.shutdown()
    }

    /// Both engines exist for the whole session, so a channel change or an
    /// engine fallback never constructs a second player.
    @MainActor
    func testControllerKeepsOneInstanceOfEachEngine() {
        let controller = MobilePlaybackController()
        let vlc = controller.player
        let system = controller.systemPlayer
        controller.handleScenePhase(active: false)
        controller.handleScenePhase(active: true)
        XCTAssertTrue(controller.player === vlc)
        XCTAssertTrue(controller.systemPlayer === system)
        controller.shutdown()
    }
}
