import XCTest
import AVKit
import Combine
import LineupAetherPlayback
@testable import LineupiOS

@MainActor
final class AetherPlaybackTests: XCTestCase {
    func testSourceQualityDeadlineClosesARealHTTPOriginThatNeverSendsHeaders() async throws {
        let ready = expectation(description: "stalled local origin is ready")
        let requested = expectation(description: "probe reached the stalled origin")
        let file = try fixture("playback-native", "mp4")
        let origin = try PlaybackFixtureServer(file: file, contentType: "video/mp4",
            stallsBeforeHeaders: true, onReady: { ready.fulfill() }, onStalledRequest: { requested.fulfill() })
        defer { origin.stop() }
        await fulfillment(of: [ready], timeout: 5)
        let url = try XCTUnwrap(origin.url(path: "stalled-quality"))
        let began = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await AetherSourceProbe.quality(url: url, timeout: LiveQualityVerifier.perURLBudget)
            XCTFail("An origin that never sends headers cannot supply video dimensions")
        } catch {
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 4,
                "The native probe must close on its deadline, not wait for a normal HTTP timeout")
        }
        await fulfillment(of: [requested], timeout: 5)
    }

    func testSourceProbeMeasuresVideoRatherThanTheFHDChannelName() async throws {
        let file = try fixture("playback-native", "mp4")
        let origin = try PlaybackFixtureServer(file: file, contentType: "video/mp4")
        defer { origin.stop() }
        try await waitUntil("Local probe origin did not become ready") { origin.port != nil }
        let url = try XCTUnwrap(origin.url(path: "live/FHD-channel"))
        let quality = try await AetherSourceProbe.quality(url: url, timeout: 5)
        XCTAssertEqual(quality.width, 320)
        XCTAssertEqual(quality.height, 180)
        // Aether 7.36.0 SourceProbe.videoFrameRate is display-normalized:
        // FrameRateSnap maps even an exact 24 fps source to 23.976.
        XCTAssertEqual(try XCTUnwrap(quality.frameRate), 23.976, accuracy: 0.0001)
    }

    func testLocalOriginServesRangesOnlyAfterARealPortIsReady() async throws {
        let file = try fixture("playback-native", "mp4")
        let origin = try PlaybackFixtureServer(file: file, contentType: "video/mp4")
        defer { origin.stop() }
        try await waitUntil("Local media origin did not become ready") { origin.port != nil }
        let url = try XCTUnwrap(origin.url(path: "Videos/title/stream"))
        XCTAssertGreaterThan(try XCTUnwrap(url.port), 0)
        var request = URLRequest(url: url)
        request.setValue("bytes=0-187", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(data, Data(try Data(contentsOf: file).prefix(188)))
        let media = try Data(contentsOf: file)
        for (range, expected) in [
            ("bytes=-65536", (media.count - 65_536)..<media.count),
            ("bytes=188-", 188..<media.count)
        ] {
            request.setValue(range, forHTTPHeaderField: "Range")
            let (body, reply) = try await URLSession.shared.data(for: request)
            let http = try XCTUnwrap(reply as? HTTPURLResponse)
            XCTAssertEqual(http.statusCode, 206)
            XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Range"),
                           "bytes \(expected.lowerBound)-\(expected.upperBound - 1)/\(media.count)")
            XCTAssertEqual(body, media.subdata(in: expected))
        }
        request.setValue("bytes=\(media.count)-", forHTTPHeaderField: "Range")
        let (empty, invalid) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((invalid as? HTTPURLResponse)?.statusCode, 416)
        XCTAssertEqual((invalid as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"), "bytes */\(media.count)")
        XCTAssertTrue(empty.isEmpty)
    }

    func testMP4AndSoftwareMKVExposePiPSourcesAndKeepResumeAndSubtitles() async throws {
        for (name, ext, contentType, route) in [
            ("playback-native", "mp4", "video/mp4", "Native"),
            ("playback-software", "mkv", "video/x-matroska", "Sample buffer")
        ] {
            let file = try fixture(name, ext)
            let origin = try PlaybackFixtureServer(file: file, contentType: contentType)
            defer { origin.stop() }
            try await waitUntil("Local media origin did not start") { origin.port != nil }
            // Deliberately omit the extension, like a Nullfin/Jellyfin route.
            let url = try XCTUnwrap(origin.url(path: "Videos/title/stream?mediaSourceId=fixture"))
            let (defaults, suite) = try preferences(.automatic)
            defer { defaults.removePersistentDomain(forName: suite) }
            let controller = MobilePlaybackController(defaults: defaults)
            let (window, host, previous) = try show(controller)
            defer { controller.shutdown(); window.isHidden = true; previous?.makeKey() }
            controller.isLive = false
            controller.start(urls: [url], initialPosition: 10)
            guard await waitForRenderedPicture(controller, route: route) else { return }
            let session = try XCTUnwrap(controller.aetherSession)
            try await waitUntil("Selected-source audio metadata was not reported") {
                controller.mediaInfo.badges.contains("AAC")
            }
            XCTAssertNil(controller.mediaInfo.dynamicRange, "The SDR fixture must not be labeled HDR")
            XCTAssertFalse(controller.mediaInfo.isDolbyAtmos, "AAC is not Dolby Atmos")
            assertPiPSource(session, expectedOnDevice: route)
            XCTAssertEqual(controller.engineTitle, "AetherEngine")
            XCTAssertGreaterThanOrEqual(controller.progress?.position ?? 0, 9)
            XCTAssertEqual(controller.progress?.duration ?? 0, 36, accuracy: 1)
            let surface = session.surface
            host.frame.size = CGSize(width: 700, height: 394)
            host.layoutIfNeeded()
            controller.attachVideo(host)
            XCTAssertTrue(controller.aetherSession?.surface === surface)
            try await waitUntil("Embedded subtitles were not discovered") { controller.subtitleTracks.count > 1 }
            controller.selectSubtitle(try XCTUnwrap(controller.subtitleTracks.last))
            controller.toggle()
            let paused = try await pausedClock(controller, session: session)
            let subtitleSession = controller.subtitleSessionID
            let online = Data("1\n00:00:00,000 --> 00:00:35,000\nOnline fixture caption\n".utf8)
            try await controller.addOnlineSubtitle(online, title: "Online fixture", language: "en", sessionID: subtitleSession)
            try await waitUntil("The added sidecar must be a selectable engine track") {
                controller.subtitleTracks.contains { $0.title.contains("Online fixture") && $0.id == controller.selectedSubtitleID }
            }
            let caption = {
                surface.subviews.compactMap { $0 as? UILabel }.first {
                    $0.attributedText?.string.contains("Online fixture caption") == true
                }
            }
            try await waitUntil("The selected sidecar must actually render its caption while paused") { caption() != nil }
            surface.layoutIfNeeded()
            let originalFont = try XCTUnwrap(caption()?.attributedText?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
            var appearance = controller.subtitlePreferences
            appearance.scale = 1.5; appearance.background = true
            controller.setSubtitlePreferences(appearance)
            let larger = try XCTUnwrap(caption()?.attributedText?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
            XCTAssertEqual(larger.pointSize, originalFont.pointSize * 1.5, accuracy: 0.1)
            XCTAssertNotNil(caption()?.attributedText?.attribute(.backgroundColor, at: 0, effectiveRange: nil))
            controller.setSubtitleDelay(30)
            XCTAssertNil(caption(), "A delayed cue outside its interval must disappear without seeking the video")
            controller.setSubtitleDelay(0)
            XCTAssertNotNil(caption())
            XCTAssertTrue(controller.aetherSession === session)
            XCTAssertTrue(session.surface === surface)
            XCTAssertEqual(session.position, paused, accuracy: 0.4, "Adding subtitles must not restart or seek video")
            XCTAssertFalse(controller.isPlaying, "Adding subtitles must preserve pause intent")
            assertPiPSource(session, expectedOnDevice: route)
            do {
                try await controller.addOnlineSubtitle(online, title: "Stale", language: "en", sessionID: UUID())
                XCTFail("An obsolete source token must not attach a subtitle")
            } catch { XCTAssertTrue(error is MobileSubtitleFailure) }
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(session.position, paused, accuracy: 0.4)
            controller.seek(to: 16)
            controller.toggle()
            try await waitUntil("Seek/resume did not preserve the position") { session.position >= 16 && controller.isPlaying }
            XCTAssertNotNil(session.selectedSubtitleIndex)
            let committed = try XCTUnwrap(controller.progress).position
            controller.beginScrubbing()
            XCTAssertTrue(controller.isScrubbing)
            controller.previewScrubbing(at: 30)
            controller.previewScrubbing(at: 8)
            XCTAssertEqual(controller.progress?.position, committed, "Draft positions must not become watched progress")
            controller.endScrubbing(at: 12)
            try await waitUntil("Releasing a drag did not land at the newest destination") {
                abs(session.position - 12) < 2 && controller.isPlaying
            }
            XCTAssertTrue(session.surface === surface)
            controller.toggle()
            try await waitUntil("Pause before a second drag did not settle") { !controller.isPlaying }
            controller.beginScrubbing()
            controller.previewScrubbing(at: 20)
            controller.endScrubbing(at: 6)
            try await waitUntil("A drag while paused did not preserve the paused state and destination") {
                abs(session.position - 6) < 2 && !controller.isPlaying
            }
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertEqual(session.position, 6, accuracy: 2, "Older previews must not run after the final destination")
            XCTAssertFalse(controller.finished)
            controller.toggle()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "AetherEngine-iPhone-\(route)-PiP-source"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testVLCAddsAnOnlineSubtitleWithoutChangingEngineSessionOrPauseIntent() async throws {
        let ready = expectation(description: "subtitle fixture origin is listening")
        let origin = try PlaybackFixtureServer(file: fixture("playback-native", "mp4"),
            contentType: "video/mp4", onReady: { ready.fulfill() })
        defer { origin.stop() }
        await fulfillment(of: [ready], timeout: 5)
        let url = try XCTUnwrap(origin.url(path: "online-subtitle-fixture.mp4"))
        let (defaults, suite) = try preferences(.vlc)
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MobilePlaybackController(defaults: defaults)
        let (window, _, previous) = try show(controller)
        defer { controller.shutdown(); window.isHidden = true; previous?.makeKey() }
        let playing = expectation(description: "VLC publishes playing picture and discovered embedded tracks")
        let subscription = controller.$loading.combineLatest(controller.$isPlaying, controller.$subtitleTracks)
            .first { loading, playing, tracks in controller.engine == .vlc && !loading && playing && tracks.count > 1 }
            .sink { _ in playing.fulfill() }
        defer { subscription.cancel() }
        controller.isLive = false
        controller.start(urls: [url])
        await fulfillment(of: [playing], timeout: 30)
        let oldIDs = Set(controller.subtitleTracks.map(\.id))
        let sessionID = controller.subtitleSessionID
        let player = controller.player
        controller.toggle()
        let added = expectation(description: "VLC selects its actual newly added subtitle track")
        let chosen = controller.$subtitleTracks.combineLatest(controller.$selectedSubtitleID)
            .first { tracks, selected in selected != PlaybackSubtitleTrack.off.id && !oldIDs.contains(selected) && tracks.contains { $0.id == selected } }
            .sink { _ in added.fulfill() }
        defer { chosen.cancel() }
        try await controller.addOnlineSubtitle(Data("1\n00:00:00,000 --> 00:00:35,000\nVLC fixture caption\n".utf8),
            title: "Online fixture", language: "en", sessionID: sessionID)
        await fulfillment(of: [added], timeout: 5)
        controller.setSubtitleDelay(0.75)
        XCTAssertEqual(player.currentVideoSubTitleDelay, 750_000, "VLC uses microseconds; positive values show captions later")
        var appearance = controller.subtitlePreferences
        appearance.scale = 1.25; appearance.background = true
        controller.setSubtitlePreferences(appearance)
        XCTAssertEqual(controller.engine, .vlc)
        XCTAssertTrue(controller.player === player)
        XCTAssertEqual(controller.subtitleSessionID, sessionID)
        XCTAssertFalse(controller.isPlaying)
        controller.selectSubtitle(.off)
        XCTAssertEqual(controller.selectedSubtitleID, PlaybackSubtitleTrack.off.id)
        controller.stop()
        XCTAssertEqual(controller.subtitleDelaySeconds, 0, "Timing must not leak into another video/release")
        XCTAssertNotEqual(controller.subtitleSessionID, sessionID)
        XCTAssertFalse(controller.canAttachOnlineSubtitles)
    }

    func testLiveTransportStreamHasAPiPSourceWithoutAnHLSURL() async throws {
        let origin = try PlaybackFixtureServer(file: fixture("playback-live", "ts"), contentType: "video/mp2t", live: true)
        defer { origin.stop() }
        try await waitUntil("Local live origin did not start") { origin.port != nil }
        let url = try XCTUnwrap(origin.url(path: "live/fixture.ts"))
        let (defaults, suite) = try preferences(.automatic)
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MobilePlaybackController(defaults: defaults)
        let (window, _, previous) = try show(controller)
        defer { controller.shutdown(); window.isHidden = true; previous?.makeKey() }
        controller.start(urls: [url])
        try await waitUntil("Live transport stream did not render through Aether", timeout: 35) {
            controller.engine == .aether && controller.aetherSession?.hasPicture == true && !controller.loading
        }
        assertPiPSource(try XCTUnwrap(controller.aetherSession), expectedOnDevice: "Native")
        XCTAssertTrue(MobileEngineSelection.canPictureInPicture([url]))
    }

    func testChangingTheSettingUsesTheNewEngineOnTheNextStream() async throws {
        let file = try fixture("playback-native", "mp4")
        let (defaults, suite) = try preferences(.aether)
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MobilePlaybackController(defaults: defaults)
        let (window, _, previous) = try show(controller)
        defer { controller.shutdown(); window.isHidden = true; previous?.makeKey() }
        controller.isLive = false
        controller.start(urls: [file])
        try await waitUntil("Initial Aether stream did not render") { !controller.loading && controller.engine == .aether }
        defaults.set("vlc", forKey: MobilePlaybackPreference.storageKey)
        XCTAssertEqual(controller.engineTitle, "AetherEngine")
        controller.start(urls: [file])
        XCTAssertEqual(controller.engineTitle, "VLC")
        XCTAssertFalse(controller.canOfferPictureInPicture)
        XCTAssertFalse(controller.aetherSession?.isOpen ?? true)
        defaults.set("aether", forKey: MobilePlaybackPreference.storageKey)
        controller.start(urls: [file])
        try await waitUntil("Switching back did not render") { !controller.loading && controller.engine == .aether }
        assertPiPSource(try XCTUnwrap(controller.aetherSession), expectedOnDevice: "Native")
    }

    func testFloatingPiPWindowOnSupportedPhysicalDevice() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("A floating PiP window and app backgrounding require physical iPhone review.")
        #else
        guard AVPictureInPictureController.isPictureInPictureSupported() else { throw XCTSkip("PiP is unavailable on this device") }
        for (name, ext) in [("playback-native", "mp4"), ("playback-software", "mkv")] {
            let session = try AetherPlaybackSession()
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first { $0.isKeyWindow }
            let window = UIWindow(windowScene: scene)
            let host = UIViewController()
            window.rootViewController = host
            window.makeKeyAndVisible()
            session.surface.frame = host.view.bounds
            host.view.addSubview(session.surface)
            defer { session.stop(); window.isHidden = true; previous?.makeKey() }
            session.load(url: try fixture(name, ext), startPosition: nil, isLive: false,
                         expectedDuration: 36, primary: true, matchContent: false)
            try await waitUntil("PiP source did not become ready") {
                session.refreshPictureInPicture()
                return session.hasPicture && session.pictureInPicturePossible
            }
            XCTAssertEqual(session.pictureInPictureRoute, ext == "mp4" ? "Native" : "Sample buffer")
            session.togglePictureInPicture()
            try await waitUntil("AVKit did not activate the floating window") { session.pictureInPictureActive }
            session.togglePictureInPicture()
            try await waitUntil("PiP did not return to the app") { !session.pictureInPictureActive }
            XCTAssertTrue(session.hasPicture)
        }
        #endif
    }

    private func assertPiPSource(_ session: AetherPlaybackSession, expectedOnDevice route: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        #if targetEnvironment(simulator)
        // There is no device hardware decoder here. The real software renderer
        // must still expose its PiP source; hardware/native proof stays on device.
        XCTAssertEqual(session.pictureInPictureRoute, "Sample buffer", file: file, line: line)
        #else
        XCTAssertEqual(session.pictureInPictureRoute, route, file: file, line: line)
        #endif
    }

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }
    private func preferences(_ value: MobilePlaybackPreference) throws -> (UserDefaults, String) {
        let suite = "AetherPlaybackTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(value.rawValue, forKey: MobilePlaybackPreference.storageKey)
        return (defaults, suite)
    }
    private func show(_ controller: MobilePlaybackController) throws -> (UIWindow, MobileVideoHost, UIWindow?) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let screen = UIViewController()
        window.rootViewController = screen
        window.makeKeyAndVisible()
        let host = MobileVideoHost(frame: CGRect(x: 0, y: 60, width: 390, height: 220))
        host.controller = controller
        screen.view.addSubview(host)
        controller.attachVideo(host)
        return (window, host, previous)
    }
    private func waitForRenderedPicture(_ controller: MobilePlaybackController, route: String) async -> Bool {
        // Observe the production controller's ready publications. XCTest owns
        // the same bounded 30-second wait; success still requires a real
        // picture and the original playing/engine/loading conditions.
        let picture = expectation(description: "\(route) playback publishes an actual rendered picture")
        let subscription = controller.$loading.combineLatest(controller.$isPlaying)
            .first { loading, playing in
                controller.engine == .aether && !loading && playing
                    && controller.aetherSession?.hasPicture == true
            }
            .sink { _ in picture.fulfill() }
        defer { subscription.cancel() }
        await fulfillment(of: [picture], timeout: 30)
        let ready = controller.engine == .aether && controller.isPlaying && !controller.loading
            && controller.aetherSession?.hasPicture == true
        XCTAssertTrue(ready, "\(route) playback must still be rendering when the ready wait completes")
        if !ready {
            let evidence = XCTAttachment(string: "engine=\(controller.engineTitle), loading=\(controller.loading), playing=\(controller.isPlaying), phase=\(String(describing: controller.aetherSession?.phase)), picture=\(controller.aetherSession?.hasPicture == true), error=\(controller.error ?? "none")")
            evidence.name = "\(route)-playback-readiness-failure"
            evidence.lifetime = .keepAlways
            add(evidence)
        }
        return ready
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 30, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(condition(), message)
        if !condition() { throw NSError(domain: "AetherPlaybackTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    /// isPlaying reflects pause intent immediately, while Aether's published
    /// clock can still contain its last playing sample. Wait for an actual
    /// paused phase and a stationary clock before measuring post-pause drift.
    /// A decoder that keeps advancing never satisfies this bounded check.
    private func pausedClock(_ controller: MobilePlaybackController,
                             session: AetherPlaybackSession) async throws -> Double {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var lastPosition = session.position
        var stationarySince = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(100))
            let now = ProcessInfo.processInfo.systemUptime
            let position = session.position
            if controller.isPlaying || session.phase != .paused || abs(position - lastPosition) > 0.01 {
                stationarySince = now
            }
            lastPosition = position
            if now - stationarySince >= 0.5 { return position }
        }
        XCTFail("Pause did not stop Aether's published clock within five seconds")
        throw NSError(domain: "AetherPlaybackTests", code: 2)
    }
}
