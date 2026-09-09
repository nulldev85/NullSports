import SwiftUI

/// Both compact and expanded layouts keep this same VLC surface and controller.
/// Resizing must not open a second provider connection or restart the stream.
struct MobileGuidePlayer: View {
    @ObservedObject var controller: MobilePlaybackController
    let stream: XtreamStream
    let program: CurrentProgram?
    let expanded: Bool
    let showsMetadata: Bool
    let videoHeight: CGFloat
    let onClose: () -> Void
    let onExpand: () -> Void
    let onRetry: () -> Void
    @State private var controlsVisible = true
    @State private var hideControlsTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                MobileVideoSurface(controller: controller)
                // A transparent tap-catching layer, separate from the embedded VLC
                // view itself. VLCKit inserts its own rendering subview into that
                // UIKit view, and a plain SwiftUI gesture attached directly to a
                // UIViewRepresentable doesn't reliably win against touch handling
                // that library owns — this overlay guarantees ours does.
                Color.clear
                    .contentShape(Rectangle())
                    .highPriorityGesture(TapGesture().onEnded { toggleControls() })
                    .accessibilityLabel("Video. Tap to show playback controls")
                if let error = controller.error {
                    VStack(spacing: 8) {
                        Text(error).font(.caption).multilineTextAlignment(.center)
                        Button("Retry", systemImage: "arrow.clockwise", action: onRetry)
                            .buttonStyle(.borderedProminent)
                    }.padding(.horizontal, 52)
                } else if controller.loading {
                    ProgressView("Opening stream…").font(.caption)
                }
                if controlsVisible {
                    VStack {
                        HStack {
                            control("xmark", label: "Close player", action: onClose)
                            Spacer()
                            control(expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                    label: expanded ? "Return to guide" : "Expand player") {
                                showControls()
                                onExpand()
                            }
                        }
                        Spacer()
                        HStack(spacing: 7) {
                            Button { controller.goLive() } label: {
                                Label(controller.isPlaying ? "LIVE" : "PAUSED", systemImage: "circle.fill")
                                    .font(.caption2.bold()).padding(7)
                                    .background(.black.opacity(0.65), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(controller.isPlaying ? "Live. Tap to jump back to live." : "Paused. Tap to jump back to live.")
                            if let quality = controller.streamQualityLabel {
                                Text(quality).font(.caption2.weight(.semibold)).padding(7)
                                    .background(.black.opacity(0.65), in: Capsule())
                            }
                            Spacer()
                        }
                        .opacity(controller.loading || controller.error != nil ? 0 : 1)
                    }
                    .padding(.horizontal, expanded ? 36 : 8)
                    .padding(.vertical, expanded ? 28 : 8)
                    .transition(.opacity)
                    if !controller.loading && controller.error == nil {
                        control(controller.isPlaying ? "pause.fill" : "play.fill",
                                label: controller.isPlaying ? "Pause" : "Play", size: 56) { controller.toggle() }
                            .transition(.opacity)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: controlsVisible)
            .frame(height: videoHeight).background(.black).clipped()
            if !expanded && showsMetadata {
                VStack(alignment: .leading, spacing: 7) {
                    Text(stream.name).font(.headline).lineLimit(1)
                    HStack(spacing: 8) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                        Text(program?.title ?? "Live channel · No guide information")
                            .font(.caption.weight(.semibold)).lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(NullSportsStyle.raised, in: RoundedRectangle(cornerRadius: 16))
                }.padding(.horizontal, 12).padding(.vertical, 10)
            }
        }
        .foregroundStyle(NullSportsStyle.lightPurple)
        .background(NullSportsStyle.background)
        .onChange(of: stream.id) { _, _ in showControls() }
        .onChange(of: controller.isPlaying) { _, playing in
            if playing { scheduleAutoHide() } else { hideControlsTask?.cancel(); controlsVisible = true }
        }
        .onDisappear { hideControlsTask?.cancel() }
    }

    // Tapping the video is the only way to dismiss controls manually; while
    // actively playing they also fade on their own after a few seconds, same
    // as any other video player. Paused/loading/error states stay visible
    // since there's no motion to signal that the video is still alive.
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

    private func control(_ symbol: String, label: String, size: CGFloat = 44,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size == 56 ? 24 : 18, weight: .bold))
                .frame(width: size, height: size)
                .background(.black.opacity(0.65), in: Circle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
}