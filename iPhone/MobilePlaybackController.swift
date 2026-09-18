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
    }
    var failover: FailoverContext?
    /// The channel currently playing, so failover knows what to retire.
    private(set) var currentChannelID: Int?
    private var failoverState = StreamFailoverState()
    private var noticeTask: Task<Void, Never>?

    private var monitor: Task<Void, Never>?
    private var candidates: [URL] = []
    private var originalURLs: [URL] = []
    private var started = Date()
    private var suspended = false
    private var shouldResume = false
    private weak var videoView: MobileVideoHost?
    private var waitingForVideo = false
    private var waitingSince: Date?
    private var currentURL: URL?
    private var pausedByUser = false
    private var health = LivePlaybackHealth(now: ProcessInfo.processInfo.systemUptime)
    private var retries = LivePlaybackRetry()
    private var retryAt: TimeInterval?

    // AVPlayer engine state.
    private var systemObservers: [NSKeyValueObservation] = []
    private var systemNotifications: [NSObjectProtocol] = []
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

    // MARK: - Surface

    func attachVideo(_ view: MobileVideoHost) {
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
        stop()
        player.drawable = nil
        view.removePlayerLayer()
        videoView = nil
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
    func start(urls: [URL], channelID: Int? = nil, resetFailover: Bool = true) {
        diag.beginSession("start channel=\(channelID.map(String.init) ?? "—") urls=\(urls.count) resetFailover=\(resetFailover)")
        for url in MobileEngineSelection.ordered(urls) {
            diag.record("  candidate \(url.lastPathComponent) -> \(MobileEngineSelection.engine(for: url).rawValue)")
        }
        stop()
        error = nil
        originalURLs = urls
        if let channelID { currentChannelID = channelID }
        if resetFailover { failoverState.reset() }
        retries.reset()
        // HLS first on the phone so Picture in Picture is reachable; the
        // transport stream stays queued behind it. Apple TV keeps its own order.
        candidates = MobileEngineSelection.ordered(urls)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
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
                // exactly when some of these values matter. Observation only.
                self.diag.update(snapshot: self.diagnosticsSnapshot)
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
                if self.engine == .system, self.error == nil {
                    let item = self.systemPlayer.currentItem
                    let verdict = SystemEngineWatchdog.verdict(
                        elapsed: Date().timeIntervalSince(self.started),
                        isReady: item?.status == .readyToPlay,
                        hasVideo: (item?.presentationSize.width ?? 0) > 0)
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
                let recover = self.health.observe(now: now, playing: self.player.isPlaying, video: self.player.hasVideoOut,
                    time: self.player.time.intValue, frames: self.player.media?.numberOfDisplayedPictures,
                    failed: self.player.state == .error || self.player.state == .ended || self.player.state == .stopped)
                if self.health.isStable(now: now) { self.retries.reset() }
                if recover { self.scheduleRecovery(now: now) }
            }
        }
    }

    private func openNext() {
        teardownSystemEngine()
        player.stop()
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
        // Matches tvOS's buffer size — 3s was too tight for some providers and
        // read as a stall/drop after several minutes on a slightly slower link.
        media.addOption(":network-caching=5000")
        media.addOption(":live-caching=5000")
        media.addOption(":http-reconnect=true")
        player.media = media
        waitingForVideo = true
        waitingSince = Date()
        startWhenVideoIsReady()
    }

    private func openSystem(_ url: URL) {
        health = LivePlaybackHealth(now: ProcessInfo.processInfo.systemUptime)
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
        // A live playlist that ends is a dropped feed, not a finished programme.
        systemNotifications.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                     object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemEngineFailed() }
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
        health = LivePlaybackHealth(now: ProcessInfo.processInfo.systemUptime)
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
            health = LivePlaybackHealth(now: ProcessInfo.processInfo.systemUptime)
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
        player.stop()
        systemPlayer.pause()
        isPlaying = false
        guard let delay = retries.nextDelay(), !originalURLs.isEmpty else {
            // This channel's own URLs are spent — including the HLS-then-VLC
            // fallback, which happens inside `candidates` before ever reaching
            // here. Only now is another channel worth trying.
            if switchToNextChannel() { return }
            loading = false
            error = "The stream disconnected. Tap Retry to reconnect."
            UIApplication.shared.isIdleTimerDisabled = false
            return
        }
        let ordered = MobileEngineSelection.ordered(originalURLs)
        let index = currentURL.flatMap { ordered.firstIndex(of: $0) } ?? 0
        // First attempt retries the same endpoint; later ones rotate, so a dead
        // HLS endpoint ends up on the transport stream instead of looping.
        let next = retries.attempts == 1 ? index : (index + 1) % ordered.count
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
            started = Date()
            health = LivePlaybackHealth(now: ProcessInfo.processInfo.systemUptime)
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

    // MARK: - Teardown

    func stop() {
        monitor?.cancel()
        monitor = nil
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
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func shutdown() {
        diag.record("shutdown")
        noticeTask?.cancel()
        noticeTask = nil
        failoverNotice = nil
        failover = nil
        currentChannelID = nil
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
        // expanding, collapsing, or rotating without replacing the drawable.
        for renderer in subviews {
            renderer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            if renderer.frame != bounds { renderer.frame = bounds }
        }
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
