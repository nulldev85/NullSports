import XCTest
import UIKit
import LineupAetherPlayback
@testable import Lineup

/// Real decoders, generated video/audio/subtitles, and no network account.
/// Controller policy tests above also cover failure and retry deterministically.
@MainActor
final class PlaybackBackendIntegrationTests: XCTestCase {
    func testBoundedSourceProbeReportsGeneratedVideoDimensions() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback", withExtension: "mkv", subdirectory: "Fixtures"))
        let quality = try await AetherSourceProbe.quality(url: fixture, timeout: 5)
        XCTAssertEqual(quality.width, 320)
        XCTAssertEqual(quality.height, 180)
        // Aether 7.49.0 SourceProbe.videoFrameRate is display-normalized,
        // and FrameRateSnap keeps an exact 24 fps source at 24 (AE#884).
        XCTAssertEqual(try XCTUnwrap(quality.frameRate), 24, accuracy: 0.0001)
    }

    func testVLCAndAetherAndMPVKitRenderSeekSelectTracksAndReachTheEnd() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback", withExtension: "mkv",
                                                              subdirectory: "Fixtures"))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKey() }

        for kind in TVPlaybackEngine.allCases {
            let backend = makeTVPlaybackBackend(kind)
            defer { backend.stop(); backend.surface.removeFromSuperview() }
            backend.surface.frame = host.view.bounds
            backend.surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.view.addSubview(backend.surface)
            backend.isMuted = true
            backend.volume = 100
            backend.load(url: fixture, startPosition: nil, isLive: false,
                         expectedDuration: 12, primary: false, matchContent: false)
            backend.play()
            try await waitUntil("\(kind.title) did not show a picture: \(backend.errorMessage ?? "no error")") {
                backend.isPlaying && backend.hasVideoOut && backend.time > 0.2
            }
            XCTAssertEqual(backend.kind.title, kind.title)
            try await waitUntil("\(kind.title) did not expose the actual video/audio formats " +
                                "(video=\(backend.mediaInfo.videoCodec ?? "nil"), " +
                                "audio=\(backend.mediaInfo.audioCodec ?? "nil"), " +
                                "badges=\(backend.mediaInfo.badges))") {
                backend.mediaInfo.badges.contains("H.264") && backend.mediaInfo.badges.contains("AAC")
            }
            XCTAssertNil(backend.mediaInfo.dynamicRange)
            XCTAssertFalse(backend.mediaInfo.isDolbyAtmos)
            XCTAssertEqual(backend.duration, 12, accuracy: 0.75)
            try await waitUntil("\(kind.title) did not expose both audio tracks") { backend.audioTracks.count == 2 }
            let audio = try XCTUnwrap(backend.audioTracks.last)
            backend.selectAudio(index: audio.id)
            try await waitUntil("\(kind.title) did not select the second audio track") {
                backend.selectedAudioIndex == audio.id && backend.isPlaying && backend.hasVideoOut
            }
            try await waitUntil("\(kind.title) did not expose timed subtitles") { backend.subtitles.count > 1 }
            let subtitles = try XCTUnwrap(backend.subtitles.last?.engineIndex)
            backend.selectSubtitle(index: subtitles)
            try await waitUntil("\(kind.title) did not select subtitles") { backend.selectedSubtitleIndex == subtitles }

            backend.pause()
            try await waitUntil("\(kind.title) did not pause") { backend.state == .paused }
            let paused = backend.time
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(backend.time, paused, accuracy: 0.3)
            try await waitUntil("\(kind.title) did not become seekable") { backend.isSeekable }
            backend.seek(to: 6)
            backend.play()
            try await waitUntil("\(kind.title) did not play forward from the seek") { backend.time >= 6.5 && backend.isPlaying }
            if kind == .aether {
                try await waitUntil("AetherEngine did not render the selected subtitle cue") {
                    self.subtitleText(in: backend.surface).contains("Subtitles and resume work together")
                }
            }
            backend.isMuted = false
            XCTAssertFalse(backend.isMuted)
            backend.isMuted = true
            XCTAssertTrue(backend.isMuted)

            let label = UILabel(frame: CGRect(x: 60, y: 45, width: 600, height: 60))
            label.text = "Playback engine: \(backend.kind.title)"
            label.textColor = .white
            label.font = .systemFont(ofSize: 30, weight: .bold)
            label.backgroundColor = UIColor.black.withAlphaComponent(0.6)
            host.view.addSubview(label)
            defer { label.removeFromSuperview() }
            let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = "Actual-\(backend.kind.title)-Playback"
            attachment.lifetime = .keepAlways
            add(attachment)
            try await waitUntil("\(kind.title) did not report natural completion") { backend.state == .ended }
            XCTAssertGreaterThan(backend.time, 10)
            backend.stop()
            XCTAssertFalse(backend.isOpen)
            XCTAssertFalse(backend.isSeekable)
        }
    }

    func testAetherStopAndRetuneCannotResurrectTheOldLoad() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback", withExtension: "mkv",
                                                              subdirectory: "Fixtures"))
        let backend = TVAetherBackend()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        backend.surface.frame = host.view.bounds
        host.view.addSubview(backend.surface)
        defer { backend.stop(); window.isHidden = true; previousWindow?.makeKey() }
        backend.load(url: fixture, startPosition: 2, isLive: false,
                     expectedDuration: 12, primary: false, matchContent: false)
        backend.stop()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(backend.isOpen)
        XCTAssertFalse(backend.isPlaying)
        backend.load(url: fixture, startPosition: 6, isLive: false,
                     expectedDuration: 12, primary: false, matchContent: false)
        backend.play()
        try await waitUntil("AetherEngine did not resume the replacement session") {
            backend.isPlaying && backend.hasVideoOut && backend.time >= 6
        }
        XCTAssertEqual(backend.kind.title, "AetherEngine")
    }

    private func subtitleText(in view: UIView) -> String {
        ([ (view as? UILabel)?.text ?? "" ] + view.subviews.map { subtitleText(in: $0) }).joined(separator: "\n")
    }

    private func waitUntil(_ message: @autoclosure () -> String, timeout: TimeInterval = 40,
                           condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(condition(), message())
        if !condition() { throw NSError(domain: "PlaybackBackendIntegrationTests", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: message()]) }
    }
}
