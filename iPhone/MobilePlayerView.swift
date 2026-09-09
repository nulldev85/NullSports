import SwiftUI
import AVFoundation
import VLCKitSPM

struct MobilePlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = MobilePlaybackController()
    @State private var controlsVisible = true
    @State private var hideControlsTask: Task<Void, Never>?
    let name: String
    let urls: [URL]

    var body: some View {
        ZStack {
            MobileVideoSurface(controller: controller)
                .ignoresSafeArea()
            // A transparent tap-catching layer, separate from the embedded VLC
            // view itself. VLCKit inserts its own rendering subview into that
            // UIKit view, and a plain SwiftUI gesture attached directly to a
            // UIViewRepresentable doesn't reliably win against touch handling
            // that library owns — this overlay guarantees ours does.
            Color.clear
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .highPriorityGesture(TapGesture().onEnded { toggleControls() })
                .accessibilityLabel("Video. Tap to show playback controls")
            if let error = controller.error {
                VStack(spacing: 16) {
                    Text(error).multilineTextAlignment(.center)
                    Button("Retry", systemImage: "arrow.clockwise") { controller.start(urls: urls) }
                        .buttonStyle(.borderedProminent)
                }.padding(32)
            } else if controller.loading {
                ProgressView("Opening stream…").padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            if controlsVisible {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        control("xmark", label: "Close player") { dismiss() }
                        Text(name).font(.headline).lineLimit(1)
                        Spacer(minLength: 8)
                        if controller.error == nil && !controller.loading {
                            statusBadge
                            if let quality = controller.streamQualityLabel { qualityBadge(quality) }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 22)
                    .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
                    Spacer()
                }
                .transition(.opacity)
                // A ZStack-centered sibling, not nested in the VStack above, so it
                // lands dead-center on screen — the same spot every other player
                // in the app puts its play/pause control.
                if !controller.loading && controller.error == nil {
                    control(controller.isPlaying ? "pause.fill" : "play.fill",
                            label: controller.isPlaying ? "Pause" : "Play", size: 64) { controller.toggle() }
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .background(.black).foregroundStyle(NullSportsStyle.lightPurple)
        .modifier(MobileDismissGesture(enabled: true) { dismiss() })
        .ignoresSafeArea()
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { controller.start(urls: urls) }
        .onDisappear { controller.shutdown(); hideControlsTask?.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { controller.suspend() }
            else { controller.resume() }
        }
        .onChange(of: controller.isPlaying) { _, playing in
            if playing { scheduleAutoHide() } else { hideControlsTask?.cancel(); controlsVisible = true }
        }
    }

    private func toggleControls() {
        if controlsVisible {
            hideControlsTask?.cancel()
            controlsVisible = false
        } else {
            showControls()
        }
    }

    private func showControls() {
        controlsVisible = true
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        hideControlsTask?.cancel()
        guard controller.isPlaying else { return }
        hideControlsTask = Task {
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard !Task.isCancelled else { return }
            controlsVisible = false
        }
    }

    // Doubles as a jump-back-to-live action: reopens the stream fresh, so a
    // viewer who paused for a few seconds (or hit a stall) can snap back to
    // the live edge instead of waiting or guessing why nothing's happening.
    private var statusBadge: some View {
        Button { controller.goLive() } label: {
            HStack(spacing: 6) {
                if controller.isPlaying { MobileLiveDot() }
                Text(controller.isPlaying ? "LIVE" : "PAUSED").font(.caption2.bold())
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.black.opacity(0.6), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(controller.isPlaying ? "Live. Tap to jump back to live." : "Paused. Tap to jump back to live.")
    }

    private func qualityBadge(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.black.opacity(0.6), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }

    private func control(_ symbol: String, label: String, size: CGFloat = 44,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size >= 60 ? 26 : 18, weight: .bold))
                .frame(width: size, height: size)
                .background(.black.opacity(0.6), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
}

@MainActor
final class MobilePlaybackController: ObservableObject {
    let player = VLCMediaPlayer()
    @Published var isPlaying = false
    @Published var loading = true
    @Published var error: String?
    @Published private(set) var videoWidth: Int?
    @Published private(set) var videoHeight: Int?
    private var monitor: Task<Void, Never>?
    private var candidates: [URL] = []
    private var originalURLs: [URL] = []
    private var started = Date()
    private var suspended = false
    private var shouldResume = false
    private weak var videoView: MobileVideoHost?
    private var waitingForVideo = false
    private var missingVideoSince: Date?
    private var waitingSince: Date?
    private var lastPlaybackTimeMs: Int32?
    private var timeUnchangedSince: Date?

    /// "1080p", "720p", etc., derived from the source video track. Nil until
    /// VLC reports track info, which only happens once a video is decoding.
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
    // versions and isn't worth pinning to for a badge — videoSize alone
    // covers what was actually asked for ("quality of channel").
    var streamQualityLabel: String? { qualityLabel }

    func attachVideo(_ view: MobileVideoHost) {
        videoView = view
        if (player.drawable as? UIView) !== view { player.drawable = view }
        startWhenVideoIsReady()
    }

    func detachVideo(_ view: MobileVideoHost) {
        guard videoView === view else { return }
        stop()
        player.drawable = nil
        videoView = nil
    }

    private func startWhenVideoIsReady() {
        guard waitingForVideo, !suspended, let view = videoView,
              view.window != nil, view.bounds.width > 0, view.bounds.height > 0 else { return }
        // Never call play before VLC has a mounted, nonzero drawable.
        player.drawable = view
        waitingForVideo = false
        waitingSince = nil
        started = Date()
        player.play()
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func start(urls: [URL]) {
        stop()
        error = nil
        originalURLs = urls
        candidates = Array(urls.reversed()) // Prefer transport streams, as on Apple TV.
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
                guard !self.suspended else { continue }
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
                self.isPlaying = self.player.isPlaying
                if self.player.isPlaying && self.player.hasVideoOut {
                    self.loading = false
                    self.missingVideoSince = nil
                    self.refreshStats()
                    // Some provider drops don't close the connection or raise a VLC
                    // error — the feed just goes quiet and the last frame freezes
                    // while isPlaying/hasVideoOut both still read true. Watch the
                    // actual playback clock: if it hasn't moved in 10s, treat it as
                    // dead and reconnect, instead of leaving a frozen picture up
                    // until the viewer notices and force-quits back to reload it.
                    // VLCKit 4.0.0-a22's `player.time` is a non-optional VLCTime
                    // (not `VLCTime?` as some older docs describe), so no `?` here.
                    let currentMs = self.player.time.intValue
                    if let last = self.lastPlaybackTimeMs, last == currentMs {
                        if self.timeUnchangedSince == nil { self.timeUnchangedSince = Date() }
                        if Date().timeIntervalSince(self.timeUnchangedSince!) > 10 {
                            self.goLive()
                            continue
                        }
                    } else {
                        self.timeUnchangedSince = nil
                    }
                    self.lastPlaybackTimeMs = currentMs
                } else if self.player.isPlaying {
                    self.loading = true
                    if self.missingVideoSince == nil { self.missingVideoSince = Date() }
                }
                if let since = self.missingVideoSince, Date().timeIntervalSince(since) > 15 {
                    self.openNext()
                    continue
                }
                if self.error == nil && (self.player.state == .error || (self.loading && Date().timeIntervalSince(self.started) > 30)) {
                    self.openNext()
                }
            }
        }
    }

    private func openNext() {
        player.stop()
        waitingForVideo = false
        missingVideoSince = nil
        waitingSince = nil
        lastPlaybackTimeMs = nil
        timeUnchangedSince = nil
        isPlaying = false
        videoWidth = nil
        videoHeight = nil
        guard !candidates.isEmpty, let media = VLCMedia(url: candidates.removeFirst()) else {
            loading = false
            UIApplication.shared.isIdleTimerDisabled = false
            error = "This stream is unavailable. Try again or choose another channel."
            return
        }
        // Matches tvOS's buffer size — 3s was too tight for some providers and
        // read as a stall/drop after several minutes on a slightly slower link.
        media.addOption(":network-caching=5000")
        media.addOption(":live-caching=5000")
        media.addOption(":http-reconnect=true")
        player.media = media
        started = Date()
        loading = true
        waitingForVideo = true
        waitingSince = Date()
        startWhenVideoIsReady()
    }

    func toggle() {
        if player.isPlaying { player.pause() } else { player.play() }
        isPlaying = player.isPlaying
        UIApplication.shared.isIdleTimerDisabled = isPlaying
    }

    /// Reopens the same channel from scratch. VLC has no reliable "seek to live
    /// edge" for these streams, so the robust way to snap back to live after a
    /// pause (or a stall) is a fresh connection rather than trying to seek.
    func goLive() {
        guard !originalURLs.isEmpty else { return }
        start(urls: originalURLs)
    }

    private func refreshStats() {
        let size = player.videoSize
        guard size.width > 0, size.height > 0 else { return }
        videoWidth = Int(size.width)
        videoHeight = Int(size.height)
    }

    func suspend() {
        guard !suspended else { return }
        shouldResume = player.isPlaying || loading
        suspended = true
        player.pause()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        started = Date()
        missingVideoSince = nil
        if waitingForVideo {
            waitingSince = Date() // Give it a fresh 8s window instead of counting time spent backgrounded.
            startWhenVideoIsReady()
        } else if shouldResume { player.play(); UIApplication.shared.isIdleTimerDisabled = true }
        shouldResume = false
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        waitingForVideo = false
        missingVideoSince = nil
        waitingSince = nil
        lastPlaybackTimeMs = nil
        timeUnchangedSince = nil
        player.stop()
        player.media = nil
        suspended = false
        shouldResume = false
        isPlaying = false
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func shutdown() {
        stop()
        // Cancel queued layout attachments from the retired view before another
        // tab/session can start. Old dismantle callbacks only own their old player.
        videoView?.controller = nil
        player.drawable = nil
        videoView = nil
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
    private var attachmentScheduled = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        autoresizesSubviews = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
