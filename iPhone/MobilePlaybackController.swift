import SwiftUI
import AVFoundation
import AVKit
import VLCKitSPM

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

    static func activate() throws {
        try queue.sync {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        }
    }

    static func deactivate() {
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
    /// VLCKit. Still the engine for transport streams and anything AVPlayer
    /// refuses, and still the object the surface tests reach for.
    let player = VLCMediaPlayer()
    /// AVPlayer. Drives Picture in Picture and keeps audio alive in the
    /// background. One instance per controller, reused across channel changes.
    let systemPlayer = AVPlayer()

    @Published var isPlaying = false
    @Published var loading = true
    @Published var error: String?
    @Published private(set) var videoWidth: Int?
    @Published private(set) var videoHeight: Int?
    /// Which engine is currently rendering. Views use it only to decide whether
    /// a Picture in Picture button can do anything.
    @Published private(set) var engine: MobileStreamEngine = .vlc
    @Published private(set) var pictureInPicturePossible = false
    @Published private(set) var pictureInPictureActive = false
    /// A short, self-clearing line shown when Lineup moves to a different feed.
    @Published private(set) var failoverNotice: String?
    /// Where playback is in a title that has an end. Nil for a live stream,
    /// which has no length to report and nothing to scrub through.
    @Published private(set) var progress: MobilePlaybackProgress?
    @Published private(set) var subtitleTracks: [PlaybackSubtitleTrack] = [.off]
    @Published private(set) var selectedSubtitleID = PlaybackSubtitleTrack.off.id

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
    private var isScrubbing = false
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
    /// A title played to its end. The player closes on it.
    @Published private(set) var finished = false
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

    // AVPlayer engine state.
    private var systemObservers: [NSKeyValueObservation] = []
    private var systemNotifications: [NSObjectProtocol] = []
    private var systemSubtitleGroup: AVMediaSelectionGroup?
    private var systemSubtitleOptions: [String: AVMediaSelectionOption] = [:]
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
            ("loading", loading ? "yes" : "no"),
            ("error", error ?? "—")
        ]
    }

    init() {
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

    // VLCKit's per-track dictionary API (frame rate, codec) varies across
    // versions and isn't worth pinning to for a badge — the video size alone
    // covers what was actually asked for ("quality of channel").
    var streamQualityLabel: String? { qualityLabel }

    var selectedSubtitleTitle: String {
        subtitleTracks.first(where: { $0.id == selectedSubtitleID })?.title ?? "Off"
    }

    // MARK: - Position

    /// Read straight from whichever engine is running. Both report a length of
    /// zero for a live stream, so a title with no end simply has no progress to
    /// publish and the player shows live chrome instead of a scrubber.
    private func sampleProgress() {
        guard !isScrubbing else { return }
        let sampled: MobilePlaybackProgress?
        switch engine {
        case .system:
            let item = systemPlayer.currentItem
            let duration = item?.duration.seconds ?? .nan
            let position = systemPlayer.currentTime().seconds
            sampled = duration.isFinite && duration > 0 && position.isFinite
                ? MobilePlaybackProgress(position: min(max(0, position), duration), duration: duration) : nil
        case .vlc:
            let lengthMs = player.media?.length.intValue ?? 0
            let duration = Double(lengthMs) / 1000
            let position = Double(player.time.intValue) / 1000
            sampled = lengthMs > 0
                ? MobilePlaybackProgress(position: min(max(0, position), duration), duration: duration) : nil
        }
        if let reopenPosition {
            // Until the reopened stream is back where it was, its clock reads
            // from the beginning, and showing or saving that would lose the
            // viewer's place. The last good position stands in meanwhile.
            let playing = engine == .vlc ? player.isPlaying : systemPlayer.timeControlStatus == .playing
            guard retryAt == nil, playing, let sampled else { return }
            // VLC was opened there; only a stream that would not start there
            // is moved, which would buffer it a second time.
            if engine == .vlc {
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
        progress = sampled
        if !appliedInitialPosition, let requestedInitialPosition, let progress,
           requestedInitialPosition >= 10, requestedInitialPosition < progress.duration - 30 {
            if engine == .vlc {
                guard player.isPlaying, progress.position > 0 else { return }
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
    func beginScrubbing() { isScrubbing = true }

    func endScrubbing(at seconds: Double) {
        isScrubbing = false
        seek(to: seconds)
    }

    func seek(to seconds: Double) {
        guard let current = progress, current.duration > 0 else { return }
        let target = min(max(0, seconds), current.duration)
        switch engine {
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
        }
        progress = MobilePlaybackProgress(position: target, duration: current.duration)
        diag.record("seek to \(Int(target))s of \(Int(current.duration))s via \(engine.rawValue)")
    }

    func skip(by seconds: Double) {
        guard let current = progress else { return }
        seek(to: current.position + seconds)
    }

    // MARK: - Surface

    func attachVideo(_ view: MobileVideoHost) {
        pendingTeardown?.cancel()
        pendingTeardown = nil
        diag.record("attachVideo \(Int(view.bounds.width))x\(Int(view.bounds.height)) window=\(view.window == nil ? "no" : "yes") engine=\(engine.rawValue) first=\(videoView !== view)")
        videoView = view
        switch engine {
        case .vlc:
            view.removePlayerLayer()
            if (player.drawable as? UIView) !== view { player.drawable = view }
            startWhenVideoIsReady()
        case .system:
            attachSystemLayer(to: view)
        }
    }

    func detachVideo(_ view: MobileVideoHost) {
        diag.record("detachVideo mine=\(videoView === view) pip=\(pictureInPictureActive)")
        guard videoView === view else { return }
        // Picture in Picture outlives the view that started it: the window is
        // showing this stream, and tearing the engine down here would close it.
        guard !pictureInPictureActive else {
            view.removePlayerLayer()
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
        let layer = view.installPlayerLayer(for: systemPlayer)
        diag.record("attachSystemLayer \(existed ? "reused" : "created") frame=\(Int(layer.frame.width))x\(Int(layer.frame.height)) player=\(layer.player == nil ? "nil" : "set")")
        if pipController?.playerLayer !== layer {
            pipController = AVPictureInPictureController(playerLayer: layer)
            pipController?.delegate = pipDelegate
            // Backgrounding an inline player hands it to the system window
            // instead of stopping it. This is what "entering PiP preserves the
            // stream" means in practice: no new item, no new connection.
            pipController?.canStartPictureInPictureAutomaticallyFromInline = true
            observePictureInPicturePossible()
        }
    }

    private func observePictureInPicturePossible() {
        guard let pip = pipController else { return }
        pictureInPicturePossible = pip.isPictureInPicturePossible
        pipObserver = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] pip, _ in
            let possible = pip.isPictureInPicturePossible
            onMain { self?.pictureInPicturePossible = possible }
        }
    }

    // MARK: - Picture in Picture

    var canOfferPictureInPicture: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
            && engine == .system && pictureInPicturePossible
    }

    func togglePictureInPicture() {
        guard let pip = pipController else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() }
        else { pip.startPictureInPicture() }
    }

    fileprivate func pictureInPictureChanged(active: Bool) {
        diag.record("pictureInPicture active=\(active)")
        pictureInPictureActive = active
        // Coming back from the PiP window into a foregrounded app: whatever the
        // background detach did has to be undone before the layer can draw.
        if !active { reattachLayerAfterBackground() }
    }

    // MARK: - Opening

    /// - Parameters:
    ///   - channelID: the provider stream this is, so failover can retire it.
    ///   - resetFailover: true for anything the viewer initiated — a new
    ///     selection, Retry, or jumping back to live — which makes the channels
    ///     that failed earlier eligible again. Only an automatic switch passes
    ///     false, so one bad game cannot loop through the same dead feeds.
    func start(urls: [URL], channelID: Int? = nil, resetFailover: Bool = true,
               initialPosition: TimeInterval? = nil) {
        diag.beginSession("start channel=\(channelID.map(String.init) ?? "—") urls=\(urls.count) resetFailover=\(resetFailover)")
        for url in MobileEngineSelection.ordered(urls) {
            diag.record("  candidate \(url.lastPathComponent) -> \(MobileEngineSelection.engine(for: url).rawValue)")
        }
        stop()
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
        // HLS first on the phone so Picture in Picture is reachable; the
        // transport stream stays queued behind it. Apple TV keeps its own order.
        candidates = MobileEngineSelection.ordered(urls)
        do {
            try MobileAudioSession.activate()
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
                self.sampleProgress()
                if self.engine == .system,
                   self.systemPlayer.timeControlStatus == .playing,
                   self.videoView?.playerLayer?.isReadyForDisplay == true {
                    self.confirmWorkingChannel()
                }
                if self.engine == .vlc { self.refreshVLCSubtitleTracks() }
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
                self.loading = !self.player.isPlaying || !self.player.hasVideoOut
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
                        && (!self.isLive || self.health.hasShownPicture || self.health.age(now: now) >= 8))
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
                if recover { self.scheduleRecovery(now: now) }
            }
        }
    }

    private func openNext() {
        systemPictureSeen = false
        teardownSystemEngine()
        player.stop()
        resetSubtitles()
        waitingForVideo = false
        waitingSince = nil
        isPlaying = false
        videoWidth = nil
        videoHeight = nil
        guard !candidates.isEmpty else {
            loading = false
            UIApplication.shared.isIdleTimerDisabled = false
            error = "This stream is unavailable. Try again or choose another channel."
            return
        }
        let url = candidates.removeFirst()
        currentURL = url
        engine = MobileEngineSelection.engine(for: url)
        diag.record("openNext \(url.lastPathComponent) engine=\(engine.rawValue) remaining=\(candidates.count)")
        started = Date()
        loading = true
        switch engine {
        case .system: openSystem(url)
        case .vlc: openVLC(url)
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
        player.media = media
        waitingForVideo = true
        waitingSince = Date()
        startWhenVideoIsReady()
    }

    private func openSystem(_ url: URL) {
        health = LivePlaybackHealth(now: ProcessInfo.processInfo.systemUptime, stallLimit: isLive ? 12 : 30)
        let item = AVPlayerItem(url: url)
        systemPlayer.replaceCurrentItem(with: item)

        systemObservers.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            onMain {
                guard let self else { return }
                self.diag.record("item status -> \(["unknown", "readyToPlay", "failed"][min(max(status.rawValue, 0), 2)])\(item.error.map { " error=\($0.localizedDescription)" } ?? "")")
                switch status {
                case .failed: self.systemEngineFailed()
                case .readyToPlay:
                    self.loading = false
                    UIApplication.shared.isIdleTimerDisabled = true
                    self.loadSystemSubtitleTracks(for: item)
                default: break
                }
            }
        })
        systemObservers.append(item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
            let size = item.presentationSize
            guard size.width > 0, size.height > 0 else { return }
            onMain {
                self?.videoWidth = Int(size.width)
                self?.videoHeight = Int(size.height)
            }
        })
        systemObservers.append(systemPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus == .playing
            onMain {
                guard let self else { return }
                self.diag.record("timeControlStatus -> \(playing ? "playing" : "not playing") rate=\(player.rate) layerReady=\(self.videoView?.playerLayer?.isReadyForDisplay.description ?? "—")")
                self.isPlaying = playing
                if playing {
                    self.loading = false
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
                guard let self else { return }
                if self.isLive { self.systemEngineFailed() } else { self.finish() }
            }
        })

        diag.record("openSystem item created; videoView=\(videoView == nil ? "nil" : "present")")
        if let view = videoView { attachSystemLayer(to: view) }
        systemPlayer.play()
        diag.record("openSystem play() called; layer=\(videoView?.playerLayer == nil ? "ABSENT" : "present")")
        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// The HLS endpoint did not work. Fall through to the next candidate, which
    /// for a normal Xtream channel is the transport stream on VLC.
    private func systemEngineFailed() {
        diag.record("systemEngineFailed candidates=\(candidates.count)")
        guard engine == .system, error == nil, retryAt == nil else { return }
        if !candidates.isEmpty {
            openNext()
        } else {
            scheduleRecovery(now: ProcessInfo.processInfo.systemUptime)
        }
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
        player.play()
        UIApplication.shared.isIdleTimerDisabled = true
    }

    // MARK: - Transport

    func toggle() {
        pausedByUser.toggle()
        if pausedByUser {
            switch engine {
            case .vlc: player.pause()
            case .system: systemPlayer.pause()
            }
        } else {
            health = LivePlaybackHealth(now: ProcessInfo.processInfo.systemUptime, stallLimit: isLive ? 12 : 30)
            switch engine {
            case .vlc:
                if waitingForVideo { startWhenVideoIsReady() }
                else if retryAt == nil { player.play() }
            case .system:
                if retryAt == nil { systemPlayer.play() }
            }
        }
        refreshIsPlaying()
        UIApplication.shared.isIdleTimerDisabled = isPlaying
    }

    /// Reopens the same channel from scratch. Neither engine has a reliable
    /// "seek to live edge" for these streams, so the robust way to snap back to
    /// live after a pause (or a stall) is a fresh connection rather than a seek.
    func goLive() {
        guard !originalURLs.isEmpty else { return }
        start(urls: originalURLs)
    }

    private func scheduleRecovery(now: TimeInterval) {
        // A channel the server closed while it played is opened again at once
        // on the same address, as other players do; waiting, then trying the
        // other address, turned a moment's drop into a long wait.
        let droppedWhilePlaying = isLive && engine == .vlc && health.stall == .failed
            && player.state != .error && health.hasShownPicture
        let neverPlayed = !health.hasShownPicture
        player.stop()
        systemPlayer.pause()
        isPlaying = false
        // A title goes back to where it was, not to its beginning:
        // reconnecting a film used to start it over.
        if !isLive, reopenPosition == nil, let position = progress?.position, position > 0 {
            reopenPosition = max(0, position - 2)
        }
        guard var delay = retries.nextDelay(), !originalURLs.isEmpty else {
            // This channel's own URLs are spent — including the HLS-then-VLC
            // fallback, which happens inside `candidates` before ever reaching
            // here. Only now is another channel worth trying.
            if switchToNextChannel() { return }
            loading = false
            error = "The stream disconnected. Tap Retry to reconnect."
            UIApplication.shared.isIdleTimerDisabled = false
            return
        }
        if droppedWhilePlaying { delay = 0 }
        let ordered = MobileEngineSelection.ordered(originalURLs)
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

    private func refreshIsPlaying() {
        isPlaying = engine == .vlc ? player.isPlaying : systemPlayer.timeControlStatus == .playing
    }

    private func confirmWorkingChannel() {
        guard let id = pendingWorkingChannelID, id == currentChannelID else { return }
        pendingWorkingChannelID = nil
        failover?.didPlay(id)
    }

    // MARK: - Subtitles

    func selectSubtitle(_ track: PlaybackSubtitleTrack) {
        switch engine {
        case .vlc:
            player.currentVideoSubTitleIndex = Int32(track.engineIndex ?? -1)
        case .system:
            guard let item = systemPlayer.currentItem, let group = systemSubtitleGroup else { return }
            // An explicit choice, including Off, belongs to the viewer rather
            // than AVPlayer's language heuristic for the rest of this session.
            systemPlayer.appliesMediaSelectionCriteriaAutomatically = false
            item.select(systemSubtitleOptions[track.id], in: group)
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
            } catch {
                // No legible group is a normal answer for a title with no
                // captions. Playback remains untouched and the button stays
                // out of the way.
            }
        }
    }

    private func resetSubtitles() {
        subtitleTracks = [.off]
        selectedSubtitleID = PlaybackSubtitleTrack.off.id
        systemSubtitleGroup = nil
        systemSubtitleOptions.removeAll()
        systemPlayer.appliesMediaSelectionCriteriaAutomatically = true
    }

    private func refreshStats() {
        let size = player.videoSize
        guard size.width > 0, size.height > 0 else { return }
        videoWidth = Int(size.width)
        videoHeight = Int(size.height)
    }

    // MARK: - Scene phase

    /// Backgrounding no longer means stopping. `MobileBackgroundPolicy` owns the
    /// decision; this method only carries it out.
    func handleScenePhase(active: Bool) {
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
            isPlaying = false
        case .keepPlaying:
            suspended = false
            shouldResume = false
        }
    }

    private func enterForeground(_ action: MobilePlaybackPhaseAction) {
        inBackground = false
        reattachLayerAfterBackground()
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
        guard !isLive, !finished else { return }
        monitor?.cancel()
        monitor = nil
        retryAt = nil
        isPlaying = false
        loading = false
        if let progress { self.progress = MobilePlaybackProgress(position: progress.duration, duration: progress.duration) }
        finished = true
    }

    // MARK: - Teardown

    func stop() {
        monitor?.cancel()
        monitor = nil
        pendingTeardown?.cancel()
        pendingTeardown = nil
        retryAt = nil
        pausedByUser = false
        waitingForVideo = false
        waitingSince = nil
        player.stop()
        player.media = nil
        teardownSystemEngine()
        inBackground = false
        suspended = false
        shouldResume = false
        isPlaying = false
        resetSubtitles()
        UIApplication.shared.isIdleTimerDisabled = false
        MobileAudioSession.deactivate()
    }

    func shutdown() {
        diag.record("shutdown")
        noticeTask?.cancel()
        noticeTask = nil
        failoverNotice = nil
        failover = nil
        currentChannelID = nil
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

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { self.controller?.pictureInPictureChanged(active: true) }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { self.controller?.pictureInPictureChanged(active: false) }
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        MainActor.assumeIsolated { self.controller?.pictureInPictureChanged(active: false) }
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
        case .vlc: if player.isPlaying { player.pause() }
        case .system: systemPlayer.pause()
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
    func installPlayerLayer(for player: AVPlayer) -> AVPlayerLayer {
        if let existing = playerLayer {
            if existing.player !== player { existing.player = player }
            return existing
        }
        let created = AVPlayerLayer(player: player)
        created.videoGravity = .resizeAspect
        created.frame = bounds
        layer.addSublayer(created)
        playerLayer = created
        return created
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
        addSubview(still)
        stillPicture = still
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
