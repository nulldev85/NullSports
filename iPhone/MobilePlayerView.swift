import SwiftUI
import AVFoundation

struct MobilePlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = MobilePlaybackController()
    @State private var controlsVisible = true
    @State private var hideControlsTask: Task<Void, Never>?
    let name: String
    let urls: [URL]
    /// A channel, which runs at the live edge and cannot be scrubbed, or a
    /// title from a media server, which has a length and a position. The two
    /// want different chrome, and showing a LIVE dot over a film was the tell.
    var isLive: Bool = true
    /// What the server says this particular source is, for a title. Beats
    /// guessing from the decoded picture, which is all a channel can offer.
    var sourceDetail: String? = nil
    @State private var scrubTarget: Double?

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
                    .lineupLiquidGlass(RoundedRectangle(cornerRadius: 16, style: .continuous),
                                     fallback: Material.ultraThinMaterial, border: .clear)
            }
            if let notice = controller.failoverNotice {
                VStack {
                    Spacer()
                    Text(notice)
                        .font(.inter(.subheadline, .semibold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .lineupLiquidGlass(Capsule(), fallback: Color.black.opacity(0.62))
                        .padding(.bottom, 40)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
                .accessibilityAddTraits(.updatesFrequently)
            }
            VStack {
                Spacer()
                HStack {
                    PlaybackDiagnosticsOverlay(controller: controller)
                    Spacer()
                }
            }
            if controlsVisible {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        control("xmark", label: "Close player") { dismiss() }
                        Text(name).font(.inter(.headline)).lineLimit(1)
                        Spacer(minLength: 8)
                        if controller.canOfferPictureInPicture {
                            control("pip.enter", label: "Picture in Picture") {
                                showControls()
                                controller.togglePictureInPicture()
                            }
                        }
                        if controller.error == nil && !controller.loading {
                            if isLive { statusBadge }
                            if let detail = badgeDetail { qualityBadge(detail) }
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
                    HStack(spacing: 28) {
                        if showsTransport {
                            control("gobackward.15", label: "Back 15 seconds") {
                                showControls()
                                controller.skip(by: -15)
                            }
                        }
                        control(controller.isPlaying ? "pause.fill" : "play.fill",
                                label: controller.isPlaying ? "Pause" : "Play", size: 64) { controller.toggle() }
                        if showsTransport {
                            control("goforward.15", label: "Forward 15 seconds") {
                                showControls()
                                controller.skip(by: 15)
                            }
                        }
                    }
                    .transition(.opacity)
                }
                if showsTransport, let progress = controller.progress {
                    VStack {
                        Spacer()
                        scrubber(progress)
                    }
                    .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .animation(.easeInOut(duration: 0.2), value: controller.failoverNotice)
        .background(.black).foregroundStyle(LineupStyle.lightPurple)
        .modifier(MobileDismissGesture(enabled: true) { dismiss() })
        .ignoresSafeArea()
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { controller.start(urls: urls) }
        .onDisappear { controller.shutdown(); hideControlsTask?.cancel() }
        // Backgrounding is no longer a stop. MobileBackgroundPolicy decides
        // whether this transition touches playback at all.
        .onChange(of: scenePhase) { _, phase in
            controller.handleScenePhase(active: phase == .active)
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
                Text(controller.isPlaying ? "LIVE" : "PAUSED").font(.inter(.caption2, .bold))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .lineupLiquidGlass(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(controller.isPlaying ? "Live. Tap to jump back to live." : "Paused. Tap to jump back to live.")
    }

    /// A title that reports a length gets a scrubber; a live channel never
    /// does, however the engine happens to be feeling about its own duration.
    private var showsTransport: Bool {
        !isLive && controller.progress != nil && controller.error == nil && !controller.loading
    }

    /// The server's own account of the source beats the decoded picture size,
    /// which is all a channel can be asked for.
    private var badgeDetail: String? { sourceDetail ?? controller.streamQualityLabel }

    private func scrubber(_ progress: MobilePlaybackProgress) -> some View {
        let shown = scrubTarget ?? progress.position
        return VStack(spacing: 6) {
            Slider(value: Binding(
                get: { shown },
                set: { scrubTarget = $0 }
            ), in: 0...max(progress.duration, 1), onEditingChanged: { editing in
                if editing {
                    hideControlsTask?.cancel()
                    controller.beginScrubbing()
                } else {
                    controller.endScrubbing(at: scrubTarget ?? shown)
                    scrubTarget = nil
                    scheduleAutoHide()
                }
            })
            .tint(LineupStyle.lightPurple)
            HStack {
                Text(MobilePlaybackProgress.timecode(shown))
                Spacer()
                Text("-" + MobilePlaybackProgress.timecode(max(0, progress.duration - shown)))
            }
            .font(.inter(.caption2, .semibold).monospacedDigit())
            .foregroundStyle(LineupStyle.lightPurple.opacity(0.75))
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 26)
        .padding(.top, 30)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Playback position")
    }

    private func qualityBadge(_ text: String) -> some View {
        Text(text).font(.inter(.caption2, .semibold))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .lineupLiquidGlass(Capsule())
    }

    private func control(_ symbol: String, label: String, size: CGFloat = 44,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size >= 60 ? 26 : 18, weight: .bold))
                .frame(width: size, height: size)
                .lineupLiquidGlass(Circle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
}
