import SwiftUI
import AVFoundation
import AVKit
import CoreMedia
import VLCKitSPM
import LineupAetherPlayback
import LineupMPVPlayback
import ImageIO

/// Runs `body` on the main actor. AVFoundation delivers KVO on an unspecified
/// queue, so every observer hops through here before touching controller state;
/// `assumeIsolated` is safe only once the hop has actually happened.
private func onMain(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
}

/// The audio session, switched on and off in order on one queue.
///
/// Switching it off waits for the sound to finish and can take a noticeable
/// moment, so it is never done on the main thread -- it used to run there
/// as the viewer left the Live tab. Switching it on waits for any switch-off
/// still queued, so the two can never land out of order.
enum MobileAudioSession {
    private static let queue = DispatchQueue(label: "lineup.audio-session", qos: .userInitiated)
    /// The players holding the session. With two on screen, one stopping
    /// mustn't switch the sound off under the other.
    @MainActor private static var holders = Set<ObjectIdentifier>()

    @MainActor
    static func activate(for holder: AnyObject) throws {
        try queue.sync {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        }
        holders.insert(ObjectIdentifier(holder))
    }

    @MainActor
    static func deactivate(for holder: AnyObject) {
        guard holders.remove(ObjectIdentifier(holder)) != nil, holders.isEmpty else { return }
        queue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

/// Holds a screen's player, made once.
///
/// `@State` builds its initial value every time the view holding it is
/// re-created, which for a tab is every time the tab bar's view redraws --
/// and a player is a VLC instance and an AVPlayer, made and thrown away on
/// the main thread each time. `@StateObject` makes its object once.
@MainActor
final class MobilePlaybackSlot: ObservableObject {
    @Published var controller: MobilePlaybackController

    init() { controller = MobilePlaybackController() }
}

/// One stream, one controller, two possible engines.
///
/// `MobilePlaybackController` is the only playback object the iPhone views know
/// about. It owns both engines for the lifetime of a session and runs exactly
/// one of them at a time — see `MobileStreamEngine`. Switching engines happens
/// only when a candidate URL fails and the next one needs a different player, so
/// resizing, expanding, collapsing, rotating, or entering Picture in Picture
/// never opens a second connection to the provider.
@MainActor
final class MobilePlaybackController: ObservableObject {
    private let defaults: UserDefaults
    private var preference = MobilePlaybackPreference.automatic
    private var failedEngines: [URL: Set<MobileStreamEngine>] = [:]
    private var sourceIsRecording = false
    private(set) var aetherSession: AetherPlaybackSession?
    private(set) var mpvSession: MPVPlaybackSession?
    /// VLCKit. Still the engine for transport streams and anything AVPlayer
    /// refuses, and still the object the surface tests reach for.
    let player = VLCMediaPlayer()
    /// AVPlayer. Drives Picture in Picture and keeps audio alive in the
    /// background. One instance per controller, reused across channel changes.
    let systemPlayer = AVPlayer()

    @Published var isPlaying = false { didSet { reportLibraryTracking() } }
    var libraryTrackingEvent: ((LibraryPlaybackSample) -> Void)?
    private var lastLibraryTrackingSample: LibraryPlaybackSample?
    private func reportLibraryTracking() {
        guard let libraryTrackingEvent, !isScrubbing else { return }
        let sample = LibraryPlaybackSample(playing: isPlaying, pictureInPicture: pictureInPictureActive,
            position: progress?.position ?? 0, duration: progress?.duration ?? 0)
        guard sample.differs(from: lastLibraryTrackingSample) else { return }
        lastLibraryTrackingSample = sample
        libraryTrackingEvent(sample)
    }
    @Published var loading = true
    @Published private(set) var presentation = MobilePlaybackPresentation()
    var loadingMessage: String { presentation.loadingMessage(waitingForPicture: isPlaying && !startGateOpen) }
    @Published var error: String?
    @Published private(set) var videoWidth: Int?
    @Published private(set) var videoHeight: Int?
    @Published private(set) var mediaInfo = PlaybackMediaInfo()
    private let nativeMediaInfo = NativePlaybackMediaInfoReader()
    private let liveQualityReporter = LivePlaybackQualityReporter()
    /// Which engine is currently rendering. Views use it only to decide whether
    /// a Picture in Picture button can do anything.
    @Published private(set) var engine: MobileStreamEngine = .vlc
    var engineTitle: String { engine.title }
    @Published private(set) var pictureInPicturePossible = false
    @Published private(set) var pictureInPictureActive = false { didSet { reportLibraryTracking() } }
    /// A short, self-clearing line shown when Lineup moves to a different feed.
    @Published private(set) var failoverNotice: String?
    /// Where playback is in a title that has an end. Nil for a live stream,
    /// which has no length to report and nothing to scrub through.
    @Published private(set) var progress: MobilePlaybackProgress? { didSet { reportLibraryTracking() } }
    @Published private(set) var subtitleTracks: [PlaybackSubtitleTrack] = [.off]
    @Published private(set) var selectedSubtitleID = PlaybackSubtitleTrack.off.id
    @Published private(set) var subtitleSessionID = UUID()
    @Published private(set) var subtitlePreferences: MobileSubtitlePreferences
    @Published private(set) var subtitleDelaySeconds: Double = 0
    private var explicitSubtitleChoice = false
    private var onlineSubtitleFiles: [URL] = []
    /// The title's own sound tracks -- languages, commentary -- for a title
    /// with an end. A channel keeps the one it plays.
    @Published private(set) var audioTracks: [MobileTrackOption] = []
    @Published private(set) var selectedAudioID: String?
    /// The subtitle tracks' languages, by track, where the engine knows them.
    private var subtitleLanguages: [String: String] = [:]
    /// The show whose sound and subtitles this player keeps from episode to
    /// episode, and what it kept.
    private var trackMemoryShow: String?
    private var showTracks: MobileShowTracks?
    private var appliedShowAudio = false
    private var appliedShowSubtitle = false
    var canAttachOnlineSubtitles: Bool { !isLive && monitor != nil && currentURL != nil && engine != .system && error == nil }

    /// How the controller reaches other channels for the game on screen. Left
    /// nil for plain Guide playback, which has no game and therefore no verified
    /// alternates — without it, failover simply never happens.
    /// Isolated to the main actor: every member reads `SportsLibrary`, which is
    /// `@MainActor`, and the controller only ever calls these from there.
    struct FailoverContext {
        /// Ordered channels worth trying. Recomputed at each switch so it
        /// reflects the provider's current channel list.
        let plan: @MainActor () -> [FailoverChannel]
        let urls: @MainActor (Int) -> [URL]
        let didSwitch: @MainActor (FailoverChannel) -> Void
        let didPlay: @MainActor (Int) -> Void
    }
    var failover: FailoverContext?
    /// The channel currently playing, so failover knows what to retire.
    private(set) var currentChannelID: Int?
    private var failoverState = StreamFailoverState()
    private var pendingWorkingChannelID: Int?
    private var noticeTask: Task<Void, Never>?

    private var monitor: Task<Void, Never>?
    private(set) var isScrubbing = false
    private var resumeAfterScrubbing = false
    private var scrubDestination: Double?
    private let scrubSeeks = PlaybackSeekCoalescer()
    private var seekLanding = PlaybackSeekLanding()
    private var requestedInitialPosition: TimeInterval?
    private var appliedInitialPosition = false
    /// A channel runs at the live edge and is buffered for a link that may
    /// wobble; a title is a file on a server that will be scrubbed through.
    /// The two want opposite buffers, so the caller says which this is.
    ///
    /// They want opposite recoveries too. A channel that stops is reconnected
    /// at the live edge. A title that stops is reopened where it was, and one
    /// that reaches its end has finished, not failed.
    var isLive = true
    /// Where to put a title back once its stream has reopened.
    private var reopenPosition: TimeInterval?
    /// A title played to its end. The player closes on it. So does a
    /// programme from the past played from the Catch Up list, at its end.
    @Published private(set) var finished = false

    // Catch-up; see the section of that name below.
    /// How to play this channel's recording, while a channel the provider
    /// records is on. Nil for a channel that isn't recorded, for a title, and
    /// until the server's time zone is known. Set by the screen that opened
    /// the channel, which knows the stream; a change of channel -- the
    /// viewer's or failover's -- leaves it behind.
    @Published var catchUpSource: CatchUpSource?
    /// Playing the channel's recording rather than the channel live: where
    /// the open stream starts and the programme its timeline is drawn across.
    @Published private(set) var catchUp: CatchUpTimeline?
    /// Where a skip is taking the recording, while it waits to see whether
    /// another press follows before reopening the stream there.
    @Published private(set) var skipTarget: Date?
    /// How far the open recording has played, in whole seconds as far as the
    /// screen is concerned: the timeline and the badge show no finer, so a
    /// finer number would only redraw them for nothing.
    @Published private(set) var recordingElapsed: TimeInterval = 0
    /// A programme chosen from the past ends with it. Start Over, a pause and
    /// a rewind carry on through whatever came next, up to live.
    private(set) var recordingEndsWithProgramme = false
    /// When a live channel the provider records was paused, to pick up from.
    private var pausedAt: Date?
    /// This player's sound is off: a picture sharing the screen with
    /// another, whose sound is on. Held through reconnects and engine
    /// changes, and through the start gate, which used to switch every
    /// player's sound back on as its picture came up.
    var audioMuted = false {
        didSet { if audioMuted != oldValue { applyMute() } }
    }
    /// Leaving the app hands this picture to the system window. Off for a
    /// picture sharing the screen with another.
    var allowsPictureInPicture = true {
        didSet {
            pipController?.canStartPictureInPictureAutomaticallyFromInline = allowsPictureInPicture
            aetherSession?.startsPictureInPictureAutomatically = allowsPictureInPicture
        }
    }
    /// The player that owns the system's Now Playing and display. A second
    /// picture on screen does not.
    var isPrimaryOutput = true
    /// Held to about 540p for a muted picture sharing the screen while the
    /// phone runs hot. Only Apple's player can lower a stream, and only one
    /// that offers more than one quality: anything else plays as it is.
    var holdsQualityDown = false {
        didSet {
            guard holdsQualityDown != oldValue else { return }
            applyQualityCeiling(to: systemPlayer.currentItem)
            diag.record(holdsQualityDown ? "running hot: quality held down while muted" : "quality ceiling lifted")
        }
    }
    /// Pauses on a channel playing live since it was last opened: the
    /// picture falls behind the broadcast by each one, however the engine
    /// then catches up, and nothing shown beside it may run ahead.
    private var liveHoldSince: Date?
    private var liveHeldSeconds: TimeInterval = 0
    private var skipTask: Task<Void, Never>?
    /// Holds a surface teardown back long enough for a replacement to arrive.
    private var pendingTeardown: Task<Void, Never>?
    private var candidates: [URL] = []
    private var originalURLs: [URL] = []
    private var started = Date()
    private var suspended = false
    private var shouldResume = false
    private weak var videoView: MobileVideoHost?
    /// The same view, readable by the dismissal so it can still the picture.
    var videoViewForExit: MobileVideoHost? { videoView }
    private var waitingForVideo = false
    private var waitingSince: Date?
    private var currentURL: URL?
    private var pausedByUser = false
    private var health = LivePlaybackHealth(now: ProcessInfo.processInfo.systemUptime)
    private var retries = LivePlaybackRetry()
    private var retryAt: TimeInterval?
    /// Whether the AVPlayer item now open has shown a picture: past that, its
    /// opening watchdog has nothing more to judge.
    private var systemPictureSeen = false

    // Starting together; see `StartTogether`.
    /// Shut from the moment a stream is opened until its picture moves.
    private var startGateOpen = true
    private var startGate: Task<Void, Never>?
    /// Hands over the AVPlayer item's frames as each falls due, which is how
    /// a moving picture is told from a held one. Attached only while shut.
    private var gateOutput: AVPlayerItemVideoOutput?
    private var gateFrames = 0
    private var gateLastFrameAt: TimeInterval?
    /// When the engine started playing behind the shut gate: the sound has
    /// been held since then.
    private var heldSoundSince: TimeInterval?
    /// VLC's picture behind the gate: when it first came up, the pictures
    /// shown by then, and its size and how long it has held it.
    private var vlcPictureUpAt: TimeInterval?
    private var vlcPicturesAtUp = 0
    private var vlcGateSize = CGSize.zero
    private var vlcGateSizeSince: TimeInterval?

    // AVPlayer engine state.
    private var systemObservers: [NSKeyValueObservation] = []
    private var systemNotifications: [NSObjectProtocol] = []
    private var systemSubtitleGroup: AVMediaSelectionGroup?
    private var systemSubtitleOptions: [String: AVMediaSelectionOption] = [:]
    private var systemAudioGroup: AVMediaSelectionGroup?
    private var systemAudioOptions: [String: AVMediaSelectionOption] = [:]
    /// Held apart from `systemObservers`: those are torn down on every channel
    /// change, and this one belongs to the layer, which outlives the item.
    private var pipObserver: NSKeyValueObservation?
    private var pipController: AVPictureInPictureController?
    private let pipDelegate = MobilePictureInPictureDelegate()
    /// Set while the app is backgrounded without PiP: the layer gives up its
    /// player so audio keeps decoding, and takes it back on return. This is a
    /// detach, not a teardown — the same `AVPlayer` keeps the same item and
    /// position throughout.
    private var layerDetachedForBackground = false
    private var lifecycleNotifications: [NSObjectProtocol] = []
    /// True between a non-active scene phase and the return to active. The
    /// health monitor reads it because a backgrounded stream is legitimately
    /// audio-only — see the monitor loop.
    private var inBackground = false

    /// Whether the bundle actually declares the `audio` background mode. Read
    /// from the built Info.plist rather than assumed, so dropping the key in
    /// `project.yml` degrades to a clean pause instead of iOS killing the app
    /// mid-buffer.
    static let backgroundAudioEnabled: Bool = {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        return modes?.contains("audio") ?? false
    }()

    /// Observation only. Every call is a no-op unless the viewer has switched
    /// diagnostics on, and none of them can alter what playback does.
    private let diag = PlaybackDiagnostics.shared

    /// The libvlc player behind this controller's VLC engine, when VLCKit's
    /// internals are reachable. The frame pipeline that will give VLC-backed
    /// channels Picture in Picture is built on this handle; nothing uses it yet.
    var libVLCHandle: OpaquePointer? { VLCFrameTap.handle(for: player) }

    /// The live values that decide whether a picture can appear at all.
    /// `layer ready` is the one that matters most: an AVPlayer can report
    /// itself playing, with audio, while its layer has never produced a frame.
    var diagnosticsSnapshot: [(label: String, value: String)] {
        let layer = videoView?.playerLayer
        let item = systemPlayer.currentItem
        return [
            ("engine", engine.rawValue),
            ("PiP renderer", engine == .aether ? aetherSession?.pictureInPictureRoute ?? "preparing" : engine.title),
            ("channel", currentChannelID.map(String.init) ?? "—"),
            ("url", currentURL?.lastPathComponent ?? "—"),
            ("awaiting surface", waitingForVideo ? "yes" : "no"),
            ("host", videoView.map { "\(Int($0.bounds.width))x\(Int($0.bounds.height)) window=\($0.window == nil ? "no" : "yes")" } ?? "none"),
            ("layer", layer == nil ? "none"
                : "frame \(Int(layer!.frame.width))x\(Int(layer!.frame.height)) attached=\(layer!.superlayer == nil ? "no" : "yes") player=\(layer!.player == nil ? "nil" : "set")"),
            ("layer ready", layer.map { $0.isReadyForDisplay ? "YES" : "NO" } ?? "—"),
            ("item status", item.map { ["unknown", "readyToPlay", "failed"][min(max($0.status.rawValue, 0), 2)] } ?? "—"),
            ("item error", item?.error.map { "\($0.localizedDescription)" } ?? "—"),
            ("player error", systemPlayer.error.map { "\($0.localizedDescription)" } ?? "—"),
            ("rate", String(format: "%.2f", systemPlayer.rate)),
            ("timeControl", ["paused", "waitingToPlay", "playing"][min(max(systemPlayer.timeControlStatus.rawValue, 0), 2)]),
            ("likelyToKeepUp", item.map { $0.isPlaybackLikelyToKeepUp ? "yes" : "no" } ?? "—"),
            ("presentationSize", item.map { "\(Int($0.presentationSize.width))x\(Int($0.presentationSize.height))" } ?? "—"),
            // The decisive one for a stream that plays audio with a black
            // picture: AVPlayer will happily run an item whose video track it
            // cannot decode, reporting no error at all.
            ("video tracks", item.map { i in
                let video = i.tracks.filter { $0.assetTrack?.mediaType == .video }
                return "\(video.count) enabled=\(video.filter(\.isEnabled).count)"
            } ?? "—"),
            ("vlc playing", player.isPlaying ? "yes" : "no"),
            ("vlc videoOut", player.hasVideoOut ? "yes" : "no"),
            ("pip possible", pictureInPicturePossible ? "yes" : "no"),
            ("libvlc handle", libVLCHandle == nil ? "UNAVAILABLE" : "ok"),
            ("frame api", VLCFrameTap.videoCallbackAPIIsLinked ? "linked" : "MISSING"),
            ("start together", startGateOpen ? "open"
                : "holding sound" + (heldSoundSince.map { String(format: " %.1fs", ProcessInfo.processInfo.systemUptime - $0) } ?? "")),
            ("loading", loading ? "yes" : "no"),
            ("catch-up", catchUp.map { "replay from \($0.streamStart.formatted(date: .omitted, time: .shortened)) +\(Int(recordingElapsed))s" }
                ?? (catchUpSource == nil ? "—" : "recorded, live")),
            ("error", error ?? "—")
        ]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        subtitlePreferences = MobileSubtitlePreferences(defaults: defaults)
        pipDelegate.controller = self
        // An AVPlayerLayer that still holds its player suspends decoding once
        // the window leaves the screen, which would silence background audio.
        // This rides real backgrounding rather than `scenePhase`, so a
        // control-centre pull (a transient `.inactive`) does not blank the
        // video, and it never fights PiP: if PiP starts automatically a moment
        // later, its delegate reattaches the layer.
        let center = NotificationCenter.default
        lifecycleNotifications = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.detachLayerForBackground() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reattachLayerAfterBackground() }
            }
        ]
    }

    deinit {
        lifecycleNotifications.forEach { NotificationCenter.default.removeObserver($0) }
        // Its last release tears VLC down, which is not for the main thread:
        // each new preview replaces the controller that showed the last one.
        VLCPlayerDisposal.release(player)
    }

    /// "1080p", "720p", etc., derived from the source video track. Nil until the
    /// engine reports track info, which only happens once a video is decoding.
    var qualityLabel: String? {
        guard let height = videoHeight, height > 0 else { return nil }
        switch height {
        case 2160...: return "4K"
        case 1440...: return "1440p"
        case 1080...: return "1080p"
        case 720...: return "720p"
        case 480...: return "480p"
        default: return "\(height)p"
        }
    }

    var streamQualityLabel: String? { qualityLabel }

    var selectedSubtitleTitle: String {
        subtitleTracks.first(where: { $0.id == selectedSubtitleID })?.title ?? "Off"
    }

    var selectedAudioTitle: String {
        audioTracks.first(where: { $0.id == selectedAudioID })?.title ?? "Default"
    }

    /// Keep the sound and subtitles chosen for a show's episodes, and put
    /// them back on the next one. Set before `start`, so the engine opens on
    /// the kept language rather than switching to it.
    func remembersTracks(forShow show: String?) {
        trackMemoryShow = show
        showTracks = show.flatMap { MobileTrackMemory.load($0, defaults: defaults) }
    }

    var remembersShowTracks: Bool { trackMemoryShow != nil }

    // MARK: - Position

    /// Query the real input clock rather than VLCKit's event cache. VLC3
    /// suppresses position/time events while paused, including after a seek.
    /// A missing input is unknown, not a fabricated zero or requested target.
    var vlcPlaybackSeconds: Double? {
        guard engine == .vlc, player.media != nil else { return nil }
        let milliseconds = LineupVLCPlaybackTimeMilliseconds(player)
        return milliseconds >= 0 ? Double(milliseconds) / 1000 : nil
    }

    /// Read straight from whichever engine is running. Both report a length of
    /// zero for a live stream, so a title with no end simply has no progress to
    /// publish and the player shows live chrome instead of a scrubber.
    private func sampleProgress() {
        guard !isScrubbing else { return }
        let sampled: MobilePlaybackProgress?
        switch engine {
        case .aether:
            let duration = aetherSession?.duration ?? 0
            let position = aetherSession?.position ?? 0
            sampled = duration > 0 && position.isFinite
                ? MobilePlaybackProgress(position: min(max(0, position), duration), duration: duration) : nil
        case .system:
            let item = systemPlayer.currentItem
            let duration = item?.duration.seconds ?? .nan
            let position = systemPlayer.currentTime().seconds
            sampled = duration.isFinite && duration > 0 && position.isFinite
                ? MobilePlaybackProgress(position: min(max(0, position), duration), duration: duration) : nil
        case .vlc:
            let lengthMs = player.media?.length.intValue ?? 0
            let duration = Double(lengthMs) / 1000
            guard let position = vlcPlaybackSeconds else { return }
            sampled = lengthMs > 0
                ? MobilePlaybackProgress(position: min(max(0, position), duration), duration: duration) : nil
        case .mpv:
            let duration = mpvSession?.duration ?? 0
            let position = mpvSession?.position ?? 0
            sampled = duration > 0 && position.isFinite
                ? MobilePlaybackProgress(position: min(max(0, position), duration), duration: duration) : nil
        }
        if let reopenPosition {
            // Until the reopened stream is back where it was, its clock reads
            // from the beginning, and showing or saving that would lose the
            // viewer's place. The last good position stands in meanwhile.
            let playing = activeEngineIsPlaying
            guard retryAt == nil, playing, let sampled else { return }
            // VLC was opened there; only a stream that would not start there
            // is moved, which would buffer it a second time.
            if engine != .system {
                guard sampled.position > 0 else { return }
                if Self.opened(at: reopenPosition, position: sampled.position) {
                    progress = sampled
                    self.reopenPosition = nil
                    return
                }
            }
            progress = MobilePlaybackProgress(position: min(reopenPosition, sampled.duration),
                                              duration: sampled.duration)
            self.reopenPosition = nil
            seek(to: reopenPosition)
            return
        }
        if let sampled, !seekLanding.accepts(sampled.position, now: ProcessInfo.processInfo.systemUptime) { return }
        progress = sampled
        if !appliedInitialPosition, let requestedInitialPosition, let progress,
           requestedInitialPosition >= 10, requestedInitialPosition < progress.duration - 30 {
            if engine != .system {
                guard activeEngineIsPlaying, progress.position > 0 else { return }
                if Self.opened(at: requestedInitialPosition, position: progress.position) {
                    appliedInitialPosition = true
                    return
                }
            }
            appliedInitialPosition = true
            seek(to: requestedInitialPosition)
        }
    }

    /// Where a title's stream is opened: back where it was after a drop, or
    /// where it was left off. VLC starts there itself; AVPlayer is moved
    /// there once it is ready.
    private var openingPlace: TimeInterval? {
        if let reopenPosition { return reopenPosition }
        guard !appliedInitialPosition, let requestedInitialPosition, requestedInitialPosition >= 10 else {
            return nil
        }
        return requestedInitialPosition
    }

    /// Whether a stream asked to open at a place did. The first frames land
    /// on the keyframe before it, so close counts; a stream that ignored the
    /// request starts at its beginning instead.
    private static func opened(at place: TimeInterval, position: TimeInterval) -> Bool {
        abs(position - place) <= 15
    }

    /// Hold the sampled position still while a finger is on the scrubber, so
    /// the thumb does not fight the engine's own reports on the way past.
    func beginScrubbing() {
        guard !isScrubbing, let progress = isLive ? recordingProgress : self.progress,
              progress.duration.isFinite, progress.duration > 0 else { return }
        isScrubbing = true
        scrubDestination = progress.position
        skipTask?.cancel()
        skipTask = nil
        skipTarget = nil
        scrubSeeks.cancel()
        resumeAfterScrubbing = !pausedByUser
        if resumeAfterScrubbing { toggle() }
    }

    func previewScrubbing(at seconds: Double) {
        guard isScrubbing, seconds.isFinite, let progress = isLive ? recordingProgress : self.progress else { return }
        let target = PlaybackSeekPolicy.clamped(seconds, duration: progress.duration)
        scrubDestination = target
        if isLive, let catchUp {
            let offset = catchUp.programmeStart.addingTimeInterval(target).timeIntervalSince(catchUp.streamStart)
            // A provider-only seek reopens once on release, never for every
            // finger update. Engines that can seek preview through the same
            // coalescer as Library playback.
            if canSeekRecording(to: offset) {
                scrubSeeks.preview(offset) { [weak self] in self?.performRecordingSeek(to: $0) }
            }
            return
        }
        scrubSeeks.preview(target) { [weak self] in self?.performSeek(to: $0) }
    }

    func endScrubbing(at seconds: Double) {
        guard isScrubbing else { return }
        let resume = resumeAfterScrubbing
        if isLive, let catchUp, seconds.isFinite {
            seekRecording(to: catchUp.programmeStart.addingTimeInterval(seconds), immediately: true)
        } else {
            seek(to: seconds)
        }
        isScrubbing = false
        scrubDestination = nil
        // A provider reopen clears pause intent. Restore it in either
        // direction, including a drag that began while already paused.
        if resume == pausedByUser { toggle() }
        resumeAfterScrubbing = false
    }

    func finishScrubbing(resume: Bool = true) {
        guard isScrubbing else { return }
        if isLive, !resume {
            // A disappearing/retuned replay must not commit an obsolete drag.
            scrubSeeks.cancel()
            isScrubbing = false
            scrubDestination = nil
            resumeAfterScrubbing = false
            return
        }
        if !resume { resumeAfterScrubbing = false }
        endScrubbing(at: scrubDestination ?? progress?.position ?? 0)
    }

    func seek(to seconds: Double) {
        guard let current = progress, current.duration > 0 else { return }
        guard seconds.isFinite else { return }
        let target = PlaybackSeekPolicy.clamped(seconds, duration: current.duration)
        appliedInitialPosition = true
        reopenPosition = nil
        seekLanding.expect(target, now: ProcessInfo.processInfo.systemUptime)
        scrubSeeks.commit(target) { [weak self] in self?.performSeek(to: $0) }
        progress = MobilePlaybackProgress(position: target, duration: current.duration)
        diag.record("seek to \(Int(target))s of \(Int(current.duration))s via \(engine.rawValue)")
    }

    private func performSeek(to target: Double) {
        guard let current = progress, current.duration > 0 else { return }
        switch engine {
        case .aether:
            aetherSession?.seek(to: target)
        case .system:
            // Half a second either side rather than an exact frame. An exact
            // seek makes AVPlayer decode forward from the previous keyframe,
            // which is most of the wait for no difference anyone can see.
            let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
            systemPlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                              toleranceBefore: tolerance, toleranceAfter: tolerance)
        case .vlc:
            // A fraction rather than a VLCTime: `position` is the one seek the
            // pinned VLCKit has always exposed the same way.
            player.position = Float(target / current.duration)
        case .mpv:
            mpvSession?.seek(to: target)
        }
    }

    /// Back or on by `seconds`. A title steps through itself. A channel the
    /// provider records goes back into its recording, and a recording brought
    /// up to the present goes back to live. Presses in quick succession add
    /// up before the stream is reopened, so a run of taps opens it once.
    func skip(by seconds: Double) {
        guard isLive else {
            guard let current = progress else { return }
            seek(to: current.position + seconds)
            return
        }
        skipRecording(by: seconds)
    }

    // MARK: - Surface

    func attachVideo(_ view: MobileVideoHost) {
        pendingTeardown?.cancel()
        pendingTeardown = nil
        diag.record("attachVideo \(Int(view.bounds.width))x\(Int(view.bounds.height)) window=\(view.window == nil ? "no" : "yes") engine=\(engine.rawValue) first=\(videoView !== view)")
        videoView = view
        switch engine {
        case .aether:
            player.drawable = nil
            view.removePlayerLayer()
            if let surface = aetherSession?.surface { view.installEngineSurface(surface) }
        case .mpv:
            player.drawable = nil
            view.removePlayerLayer()
            if let surface = mpvSession?.surface { view.installEngineSurface(surface) }
        case .vlc:
            view.removeEngineSurface()
            view.removePlayerLayer()
            if (player.drawable as? UIView) !== view { player.drawable = view }
            startWhenVideoIsReady()
        case .system:
            view.removeEngineSurface()
            attachSystemLayer(to: view)
        }
    }

    func detachVideo(_ view: MobileVideoHost) {
        diag.record("detachVideo mine=\(videoView === view) pip=\(pictureInPictureActive)")
        guard videoView === view else { return }
        // Picture in Picture outlives the view that started it: the window is
        // showing this stream, and tearing the engine down here would close it.
        guard !pictureInPictureActive else {
            // AVKit still owns this renderer. Clearing its player here would
            // close the floating window as the original host leaves the screen.
            if engine == .system { view.releasePlayerLayerForPictureInPicture() }
            videoView = nil
            return
        }
        player.drawable = nil
        view.removePlayerLayer()
        videoView = nil
        // A layout change big enough for SwiftUI to rebuild the video surface
        // arrives here as a teardown immediately followed by a new surface.
        // Stopping the engine on the spot turns going full screen into a visible
        // reconnect, so hold off a moment: a replacement surface cancels this,
        // and anything else really was a teardown.
        pendingTeardown?.cancel()
        pendingTeardown = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            // Re-check Picture in Picture as well as the surface: the window can
            // take the stream over inside this window, and stopping the engine
            // underneath it would close the very thing the viewer moved to.
            guard let self, !Task.isCancelled,
                  self.videoView == nil, !self.pictureInPictureActive else { return }
            self.pendingTeardown = nil
            self.stop()
        }
    }

    /// Installs the AVPlayer layer and, the first time, the PiP controller that
    /// rides on it. Re-attaching an existing layer is a no-op, which is what
    /// keeps expand/collapse and rotation from restarting the stream.
    private func attachSystemLayer(to view: MobileVideoHost) {
        player.drawable = nil
        let existed = view.playerLayer != nil
        let layer = view.installPlayerLayer(for: systemPlayer, reusing: pipController?.playerLayer)
        view.holdPicture(!startGateOpen)
        diag.record("attachSystemLayer \(existed ? "reused" : "created") frame=\(Int(layer.frame.width))x\(Int(layer.frame.height)) player=\(layer.player == nil ? "nil" : "set")")
        if pipController?.playerLayer !== layer {
            pipController = AVPictureInPictureController(playerLayer: layer)
            pipController?.delegate = pipDelegate
            // Backgrounding an inline player hands it to the system window
            // instead of stopping it. This is what "entering PiP preserves the
            // stream" means in practice: no new item, no new connection.
            pipController?.canStartPictureInPictureAutomaticallyFromInline = allowsPictureInPicture
            observePictureInPicturePossible()
        }
    }

    private func observePictureInPicturePossible() {
        guard let pip = pipController else { return }
        pictureInPicturePossible = pip.isPictureInPicturePossible
        pipObserver = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] pip, _ in
            let possible = pip.isPictureInPicturePossible
            onMain {
                guard let self, self.engine == .system, self.pipController === pip else { return }
                self.pictureInPicturePossible = possible
            }
        }
    }

    // MARK: - Starting together

    /// Holds the sound and keeps the picture back until the picture moves.
    private func closeStartGate() {
        startGate?.cancel()
        startGateOpen = false
        gateFrames = 0
        gateLastFrameAt = nil
        heldSoundSince = nil
        vlcPictureUpAt = nil
        vlcGateSize = .zero
        vlcGateSizeSince = nil
        switch engine {
        case .aether: aetherSession?.isMuted = true
        case .mpv: mpvSession?.isMuted = true
        case .system: systemPlayer.isMuted = true
        case .vlc: player.audio?.isMuted = true
        }
        videoView?.holdPicture(true)
        diag.record("start together: holding sound until the picture moves")
        startGate = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
                guard let self, !Task.isCancelled, !self.startGateOpen else { return }
                self.checkStartGate()
            }
        }
    }

    private func checkStartGate() {
        let now = ProcessInfo.processInfo.systemUptime
        // Backgrounded, the sound is all there is to play.
        if inBackground {
            openStartGate("in background")
            return
        }
        switch engine {
        case .aether:
            if aetherSession?.hasPicture == true { openStartGate("Aether picture ready") }
        case .mpv:
            guard let session = mpvSession else { return }
            if session.hasVideoOut {
                openStartGate("MPV picture ready")
            } else if let audioCodec = session.audioCodec, !audioCodec.isEmpty, session.isPlaying {
                if heldSoundSince == nil { heldSoundSince = now }
                guard let since = heldSoundSince, now - since > StartTogether.soundAloneAfter else { return }
                openStartGate("no picture after \(Int(StartTogether.soundAloneAfter))s, sound alone")
            } else {
                heldSoundSince = nil
            }
        case .system:
            let playing = systemPlayer.timeControlStatus == .playing
            if playing, heldSoundSince == nil { heldSoundSince = now }
            // Paused, by the viewer or the app going to the background, no
            // sound is being held: the wait starts again on resuming.
            if systemPlayer.timeControlStatus == .paused { heldSoundSince = nil }
            if let item = systemPlayer.currentItem, item.status == .readyToPlay, !item.tracks.isEmpty,
               !item.tracks.contains(where: { $0.assetTrack?.mediaType == .video }) {
                openStartGate("no picture to wait for")
                return
            }
            guard playing, let output = gateOutput else { return }
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            guard output.hasNewPixelBuffer(forItemTime: time) else { return }
            // Taken rather than only seen, so the next one reads as new.
            _ = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
            gateFrames = StartTogether.frames(after: gateFrames, lastFrameAt: gateLastFrameAt, now: now)
            gateLastFrameAt = now
            if gateFrames >= StartTogether.framesToStart { openStartGate("picture moving") }
        case .vlc:
            guard player.isPlaying else { return }
            if heldSoundSince == nil { heldSoundSince = now }
            // VLC builds its sound output as it starts and can bring it up
            // unmuted; held again until the picture is there.
            if player.audio?.isMuted == false { player.audio?.isMuted = true }
            if player.hasVideoOut {
                // Shown once its shape has settled, so a first frame drawn
                // before VLC knows it never shows stretched.
                let pictures = player.media?.numberOfDisplayedPictures ?? 0
                if vlcPictureUpAt == nil {
                    vlcPictureUpAt = now
                    vlcPicturesAtUp = pictures
                }
                let size = player.videoSize
                if size != vlcGateSize {
                    vlcGateSize = size
                    vlcGateSizeSince = now
                }
                let steady = size.width > 0 && size.height > 0
                    && now - (vlcGateSizeSince ?? now) >= StartTogether.vlcSettle
                    && pictures - vlcPicturesAtUp >= StartTogether.vlcFramesToSettle
                if StartTogether.canRevealVLC(displayedPictures: pictures, settled: steady,
                                             outputAge: now - (vlcPictureUpAt ?? now)) {
                    if steady {
                        openStartGate("picture up, \(Int(size.width))x\(Int(size.height))")
                    } else {
                        openStartGate("picture rendered, shape not settled")
                    }
                }
            } else if let since = heldSoundSince, now - since > StartTogether.soundAloneAfter {
                let tracks = player.media?.tracksInformation as? [[String: Any]] ?? []
                let hasVideo = player.videoSize.width > 0 || tracks.contains {
                    ($0[VLCMediaTracksInformationType] as? String) == VLCMediaTracksInformationTypeVideo
                }
                let hasAudio = tracks.contains {
                    ($0[VLCMediaTracksInformationType] as? String) == VLCMediaTracksInformationTypeAudio
                }
                if StartTogether.canReleaseAudioOnly(heldFor: now - since, hasAudio: hasAudio, hasVideo: hasVideo) {
                    openStartGate("audio-only stream")
                }
            }
        }
    }

    /// Sound and picture, together.
    private func openStartGate(_ reason: String) {
        guard !startGateOpen else { return }
        startGateOpen = true
        startGate?.cancel()
        startGate = nil
        let held = heldSoundSince.map { ProcessInfo.processInfo.systemUptime - $0 }
        diag.record("start together: \(reason)" + (held.map { String(format: ", sound held %.1fs", $0) } ?? ""))
        heldSoundSince = nil
        releaseGateOutput()
        switch engine {
        case .aether: aetherSession?.isMuted = audioMuted
        case .mpv: mpvSession?.isMuted = audioMuted
        case .system:
            systemPlayer.isMuted = audioMuted
            if systemPlayer.currentItem?.status == .readyToPlay { loading = false }
        case .vlc:
            player.audio?.isMuted = audioMuted
        }
        videoView?.holdPicture(false)
        notePresentedVideo()
    }

    private func notePresentedVideo() {
        guard startGateOpen else { return }
        let ready: Bool
        switch engine {
        case .vlc: ready = player.hasVideoOut && (player.media?.numberOfDisplayedPictures ?? 0) > 0
        case .aether: ready = aetherSession?.hasPicture == true
        case .system: ready = systemPictureSeen
        case .mpv: ready = mpvSession?.hasVideoOut == true
        }
        if ready, !presentation.hasPresentedVideo || presentation.recovering { presentation.presentedVideo() }
    }

    /// The sound as the viewer has it, once the start gate has let it out.
    private func applyMute() {
        guard startGateOpen else { return }
        systemPlayer.isMuted = audioMuted
        player.audio?.isMuted = audioMuted
        aetherSession?.isMuted = audioMuted
        mpvSession?.isMuted = audioMuted
    }

    /// The gate goes with the stream it held: nothing left muted or hidden.
    private func resetStartGate() {
        startGate?.cancel()
        startGate = nil
        releaseGateOutput()
        heldSoundSince = nil
        startGateOpen = true
        systemPlayer.isMuted = audioMuted
        player.audio?.isMuted = audioMuted
        aetherSession?.isMuted = audioMuted
        mpvSession?.isMuted = audioMuted
        videoView?.holdPicture(false)
    }

    private func releaseGateOutput() {
        if let output = gateOutput, let item = systemPlayer.currentItem,
           item.outputs.contains(where: { $0 === output }) {
            item.remove(output)
        }
        gateOutput = nil
    }

    // MARK: - Picture in Picture

    var canOfferPictureInPicture: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
            && engine.supportsPictureInPicture && (pictureInPicturePossible || pictureInPictureActive)
    }

    func togglePictureInPicture() {
        if engine == .aether { aetherSession?.togglePictureInPicture(); return }
        guard let pip = pipController else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() }
        else { pip.startPictureInPicture() }
    }

    fileprivate func pictureInPictureChanged(active: Bool) {
        diag.record("pictureInPicture active=\(active)")
        pictureInPictureActive = active
        // Coming back from the PiP window into a foregrounded app: whatever the
        // background detach did has to be undone before the layer can draw.
        reattachLayerAfterBackground()
    }

    fileprivate func ownsSystemPiP(_ controller: AVPictureInPictureController) -> Bool {
        engine == .system && pipController === controller
    }

    fileprivate func pictureInPictureClosed() {
        guard inBackground else { return }
        pausedByUser = true
        switch engine {
        case .aether: aetherSession?.pause()
        case .mpv: mpvSession?.pause()
        case .system: systemPlayer.pause()
        case .vlc: player.pause()
        }
        refreshIsPlaying()
    }

    // MARK: - Opening

    /// - Parameters:
    ///   - channelID: the provider stream this is, so failover can retire it.
    ///   - resetFailover: true for anything the viewer initiated — a new
    ///     selection, Retry, or jumping back to live — which makes the channels
    ///     that failed earlier eligible again. Only an automatic switch passes
    ///     false, so one bad game cannot loop through the same dead feeds.
    func start(urls: [URL], channelID: Int? = nil, resetFailover: Bool = true,
               initialPosition: TimeInterval? = nil, recording: Bool = false) {
        diag.beginSession("start channel=\(channelID.map(String.init) ?? "—") urls=\(urls.count) resetFailover=\(resetFailover)")
        for url in MobileEngineSelection.ordered(urls, live: isLive) {
            diag.record("  candidate \(url.lastPathComponent) -> \(MobileEngineSelection.engine(for: url)?.title ?? "unavailable")")
        }
        // Also ends any recording: whatever opens next is live unless the
        // recording itself is what is being opened, which says so afterwards.
        stop()
        presentation = MobilePlaybackPresentation()
        preference = MobilePlaybackPreference.selected(in: defaults)
        failedEngines.removeAll()
        sourceIsRecording = recording
        // A recording belongs to its channel. Another channel -- the viewer's
        // choice or failover's -- leaves the last one's behind.
        if let channelID, let source = catchUpSource, source.stream.id != channelID {
            catchUpSource = nil
        }
        requestedInitialPosition = initialPosition
        appliedInitialPosition = false
        reopenPosition = nil
        finished = false
        error = nil
        originalURLs = urls
        if let channelID { currentChannelID = channelID }
        if resetFailover {
            failoverState.reset()
            pendingWorkingChannelID = nil
        }
        retries.reset()
        // Keep a playback-confirmed live transport first. Fresh provider lists
        // still start HLS first, and Library ordering/PiP behavior is unchanged.
        candidates = MobileEngineSelection.ordered(urls, live: isLive)
        do {
            try MobileAudioSession.activate(for: self)
        } catch {
            self.error = "Audio could not start. Please try again."
            loading = false
            return
        }
        openNext()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self else { return }
                // Sampled before every other guard: the AVPlayer engine skips
                // the rest of this loop, and a paused or backgrounded stream is
                // exactly when some of these values matter. Observation only,
                // and only built while the diagnostics are on: the snapshot
                // reads tracks from both engines and formats every value.
                if self.diag.isEnabled { self.diag.update(snapshot: self.diagnosticsSnapshot) }
                self.refreshMediaInfo()
                self.notePresentedVideo()
                if self.isScrubbing { continue }
                self.sampleProgress()
                // A recording's place is kept while it is paused too, so the
                // timeline still reads right after a skip made without resuming.
                self.sampleRecording()
                if self.seekLanding.isWaiting(now: ProcessInfo.processInfo.systemUptime) { continue }
                self.followRecordingIntoNextProgramme()
                if self.engine == .system, self.startGateOpen,
                   self.systemPlayer.timeControlStatus == .playing,
                   self.videoView?.playerLayer?.isReadyForDisplay == true {
                    self.confirmWorkingChannel()
                }
                if self.engine == .vlc {
                    self.refreshVLCSubtitleTracks()
                    self.refreshVLCAudioTracks()
                }
                // VLC can bring its sound output back up unmuted as it
                // reconnects; a quiet picture stays quiet.
                if self.audioMuted, self.startGateOpen, self.engine == .vlc,
                   self.player.audio?.isMuted == false { self.player.audio?.isMuted = true }
                if self.engine == .aether { self.checkAetherPlayback() }
                guard !self.suspended, !self.pausedByUser else { continue }
                if let retryAt = self.retryAt {
                    if ProcessInfo.processInfo.systemUptime >= retryAt {
                        self.retryAt = nil
                        self.openNext()
                    }
                    continue
                }
                // AVPlayer reports status through KVO, but it has no failure to
                // report when a playlist simply never loads: the item stays at
                // .unknown with no error, so nothing fires and the transport
                // stream queued behind it is never tried. This deadline is the
                // AVPlayer equivalent of the drawable timeout the VLC path has
                // had since 0.17.4.
                // It judges an opening only. Once the item has shown a picture
                // it has opened, and a size reading zero for a moment later on
                // -- a rendition switch -- is not a dead endpoint; failing over
                // then dropped a working stream and Picture in Picture with it.
                if self.engine == .system, self.error == nil, !self.systemPictureSeen {
                    let item = self.systemPlayer.currentItem
                    let isReady = item?.status == .readyToPlay
                    let hasVideo = (item?.presentationSize.width ?? 0) > 0
                    if isReady && hasVideo { self.systemPictureSeen = true }
                    let verdict = SystemEngineWatchdog.verdict(
                        elapsed: Date().timeIntervalSince(self.started),
                        isReady: isReady, hasVideo: hasVideo)
                    if verdict == .failOver {
                        self.diag.record("watchdog: giving up on \(self.currentURL?.lastPathComponent ?? "—") after \(Int(Date().timeIntervalSince(self.started)))s, status=\(item?.status == .readyToPlay ? "ready" : "unready") size=\(Int(item?.presentationSize.width ?? 0))x\(Int(item?.presentationSize.height ?? 0))")
                        self.systemEngineFailed()
                    }
                }
                // Sound held over a picture that will not move: the channel's
                // other stream is likelier to start than this one is to catch up.
                if self.engine == .system, !self.startGateOpen, self.error == nil,
                   StartTogether.shouldTryNext(
                       heldFor: self.heldSoundSince.map { ProcessInfo.processInfo.systemUptime - $0 },
                       isLive: self.isLive, hasAnotherStream: !self.candidates.isEmpty) {
                    self.diag.record("start together: picture still after \(Int(StartTogether.stillPictureDeadline))s of sound, trying the next stream")
                    self.systemEngineFailed()
                    continue
                }
                if self.engine == .mpv {
                    self.checkMPVPlayback()
                    continue
                }
                guard self.engine == .vlc else { continue }
                self.startWhenVideoIsReady()
                if self.waitingForVideo {
                    // The video surface never got a real window/size to attach to
                    // (e.g. a layout hiccup). Without this, playback silently
                    // never starts: no audio, no video, no error, forever.
                    if let since = self.waitingSince, Date().timeIntervalSince(since) > 8 {
                        self.waitingForVideo = false
                        self.loading = false
                        self.error = "The video couldn't start. Try again."
                        UIApplication.shared.isIdleTimerDisabled = false
                    }
                    continue
                }
                guard self.error == nil else { continue }
                self.isPlaying = self.player.isPlaying
                self.loading = !self.player.isPlaying || !self.player.hasVideoOut || !self.startGateOpen
                if self.player.isPlaying && self.player.hasVideoOut { self.refreshStats() }
                // A backgrounded stream has no video output by design. Feeding
                // that to the health model would read as a lost picture and
                // reconnect on a loop for as long as the app stays backgrounded,
                // which is the opposite of keeping playback alive. Recovery
                // resumes, with a fresh baseline, on return to the foreground.
                guard !self.inBackground else { continue }
                let now = ProcessInfo.processInfo.systemUptime
                // VLC finishes a stop on its own thread, so a stream reopened a
                // moment ago can still read as stopped or ended while the new
                // one starts. A channel has only stopped once it has played
                // since it was opened, or once it has had long enough to.
                let state = self.player.state
                let stopped = state == .error
                    || ((state == .ended || state == .stopped)
                        && MobilePlaybackOpeningPolicy.stoppedIsFailure(isLive: self.isLive,
                            hasShownPicture: self.health.hasShownPicture, age: self.health.age(now: now)))
                // A title that stops at its end has finished. The same stop
                // anywhere earlier is a dropped stream, reopened in place.
                if stopped, self.reachedEnd(vlcPosition: self.player.position) {
                    self.finish()
                    continue
                }
                // What has been read from the server tells a feed VLC is catching
                // up on from one that has stopped coming.
                let recover = self.health.observe(now: now, playing: self.player.isPlaying, video: self.player.hasVideoOut,
                    time: self.player.time.intValue, frames: self.player.media?.numberOfDisplayedPictures,
                    bytes: self.player.media?.numberOfReadBytesOnInput, failed: stopped)
                if self.health.isStable(now: now) {
                    self.retries.reset()
                    self.confirmWorkingChannel()
                }
                if recover {
                    if !self.health.hasShownPicture, !self.candidates.isEmpty { self.advanceAfterEngineFailure() }
                    else { self.scheduleRecovery(now: now) }
                }
            }
        }
    }

    private func openNext() {
        liveQualityReporter.reset()
        systemPictureSeen = false
        resetStartGate()
        teardownSystemEngine()
        aetherSession?.stop()
        mpvSession?.stop()
        videoView?.removeEngineSurface()
        pictureInPicturePossible = false
        player.stop()
        resetSubtitles()
        waitingForVideo = false
        waitingSince = nil
        isPlaying = false
        videoWidth = nil
        videoHeight = nil
        mediaInfo = PlaybackMediaInfo()
        nativeMediaInfo.reset()
        guard !candidates.isEmpty else {
            loading = false
            UIApplication.shared.isIdleTimerDisabled = false
            error = "This stream is unavailable. Try again or choose another channel."
            return
        }
        let url = candidates.removeFirst()
        currentURL = url
        guard let selected = MobileEngineSelection.engine(for: url, preference: preference,
                                                          failed: failedEngines[url] ?? []) else {
            openNext()
            return
        }
        engine = selected
        health = LivePlaybackHealth(now: ProcessInfo.processInfo.systemUptime, stallLimit: isLive ? 12 : 30)
        diag.record("openNext \(url.lastPathComponent) engine=\(engine.rawValue) remaining=\(candidates.count)")
        started = Date()
        loading = true
        switch engine {
        case .aether: openAether(url)
        case .system: openSystem(url)
        case .vlc: openVLC(url)
        case .mpv: openMPV(url)
        }
    }

    private func openAether(_ url: URL) {
        player.drawable = nil
        do {
            let session: AetherPlaybackSession
            if let existing = aetherSession { session = existing }
            else {
                session = try AetherPlaybackSession(); aetherSession = session
                session.startsPictureInPictureAutomatically = allowsPictureInPicture
            }
            session.onPictureInPictureChange = { [weak self] active in
                guard let self, self.engine == .aether else { return }
                self.pictureInPictureChanged(active: active)
            }
            session.onPictureInPictureClosed = { [weak self] in
                guard let self, self.engine == .aether else { return }
                self.pictureInPictureClosed()
            }
            session.onPictureInPictureTransportChange = { [weak self] playing in
                guard let self, self.engine == .aether else { return }
                self.pausedByUser = !playing
                self.refreshIsPlaying()
            }
            if let view = videoView {
                view.removePlayerLayer()
                view.installEngineSurface(session.surface)
            }
            session.load(url: url, startPosition: isLive ? nil : openingPlace,
                         isLive: isLive && !sourceIsRecording, expectedDuration: nil,
                         primary: isPrimaryOutput, matchContent: false,
                         preferredSubtitleLanguages: preferredSubtitleLanguages,
                         preferredAudioLanguages: preferredAudioLanguages)
            applySubtitleAppearance()
            closeStartGate()
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            diag.record("AetherEngine initialization failed")
            advanceAfterEngineFailure()
        }
    }

    private func openMPV(_ url: URL) {
        player.drawable = nil
        do {
            let session: MPVPlaybackSession
            if let existing = mpvSession { session = existing }
            else { session = try MPVPlaybackSession(); mpvSession = session }
            if let view = videoView {
                view.removePlayerLayer()
                view.installEngineSurface(session.surface)
            }
            closeStartGate()
            session.load(url: url, startPosition: isLive ? nil : openingPlace,
                         isLive: isLive && !sourceIsRecording,
                         preferredSubtitleLanguage: isLive || subtitlePreferences.language.isEmpty
                            ? nil : subtitlePreferences.language)
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            diag.record("MPV trial initialization failed")
            advanceAfterEngineFailure()
        }
    }

    private func checkAetherPlayback() {
        guard engine == .aether, let session = aetherSession, retryAt == nil else { return }
        if !inBackground { session.restoreForegroundVideo() }
        session.refreshPictureInPicture()
        let possible = session.pictureInPicturePossible
        if pictureInPicturePossible != possible { pictureInPicturePossible = possible }
        refreshIsPlaying()
        loading = !session.hasPicture || session.phase == .loading || session.phase == .buffering || !startGateOpen
        let size = session.videoSize
        if size.width > 0, size.height > 0 {
            let width = Int(size.width), height = Int(size.height)
            if videoWidth != width { videoWidth = width }
            if videoHeight != height { videoHeight = height }
        }
        let subtitles = session.subtitles
        let tracks: [PlaybackSubtitleTrack] = [.off] + subtitles.map {
            .init(id: "aether-\($0.id)", title: $0.title, engineIndex: $0.id)
        }
        if tracks != subtitleTracks { subtitleTracks = tracks }
        let selected = tracks.first { $0.engineIndex == session.selectedSubtitleIndex }?.id ?? PlaybackSubtitleTrack.off.id
        if selected != selectedSubtitleID { selectedSubtitleID = selected }
        if !isLive {
            for subtitle in subtitles { subtitleLanguages["aether-\(subtitle.id)"] = subtitle.language }
            let audio = session.audioTracks.map {
                MobileTrackOption(id: "aether-audio-\($0.id)", title: $0.title, language: $0.language, engineIndex: $0.id)
            }
            if audio != audioTracks { audioTracks = audio }
            let audioID = audio.first { $0.engineIndex == session.selectedAudioIndex }?.id
            if audioID != selectedAudioID { selectedAudioID = audioID }
            applyShowTracks()
        }
        if session.hasPicture && session.isPlaying { confirmWorkingChannel() }
        // PiP and background audio have their own renderer lifecycle; never
        // mistake a deliberately detached foreground picture for a lost feed.
        guard !pausedByUser, !suspended, error == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if session.phase == .ended, !isLive,
           LocalMediaTrackingPolicy.reachedEnd(ended: true, failed: false, hasPlayed: session.hasPicture,
               position: session.position, duration: session.duration,
               fraction: session.duration > 0 ? session.position / session.duration : 0) {
            finish()
            return
        }
        if session.phase == .failed {
            advanceAfterEngineFailure()
            return
        }
        guard !inBackground || pictureInPictureActive else { return }
        let recover = health.observe(now: now, playing: session.isPlaying, video: session.hasPicture,
            time: Int32(clamping: Int64(min(session.position * 1000, Double(Int32.max)))),
            frames: nil, bytes: session.bytesReceived, failed: session.phase == .failed || session.phase == .ended)
        if health.isStable(now: now) { retries.reset() }
        if recover {
            if !health.hasShownPicture { advanceAfterEngineFailure() }
            else { scheduleRecovery(now: now) }
        }
    }

    private func checkMPVPlayback() {
        guard engine == .mpv, let session = mpvSession, retryAt == nil else { return }
        refreshIsPlaying()
        loading = session.phase == .loading || session.phase == .buffering || !startGateOpen
        if session.videoSize.width > 0, session.videoSize.height > 0 {
            videoWidth = Int(session.videoSize.width)
            videoHeight = Int(session.videoSize.height)
        }
        let tracks: [PlaybackSubtitleTrack] = [.off] + session.subtitleTracks.map {
            .init(id: "mpv-\($0.id)", title: $0.title, engineIndex: $0.id)
        }
        if tracks != subtitleTracks { subtitleTracks = tracks }
        let selected = tracks.first { $0.engineIndex == session.selectedSubtitleIndex }?.id ?? PlaybackSubtitleTrack.off.id
        if selected != selectedSubtitleID { selectedSubtitleID = selected }
        if session.hasVideoOut && session.isPlaying { confirmWorkingChannel() }
        guard !pausedByUser, !suspended, error == nil else { return }
        if session.phase == .ended, !isLive,
           LocalMediaTrackingPolicy.reachedEnd(ended: true, failed: false, hasPlayed: session.hasVideoOut,
               position: session.position, duration: session.duration,
               fraction: session.duration > 0 ? session.position / session.duration : 0) {
            finish()
            return
        }
        if session.phase == .failed, !health.hasShownPicture {
            advanceAfterEngineFailure()
            return
        }
        guard !inBackground else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let recover = health.observe(now: now, playing: session.isPlaying, video: session.hasVideoOut,
            time: Int32(clamping: Int64(min(session.position * 1000, Double(Int32.max)))),
            frames: nil, bytes: nil, failed: session.phase == .failed || session.phase == .ended)
        if health.isStable(now: now) { retries.reset() }
        if recover {
            if !health.hasShownPicture { advanceAfterEngineFailure() }
            else { scheduleRecovery(now: now) }
        }
    }

    private func advanceAfterEngineFailure() {
        guard let url = currentURL else { return }
        if isLive && !health.hasShownPicture {
            Task { await LiveQualityVerifier.shared.forgetPlayback(url: url) }
        }
        failedEngines[url, default: []].insert(engine)
        if let next = MobileEngineSelection.engine(for: url, preference: preference, failed: failedEngines[url] ?? []) {
            // Try the provider's other PiP-capable endpoint before settling
            // for VLC, or retrying a broken HLS address through another engine.
            if (engine == .system || next == .vlc),
               let index = candidates.firstIndex(where: {
                   MobileEngineSelection.engine(for: $0, preference: preference,
                       failed: failedEngines[$0] ?? [])?.supportsPictureInPicture == true
               }) {
                let alternative = candidates.remove(at: index)
                candidates.append(url)
                candidates.insert(alternative, at: 0)
                openNext()
                return
            }
            if next == .vlc { show(notice: "Using VLC for this source. Picture in Picture is unavailable.") }
            if !isLive, reopenPosition == nil, let position = progress?.position, position > 0 { reopenPosition = position }
            candidates.insert(url, at: 0)
            openNext()
        } else if !candidates.isEmpty { openNext() }
        else {
            // A genuinely failed playback session gets a fresh bounded retry.
            // Keep the final engine so an unsupported Aether source does not
            // alternate forever between failed players on every attempt.
            failedEngines[url]?.remove(engine)
            scheduleRecovery(now: ProcessInfo.processInfo.systemUptime)
        }
    }

    private func openVLC(_ url: URL) {
        videoView?.removePlayerLayer()
        // VLCMedia(url:) is a plain, non-failable initializer on VLCKit 3.6.0
        // (the 4.0 alpha we moved off of made it failable), so no optional
        // binding here.
        let media = VLCMedia(url: url)
        if isLive {
            // Matches tvOS's buffer size — 3s was too tight for some providers
            // and read as a stall/drop after several minutes on a slightly
            // slower link.
            media.addOption(":network-caching=5000")
            media.addOption(":live-caching=5000")
            // A broadcast can carry a second language -- Spanish, most often
            // -- and VLC otherwise plays whichever track comes first.
            media.addOption(":audio-language=en")
        } else {
            // Five seconds of buffer is five seconds refilled after every
            // seek, which made scrubbing feel like it had hung; one second
            // seeks fast but leaves nothing in hand and a real server on a
            // real link stutters. Three is the compromise, and it is the one
            // number to move if either complaint comes back.
            media.addOption(":network-caching=3000")
            media.addOption(":file-caching=3000")
            // Opened at its place rather than at its beginning and then
            // moved, which buffered it twice before the first frame.
            if let place = openingPlace { media.addOption(":start-time=\(place)") }
        }
        media.addOption(":http-reconnect=true")
        if !isLive {
            if let language = preferredSubtitleLanguages.first {
                media.addOption(":sub-language=\(language),\(language.prefix(2))")
            }
            if showTracks?.audio != nil, let language = preferredAudioLanguages.first {
                media.addOption(":audio-language=\(language),\(language.prefix(2))")
            }
            media.addOption(":freetype-rel-fontsize=\(Int((16 / subtitlePreferences.scale).rounded()))")
            media.addOption(":freetype-background-opacity=\(subtitlePreferences.background ? 204 : 0)")
            media.addOption(":freetype-background-color=0")
        }
        player.media = media
        waitingForVideo = true
        waitingSince = Date()
        startWhenVideoIsReady()
    }

    private func applyQualityCeiling(to item: AVPlayerItem?) {
        guard let item else { return }
        item.preferredPeakBitRate = holdsQualityDown ? 2_500_000 : 0
        item.preferredMaximumResolution = holdsQualityDown ? CGSize(width: 960, height: 540) : .zero
    }

    private func openSystem(_ url: URL) {
        health = LivePlaybackHealth(now: ProcessInfo.processInfo.systemUptime, stallLimit: isLive ? 12 : 30)
        let item = AVPlayerItem(url: url)
        applyQualityCeiling(to: item)
        systemPlayer.replaceCurrentItem(with: item)
        applySubtitleAppearance()

        systemObservers.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            onMain {
                guard let self, self.engine == .system, self.systemPlayer.currentItem === item else { return }
                self.diag.record("item status -> \(["unknown", "readyToPlay", "failed"][min(max(status.rawValue, 0), 2)])\(item.error.map { " error=\($0.localizedDescription)" } ?? "")")
                switch status {
                case .failed: self.systemEngineFailed()
                case .readyToPlay:
                    // Ready is not started: the gate decides when the
                    // picture and sound come up.
                    if self.startGateOpen { self.loading = false }
                    UIApplication.shared.isIdleTimerDisabled = true
                    self.loadSystemSubtitleTracks(for: item)
                    self.loadSystemAudioTracks(for: item)
                default: break
                }
            }
        })
        systemObservers.append(item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
            let size = item.presentationSize
            guard size.width > 0, size.height > 0 else { return }
            onMain {
                guard let self, self.engine == .system, self.systemPlayer.currentItem === item else { return }
                self.videoWidth = Int(size.width)
                self.videoHeight = Int(size.height)
            }
        })
        systemObservers.append(systemPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus == .playing
            onMain {
                guard let self, self.engine == .system, self.systemPlayer.currentItem === item else { return }
                self.diag.record("timeControlStatus -> \(playing ? "playing" : "not playing") rate=\(player.rate) layerReady=\(self.videoView?.playerLayer?.isReadyForDisplay.description ?? "—")")
                self.isPlaying = playing
                if self.pictureInPictureActive {
                    if player.timeControlStatus == .paused { self.pausedByUser = true }
                    if playing { self.pausedByUser = false }
                }
                if playing {
                    if self.startGateOpen { self.loading = false }
                    self.retries.reset()
                }
            }
        })

        let center = NotificationCenter.default
        systemNotifications.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification,
                                                     object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemEngineFailed() }
        })
        // A live playlist that ends is a dropped feed, not a finished programme;
        // a title that ends has finished.
        systemNotifications.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                     object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.engine == .system, self.systemPlayer.currentItem === item else { return }
                if self.isLive { self.systemEngineFailed() } else { self.finish() }
            }
        })

        diag.record("openSystem item created; videoView=\(videoView == nil ? "nil" : "present")")
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        gateOutput = output
        closeStartGate()
        if let view = videoView { attachSystemLayer(to: view) }
        systemPlayer.play()
        diag.record("openSystem play() called; layer=\(videoView?.playerLayer == nil ? "ABSENT" : "present")")
        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// Try Aether on this HLS address before giving up its PiP-capable routes.
    private func systemEngineFailed() {
        diag.record("systemEngineFailed candidates=\(candidates.count)")
        guard engine == .system, error == nil, retryAt == nil else { return }
        advanceAfterEngineFailure()
    }

    private func teardownSystemEngine() {
        // `pipObserver` is deliberately not invalidated here: it belongs to the
        // layer and the PiP controller, both of which survive a channel change.
        systemObservers.forEach { $0.invalidate() }
        systemObservers.removeAll()
        systemNotifications.forEach { NotificationCenter.default.removeObserver($0) }
        systemNotifications.removeAll()
        systemPlayer.pause()
        systemPlayer.replaceCurrentItem(with: nil)
        systemSubtitleGroup = nil
        systemSubtitleOptions.removeAll()
        systemAudioGroup = nil
        systemAudioOptions.removeAll()
        layerDetachedForBackground = false
    }

    private func startWhenVideoIsReady() {
        guard engine == .vlc, waitingForVideo, !suspended, !pausedByUser, let view = videoView,
              view.window != nil, view.bounds.width > 0, view.bounds.height > 0 else {
            diag.record("startWhenVideoIsReady declined: engine=\(engine.rawValue) waiting=\(waitingForVideo) suspended=\(suspended) paused=\(pausedByUser) view=\(videoView == nil ? "nil" : "set") window=\(videoView?.window == nil ? "no" : "yes") size=\(Int(videoView?.bounds.width ?? 0))x\(Int(videoView?.bounds.height ?? 0))")
            return
        }
        diag.record("startWhenVideoIsReady starting VLC")
        // Never call play before VLC has a mounted, nonzero drawable.
        player.drawable = view
        waitingForVideo = false
        waitingSince = nil
        started = Date()
        health = LivePlaybackHealth(now: ProcessInfo.processInfo.systemUptime, stallLimit: isLive ? 12 : 30)
        closeStartGate()
        player.play()
        UIApplication.shared.isIdleTimerDisabled = true
    }

    // MARK: - Transport

    func toggle() {
        pausedByUser.toggle()
        if pausedByUser, isLive, catchUp == nil {
            liveHoldSince = Date()
        } else if !pausedByUser, let since = liveHoldSince {
            liveHeldSeconds += Date().timeIntervalSince(since)
            liveHoldSince = nil
        }
        if pausedByUser {
            switch engine {
            case .aether: aetherSession?.pause()
            case .vlc: player.pause()
            case .system: systemPlayer.pause()
            case .mpv: mpvSession?.pause()
            }
            // A channel the provider records picks up from here, however
            // long the pause: the broadcast doesn't wait, but its recording
            // does.
            if isLive, catchUp == nil, catchUpSource != nil { pausedAt = Date() }
        } else {
            let pause = pausedAt
            pausedAt = nil
            // Paused for longer than the player's own buffer covers: on from
            // the moment it was paused, by way of the recording. A pause
            // shorter than that just plays on.
            if let pause, catchUp == nil, catchUpSource != nil,
               Date().timeIntervalSince(pause) >= CatchUpPolicy.resumeFromPauseAfter,
               rewindFromLive(to: pause.addingTimeInterval(-CatchUpPolicy.liveLatency)) {
                diag.record("catch-up: resumed from the pause, \(Int(Date().timeIntervalSince(pause)))s behind live")
                return
            }
            health = LivePlaybackHealth(now: ProcessInfo.processInfo.systemUptime, stallLimit: isLive ? 12 : 30)
            switch engine {
            case .aether:
                if retryAt == nil { aetherSession?.play() }
            case .vlc:
                if waitingForVideo { startWhenVideoIsReady() }
                else if retryAt == nil { player.play() }
            case .system:
                if retryAt == nil { systemPlayer.play() }
            case .mpv:
                if retryAt == nil { mpvSession?.play() }
            }
        }
        refreshIsPlaying()
        UIApplication.shared.isIdleTimerDisabled = isPlaying
    }

    /// Reopens the same channel from scratch. Neither engine has a reliable
    /// "seek to live edge" for these streams, so the robust way to snap back to
    /// live after a pause (or a stall) is a fresh connection rather than a seek.
    ///
    /// From a recording, or a pause that would otherwise resume through one,
    /// it is the channel's live addresses that are opened, not the recording's.
    func goLive() {
        if catchUp != nil || pausedAt != nil, let source = catchUpSource {
            diag.record("catch-up: back to live")
            start(urls: source.liveURLs, channelID: source.stream.id, resetFailover: false)
            return
        }
        guard !originalURLs.isEmpty else { return }
        start(urls: originalURLs)
    }

    private func scheduleRecovery(now: TimeInterval) {
        presentation.beganRecovery()
        // A channel the server closed while it played is opened again at once
        // on the same address, as other players do; waiting, then trying the
        // other address, turned a moment's drop into a long wait.
        let droppedWhilePlaying = isLive && engine == .vlc && health.stall == .failed
            && player.state != .error && health.hasShownPicture
        let neverPlayed = !health.hasShownPicture
        player.stop()
        systemPlayer.pause()
        aetherSession?.stop()
        isPlaying = false
        // A title goes back to where it was, not to its beginning:
        // reconnecting a film used to start it over.
        if !isLive, reopenPosition == nil, let position = progress?.position, position > 0 {
            reopenPosition = max(0, position - 2)
        }
        // A recording that stops is picked up from where it had got to -- or,
        // having reached the present or the end of its programme, isn't.
        if catchUp != nil, recordingStopped() { return }
        guard var delay = retries.nextDelay(), !originalURLs.isEmpty else {
            // This channel's own URLs are spent — including the HLS-then-VLC
            // fallback, which happens inside `candidates` before ever reaching
            // here. Only now is another channel worth trying. Never from a
            // recording: another channel live is no answer to a programme the
            // viewer went back for.
            if catchUp == nil, switchToNextChannel() { return }
            loading = false
            error = "The stream disconnected. Tap Retry to reconnect."
            UIApplication.shared.isIdleTimerDisabled = false
            return
        }
        if droppedWhilePlaying { delay = 0 }
        let ordered = MobileEngineSelection.ordered(originalURLs, live: isLive)
        let index = currentURL.flatMap { ordered.firstIndex(of: $0) } ?? 0
        // First attempt retries the same endpoint; later ones rotate, so a dead
        // HLS endpoint ends up on the transport stream instead of looping. An
        // endpoint that played and then dropped is kept: it works.
        let next = retries.attempts == 1 || !neverPlayed ? index : (index + 1) % ordered.count
        candidates = [ordered[next]]
        loading = true
        retryAt = now + delay
    }

    /// Moves to the next verified channel for this game, if there is one left.
    ///
    /// `StreamFailoverState` retires each channel as it hands it back and caps
    /// the number of moves, so this terminates: every call either consumes a
    /// candidate or returns false.
    private func switchToNextChannel() -> Bool {
        guard let failover else { return false }
        while let next = failoverState.next(from: failover.plan(), current: currentChannelID) {
            let urls = failover.urls(next.streamID)
            guard !urls.isEmpty else { continue }
            failover.didSwitch(next)
            show(notice: next.notice)
            // Same controller, same two engines: a channel change is a new
            // session, never a second player.
            start(urls: urls, channelID: next.streamID, resetFailover: false)
            pendingWorkingChannelID = next.streamID
            return true
        }
        return false
    }

    private func show(notice: String) {
        failoverNotice = notice
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.failoverNotice = nil
        }
    }

    private var activeEngineIsPlaying: Bool {
        switch engine {
        case .vlc: player.isPlaying
        case .system: systemPlayer.timeControlStatus == .playing
        case .aether: aetherSession?.isPlaying == true
        case .mpv: mpvSession?.isPlaying == true
        }
    }
    private func refreshIsPlaying() {
        // VLC completes pause asynchronously. Reading its old playing flag
        // immediately after pause() must not undo the viewer's intent: the
        // paused monitor deliberately skips transport/recovery updates.
        isPlaying = !pausedByUser && activeEngineIsPlaying
    }

    private func confirmWorkingChannel() {
        guard let id = pendingWorkingChannelID, id == currentChannelID else { return }
        pendingWorkingChannelID = nil
        failover?.didPlay(id)
    }

    // MARK: - Frames for Auto Sync

    /// A picture taken from the stream: AVPlayer's and Aether's as decoded,
    /// VLC's as the PNG it writes.
    typealias CapturedFrame = CapturedVideoFrame

    private var frameOutput: AVPlayerItemVideoOutput?
    private weak var frameOutputItem: AVPlayerItem?

    /// The picture on screen now, for Auto Sync to read the scoreboard in.
    /// Nil while there is nothing to read, and for the first ask on a new
    /// stream, whose output sees frames only from then on.
    func captureFrame() async -> CapturedFrame? {
        guard error == nil, !loading, isPlaying else { return nil }
        switch engine {
        case .system:
            return systemPlayer.currentItem.flatMap(frame(from:)).map(CapturedFrame.pixelBuffer)
        case .aether:
            guard let session = aetherSession else { return nil }
            if let shown = session.displayedFrame() { return .pixelBuffer(shown) }
            return session.currentPlayerItem.flatMap(frame(from:)).map(CapturedFrame.pixelBuffer)
        case .vlc:
            return await vlcSnapshot().map(CapturedFrame.image)
        case .mpv:
            // MPVKit's Metal surface does not expose decoded-frame readback.
            return nil
        }
    }

    /// Done reading frames: the output comes off the item.
    func releaseFrameOutput() {
        if let output = frameOutput, let item = frameOutputItem { item.remove(output) }
        frameOutput = nil
        frameOutputItem = nil
    }

    private func frame(from item: AVPlayerItem) -> CVPixelBuffer? {
        if frameOutputItem !== item {
            releaseFrameOutput()
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            item.add(output)
            frameOutput = output
            frameOutputItem = item
            return nil
        }
        guard let output = frameOutput else { return nil }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        return output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
    }

    /// VLC writes the picture to a file on its own thread; it is read once
    /// it is whole, then thrown away.
    private func vlcSnapshot() async -> CGImage? {
        guard let handle = libVLCHandle else { return nil }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("lineup-scoreboard-\(UUID().uuidString).png")
        let status = file.path.withCString { libvlc_video_take_snapshot(handle, 0, $0, 1280, 0) }
        guard status == 0 else { return nil }
        defer { try? FileManager.default.removeItem(at: file) }
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(100))
            guard let data = try? Data(contentsOf: file),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetStatus(source) == .statusComplete,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            return image
        }
        return nil
    }

    // MARK: - Subtitles

    func setSubtitlePreferences(_ value: MobileSubtitlePreferences) {
        guard value != subtitlePreferences else { return }
        subtitlePreferences = value
        value.save(to: defaults)
        applySubtitleAppearance()
    }

    func setSubtitleDelay(_ seconds: Double) {
        guard engine != .system else { return }
        let delay = MobileSubtitlePreferences.delay(seconds)
        guard delay != subtitleDelaySeconds else { return }
        subtitleDelaySeconds = delay
        applySubtitleAppearance()
    }

    private func applySubtitleAppearance() {
        guard !isLive else { return }
        switch engine {
        case .aether:
            aetherSession?.configureSubtitles(scale: subtitlePreferences.scale,
                background: subtitlePreferences.background, delay: subtitleDelaySeconds)
        case .vlc:
            player.currentVideoSubTitleDelay = Int((subtitleDelaySeconds * 1_000_000).rounded())
        case .system:
            let attributes: [String: Any] = [
                kCMTextMarkupAttribute_RelativeFontSize as String: subtitlePreferences.scale * 100,
                kCMTextMarkupAttribute_BackgroundColorARGB as String: [subtitlePreferences.background ? 0.8 : 0, 0, 0, 0]
            ]
            if let rule = AVTextStyleRule(textMarkupAttributes: attributes) {
                systemPlayer.currentItem?.textStyleRules = [rule]
            }
        case .mpv:
            mpvSession?.configureSubtitles(scale: subtitlePreferences.scale,
                background: subtitlePreferences.background, delay: subtitleDelaySeconds,
                language: subtitlePreferences.language)
        }
    }

    func addOnlineSubtitle(_ data: Data, title: String, language: String, sessionID: UUID) async throws {
        guard sessionID == subtitleSessionID, canAttachOnlineSubtitles else { throw MobileSubtitleFailure.unsupported }
        let preparation = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let data = MobileOpenSubtitles.normalizedSubtitle(data) else { throw MobileSubtitleFailure.invalidFile }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LineupSubtitles", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("srt")
            do {
                try Task.checkCancellation()
                try data.write(to: file, options: .atomic)
                try Task.checkCancellation()
                return file
            } catch { try? FileManager.default.removeItem(at: file); throw error }
        }
        let file = try await withTaskCancellationHandler(operation: { try await preparation.value }, onCancel: { preparation.cancel() })
        do {
            try Task.checkCancellation()
            guard sessionID == subtitleSessionID, canAttachOnlineSubtitles else { throw MobileSubtitleFailure.unsupported }
            switch engine {
            case .aether:
                guard let session = aetherSession else { throw MobileSubtitleFailure.unsupported }
                _ = session.addSubtitle(url: file, title: title, language: language)
                checkAetherPlayback()
            case .vlc:
                guard player.addPlaybackSlave(file, type: .subtitle, enforce: true) == 0 else { throw MobileSubtitleFailure.invalidFile }
                refreshVLCSubtitleTracks()
            case .mpv:
                guard let session = mpvSession else { throw MobileSubtitleFailure.unsupported }
                session.addSubtitle(url: file, title: title, language: language)
            case .system: throw MobileSubtitleFailure.unsupported
            }
            onlineSubtitleFiles.append(file)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    func selectSubtitle(_ track: PlaybackSubtitleTrack, byViewer: Bool = true) {
        explicitSubtitleChoice = true
        if byViewer {
            appliedShowSubtitle = true
            rememberSubtitle(track)
        }
        switch engine {
        case .aether: aetherSession?.selectSubtitle(index: track.engineIndex)
        case .vlc:
            player.currentVideoSubTitleIndex = Int32(track.engineIndex ?? -1)
        case .system:
            guard let item = systemPlayer.currentItem, let group = systemSubtitleGroup else { return }
            // An explicit choice, including Off, belongs to the viewer rather
            // than AVPlayer's language heuristic for the rest of this session.
            systemPlayer.appliesMediaSelectionCriteriaAutomatically = false
            item.select(systemSubtitleOptions[track.id], in: group)
        case .mpv:
            mpvSession?.selectSubtitle(index: track.engineIndex)
        }
        selectedSubtitleID = track.id
    }

    private func refreshVLCSubtitleTracks() {
        let names = (player.videoSubTitlesNames as? [String]) ?? []
        let indexes = ((player.videoSubTitlesIndexes as? [NSNumber]) ?? []).map(\.intValue)
        let discovered = PlaybackSubtitleTrack.vlcTracks(names: names, indexes: indexes)
        if discovered != subtitleTracks { subtitleTracks = discovered }
        let current = Int(player.currentVideoSubTitleIndex)
        let selected = discovered.first(where: { $0.engineIndex == current })?.id
            ?? PlaybackSubtitleTrack.off.id
        if selected != selectedSubtitleID { selectedSubtitleID = selected }
    }

    private func loadSystemSubtitleTracks(for item: AVPlayerItem) {
        Task { [weak self, weak item] in
            guard let self, let item else { return }
            do {
                guard let group = try await item.asset.loadMediaSelectionGroup(for: .legible),
                      self.systemPlayer.currentItem === item else { return }
                self.systemSubtitleGroup = group
                var tracks: [PlaybackSubtitleTrack] = [.off]
                var options: [String: AVMediaSelectionOption] = [:]
                for (offset, option) in group.options.enumerated() {
                    let id = "system-\(offset)"
                    let title = option.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    tracks.append(PlaybackSubtitleTrack(id: id,
                        title: title.isEmpty ? "Subtitle \(offset + 1)" : title,
                        engineIndex: nil))
                    options[id] = option
                }
                self.systemSubtitleOptions = options
                self.subtitleTracks = tracks
                let chosen = item.currentMediaSelection.selectedMediaOption(in: group)
                if let chosen {
                    self.selectedSubtitleID = options.first(where: { $0.value === chosen })?.key
                        ?? PlaybackSubtitleTrack.off.id
                } else {
                    self.selectedSubtitleID = PlaybackSubtitleTrack.off.id
                }
                for (id, option) in options {
                    self.subtitleLanguages[id] = option.extendedLanguageTag ?? option.locale?.identifier
                }
                if !self.explicitSubtitleChoice, self.showTracks?.hasSubtitleChoice != true,
                   !self.subtitlePreferences.language.isEmpty,
                   let option = group.options.first(where: {
                       MobileSubtitlePreferences.matches($0.extendedLanguageTag ?? $0.locale?.identifier,
                                                         preferred: self.subtitlePreferences.language)
                   }), let id = options.first(where: { $0.value === option })?.key,
                   let track = tracks.first(where: { $0.id == id }) {
                    self.selectSubtitle(track, byViewer: false)
                }
                self.applyShowTracks()
            } catch {
                // No legible group is a normal answer for a title with no
                // captions. Playback remains untouched and the button stays
                // out of the way.
            }
        }
    }

    private func resetSubtitles() {
        subtitleSessionID = UUID()
        explicitSubtitleChoice = false
        subtitleDelaySeconds = 0
        player.currentVideoSubTitleDelay = 0
        for file in onlineSubtitleFiles { try? FileManager.default.removeItem(at: file) }
        onlineSubtitleFiles.removeAll()
        subtitleTracks = [.off]
        selectedSubtitleID = PlaybackSubtitleTrack.off.id
        systemSubtitleGroup = nil
        systemSubtitleOptions.removeAll()
        systemPlayer.appliesMediaSelectionCriteriaAutomatically = true
        subtitleLanguages.removeAll()
        audioTracks = []
        selectedAudioID = nil
        systemAudioGroup = nil
        systemAudioOptions.removeAll()
        appliedShowAudio = false
        appliedShowSubtitle = false
    }

    // MARK: - Sound tracks and a show's kept choices

    /// What the engine opens with: the show's kept language, else the
    /// viewer's subtitle preference. Subtitles kept off open with none.
    private var preferredSubtitleLanguages: [String] {
        guard !isLive else { return [] }
        if let showTracks, showTracks.hasSubtitleChoice {
            return showTracks.subtitlesOff ? [] : [showTracks.subtitle?.language].compactMap { $0 }
        }
        return subtitlePreferences.language.isEmpty ? [] : [subtitlePreferences.language]
    }

    private var preferredAudioLanguages: [String] {
        let kept = isLive ? nil : showTracks?.audio?.language
        return (kept.map { [$0] } ?? []) + ["en", "eng"]
    }

    func selectAudioTrack(_ track: MobileTrackOption) {
        appliedShowAudio = true
        applyAudio(track)
        guard let show = trackMemoryShow else { return }
        var kept = showTracks ?? MobileShowTracks()
        kept.audio = MobileTrackMemory.choice(for: track)
        showTracks = kept
        MobileTrackMemory.save(kept, for: show, defaults: defaults)
    }

    private func applyAudio(_ track: MobileTrackOption) {
        switch engine {
        case .aether:
            if let index = track.engineIndex { aetherSession?.selectAudio(index: index) }
        case .mpv:
            if let index = track.engineIndex { mpvSession?.selectAudio(index: index) }
        case .vlc:
            if let index = track.engineIndex { player.currentAudioTrackIndex = Int32(index) }
        case .system:
            guard let item = systemPlayer.currentItem, let group = systemAudioGroup,
                  let option = systemAudioOptions[track.id] else { return }
            systemPlayer.appliesMediaSelectionCriteriaAutomatically = false
            item.select(option, in: group)
        }
        selectedAudioID = track.id
    }

    private func rememberSubtitle(_ track: PlaybackSubtitleTrack) {
        guard let show = trackMemoryShow else { return }
        var kept = showTracks ?? MobileShowTracks()
        if track.id == PlaybackSubtitleTrack.off.id {
            kept.subtitlesOff = true
            kept.subtitle = nil
        } else {
            kept.subtitlesOff = false
            kept.subtitle = MobileTrackMemory.choice(for: subtitleOption(track))
        }
        showTracks = kept
        MobileTrackMemory.save(kept, for: show, defaults: defaults)
    }

    private func subtitleOption(_ track: PlaybackSubtitleTrack) -> MobileTrackOption {
        MobileTrackOption(id: track.id, title: track.title, language: subtitleLanguages[track.id],
                          engineIndex: track.engineIndex)
    }

    /// The show's kept sound and subtitles, put back once for each episode,
    /// as soon as its tracks are known. A track the viewer picks themselves
    /// in the meantime wins.
    private func applyShowTracks() {
        guard let showTracks, !isLive else { return }
        if !appliedShowAudio, let audio = showTracks.audio, audioTracks.count > 1 {
            appliedShowAudio = true
            if let match = MobileTrackMemory.match(audio, in: audioTracks), match.id != selectedAudioID {
                applyAudio(match)
                diag.record("Put back the sound kept for this show")
            }
        }
        let offered = subtitleTracks.filter { $0.id != PlaybackSubtitleTrack.off.id }
        if !appliedShowSubtitle, showTracks.hasSubtitleChoice, !offered.isEmpty {
            appliedShowSubtitle = true
            if showTracks.subtitlesOff {
                if selectedSubtitleID != PlaybackSubtitleTrack.off.id { selectSubtitle(.off, byViewer: false) }
            } else if let subtitle = showTracks.subtitle,
                      let match = MobileTrackMemory.match(subtitle, in: offered.map(subtitleOption)),
                      match.id != selectedSubtitleID,
                      let track = offered.first(where: { $0.id == match.id }) {
                selectSubtitle(track, byViewer: false)
                diag.record("Put back the subtitles kept for this show")
            }
        }
    }

    private func refreshVLCAudioTracks() {
        guard !isLive else { return }
        let tracks = PlaybackStreamTrack.vlcTracks(names: (player.audioTrackNames as? [String]) ?? [],
            indexes: ((player.audioTrackIndexes as? [NSNumber]) ?? []).map(\.intValue), kind: "Audio")
            .map { MobileTrackOption(id: "vlc-audio-\($0.id)", title: $0.title,
                                     language: MobileTrackMemory.language(inTitle: $0.title), engineIndex: $0.id) }
        if tracks != audioTracks { audioTracks = tracks }
        let current = Int(player.currentAudioTrackIndex)
        let selected = tracks.first { $0.engineIndex == current }?.id
        if selected != selectedAudioID { selectedAudioID = selected }
        applyShowTracks()
    }

    private func loadSystemAudioTracks(for item: AVPlayerItem) {
        guard !isLive else { return }
        Task { [weak self, weak item] in
            guard let self, let item,
                  let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
                  self.systemPlayer.currentItem === item else { return }
            self.systemAudioGroup = group
            var tracks: [MobileTrackOption] = []
            var options: [String: AVMediaSelectionOption] = [:]
            for (offset, option) in group.options.enumerated() {
                let id = "system-audio-\(offset)"
                let title = option.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                tracks.append(MobileTrackOption(id: id, title: title.isEmpty ? "Audio \(offset + 1)" : title,
                                                language: option.extendedLanguageTag ?? option.locale?.identifier))
                options[id] = option
            }
            self.systemAudioOptions = options
            self.audioTracks = tracks
            let chosen = item.currentMediaSelection.selectedMediaOption(in: group)
            self.selectedAudioID = chosen.flatMap { chosen in options.first { $0.value === chosen }?.key }
            self.applyShowTracks()
        }
    }

    private func refreshStats() {
        let size = player.videoSize
        guard size.width > 0, size.height > 0 else { return }
        videoWidth = Int(size.width)
        videoHeight = Int(size.height)
    }

    private func refreshMediaInfo() {
        let next: PlaybackMediaInfo
        switch engine {
        case .aether: next = aetherSession?.mediaInfo ?? PlaybackMediaInfo()
        case .system:
            nativeMediaInfo.refresh(systemPlayer.currentItem)
            next = nativeMediaInfo.info
        case .vlc: next = VLCPlaybackMediaInfo.read(player)
        case .mpv:
            next = PlaybackMediaInfo(dynamicRange: mpvSession?.dynamicRange,
                videoCodec: mpvSession?.videoCodec, frameRate: mpvSession?.frameRate,
                audioCodec: mpvSession?.audioCodec, audioChannels: mpvSession?.audioChannels,
                audioLayout: mpvSession?.audioLayout)
        }
        if mediaInfo != next { mediaInfo = next }
        liveQualityReporter.observe(url: currentURL, width: videoWidth ?? 0, height: videoHeight ?? 0,
            frameRate: next.frameRate, live: isLive && !sourceIsRecording, playing: isPlaying,
            picture: startGateOpen && !loading)
    }

    // MARK: - Scene phase

    /// Backgrounding no longer means stopping. `MobileBackgroundPolicy` owns the
    /// decision; this method only carries it out.
    func handleScenePhase(active: Bool) {
        if !active { finishScrubbing() }
        let action = MobileBackgroundPolicy.action(enteringBackground: !active,
                                                   pictureInPictureActive: pictureInPictureActive,
                                                   pausedByUser: pausedByUser,
                                                   backgroundAudioEnabled: Self.backgroundAudioEnabled)
        if active { enterForeground(action) } else { enterBackground(action) }
    }

    private func enterBackground(_ action: MobilePlaybackPhaseAction) {
        inBackground = true
        UIApplication.shared.isIdleTimerDisabled = false
        switch action {
        case .leaveAsIs:
            return
        case .pause:
            suspended = true
            shouldResume = !pausedByUser && (isPlaying || loading)
            player.pause()
            systemPlayer.pause()
            aetherSession?.pause()
            mpvSession?.pause()
            isPlaying = false
        case .keepPlaying:
            suspended = false
            shouldResume = false
        }
    }

    private func enterForeground(_ action: MobilePlaybackPhaseAction) {
        inBackground = false
        reattachLayerAfterBackground()
        if engine == .aether { aetherSession?.restoreForegroundVideo() }
        switch action {
        case .leaveAsIs:
            suspended = false
            return
        case .pause:
            suspended = false
        case .keepPlaying:
            suspended = false
            // Nothing to resume once the session is over: playing an empty
            // player only held the screen awake with nothing on it.
            guard monitor != nil else { break }
            started = Date()
            health = LivePlaybackHealth(now: ProcessInfo.processInfo.systemUptime, stallLimit: isLive ? 12 : 30)
            switch engine {
            case .aether:
                if retryAt == nil { aetherSession?.play(); UIApplication.shared.isIdleTimerDisabled = true }
            case .vlc:
                if waitingForVideo {
                    // A fresh 8s window rather than counting time spent backgrounded.
                    waitingSince = Date()
                    startWhenVideoIsReady()
                } else if retryAt == nil, !player.isPlaying {
                    player.play()
                    UIApplication.shared.isIdleTimerDisabled = true
                }
            case .system:
                if retryAt == nil, systemPlayer.timeControlStatus != .playing {
                    systemPlayer.play()
                    UIApplication.shared.isIdleTimerDisabled = true
                }
            case .mpv:
                if retryAt == nil, mpvSession?.isPlaying != true {
                    mpvSession?.play()
                    UIApplication.shared.isIdleTimerDisabled = true
                }
            }
        }
        shouldResume = false
        refreshIsPlaying()
    }

    private func detachLayerForBackground() {
        guard engine == .system, !pictureInPictureActive, !layerDetachedForBackground,
              let layer = videoView?.playerLayer else { return }
        diag.record("detachLayerForBackground")
        layer.player = nil
        layerDetachedForBackground = true
    }

    private func reattachLayerAfterBackground() {
        guard layerDetachedForBackground else { return }
        diag.record("reattachLayerAfterBackground")
        layerDetachedForBackground = false
        videoView?.playerLayer?.player = systemPlayer
    }

    /// Kept for the call sites that describe a scene transition rather than a
    /// teardown. Neither one stops the stream any more on its own.
    func suspend() { handleScenePhase(active: false) }
    func resume() { handleScenePhase(active: true) }

    /// Whether a title that stopped did so at its end.
    private func reachedEnd(vlcPosition: Float) -> Bool {
        guard !isLive, reopenPosition == nil, let progress, progress.duration > 0 else { return false }
        return progress.position >= progress.duration - 15 || vlcPosition >= 0.99
    }

    /// The end of a title: the position reads as the end, so it is saved as
    /// watched, and the player is told to close.
    private func finish() {
        guard !isLive, !finished, !isScrubbing,
              !seekLanding.isWaiting(now: ProcessInfo.processInfo.systemUptime) else { return }
        monitor?.cancel()
        monitor = nil
        retryAt = nil
        isPlaying = false
        loading = false
        if let progress { self.progress = MobilePlaybackProgress(position: progress.duration, duration: progress.duration) }
        finished = true
    }

    // MARK: - Catch-up

    /// How far the picture is behind the live broadcast by the viewer's own
    /// doing: a channel's recording played behind live, or pauses on a
    /// channel playing live. The stream's own lag behind the broadcast is
    /// not counted here; the viewer sets that against what they see.
    var secondsBehindLive: TimeInterval {
        guard isLive else { return 0 }
        if let position = catchUpPosition {
            return max(0, Date().timeIntervalSince(position) - CatchUpPolicy.liveLatency)
        }
        var held = liveHeldSeconds
        if let liveHoldSince { held += Date().timeIntervalSince(liveHoldSince) }
        return held
    }

    /// What is on screen while a recording plays: a skip's destination while
    /// it waits, else where the stream has got to. Nil while live.
    var catchUpPosition: Date? {
        guard let catchUp else { return nil }
        return skipTarget ?? catchUp.position(playedSeconds: recordingElapsed)
    }

    /// Replay UI uses program-relative time; engines seek relative to the
    /// minute-addressed open stream. These origins can differ after a reopen.
    var recordingProgress: MobilePlaybackProgress? {
        guard isLive, let catchUp, let position = catchUpPosition else { return nil }
        let duration = catchUp.programmeEnd.timeIntervalSince(catchUp.programmeStart)
        guard duration.isFinite, duration > 0 else { return nil }
        return MobilePlaybackProgress(position: min(duration, max(0, position.timeIntervalSince(catchUp.programmeStart))),
                                      duration: duration)
    }

    /// The programme from its start -- the one a recording is playing, or
    /// the one on now when the provider records the channel and the guide
    /// knows what is on.
    var canStartOver: Bool {
        guard isLive, let catchUpSource else { return false }
        return catchUp != nil || catchUpSource.programme(Date()) != nil
    }

    /// Asks for this channel's recording, and keeps it if the channel is
    /// still the one playing once the server has answered. Nothing is asked
    /// for a channel the provider doesn't record.
    func loadCatchUpSource(for stream: XtreamStream, from library: SportsLibrary) {
        guard isLive, stream.hasCatchUp else { return }
        Task { [weak self] in
            let source = await library.catchUpSource(for: stream)
            guard let self, self.currentChannelID == stream.id else { return }
            self.catchUpSource = source
        }
    }

    /// Opens a channel on its recording rather than live -- a programme from
    /// the past, or with nil the one on now from its start -- once the
    /// recording can be addressed, and the channel live when it can't.
    ///
    /// Nothing opens while the server is asked, so the channel is never
    /// opened live only to be closed again a moment later. The player shows
    /// it opening meanwhile, and a viewer who moves on in that time -- another
    /// channel, or closing the player -- is not overruled when the answer
    /// comes.
    func openRecording(of stream: XtreamStream, programme: CatchUpProgramme?, from library: SportsLibrary,
                       requiresRecording: Bool = false) async {
        let liveURLs = library.playbackURLs(for: stream)
        // Whatever was open is closed now rather than left playing under the
        // wait; `start` below or the next channel opens the next thing.
        stop()
        currentChannelID = stream.id
        error = nil
        loading = true
        // Nil for a channel the provider doesn't record, without asking.
        let source = await library.catchUpSource(for: stream)
        guard currentChannelID == stream.id, monitor == nil else { return }
        catchUpSource = source
        if source != nil {
            if let programme, playRecording(of: programme) { return }
            if programme == nil, startOver() { return }
        }
        if requiresRecording {
            loading = false
            error = "This replay is no longer available. Refresh Game Replays and try again."
            return
        }
        start(urls: liveURLs, channelID: stream.id)
    }

    /// The programme from its beginning: the one a recording is playing, or
    /// the one on now, carrying on past its end.
    @discardableResult
    func startOver() -> Bool {
        if let catchUp {
            diag.record("catch-up: start over")
            return playRecording(from: catchUp.programmeStart, programmeStart: catchUp.programmeStart,
                                 programmeEnd: catchUp.programmeEnd, title: catchUp.title,
                                 endsWithProgramme: recordingEndsWithProgramme)
        }
        guard let source = catchUpSource, let programme = source.programme(Date()) else { return false }
        diag.record("catch-up: start over")
        return playRecording(from: programme.start, programmeStart: programme.start,
                             programmeEnd: programme.end, title: programme.title, endsWithProgramme: false)
    }

    /// A programme from the past, from its start to its end. One still on
    /// carries on past where it was to live, as Start Over does.
    @discardableResult
    func playRecording(of programme: CatchUpProgramme) -> Bool {
        diag.record("catch-up: playing a recording from \(programme.start.formatted(date: .abbreviated, time: .shortened))")
        return playRecording(from: programme.start, programmeStart: programme.start,
                             programmeEnd: programme.end, title: programme.title,
                             endsWithProgramme: programme.end <= Date())
    }

    /// The live half of `skip(by:)`.
    private func skipRecording(by seconds: Double) {
        guard seconds.isFinite, catchUpSource != nil, !isScrubbing else { return }
        let now = Date()
        guard catchUp != nil else {
            // Already live: only back means anything.
            guard seconds < 0 else { return }
            rewindFromLive(to: now.addingTimeInterval(seconds - CatchUpPolicy.liveLatency))
            return
        }
        let target = (catchUpPosition ?? now).addingTimeInterval(seconds)
        seekRecording(to: target, immediately: false)
    }

    private func seekRecording(to requested: Date, immediately: Bool) {
        guard let catchUp, requested.timeIntervalSince1970.isFinite else { return }
        let now = Date()
        var target = requested
        if recordingEndsWithProgramme {
            let last = max(catchUp.programmeStart, catchUp.programmeEnd.addingTimeInterval(-5))
            target = min(max(target, catchUp.programmeStart), last)
        } else if now.timeIntervalSince(target) < CatchUpPolicy.liveTolerance {
            goLive()
            return
        }
        target = min(target, now)
        let offset = target.timeIntervalSince(catchUp.streamStart)
        if canSeekRecording(to: offset) {
            skipTask?.cancel()
            skipTask = nil
            skipTarget = nil
            seekLanding.expect(offset, now: ProcessInfo.processInfo.systemUptime)
            scrubSeeks.commit(offset) { [weak self] in self?.performRecordingSeek(to: $0) }
            recordingElapsed = offset
            diag.record("catch-up: seek within open recording via \(engine.rawValue)")
            return
        }
        scrubSeeks.cancel()
        skipTarget = target
        skipTask?.cancel()
        if immediately {
            reopenRecording(at: target)
            return
        }
        skipTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            guard let self, !Task.isCancelled, let target = self.skipTarget else { return }
            self.reopenRecording(at: target)
        }
    }

    private func canSeekRecording(to offset: Double) -> Bool {
        guard offset.isFinite, offset >= 0, let catchUp else { return false }
        let end = recordingEndsWithProgramme ? catchUp.programmeEnd : Date()
        guard offset <= end.timeIntervalSince(catchUp.streamStart) else { return false }
        switch engine {
        case .aether:
            guard let session = aetherSession, session.canAcceptSeek else { return false }
            return session.duration <= 0 || offset <= session.duration
        case .vlc:
            guard player.isSeekable else { return false }
            let duration = Double(player.media?.length.intValue ?? 0) / 1000
            return duration <= 0 || offset <= duration
        case .system:
            return systemPlayer.currentItem?.seekableTimeRanges.contains {
                let range = $0.timeRangeValue
                return CMTimeRangeContainsTime(range, time: CMTime(seconds: offset, preferredTimescale: 600))
            } == true
        case .mpv:
            guard let session = mpvSession, session.isSeekable else { return false }
            return session.duration <= 0 || offset <= session.duration
        }
    }

    private func performRecordingSeek(to offset: Double) {
        guard catchUp != nil, canSeekRecording(to: offset) else { return }
        switch engine {
        case .aether: aetherSession?.seek(to: offset)
        case .system:
            let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
            systemPlayer.seek(to: CMTime(seconds: offset, preferredTimescale: 600),
                              toleranceBefore: tolerance, toleranceAfter: tolerance)
        case .vlc:
            let duration = Double(player.media?.length.intValue ?? 0) / 1000
            if duration > 0 { player.position = Float(offset / duration) }
            else { player.time = VLCTime(int: Int32(clamping: Int64((offset * 1000).rounded()))) }
        case .mpv: mpvSession?.seek(to: offset)
        }
    }

    private func reopenRecording(at target: Date) {
        guard let catchUp else { return }
        let current = catchUp.position(playedSeconds: recordingElapsed)
        skipTarget = nil
        skipTask = nil
        guard let begin = MobileRecordingSeekPolicy.providerStart(target: target, current: current) else {
            show(notice: "This provider supports whole-minute jumps only. Drag the timeline to another minute.")
            return
        }
        let wasPaused = pausedByUser
        if playRecording(from: begin, programmeStart: catchUp.programmeStart,
                         programmeEnd: catchUp.programmeEnd, title: catchUp.title,
                         endsWithProgramme: recordingEndsWithProgramme) {
            if wasPaused { toggle() }
            if abs(begin.timeIntervalSince(target)) > 1 {
                show(notice: "This provider supports whole-minute jumps only.")
            }
        } else {
            show(notice: "This replay could not be opened at that position.")
        }
    }

    /// From live into the recording, at a time just gone.
    @discardableResult
    private func rewindFromLive(to time: Date) -> Bool {
        guard let source = catchUpSource else { return false }
        let programme = source.programme(time)
        return playRecording(from: time,
                             programmeStart: programme?.start ?? CatchUpPolicy.minute(time),
                             programmeEnd: programme?.end ?? Date().addingTimeInterval(30 * 60),
                             title: programme?.title ?? source.stream.name,
                             endsWithProgramme: false)
    }

    /// Opens the recording from `position`. False, and nothing touched, when
    /// there is nothing to address it with.
    @discardableResult
    private func playRecording(from position: Date, programmeStart: Date, programmeEnd: Date,
                               title: String, endsWithProgramme: Bool) -> Bool {
        guard let source = catchUpSource else { return false }
        let begin = CatchUpPolicy.minute(max(position, programmeStart.addingTimeInterval(-60)))
        // A programme from the past is asked for to its end. Anything still
        // being shown is asked for up to now, and picked up again from where
        // it got to when that runs out.
        let until = endsWithProgramme ? programmeEnd : Date()
        let addresses = source.addresses(begin, until)
        guard !addresses.isEmpty else { return false }
        diag.record("catch-up: recording from \(begin.formatted(date: .omitted, time: .shortened))\(endsWithProgramme ? " to the program's end" : "")")
        // In the order given, the path form first: both forms are transport
        // streams, which VLC plays and `MobileEngineSelection` leaves in place.
        start(urls: addresses, channelID: source.stream.id, resetFailover: false, recording: true)
        recordingEndsWithProgramme = endsWithProgramme
        catchUp = CatchUpTimeline(programmeStart: programmeStart, programmeEnd: programmeEnd,
                                  title: title, streamStart: begin)
        return true
    }

    /// A recording's stream has stopped: the end of the programme, the
    /// present caught up with, or a drop. True when it has been dealt with
    /// here; false to reconnect, from where it had got to.
    private func recordingStopped() -> Bool {
        guard let catchUp, let source = catchUpSource else { return false }
        let position = catchUp.position(playedSeconds: recordingElapsed)
        if recordingEndsWithProgramme, position >= catchUp.programmeEnd.addingTimeInterval(-30) {
            diag.record("catch-up: the recording reached the end of the program")
            finishRecording()
            return true
        }
        if !recordingEndsWithProgramme, Date().timeIntervalSince(position) < CatchUpPolicy.liveTolerance {
            diag.record("catch-up: caught up with the channel")
            goLive()
            return true
        }
        let begin = CatchUpPolicy.minute(position)
        let addresses = source.addresses(begin, recordingEndsWithProgramme ? catchUp.programmeEnd : Date())
        guard !addresses.isEmpty else { return false }
        // The reconnect that follows reads these, from the path form.
        originalURLs = addresses
        recordingElapsed = 0
        self.catchUp = CatchUpTimeline(programmeStart: catchUp.programmeStart, programmeEnd: catchUp.programmeEnd,
                                       title: catchUp.title, streamStart: begin)
        return false
    }

    /// A recording that carries on past its programme's end takes the next
    /// programme's name and timeline.
    private func followRecordingIntoNextProgramme() {
        guard let catchUp, !recordingEndsWithProgramme, let source = catchUpSource,
              let position = catchUpPosition, position >= catchUp.programmeEnd,
              let next = source.programme(position), next.start >= catchUp.programmeEnd.addingTimeInterval(-60)
        else { return }
        self.catchUp = CatchUpTimeline(programmeStart: next.start, programmeEnd: next.end,
                                       title: next.title, streamStart: catchUp.streamStart)
    }

    /// How far the open recording has played. A stream that has dropped
    /// reads its clock as nothing; the place it had got to stands until it
    /// plays again, so neither the timeline nor the reconnect loses it.
    private func sampleRecording() {
        guard catchUp != nil else { return }
        let played: Double
        switch engine {
        case .vlc:
            guard let position = vlcPlaybackSeconds else { return }
            played = position
        case .aether: played = aetherSession?.position ?? 0
        case .system: played = systemPlayer.currentTime().seconds
        case .mpv: played = mpvSession?.position ?? 0
        }
        guard played.isFinite else { return }
        guard seekLanding.accepts(played, now: ProcessInfo.processInfo.systemUptime) else { return }
        if played <= 0, !activeEngineIsPlaying, recordingElapsed > 0 { return }
        let seconds = max(0, played)
        if Int(seconds) != Int(recordingElapsed) { recordingElapsed = seconds }
    }

    /// A programme from the past played to its end. The player closes on it,
    /// as on the end of a title; `finish()` is a title's alone.
    private func finishRecording() {
        guard !finished else { return }
        monitor?.cancel()
        monitor = nil
        retryAt = nil
        isPlaying = false
        loading = false
        finished = true
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Teardown

    func stop() {
        nativeMediaInfo.reset()
        mediaInfo = PlaybackMediaInfo()
        isScrubbing = false
        resumeAfterScrubbing = false
        scrubDestination = nil
        scrubSeeks.cancel()
        seekLanding.reset()
        monitor?.cancel()
        monitor = nil
        resetStartGate()
        pendingTeardown?.cancel()
        pendingTeardown = nil
        retryAt = nil
        pausedByUser = false
        waitingForVideo = false
        waitingSince = nil
        player.stop()
        player.media = nil
        aetherSession?.stop()
        mpvSession?.stop()
        pictureInPictureActive = false
        pictureInPicturePossible = false
        teardownSystemEngine()
        inBackground = false
        suspended = false
        shouldResume = false
        isPlaying = false
        resetSubtitles()
        // The recording goes with the stream that played it. The channel's
        // source stays: it describes the channel, not what was open on it.
        skipTask?.cancel()
        skipTask = nil
        skipTarget = nil
        catchUp = nil
        pausedAt = nil
        liveHoldSince = nil
        liveHeldSeconds = 0
        recordingElapsed = 0
        UIApplication.shared.isIdleTimerDisabled = false
        MobileAudioSession.deactivate(for: self)
    }

    func shutdown() {
        diag.record("shutdown")
        noticeTask?.cancel()
        noticeTask = nil
        failoverNotice = nil
        failover = nil
        currentChannelID = nil
        catchUpSource = nil
        pendingWorkingChannelID = nil
        failoverState.reset()
        if let pip = pipController, pip.isPictureInPictureActive { pip.stopPictureInPicture() }
        pictureInPictureActive = false
        pictureInPicturePossible = false
        pipObserver?.invalidate()
        pipObserver = nil
        pipController = nil
        stop()
        // Cancel queued layout attachments from the retired view before another
        // tab/session can start. Old dismantle callbacks only own their old player.
        videoView?.controller = nil
        videoView?.removePlayerLayer()
        // At once, not later: the next screen's surface must never find this
        // player still drawing into the old one. The slow parts of letting go
        // -- the audio session, VLC's own teardown -- happen off the main
        // thread instead.
        player.drawable = nil
        videoView = nil
    }
}

/// AVKit requires an `NSObject` delegate, and the controller is a `@MainActor`
/// value type in spirit — keeping the conformance out here avoids forcing the
/// whole controller into `NSObject` and changing its initializer.
private final class MobilePictureInPictureDelegate: NSObject, AVPictureInPictureControllerDelegate {
    weak var controller: MobilePlaybackController?

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            guard self.controller?.ownsSystemPiP(controller) == true else { return }
            self.controller?.pictureInPictureChanged(active: true)
        }
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            guard self.controller?.ownsSystemPiP(controller) == true else { return }
            self.controller?.pictureInPictureChanged(active: true)
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            guard self.controller?.ownsSystemPiP(controller) == true else { return }
            self.controller?.pictureInPictureChanged(active: false)
            self.controller?.pictureInPictureClosed()
        }
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        MainActor.assumeIsolated {
            guard self.controller?.ownsSystemPiP(controller) == true else { return }
            self.controller?.pictureInPictureChanged(active: false)
        }
    }

    /// The app's own UI was never dismantled — the player view stays mounted
    /// behind the PiP window — so there is nothing to rebuild before the window
    /// hands playback back.
    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void
    ) {
        completion(true)
    }
}

