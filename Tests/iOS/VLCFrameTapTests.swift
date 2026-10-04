import XCTest
@testable import LineupiOS

/// Step one of the frame pipeline that will give VLC-backed channels Picture in
/// Picture: proving libvlc's C API is reachable at all.
///
/// These run in CI on a simulator, which is the point. The rest of the pipeline
/// gets built on top of them the same way — each step verified by the machine
/// before it reaches a phone.
final class VLCFrameTapTests: XCTestCase {
    /// If VLCKit ever stops exporting these, the build fails at link time rather
    /// than here — this asserts the addresses came back, which is the belt to
    /// that braces.
    func testTheVideoCallbackAPIIsLinked() {
        XCTAssertTrue(VLCFrameTap.videoCallbackAPIIsLinked,
                      "libvlc's video callbacks must resolve, or no frame pipeline is possible")
    }

    /// The whole approach rests on reaching the libvlc player behind VLCKit's
    /// Objective-C wrapper. It lives in a private header, so this is the check
    /// that a VLCKit upgrade has not moved it.
    @MainActor
    func testAControllersVLCPlayerExposesItsLibVLCHandle() {
        let controller = MobilePlaybackController()
        XCTAssertNotNil(controller.libVLCHandle,
                        "VLCMediaPlayer.playerInstance must still be reachable")
        controller.shutdown()
    }

    /// Two controllers are two independent libvlc players — the invariant the
    /// frame pipeline will rely on when it starts routing frames per session.
    @MainActor
    func testEachControllerHasItsOwnLibVLCPlayer() {
        let first = MobilePlaybackController()
        let second = MobilePlaybackController()
        XCTAssertNotNil(first.libVLCHandle)
        XCTAssertNotNil(second.libVLCHandle)
        XCTAssertNotEqual(first.libVLCHandle, second.libVLCHandle)
        first.shutdown()
        second.shutdown()
    }
}
