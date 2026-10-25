import Foundation

enum MobileRecordingSeekPolicy {
    /// Provider URLs accept whole-minute starts. A short forward request must
    /// never round back behind the picture and restart the same minute.
    static func providerStart(target: Date, current: Date) -> Date? {
        guard target.timeIntervalSince1970.isFinite, current.timeIntervalSince1970.isFinite else { return nil }
        let minute = Date(timeIntervalSince1970: floor(target.timeIntervalSince1970 / 60) * 60)
        if target >= current, minute <= current { return nil }
        return minute
    }
}

enum MobileStreamEngine: String, Hashable {
    case system, aether, vlc, mpv
    var title: String {
        switch self { case .system: "Native player"; case .aether: "AetherEngine"; case .vlc: "VLC"; case .mpv: "MPVKit" }
    }
    var supportsPictureInPicture: Bool { self == .system || self == .aether }
}

enum MobilePlaybackPreference: String, CaseIterable, Identifiable {
    case automatic, native, aether, vlc, mpv
    static let storageKey = "Lineup.mobile.playbackEngine.v1"
    static let nativeFallbackKey = "Lineup.mobile.nativePlayer.fallback.v1"
    static let allCases: [Self] = [.native, .aether, .vlc, .mpv]
    var id: String { rawValue }
    var title: String {
        switch self { case .automatic, .native: "Native player"; case .aether: "AetherEngine"; case .vlc: "VLC"; case .mpv: "MPVKit (Trial)" }
    }
    var version: String? {
        switch self {
        case .automatic, .native: nil
        case .aether: PlaybackEngineVersions.aether
        case .vlc: PlaybackEngineVersions.vlc
        case .mpv: PlaybackEngineVersions.mpv
        }
    }
    static func selected(in defaults: UserDefaults = .standard) -> Self {
        let saved = defaults.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .native
        return saved == .automatic ? .native : saved
    }
    static func allowsNativeFallback(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: nativeFallbackKey) as? Bool ?? true
    }
}

enum MobileEngineSelection {
    /// Keep the existing HLS player; Aether handles other containers and
    /// extensionless server routes with native or sample-buffer PiP. Failed
    /// engines are skipped for this URL, so fallback cannot loop forever.
    static func engine(for url: URL, preference: MobilePlaybackPreference = .automatic,
                       failed: Set<MobileStreamEngine> = [], nativeFallback: Bool = true) -> MobileStreamEngine? {
        let order: [MobileStreamEngine]
        switch preference {
        case .native:
            // Files use the native compatibility pipeline as well, retaining
            // the app's track, subtitle and seeking features around AVPlayer.
            let direct = ["m3u8", "m3u"].contains(url.pathExtension.lowercased())
            order = (direct ? [.system, .aether] : [.aether]) + (nativeFallback ? [.vlc] : [])
        case .automatic:
            order = ["m3u8", "m3u"].contains(url.pathExtension.lowercased())
                ? [.system, .aether, .vlc] : [.aether, .vlc]
        case .aether: order = [.aether, .vlc]
        case .vlc: order = [.vlc]
        case .mpv: order = [.mpv, .aether, .vlc]
        }
        return order.first { !failed.contains($0) }
    }

    /// Reorders candidates so PiP-capable URLs are tried first, preserving the
    /// provider's relative order inside each group. A stable partition rather
    /// than a sort: when a provider lists two HLS variants, the first one stays
    /// first, and the transport streams stay available as fallbacks behind them.
    static func ordered(_ urls: [URL], live: Bool = false) -> [URL] {
        // Live providers already list HLS first. If a rendered playback
        // measurement promoted TS, do not silently undo that exact choice.
        guard !live else { return urls }
        return urls.filter { engine(for: $0) == .system } + urls.filter { engine(for: $0) != .system }
    }