extension MobilePlaybackController {
    /// Hold the last frame still while the player is dismissed.
    ///
    /// The picture trails the frame on the way out because it is not drawn by
    /// the thing moving it: the renderer draws on its own clock while the
    /// dismissal moves and scales the frame at display rate, so it arrives
    /// late to each position.
    ///
    /// Stopping the decoder is what actually settles it. A paused renderer
    /// leaves its last frame on the drawable, and a layer whose contents are
    /// not changing moves with its parent exactly. The snapshot below is tried
    /// first and usually comes back empty for VLC -- an OpenGL drawable is not
    /// something UIKit can copy -- which is why that alone did not fix it.
    ///
    /// Picture in Picture is the exception: the viewer moved the stream to
    /// another window and it must keep playing there.
    func freezePictureForExit() {
        guard !pictureInPictureActive else { return }
        switch engine {
        case .aether: aetherSession?.pause()
        case .vlc: if player.isPlaying { player.pause() }
        case .system: systemPlayer.pause()
        case .mpv: mpvSession?.pause()
        }
        videoViewForExit?.freezePicture()
    }

    func thawPictureAfterCancelledExit() { videoViewForExit?.thawPicture() }
}

struct MobileVideoSurface: UIViewRepresentable {
    let controller: MobilePlaybackController
    func makeUIView(context: Context) -> MobileVideoHost {
        let view = MobileVideoHost()
        view.controller = controller
        return view
    }
    func updateUIView(_ uiView: MobileVideoHost, context: Context) {
        uiView.controller = controller
        uiView.scheduleAttachment()
    }
    static func dismantleUIView(_ uiView: MobileVideoHost, coordinator: ()) {
        uiView.controller?.detachVideo(uiView)
        uiView.controller = nil
    }
}

