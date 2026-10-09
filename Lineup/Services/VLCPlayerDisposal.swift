import Foundation
import VLCKitSPM

/// Lets a finished VLC player go off the main thread.
///
/// The last release of a `VLCMediaPlayer` tears down its input thread and its
/// video and audio outputs before it returns. On the main thread that is a
/// hitch the viewer sees -- most of all as the Live tab hands over to another
/// while a game is playing, which is exactly when a preview's player is let go.
enum VLCPlayerDisposal {
    private static let queue = DispatchQueue(label: "lineup.vlc-disposal", qos: .utility)

    /// The player, carried to the queue. VLCKit's own calls are safe from any
    /// thread; Swift cannot know that.
    private final class Carried: @unchecked Sendable {
        let player: VLCMediaPlayer
        init(_ player: VLCMediaPlayer) { self.player = player }
    }

    /// Holds the player a moment -- until the views that drew it have let go
    /// too -- then stops it and lets it go here, so its last release is not
    /// on the main thread.
    static func release(_ player: VLCMediaPlayer) {
        let carried = Carried(player)
        queue.asyncAfter(deadline: .now() + 1) {
            carried.player.stop()
            carried.player.drawable = nil
        }
    }
}
