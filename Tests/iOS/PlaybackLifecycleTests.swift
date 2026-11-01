import XCTest
import UIKit
@testable import LineupiOS

final class PlaybackLifecycleTests: XCTestCase {
    @MainActor
    func testIdleTabLifecycleDoesNotCreateNativePlayers() {
        let controller = MobilePlaybackController()
        let host = MobileVideoHost(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        controller.attachVideo(host)
        controller.audioMuted = true
        controller.holdsQualityDown = true
        _ = controller.diagnosticsSnapshot
        controller.handleScenePhase(active: false)
        controller.handleScenePhase(active: true)
        controller.detachVideo(host)
        controller.stop()
        controller.shutdown()
        XCTAssertNil(controller.existingVLCPlayer, "Idle tab setup and cleanup must not initialize VLC")
        XCTAssertNil(controller.existingSystemPlayer, "Idle tab setup and cleanup must not initialize AVPlayer")
    }

    @MainActor
    func testRequestingVLCAllocatesOnlyVLCAndReusesIt() {
        let controller = MobilePlaybackController()
        let player = controller.player
        XCTAssertTrue(controller.player === player)
        XCTAssertNil(controller.existingSystemPlayer)
        controller.shutdown()
        XCTAssertTrue(controller.player === player)
        XCTAssertNil(controller.existingSystemPlayer, "VLC cleanup must not create the unused Apple engine")
    }

    @MainActor
    func testRequestingApplePlayerAllocatesOnlyAppleAndReusesIt() {
        let controller = MobilePlaybackController()
        let player = controller.systemPlayer
        XCTAssertTrue(controller.systemPlayer === player)
        XCTAssertNil(controller.existingVLCPlayer)
        controller.shutdown()
        XCTAssertTrue(controller.systemPlayer === player)
        XCTAssertNil(controller.existingVLCPlayer, "Apple engine cleanup must not create unused VLC")
    }

    @MainActor
    func testLeavingTabReleasesDrawableAndQueuedAttachment() async throws {
        let controller = MobilePlaybackController()
        _ = controller.player
        let host = MobileVideoHost(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let window = UIWindow(frame: host.frame)
        window.addSubview(host)
        window.isHidden = false
        defer { window.isHidden = true }
        host.controller = controller
        controller.attachVideo(host)
        XCTAssertTrue((controller.player.drawable as? UIView) === host)
        host.scheduleAttachment()
        controller.shutdown()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(controller.player.drawable)
        XCTAssertNil(host.controller)
        XCTAssertFalse(controller.isPlaying)
    }

    @MainActor
    func testOldSurfaceTeardownCannotClearNewSurface() {
        let controller = MobilePlaybackController()
        _ = controller.player
        let old = MobileVideoHost(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let current = MobileVideoHost(frame: old.frame)
        controller.attachVideo(old)
        controller.attachVideo(current)
        controller.detachVideo(old)
        XCTAssertTrue((controller.player.drawable as? UIView) === current)
        controller.shutdown()
    }

    @MainActor
    func testReturningToGuideUsesIndependentSession() {
        let retired = MobilePlaybackController()
        let fresh = MobilePlaybackController()
        _ = retired.player
        _ = fresh.player
        let oldHost = MobileVideoHost(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let newHost = MobileVideoHost(frame: oldHost.frame)
        retired.attachVideo(oldHost)
        retired.shutdown()
        fresh.attachVideo(newHost)
        retired.detachVideo(oldHost)
        XCTAssertFalse(retired.player === fresh.player)
        XCTAssertNil(retired.player.drawable)
        XCTAssertTrue((fresh.player.drawable as? UIView) === newHost)
        fresh.shutdown()
    }
}