final class MobileVideoHost: UIView {
    weak var controller: MobilePlaybackController?
    private(set) var playerLayer: AVPlayerLayer?
    private var attachmentScheduled = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        autoresizesSubviews = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Idempotent: an already-installed layer for the same player is returned
    /// untouched. Expanding, collapsing and rotating all land here, and none of
    /// them may replace the layer — doing so would drop the PiP controller
    /// riding on it and restart the stream.
    @discardableResult
    func installPlayerLayer(for player: AVPlayer, reusing retained: AVPlayerLayer? = nil) -> AVPlayerLayer {
        if let existing = playerLayer {
            if existing.player !== player { existing.player = player }
            return existing
        }
        let created = retained ?? AVPlayerLayer(player: player)
        created.videoGravity = .resizeAspect
        created.opacity = 1
        created.frame = bounds
        layer.addSublayer(created)
        playerLayer = created
        updateStartupCover()
        return created
    }

    /// Cover the picture while it decodes. Hiding the decoder itself can
    /// prevent the first displayed frame that the startup gate waits for.
    private(set) var pictureHeld = false
    private var startupCover: UIView?

    func holdPicture(_ held: Bool) {
        pictureHeld = held
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.opacity = 1
        for renderer in subviews where renderer !== stillPicture && renderer !== startupCover { renderer.alpha = 1 }
        updateStartupCover()
        CATransaction.commit()
    }

