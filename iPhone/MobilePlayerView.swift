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
            MobileVideoSurface(player: controller.player).ignoresSafeArea()
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
        .onAppear { controller.start(urls: urls) }
        .onDisappear { controller.stop() }
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
                self.isPlaying = self.player.isPlaying
                if self.player.isPlaying { self.loading = false }
                if self.error == nil && (self.player.state == .error || (self.loading && Date().timeIntervalSince(self.started) > 30)) {
                    self.openNext()
                }
            }
        }
    }

    private func openNext() {
        player.stop()
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
        player.play()
        UIApplication.shared.isIdleTimerDisabled = true
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
        if shouldResume { player.play(); UIApplication.shared.isIdleTimerDisabled = true }
        shouldResume = false
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        player.stop()
        player.media = nil
        suspended = false
        shouldResume = false
        isPlaying = false
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

struct MobileVideoSurface: UIViewRepresentable {
    let player: VLCMediaPlayer
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        player.drawable = view
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        if player.drawable == nil { player.drawable = uiView }
    }
}
