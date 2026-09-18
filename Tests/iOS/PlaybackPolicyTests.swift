import XCTest
import AVFoundation
import UIKit
@testable import LineupiOS

/// The lifecycle rules that used to live as a `scenePhase` branch in each of the
/// three player surfaces. Pulling them into `MobileBackgroundPolicy` is what
/// makes them checkable without a device.
final class PlaybackPolicyTests: XCTestCase {
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

    // MARK: - Engine selection

    private let hls = URL(string: "http://example.com/live/u/p/1234.m3u8")!
    private let ts = URL(string: "http://example.com/live/u/p/1234.ts")!

    func testHLSGoesToAVPlayerAndTransportStreamsToVLC() {
        XCTAssertEqual(MobileEngineSelection.engine(for: hls), .system)
        XCTAssertEqual(MobileEngineSelection.engine(for: ts), .vlc)
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
        XCTAssertFalse(MobileEngineSelection.canPictureInPicture([ts]))
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

    /// The regression behind "audio starts immediately, video arrives seconds
    /// later": the surfaces are built by SwiftUI *after* `start(urls:)` runs, so
    /// opening a stream must queue behind its video host rather than playing
    /// blind. AVPlayer without a layer, like VLC without a drawable, produces
    /// audio and no picture.
    @MainActor
    func testOpeningAStreamWaitsForItsVideoSurface() {
        let controller = MobilePlaybackController()
        // No host attached yet, exactly as when a channel is first selected.
        controller.start(urls: [URL(string: "http://example.invalid/live/u/p/1.m3u8")!])
        XCTAssertTrue(controller.isAwaitingVideoSurface,
                      "Playback must not begin before there is somewhere to draw")
        XCTAssertEqual(controller.systemPlayer.rate, 0,
                       "The system engine must not be playing audio into a missing layer")
        XCTAssertFalse(controller.isPlaying)
        controller.shutdown()
    }

    /// The same gate for the VLC engine, which is where this discipline began.
    @MainActor
    func testATransportStreamAlsoWaitsForItsDrawable() {
        let controller = MobilePlaybackController()
        controller.start(urls: [URL(string: "http://example.invalid/live/u/p/1.ts")!])
        XCTAssertTrue(controller.isAwaitingVideoSurface)
        XCTAssertNil(controller.player.drawable, "VLC gets no drawable until one is mounted")
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
