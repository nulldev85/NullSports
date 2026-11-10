import XCTest
import UIKit
@testable import LineupiOS

final class PlaybackLifecycleTests: XCTestCase {
    @MainActor
    func testLeavingTabReleasesDrawableAndQueuedAttachment() async throws {
        let controller = MobilePlaybackController()
        let host = MobileVideoHost(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let window = UIWindow(frame: host.frame)
        window.addSubview(host)
        window.isHidden = false
        defer { window.isHidden = true }
        host.controller = controller
        controller.attachVideo(host)
        XCTAssertTrue(controller.videoViewForExit === host)
        host.scheduleAttachment()
        controller.shutdown()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(controller.videoViewForExit)
        XCTAssertNil(host.controller)
        XCTAssertFalse(controller.isPlaying)
    }

    @MainActor
    func testOldSurfaceTeardownCannotClearNewSurface() {
        let controller = MobilePlaybackController()
        let old = MobileVideoHost(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let current = MobileVideoHost(frame: old.frame)
        controller.attachVideo(old)
        controller.attachVideo(current)
        controller.detachVideo(old)
        XCTAssertTrue(controller.videoViewForExit === current)
        controller.shutdown()
    }

    @MainActor
    func testReturningToGuideUsesIndependentSession() {
        let retired = MobilePlaybackController()
        let fresh = MobilePlaybackController()
        let oldHost = MobileVideoHost(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let newHost = MobileVideoHost(frame: oldHost.frame)
        retired.attachVideo(oldHost)
        retired.shutdown()
        fresh.attachVideo(newHost)
        retired.detachVideo(oldHost)
        XCTAssertFalse(retired === fresh)
        XCTAssertNil(retired.videoViewForExit)
        XCTAssertTrue(fresh.videoViewForExit === newHost)
        fresh.shutdown()
    }
}
