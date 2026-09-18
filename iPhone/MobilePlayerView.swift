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