    /// True when any candidate could drive Picture in Picture. Used to decide
    /// whether a PiP button is worth offering before a stream has opened.
    static func canPictureInPicture(_ urls: [URL], preference: MobilePlaybackPreference = .automatic) -> Bool {
        urls.contains { engine(for: $0, preference: preference)?.supportsPictureInPicture == true }
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

/// Sound and picture start together.
///
/// A stream can reach the player with its sound ready well before its
/// picture moves: a first frame shown and then held, or none at all, while
/// the sound runs on. Played as it arrives, that is a commentary over a
/// frozen frame. So the sound is held, and the picture kept back behind
/// "Opening stream…", until the picture is seen to move -- then both start
/// at once.
enum StartTogether {
    /// New frames in a row, each soon after the last, that show a picture
    /// is moving rather than holding on one frame.
    static let framesToStart = 3
    /// A longer wait than this between new frames is a held picture, and
    /// the count starts again.
    static let frameGap: TimeInterval = 0.5
    /// How long a live channel's sound may be held for a picture that will
    /// not move before the channel's other stream is tried instead.
    static let stillPictureDeadline: TimeInterval = 4
    /// Minimum wait before allowing an identified audio-only source to play
    /// without a picture. A known video track must still produce a frame.
    static let soundAloneAfter: TimeInterval = 6
    static func canReleaseAudioOnly(heldFor: TimeInterval, hasAudio: Bool, hasVideo: Bool) -> Bool {
        heldFor >= soundAloneAfter && hasAudio && !hasVideo
    }
    static func canRevealVLC(displayedPictures: Int, settled: Bool, outputAge: TimeInterval) -> Bool {
        displayedPictures > 0 && (settled || outputAge >= vlcSettleDeadline)
    }
    /// Once VLC's picture is up, how long its size must hold steady before
    /// it shows. VLC can draw a stream's first frames before it has worked
    /// out their shape, stretched to fill until it has.
    static let vlcSettle: TimeInterval = 0.4
    /// New pictures VLC must have shown, behind the gate, before it opens.
    static let vlcFramesToSettle = 6
    /// Shown this long after the picture first came up, settled or not.
    static let vlcSettleDeadline: TimeInterval = 2

    /// The run of moving frames after one more new frame at `now`.
    static func frames(after count: Int, lastFrameAt: TimeInterval?, now: TimeInterval) -> Int {
        guard let lastFrameAt, now - lastFrameAt <= frameGap else { return 1 }
        return count + 1
    }

    /// Whether a held start should give up on this stream for the next one.
    /// Only for live channels, and only where there is another stream to
    /// try: a title's picture can be late because it is seeking to where the
    /// viewer left off, and with nothing else to try, a late start beats a
    /// reconnect that would only start late again.
    static func shouldTryNext(heldFor: TimeInterval?, isLive: Bool, hasAnotherStream: Bool) -> Bool {
        guard isLive, hasAnotherStream, let heldFor else { return false }
        return heldFor > stillPictureDeadline
    }
}

enum MobilePlaybackOpeningPolicy {
    /// VLC may still report the old stopped/ended state while opening a new
    /// input. A movie must get its normal startup window before recovery.
    static func stoppedIsFailure(isLive: Bool, hasShownPicture: Bool, age: TimeInterval) -> Bool {
        hasShownPicture || age >= (isLive ? 8 : 30)
    }
}

struct MobilePlaybackPresentation: Equatable {
    private(set) var hasPresentedVideo = false
    private(set) var recovering = false
    mutating func presentedVideo() { hasPresentedVideo = true; recovering = false }
    mutating func beganRecovery() { recovering = true }
    func loadingMessage(waitingForPicture: Bool) -> String {
        if recovering { return "Reconnecting…" }
        if hasPresentedVideo { return "Buffering…" }
        return waitingForPicture ? "Waiting for picture…" : "Opening stream…"
    }
}

/// Where playback is in a title that has an end.
///
/// Live channels have neither a length nor a position worth showing, so the
/// player publishes this only for something that can actually be scrubbed.
struct MobilePlaybackProgress: Equatable {
    var position: Double
    var duration: Double

    var fraction: Double { duration > 0 ? min(max(position / duration, 0), 1) : 0 }
    var remaining: Double { max(0, duration - position) }

    /// "1:04:22" past an hour, "4:22" below it, which is how every other player
    /// on the platform writes a running time.
    static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

/// Which way a sideways swipe across the full-screen picture changes channel.
///
/// The picture already answers a tap, which brings up the controls, and a
/// pull downward, which closes the player. A swipe is told from both by being
/// plainly sideways: half again as wide as it is tall, and long enough not to
/// be a tap that wandered. The dismissal wants the opposite -- downward by
/// 1.3 times its width -- so between the two rules lies a band where a
/// diagonal drag does nothing, rather than the wrong thing.
///
/// Left is the next channel, down the list, as a page turns; right is the
/// one before.
enum MobileChannelSwipe: Equatable {
    case next
    case previous

    /// Points the finger has to travel sideways.
    static let minimumDistance: Double = 60
    /// How many times wider than tall the swipe has to be.
    static let dominance: Double = 1.5

    /// Nil for anything that is not a channel change: too short, or not
    /// sideways enough to be sure.
    static func direction(width: Double, height: Double) -> MobileChannelSwipe? {
        guard abs(width) > minimumDistance, abs(width) > abs(height) * dominance else { return nil }
        return width < 0 ? .next : .previous
    }

    /// One place along the lineup: on for the next channel, back for the
    /// previous one.
    var step: Int { self == .next ? 1 : -1 }
}

/// Stepping through a screen's lineup of channels, round from the end to the
/// start, as a remote's channel buttons do.
enum MobileChannelLineup {
    /// - Parameters:
    ///   - current: where the channel on screen sits in the lineup, or nil
    ///     when it is not in it -- a game's channel opened from an alert, say.
    ///   - count: how many channels the lineup has.
    ///   - step: +1 for the next channel, -1 for the previous one.
    /// - Returns: the place to tune to, or nil for an empty lineup. A channel
    ///   that is not in the lineup steps onto it from its top going forward
    ///   and from its bottom going back.
    static func index(from current: Int?, count: Int, step: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current, current >= 0, current < count else { return step >= 0 ? 0 : count - 1 }
        return ((current + step) % count + count) % count
    }
}

/// How the player speaks of a recording: how far behind live it is, in the
/// status badge and under the timeline.
enum MobileCatchUpLabel {
    /// "12 MIN", "1 HR", "1 HR 5 MIN".
    static func duration(minutes: Int) -> String {
        let minutes = max(0, minutes)
        guard minutes >= 60 else { return "\(minutes) MIN" }
        return "\(minutes / 60) HR" + (minutes % 60 == 0 ? "" : " \(minutes % 60) MIN")
    }

    /// Whole minutes a place in a recording is behind the present. Never
    /// negative: a recording cannot be ahead of the broadcast.
    static func minutesBehind(position: Date, now: Date) -> Int {
        let seconds = now.timeIntervalSince(position)
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(seconds / 60)
    }
}

/// What a title is, for the panel the player shows while its controls are up.
///
/// Built by whoever opened the player, because only they hold the record: the
/// player itself is handed a URL and a name and knows nothing about seasons,
/// air dates or plots.
struct MobilePlayerSynopsis: Equatable {
    var heading: String?
    var detail: String?
    var overview: String?

    var isEmpty: Bool {
        (heading ?? "").isEmpty && (detail ?? "").isEmpty && (overview ?? "").isEmpty
    }
}