    private func updateStartupCover() {
        guard pictureHeld else { startupCover?.removeFromSuperview(); return }
        if startupCover == nil {
            let cover = UIView(frame: bounds)
            cover.backgroundColor = .black
            cover.isOpaque = true
            cover.isUserInteractionEnabled = false
            cover.isAccessibilityElement = false
            cover.layer.zPosition = 1
            cover.accessibilityIdentifier = "PlaybackStartupCover"
            cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            startupCover = cover
        }
        guard let cover = startupCover else { return }
        cover.frame = bounds
        cover.isHidden = false
        if cover.superview !== self { addSubview(cover) }
        bringSubviewToFront(cover)
    }

    /// VLC adds its renderer once the stream's picture starts, which can be
    /// after the picture was held: covered from the moment it arrives.
    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        guard subview !== stillPicture, subview !== startupCover else { return }
        subview.alpha = 1
        subview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if bounds.width > 0, bounds.height > 0 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            subview.frame = bounds
            subview.layoutIfNeeded()
            CATransaction.commit()
        }
        updateStartupCover()
    }

    private var stillPicture: UIView?

    /// Swap the live picture for a still of itself.
    ///
    /// Dismissing moves and scales this view over a fifth of a second. The
    /// renderer inside it draws on its own clock -- VLC at the stream's frame
    /// rate, AVPlayer on its display link -- so during that movement it
    /// arrives late to each position and visibly trails the frame around it.
    /// A still has nothing to arrive late for.
    ///
    /// `snapshotView` is used rather than rendering the layer, because the
    /// picture lives in hardware-composited layers that a bitmap context
    /// cannot see. If the snapshot fails the live view simply stays, which is
    /// what happened before this existed.
    func freezePicture() {
        guard stillPicture == nil, bounds.width > 1, bounds.height > 1,
              let still = snapshotView(afterScreenUpdates: false) else { return }
        still.frame = bounds
        still.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        stillPicture = still
        addSubview(still)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for view in subviews where view !== still { view.isHidden = true }
        playerLayer?.isHidden = true
        CATransaction.commit()
    }

    /// Put the live picture back, for a dismissal that was begun and released.
    func thawPicture() {
        guard let still = stillPicture else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        still.removeFromSuperview()
        stillPicture = nil
        for view in subviews { view.isHidden = false }
        playerLayer?.isHidden = false
        CATransaction.commit()
    }

    func removePlayerLayer() {
        playerLayer?.player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
    }

    func releasePlayerLayerForPictureInPicture() {
        // AVKit retains this layer and its player. The departing host must
        // stop laying it out, and a returning host can mount that same layer.
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
    }

    private weak var engineSurface: UIView?
    func installEngineSurface(_ surface: UIView) {
        if engineSurface === surface, surface.superview === self {
            if surface.frame != bounds { surface.frame = bounds }
            surface.layoutIfNeeded()
            return
        }
        removeEngineSurface()
        surface.frame = bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(surface)
        engineSurface = surface
        // Give the decoder its real viewport before loading, including a
        // canvas created at a large placeholder size. Keep aspect fit intact.
        surface.layoutIfNeeded()
    }
    func removeEngineSurface() {
        if engineSurface?.superview === self { engineSurface?.removeFromSuperview() }
        engineSurface = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        scheduleAttachment()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // VLC installs its renderer as a child of this host. Keep it fitted when
        // expanding, collapsing, or rotating without replacing the drawable —
        // and, like the AVPlayer layer below, without the implicit animation the
        // surrounding transaction would otherwise lend each frame change. Going
        // full screen resizes this host on every frame of an animation, and a
        // renderer easing towards each of those frames drags visibly behind its
        // own window.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for renderer in subviews {
            renderer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            if renderer.frame != bounds { renderer.frame = bounds }
        }
        CATransaction.commit()
        // The same for the AVPlayer layer, minus the implicit animation a layer
        // frame change would otherwise inherit from the rotation transaction.
        if let playerLayer, playerLayer.frame != bounds {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
        scheduleAttachment()
    }

    func scheduleAttachment() {
        guard !attachmentScheduled else { return }
        attachmentScheduled = true
        // Defer until after UIKit/SwiftUI's layout transaction has completed.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.attachmentScheduled = false
            guard self.window != nil, self.bounds.width > 0, self.bounds.height > 0 else { return }
            self.controller?.attachVideo(self)
        }
    }
}
