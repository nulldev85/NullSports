import SwiftUI
import AVFoundation
import VLCKit

struct MobilePlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = MobilePlaybackController()
    let name: String
    let urls: [URL]

    var body: some View {
        ZStack {
            MobileVideoSurface(controller: controller).ignoresSafeArea()
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
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }.accessibilityLabel("Close player")
                    Text(name).font(.headline).lineLimit(2)
                    Spacer()
                }.padding(8).background(.black.opacity(0.65))
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
        }
        .background(.black).foregroundStyle(NullSportsStyle.lightPurple)
        .modifier(MobileDismissGesture(enabled: true) { dismiss() })
        .ignoresSafeArea()
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { controller.start(urls: urls) }
        .onDisappear { controller.shutdown() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { controller.suspend() }
            else { controller.resume() }
        }
    }
}

@MainActor
final class MobilePlaybackController: ObservableObject {
    let player = VLCMediaPlayer()
    @Published var isPlaying = false
    @Published var loading = true
    @Published var error: String?
    private var monitor: Task<Void, Never>?
    private var candidates: [URL] = []
    private var started = Date()
    private var suspended = false
    private var shouldResume = false
    private weak var videoView: MobileVideoHost?
    private var waitingForVideo = false
    private var missingVideoSince: Date?

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
        started = Date()
        player.play()
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func start(urls: [URL]) {
        stop()
        error = nil
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
                guard !self.waitingForVideo else { continue }
                self.isPlaying = self.player.isPlaying
                if self.player.isPlaying && self.player.hasVideoOut {
                    self.loading = false
                    self.missingVideoSince = nil
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
        isPlaying = false
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
        startWhenVideoIsReady()
    }

    func toggle() {
        if player.isPlaying { player.pause() } else { player.play() }
        isPlaying = player.isPlaying
        UIApplication.shared.isIdleTimerDisabled = isPlaying
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
        if waitingForVideo { startWhenVideoIsReady() }
        else if shouldResume { player.play(); UIApplication.shared.isIdleTimerDisabled = true }
        shouldResume = false
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        waitingForVideo = false
        missingVideoSince = nil
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
