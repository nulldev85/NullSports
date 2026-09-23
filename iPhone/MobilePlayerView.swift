import SwiftUI
import AVFoundation

struct MobilePlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    /// Compact means a short screen, which on an iPhone means landscape. It is
    /// the one layout where the synopsis and the transport controls compete
    /// for the same band of the picture.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @StateObject private var controller = MobilePlaybackController()
    @State private var controlsVisible = true
    @State private var hideControlsTask: Task<Void, Never>?
    let name: String
    let urls: [URL]
    /// A channel, which runs at the live edge and cannot be scrubbed, or a
    /// title from a media server, which has a length and a position. The two
    /// want different chrome, and showing a LIVE dot over a film was the tell.
    var isLive: Bool = true
    /// The bitrate the server reported for this source. The server holds the
    /// file, so this is the one number nothing on the device can improve on.
    var sourceBitrate: String? = nil
    /// The quality the server parsed from the release name. Only a fallback:
    /// a name can say 4K about a 1080p file, so the decoded picture wins.
    var sourceQuality: String? = nil
    /// What is playing, shown beside the controls while they are up.
    var synopsis: MobilePlayerSynopsis? = nil
    var initialPosition: TimeInterval? = nil
    var onProgress: ((TimeInterval, TimeInterval) -> Void)? = nil
    @State private var scrubTarget: Double?
    @State private var lastReportedPosition: TimeInterval = 0
    @State private var showingSubtitles = false

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
                    Button("Retry", systemImage: "arrow.clockwise") {
                        controller.start(urls: urls, initialPosition: isLive ? nil : initialPosition)
                    }
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
                        control("xmark", label: "Close player") { exit() }
                        if showsTitleInHeader {
                            Text(name).font(.inter(.headline)).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if controller.canOfferPictureInPicture {
                            control("pip.enter", label: "Picture in Picture") {
                                showControls()
                                controller.togglePictureInPicture()
                            }
                        }
                        if !isLive && controller.subtitleTracks.count > 1 {
                            control(controller.selectedSubtitleID == PlaybackSubtitleTrack.off.id
                                    ? "captions.bubble" : "captions.bubble.fill",
                                    label: "Subtitles, \(controller.selectedSubtitleTitle)") {
                                showControls()
                                showingSubtitles = true
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
                    // The panel's width is measured rather than assumed: in
                    // landscape it has to stop short of the transport controls
                    // sitting dead centre, and only the container knows where
                    // that is.
                    GeometryReader { frame in
                        VStack(alignment: .leading, spacing: 10) {
                            Spacer()
                            if let synopsis, !synopsis.isEmpty {
                                synopsisPanel(synopsis, within: frame.size.width)
                            }
                            scrubber(progress)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .bottomLeading)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 18)
                    .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .animation(.easeInOut(duration: 0.2), value: controller.failoverNotice)
        // The picture and its backing fill the screen; the controls do not.
        // Ignoring the safe area for the whole player put the close button, the
        // badges and the scrubber underneath the Dynamic Island — which a
        // screenshot does not capture, so it only showed up on the device.
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(LineupStyle.mediaText)
        .modifier(MobileDismissGesture(enabled: true,
                                       onBeginExit: { controller.freezePictureForExit() }) { dismiss() })
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .confirmationDialog("Subtitles", isPresented: $showingSubtitles,
                            titleVisibility: .visible) {
            ForEach(controller.subtitleTracks) { track in
                Button(track.title + (track.id == controller.selectedSubtitleID ? "  ✓" : "")) {
                    controller.selectSubtitle(track)
                    showControls()
                }
            }
            Button("Cancel", role: .cancel) { showControls() }
        }
        .onAppear {
            controller.isLive = isLive
            controller.start(urls: urls, initialPosition: isLive ? nil : initialPosition)
        }
        .onDisappear {
            reportProgress(force: true)
            controller.shutdown()
            hideControlsTask?.cancel()
        }
        .onChange(of: controller.progress) { _, _ in reportProgress() }
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

    private func reportProgress(force: Bool = false) {
        guard !isLive, let progress = controller.progress, progress.duration > 0 else { return }
        guard force || abs(progress.position - lastReportedPosition) >= 5 else { return }
        lastReportedPosition = progress.position
        onProgress?(progress.position, progress.duration)
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

    /// Resolution from the picture actually being decoded, bitrate from the
    /// server that holds the file. The server's parsed quality is the fallback
    /// only until something has decoded, because a release name is a claim and
    /// the decoder is the fact.
    private var badgeDetail: String? {
        let parts = [controller.streamQualityLabel ?? sourceQuality, sourceBitrate].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The panel above the scrubber already names what is playing, so the top
    /// bar does not say it twice. Tied to that panel actually being drawn
    /// rather than merely intended: a live channel has none, and neither does
    /// a title whose length never resolves, and either way the name has to be
    /// somewhere.
    private var showsTitleInHeader: Bool {
        guard showsTransport, let heading = synopsis?.heading, !heading.isEmpty else { return true }
        return false
    }

    private func synopsisPanel(_ synopsis: MobilePlayerSynopsis,
                               within available: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let heading = synopsis.heading, !heading.isEmpty {
                Text(heading).font(.inter(.subheadline, .semibold)).lineLimit(1)
            }
            if let detail = synopsis.detail, !detail.isEmpty {
                Text(detail)
                    .font(.inter(.caption2, .semibold))
                    .foregroundStyle(LineupStyle.mediaSecondary.opacity(0.82))
                    .lineLimit(1)
            }
            if let overview = synopsis.overview, !overview.isEmpty {
                Text(overview)
                    .font(.inter(.caption))
                    .foregroundStyle(LineupStyle.mediaText.opacity(0.82))
                    // A narrower column is a taller one, and in landscape the
                    // height is what runs into the controls. Two lines there.
                    .lineLimit(verticalSizeClass == .compact ? 2 : 3)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: MobilePlayerLayout.synopsisWidth(
                    available: available, compactHeight: verticalSizeClass == .compact),
                    alignment: .leading)
        .lineupLiquidGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// A track drawn to match the app's other floating controls rather than
    /// the system slider, whose stock thumb and grey rail sat on the video
    /// looking like nothing else on the screen.
    private func scrubber(_ progress: MobilePlaybackProgress) -> some View {
        let shown = scrubTarget ?? progress.position
        let fraction = progress.duration > 0 ? min(max(shown / progress.duration, 0), 1) : 0
        return VStack(spacing: 8) {
            GeometryReader { track in
                let width = track.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(LineupStyle.mediaAccent)
                        .frame(width: max(0, width * fraction))
                    Circle()
                        .fill(.white)
                        .frame(width: scrubTarget == nil ? 13 : 17)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .offset(x: max(0, width * fraction - (scrubTarget == nil ? 6.5 : 8.5)))
                }
                .frame(height: 5)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if scrubTarget == nil {
                                hideControlsTask?.cancel()
                                controller.beginScrubbing()
                            }
                            let ratio = min(max(value.location.x / max(width, 1), 0), 1)
                            scrubTarget = ratio * progress.duration
                        }
                        .onEnded { _ in
                            controller.endScrubbing(at: scrubTarget ?? shown)
                            scrubTarget = nil
                            scheduleAutoHide()
                        }
                )
            }
            .frame(height: 22)
            HStack {
                Text(MobilePlaybackProgress.timecode(shown))
                Spacer()
                Text("-" + MobilePlaybackProgress.timecode(max(0, progress.duration - shown)))
            }
            .font(.inter(.caption2, .semibold).monospacedDigit())
            .foregroundStyle(LineupStyle.mediaText.opacity(0.8))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .lineupLiquidGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(.easeOut(duration: 0.12), value: scrubTarget == nil)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(MobilePlaybackProgress.timecode(shown))
    }

    private func qualityBadge(_ text: String) -> some View {
        Text(text).font(.inter(.caption2, .semibold))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .lineupLiquidGlass(Capsule())
    }

    /// The close button leaves the same way a swipe does: the picture is
    /// stilled first, so it travels with the frame instead of trailing it.
    private func exit() {
        controller.freezePictureForExit()
        dismiss()
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
