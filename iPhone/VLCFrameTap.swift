import Foundation
import VLCKitSPM

/// Step one of taking decoded frames out of VLC.
///
/// Native Picture in Picture needs either an `AVPlayerLayer` or an
/// `AVSampleBufferDisplayLayer` fed `CMSampleBuffer`s. VLCKit renders into an
/// opaque `UIView` and offers neither, which is why a VLC-backed channel has no
/// PiP today. libvlc's C API does expose decoded frames, so the route is to let
/// VLC keep doing all the demuxing and decoding — that is what makes the awkward
/// channels play at all — and intercept the frames on their way out.
///
/// This type currently only establishes that the API is reachable. It sets no
/// callbacks and changes no playback: the pipeline is built on top of it, in
/// steps, each one verifiable in CI before it reaches a device.
enum VLCFrameTap {
    /// The libvlc player behind a `VLCMediaPlayer`, or nil if VLCKit's internals
    /// have moved. Everything the frame pipeline does needs this handle.
    static func handle(for player: VLCMediaPlayer) -> OpaquePointer? {
        // `libvlc_media_player_t` is forward-declared in the bridging header and
        // never defined, so Clang imports a pointer to it as an OpaquePointer
        // already. Wrapping it in `OpaquePointer(_:)` asks for an initializer
        // that takes one, which is the one conversion OpaquePointer doesn't
        // offer -- it converts from typed and raw pointers, not from itself.
        player.playerInstance
    }

    /// True when both video-callback entry points resolved at link time.
    /// A false here would mean the pinned VLCKit no longer exports them.
    static var videoCallbackAPIIsLinked: Bool {
        LineupVLCVideoSetCallbacksAddress() != nil
            && LineupVLCVideoSetFormatCallbacksAddress() != nil
    }
}
