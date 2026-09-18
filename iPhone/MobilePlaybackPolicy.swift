import Foundation

/// Which player opens a given stream URL.
///
/// Xtream publishes every channel twice: an HLS playlist (`.m3u8`) and a raw
/// MPEG-TS stream (`.ts`). Only the HLS endpoint can be opened by AVPlayer, and
/// only AVPlayer can drive `AVPictureInPictureController` — VLCKit renders into
/// an opaque `UIView` through `drawable` and exposes no frame source that PiP
/// can read. So the phone tries HLS first, which is deliberately the reverse of
/// the Apple TV order, and keeps VLC as the fallback that still plays a channel
/// whose HLS endpoint is missing, throttled, or broken.
///
/// Apple TV is untouched by this: it has no PiP and no background audio, and its
/// transport-stream-first order remains the better one there.
enum MobileStreamEngine: String, Equatable {
    /// AVPlayer. Native Picture in Picture and background audio.
    case system
    /// VLCKit. Everything AVPlayer cannot open.
    case vlc
}

enum MobileEngineSelection {
    /// HLS playlists go to AVPlayer; everything else goes to VLC.
    ///
    /// Query strings are irrelevant here — some providers append tokens — so
    /// this reads `pathExtension`, which already excludes the query.
    static func engine(for url: URL) -> MobileStreamEngine {
        switch url.pathExtension.lowercased() {
        case "m3u8", "m3u": return .system
        default: return .vlc
        }
    }

    /// Reorders candidates so PiP-capable URLs are tried first, preserving the
    /// provider's relative order inside each group. A stable partition rather
    /// than a sort: when a provider lists two HLS variants, the first one stays
    /// first, and the transport streams stay available as fallbacks behind them.
    static func ordered(_ urls: [URL]) -> [URL] {
        urls.filter { engine(for: $0) == .system } + urls.filter { engine(for: $0) != .system }
    }

    /// True when any candidate could drive Picture in Picture. Used to decide
    /// whether a PiP button is worth offering before a stream has opened.
    static func canPictureInPicture(_ urls: [URL]) -> Bool {
        urls.contains { engine(for: $0) == .system }
    }
}

/// What a scene-phase change should do to playback.
enum MobilePlaybackPhaseAction: Equatable {
    /// Start playing, or keep playing. Backgrounding no longer implies a pause.
    case keepPlaying
    /// Stop audio. Only reachable when the app cannot legally play in the
    /// background, which is a build-configuration problem, not a normal state.
    case pause
    /// Touch nothing: the viewer's own pause outranks every automatic rule.
    case leaveAsIs
}

/// The single decision table behind "does playback survive this?".
///
/// Before this existed, each of the three surfaces answered the question its own
/// way — the full-screen player, the Guide player, and the Live preview each had
/// their own `scenePhase` branch, and all three paused on background. Live went
/// further and tore the stream down. Centralising it here is what makes the
/// behaviour testable without a simulator, and what keeps PiP working: while the
/// PiP window is up, the app *is* backgrounded, so an unconditional pause on
/// background would stop the very playback PiP exists to continue.
enum MobileBackgroundPolicy {
    /// - Parameters:
    ///   - enteringBackground: `scenePhase != .active`. Both `.inactive` (a
    ///     control-centre pull, an incoming call banner) and `.background`.
    ///   - pictureInPictureActive: the PiP window is showing this stream.
    ///   - pausedByUser: the viewer pressed pause. Never overridden.
    ///   - backgroundAudioEnabled: the bundle declares the `audio` background
    ///     mode and the audio session is configured for playback. Without it iOS
    ///     suspends the process anyway, so pausing cleanly beats being killed
    ///     mid-buffer.
    static func action(enteringBackground: Bool,
                       pictureInPictureActive: Bool,
                       pausedByUser: Bool,
                       backgroundAudioEnabled: Bool) -> MobilePlaybackPhaseAction {
        // A deliberate pause survives every transition, in both directions:
        // returning to the app must not silently start audio the viewer stopped.
        if pausedByUser { return .leaveAsIs }
        if !enteringBackground { return .keepPlaying }
        if pictureInPictureActive { return .keepPlaying }
        return backgroundAudioEnabled ? .keepPlaying : .pause
    }
}

/// When to give up on the AVPlayer engine and fall through to the next
/// candidate — in practice the transport stream, which VLC can play.
///
/// AVPlayer has no failure of its own to report here. A dead or unresponsive
/// HLS endpoint leaves the item in `.unknown` indefinitely: no error, no status
/// change, nothing for a KVO observer to fire on. A real capture from a broken
/// provider endpoint sat exactly like that for eighteen seconds with a perfectly
/// good `.ts` candidate queued behind it and never tried. The VLC engine has had
/// a deadline for this since 0.17.4; this is the same idea for the other engine.
enum SystemEngineWatchdog {
    /// Long enough for a slow connection to open a playlist, short enough that
    /// a dead endpoint does not read as a hung app.
    static let readyDeadline: TimeInterval = 8
    /// Ready but still showing nothing. Separate and longer, because reaching
    /// `readyToPlay` means the server answered — the picture may yet arrive.
    static let videoDeadline: TimeInterval = 12

    enum Verdict: Equatable {
        case wait
        case failOver
    }

    /// - Parameters:
    ///   - elapsed: seconds since this candidate was opened.
    ///   - isReady: the item reached `readyToPlay`.
    ///   - hasVideo: the item reported a non-zero presentation size.
    static func verdict(elapsed: TimeInterval, isReady: Bool, hasVideo: Bool) -> Verdict {
        if isReady && hasVideo { return .wait }
        if !isReady { return elapsed > readyDeadline ? .failOver : .wait }
        // Ready, playing, and still no picture: the 0.17.8 rule, which the
        // AVPlayer path never got — audio without video is not success.
        return elapsed > videoDeadline ? .failOver : .wait
    }
}
