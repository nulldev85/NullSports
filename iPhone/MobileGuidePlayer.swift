import SwiftUI

/// Both compact and expanded layouts keep this same surface and controller.
/// Resizing must not open a second provider connection or restart the stream —
/// and neither may entering Picture in Picture, which rides on the very same
/// `AVPlayerLayer` this surface already owns.
struct MobileGuidePlayer: View {
    @ObservedObject var controller: MobilePlaybackController
    let stream: XtreamStream
    let program: CurrentProgram?
    let expanded: Bool
    let showsMetadata: Bool
    let videoHeight: CGFloat
    /// The screen's own insets, handed down because this view cannot read them
    /// for itself: full screen reaches past the safe area deliberately, and a
    /// view that ignores an inset is told the inset is zero. The picture is
    /// meant to fill the screen; the controls on top of it are not, or they end
    /// up under the Dynamic Island — which a screenshot does not capture, so it
    /// only ever showed up on the device.
    var screenInsets: EdgeInsets = EdgeInsets()
    let onClose: () -> Void
    let onExpand: () -> Void
    let onRetry: () -> Void
    /// Live supplies this to reopen the channel picker for the game on screen.
    /// The Guide leaves it nil, and the control does not appear there.
    var onChooseChannel: (() -> Void)? = nil
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
                        Text(error).font(.inter(.caption)).multilineTextAlignment(.center)
                        Button("Retry", systemImage: "arrow.clockwise", action: onRetry)
                            .buttonStyle(.borderedProminent)
                    }.padding(.horizontal, 52)
                } else if controller.loading {
                    ProgressView("Opening stream…").font(.inter(.caption))
                }
                if let notice = controller.failoverNotice {
                    VStack {
                        Spacer()
                        Text(notice)
                            .font(.inter(.caption, .semibold))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .lineupLiquidGlass(Capsule(), fallback: Color.black.opacity(0.62))
                            .padding(.bottom, 12)
                    }
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .accessibilityAddTraits(.updatesFrequently)
                }
                VStack {
                    HStack {
                        Spacer()
                        PlaybackDiagnosticsOverlay(controller: controller)
                    }
                    Spacer()
                }
                if controlsVisible {
                    VStack {
                        HStack(spacing: 10) {
                            control("xmark", label: "Close player", action: onClose)
                            if controller.error == nil && !controller.loading {
                                statusBadge
                                if let quality = controller.streamQualityLabel { qualityBadge(quality) }
                            }
                            Spacer()
                            if let onChooseChannel {
                                control("list.bullet", label: "Choose another channel") {
                                    showControls()
                                    onChooseChannel()
                                }
                            }
                            if controller.canOfferPictureInPicture {
                                control("pip.enter", label: "Picture in Picture") {
                                    showControls()
                                    controller.togglePictureInPicture()
                                }
                            }
                            control(expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                    label: expanded ? "Return to guide" : "Expand player") {
                                showControls()
                                onExpand()
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, expanded ? 24 : 10)
                    .padding(.vertical, expanded ? 20 : 10)
                    .padding(.leading, expanded ? screenInsets.leading : 0)
                    .padding(.trailing, expanded ? screenInsets.trailing : 0)
                    .padding(.top, expanded ? screenInsets.top : 0)
                    .transition(.opacity)
                    // A ZStack-centered sibling, not nested in the VStack above, so
                    // it lands dead-center on screen, matching every other player.
                    if !controller.loading && controller.error == nil {
                        control(controller.isPlaying ? "pause.fill" : "play.fill",
                                label: controller.isPlaying ? "Pause" : "Play", size: expanded ? 48 : 42) {
                            controller.toggle()
                        }
                            .transition(.opacity)
                    }
                }
            }
            .foregroundStyle(LineupStyle.mediaText)
            .animation(.easeInOut(duration: 0.2), value: controlsVisible)
            .animation(.easeInOut(duration: 0.2), value: controller.failoverNotice)
            .frame(height: videoHeight).background(.black).clipped()
            if !expanded && showsMetadata {
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(LineupStyle.lightPurple.opacity(0.7))
                        .frame(width: 3, height: 72)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text("NOW SHOWING")
                                .font(.inter(9, .bold))
                                .tracking(1.5)
                                .foregroundStyle(LineupStyle.lightPurple.opacity(0.65))
                            if program?.isNew == true {
                                Text("NEW")
                                    .font(.inter(9, .bold))
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(LineupStyle.raised, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            }
                            Spacer(minLength: 4)
                            if let program {
                                Text("\(program.start.formatted(date: .omitted, time: .shortened)) – \(program.end.formatted(date: .omitted, time: .shortened))")
                                    .font(.inter(.caption2))
                                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.65))
                                    .lineLimit(1)
                            }
                        }
                        Text(program?.title ?? "Live channel · No guide information")
                            .font(.inter(.headline))
                            .lineLimit(2)
                            .accessibilityAddTraits(.isHeader)
                        Text(stream.name)
                            .font(.inter(.caption))
                            .foregroundStyle(LineupStyle.lightPurple.opacity(0.7))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .accessibilityElement(children: .combine)
            }
        }
        .foregroundStyle(LineupStyle.text)
        .background(LineupStyle.background)
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

    private func control(_ symbol: String, label: String, size: CGFloat = 36,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size >= 42 ? 17 : 14, weight: .semibold))
                .frame(width: size, height: size)
                .lineupLiquidGlass(Circle(), fallback: Color.black.opacity(0.48))
                .contentShape(Circle())
        }.buttonStyle(.plain).accessibilityLabel(label)
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
            .padding(.horizontal, 9).padding(.vertical, 7)
            .lineupLiquidGlass(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(controller.isPlaying ? "Live. Tap to jump back to live." : "Paused. Tap to jump back to live.")
    }

    private func qualityBadge(_ text: String) -> some View {
        Text(text).font(.inter(.caption2, .semibold))
            .padding(.horizontal, 9).padding(.vertical, 7)
            .lineupLiquidGlass(Capsule())
    }
}
