import SwiftUI
import AVFoundation
import VLCKit

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
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }
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
                VStack {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").frame(width: 44, height: 44)
                        }.accessibilityLabel("Close player")
                        Text(name).font(.headline).lineLimit(2)
                        Spacer()
                    }.padding(8).background(.black.opacity(0.65))
                    if controller.error == nil && !controller.loading {
                        HStack(spacing: 8) {
                            statusBadge
                            if let quality = controller.streamQualityLabel { qualityBadge(quality) }
                            Spacer()
                        }.padding(.horizontal, 8).padding(.top, 6)
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        Button { controller.toggle() } label: {
                            Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2).frame(width: 56, height: 56)
                        }
                        .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")
                        .disabled(controller.error != nil || controller.loading)
                        Spacer()
                    }.background(.black.opacity(0.65))
                }
                .transition(.opacity)
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
            Label(controller.isPlaying ? "LIVE" : "PAUSED", systemImage: "circle.fill")
                .font(.caption2.bold())
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(.black.opacity(0.65), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(controller.isPlaying ? "Live. Tap to jump back to live." : "Paused. Tap to jump back to live.")
    }

    private func qualityBadge(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(.black.opacity(0.65), in: Capsule())
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
        isPlaying = false
        videoWidth = nil
        videoHeight = nil
        guard !candidates.isEmpty, let media = VLCMedia(url: candidates.removeFirst()) else {
            loading = false
            UIApplication.shared.isIdleTimerDisabled = false
            error = "This stream is unavailable. Try again or choose another channel."
            return
        }
        media.addOption(":network-caching=3000")
        media.addOption(":live-caching=3000")
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
