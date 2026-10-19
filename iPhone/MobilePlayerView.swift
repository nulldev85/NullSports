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
    /// Supplied by Library episode/movie playback, never live/preview video.
    var segmentsLookup: (() async -> MobilePlaybackSegments?)? = nil
    var subtitleIdentityLookup: (() async -> MobileSubtitleIdentity?)? = nil
    var seekPreviewLookup: (() async -> MobileSeekPreviewSource?)? = nil
    @StateObject private var seekPreviewSession = MobileSeekPreviewSession()
    private var seekPreview: MobileSeekPreviewStore { seekPreviewSession.store }
    @State private var segments: MobilePlaybackSegments?
    @AppStorage("Lineup.library.introDB.v1") private var introEnabled = true
    @AppStorage("Lineup.library.skipRecaps.v1") private var recapEnabled = true
    @AppStorage("Lineup.library.creditsPrompt.v1") private var creditsEnabled = true
    @AppStorage("Lineup.library.postCreditsNotice.v1") private var postCreditsEnabled = true
    var initialPosition: TimeInterval? = nil
    var onProgress: ((TimeInterval, TimeInterval) -> Void)? = nil
    /// Lineup chooses the episode; verified credits can show the offer earlier.
    var nextEpisode: MobileNextEpisodeOffer? = nil
    /// Told when the title plays to its end, before the player closes.
    var onReachedEnd: (() -> Void)? = nil
    /// Sent away for this episode: it does not come back.
    @State private var nextEpisodeDeclined = false
    @State private var isScrubbing = false
    @State private var lastReportedPosition: TimeInterval = 0
    @State private var showingSubtitles = false
    @State private var showingOnlineSubtitles = false
    @State private var showingSubtitleSettings = false
    @State private var onlineSubtitleSession = UUID()

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
                        // A title picks up where it was when it stopped, not
                        // where it was when the player opened.
                        controller.start(urls: urls, initialPosition: isLive ? nil
                            : (lastReportedPosition > 0 ? lastReportedPosition : initialPosition))
                    }
                        .lineupProminentButton()
                }
                .padding(24)
                .lineupLiquidGlass(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(32)
            } else if controller.loading {
                ProgressView("Opening stream…").padding(24)
                    .lineupLiquidGlass(RoundedRectangle(cornerRadius: 16, style: .continuous),
                                     fallback: Material.ultraThinMaterial, border: .clear)
            }
            if let notice = controller.failoverNotice {
                VStack {
                    Spacer()
                    PlaybackEngineText(notice, style: .subheadline)
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
                    LineupGlassGroup {
                    MobilePlayerHeader {
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
                        if !isLive && (controller.subtitleTracks.count > 1 || offersOnlineSubtitles || subtitleIdentityLookup != nil) {
                            control(controller.selectedSubtitleID == PlaybackSubtitleTrack.off.id
                                    ? "captions.bubble" : "captions.bubble.fill",
                                    label: "Subtitles, \(controller.selectedSubtitleTitle)") {
                                showControls()
                                showingSubtitles = true
                            }
                        }
                    }
                    } details: {
                        if controller.error == nil && !controller.loading {
                            MobilePlaybackEngineBadge(engine: controller.engine)
                            if isLive { statusBadge.fixedSize() }
                            if let detail = badgeDetail { qualityBadge(detail).fixedSize() }
                            ForEach(controller.mediaInfo.badges, id: \.self) { PlaybackFormatBadge(text: $0) }
                        }
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
                    LineupGlassGroup {
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
                            if skipAction != nil {
                                HStack { Spacer(); skipSegmentButton }
                            } else if showsPostCreditsNotice {
                                HStack { Spacer(); postCreditsNotice }
                            }
                            if let synopsis, !synopsis.isEmpty {
                                synopsisPanel(synopsis, within: frame.size.width)
                            }
                            MobileLibrarySeekBar(controller: controller, progress: progress, preview: seekPreview) { editing in
                                isScrubbing = editing
                                if editing { hideControlsTask?.cancel() } else { scheduleAutoHide() }
                            }
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
        // Next Episode, in the bottom-right corner while the controls are
        // away, as on the television.
        .overlay(alignment: .bottomTrailing) {
            if showsNextEpisode, let offer = nextEpisode {
                MobileNextEpisodeCard(offer: offer, play: { playNext(offer) },
                                      decline: { nextEpisodeDeclined = true })
                    .padding(.trailing, 16).padding(.bottom, 24)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if !controlsVisible, skipAction != nil {
                skipSegmentButton.padding(.trailing, 16).padding(.bottom, 24)
            } else if !controlsVisible, showsPostCreditsNotice {
                postCreditsNotice.padding(.trailing, 16).padding(.bottom, 24)
            }
        }
        .task(id: urls) {
            segments = nil
            nextEpisodeDeclined = false
            guard !isLive, let segmentsLookup else { return }
            let result = await segmentsLookup()
            guard !Task.isCancelled else { return }
            segments = result
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: showsNextEpisode)
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .animation(.easeInOut(duration: 0.2), value: controller.failoverNotice)
        // The picture and its backing fill the screen; the controls do not.
        // Ignoring the safe area for the whole player put the close button, the
        // badges and the scrubber underneath the Dynamic Island — which a
        // screenshot does not capture, so it only showed up on the device.
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(LineupStyle.mediaText)
        .modifier(MobileDismissGesture(enabled: !isScrubbing,
                                       onBeginExit: { controller.freezePictureForExit() }) { dismiss() })
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .lineupChoices("Subtitles", symbol: "captions.bubble", isPresented: $showingSubtitles) {
            var items = controller.subtitleTracks.map { track in
                MobileMenuItem(track.title, id: "\(track.id)",
                               isSelected: track.id == controller.selectedSubtitleID) {
                    controller.selectSubtitle(track)
                    showControls()
                }
            }
            if offersOnlineSubtitles {
                items.append(MobileMenuItem(controller.canAttachOnlineSubtitles ? "Find Subtitles Online" : "Use AetherEngine or VLC for Online Subtitles",
                    symbol: "magnifyingglass", id: "online-subtitles", isEnabled: controller.canAttachOnlineSubtitles,
                    namesEngine: !controller.canAttachOnlineSubtitles) {
                    onlineSubtitleSession = controller.subtitleSessionID
                    showingOnlineSubtitles = true
                })
            }
            if !isLive && subtitleIdentityLookup != nil {
                items.append(MobileMenuItem("Subtitle Settings", symbol: "textformat.size", id: "subtitle-settings") {
                    showingSubtitleSettings = true
                })
            }
            return items
        } onCancel: { showControls() }
        .sheet(isPresented: $showingOnlineSubtitles, onDismiss: { showControls() }) {
            if let subtitleIdentityLookup {
                MobileOnlineSubtitlesSheet(name: name, identity: subtitleIdentityLookup,
                    showsPiPLimitation: controller.engine == .aether) { data, subtitle in
                    try await controller.addOnlineSubtitle(data, title: subtitle.title, language: subtitle.language,
                        sessionID: onlineSubtitleSession)
                }
            }
        }
        .onChange(of: controller.subtitleSessionID) { _, _ in showingOnlineSubtitles = false }
        .task(id: urls) {
            seekPreview.configure(nil)
            guard !isLive, let seekPreviewLookup else { return }
            let source = await seekPreviewLookup()
            guard !Task.isCancelled else { return }
            seekPreview.configure(source)
        }
        .sheet(isPresented: $showingSubtitleSettings, onDismiss: { showControls() }) {
            MobileSubtitleSettingsSheet(controller: controller)
        }
        .onAppear {
            controller.isLive = isLive
            controller.start(urls: urls, initialPosition: isLive ? nil : initialPosition)
        }
        .onDisappear {
            seekPreview.cancel()
            controller.finishScrubbing(resume: false)
            reportProgress(force: true)
            controller.shutdown()
            hideControlsTask?.cancel()
        }
        .onChange(of: controller.progress) { _, _ in reportProgress() }
        // A title played to its end is saved as watched and the player closes.
        .onChange(of: controller.finished) { _, finished in
            guard finished else { return }
            reportProgress(force: true)
            onReachedEnd?()
            exit()
        }
        // Backgrounding is no longer a stop. MobileBackgroundPolicy decides
        // whether this transition touches playback at all.
        .onChange(of: scenePhase) { _, phase in
            controller.handleScenePhase(active: phase == .active)
        }
        .onChange(of: controller.isPlaying) { _, playing in
            if playing { scheduleAutoHide() } else { hideControlsTask?.cancel(); controlsVisible = true }
        }
    }

    /// Keep the existing manual offer, with a credits cue when available and
    /// the original final-thirty-seconds fallback otherwise.
    private var showsNextEpisode: Bool {
        guard nextEpisode != nil, !isLive, !nextEpisodeDeclined, !controlsVisible,
              !controller.loading, !controller.pictureInPictureActive, !isScrubbing, !controller.isScrubbing,
              controller.error == nil, let progress = controller.progress,
              progress.duration > 90 else { return false }
        return (segments ?? MobilePlaybackSegments()).offersNext(at: progress.position, duration: progress.duration,
                                                               creditsEnabled: creditsEnabled)
    }

    private var offersOnlineSubtitles: Bool {
        !isLive && !controller.loading && subtitleIdentityLookup != nil && MobileOpenSubtitles.configured
    }

    private var skipAction: (title: String, destination: Double)? {
        guard !isLive, segmentsLookup != nil, !isScrubbing, !controller.isScrubbing,
              !controller.loading, controller.error == nil, !showsNextEpisode,
              !controller.pictureInPictureActive, let progress = controller.progress else { return nil }
        if recapEnabled, let destination = segments?.recap?.destination(at: progress.position, duration: progress.duration) {
            return ("Skip Recap", destination)
        }
        if introEnabled, let destination = segments?.intro?.destination(at: progress.position, duration: progress.duration) {
            return ("Skip Intro", destination)
        }
        return nil
    }

    private var skipSegmentButton: some View {
        Button {
            guard let action = skipAction else { return }
            controller.seek(to: action.destination)
            showControls()
        } label: {
            Label(skipAction?.title ?? "Skip Intro", systemImage: "forward.end.fill")
                .font(.inter(.subheadline, .bold))
                .padding(.horizontal, 18).frame(minHeight: 48)
                .background(LineupPanelStyle.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(LineupStyle.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private var showsPostCreditsNotice: Bool {
        guard postCreditsEnabled, !isLive, !isScrubbing, !controller.isScrubbing,
              !controller.loading, controller.error == nil, !controller.pictureInPictureActive,
              let progress = controller.progress else { return false }
        return segments?.hasPostCreditsAhead(at: progress.position, duration: progress.duration) == true
    }

    private var postCreditsNotice: some View {
        Label("Post-credit scene ahead", systemImage: "film.stack")
            .font(.inter(.subheadline, .semibold)).padding(.horizontal, 14).padding(.vertical, 12)
            .background(LineupPanelStyle.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LineupStyle.line, lineWidth: 1))
            .accessibilityAddTraits(.updatesFrequently)
            .allowsHitTesting(false)
    }

    private func playNext(_ offer: MobileNextEpisodeOffer) {
        reportProgress(force: true)
        offer.play()
        exit()
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
        guard !isLive, !controller.isScrubbing, let progress = controller.progress, progress.duration > 0 else { return }
        guard force || abs(progress.position - lastReportedPosition) >= 5 else { return }
        lastReportedPosition = progress.position
        onProgress?(progress.position, progress.duration)
    }

    private func scheduleAutoHide() {
        hideControlsTask?.cancel()
        guard controller.isPlaying, !isScrubbing else { return }
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
            .lineupGlassControl(Capsule())
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

    private func qualityBadge(_ text: String) -> some View {
        Text(text).font(.inter(.caption2, .semibold)).lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .lineupLiquidGlass(Capsule())
    }

    /// The close button leaves the same way a swipe does: the picture is
    /// stilled first, so it travels with the frame instead of trailing it.
    private func exit() {
        controller.finishScrubbing(resume: false)
        controller.freezePictureForExit()
        dismiss()
    }

    /// A round glass button that gives under a finger, as the system's own
    /// player controls do. Play and pause, the large one, sits a shade
    /// brighter than the rest.
    private func control(_ symbol: String, label: String, size: CGFloat = 44,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size >= 60 ? 26 : 18, weight: .bold, design: .rounded))
                .frame(width: size, height: size)
                .contentShape(Circle())
                .lineupGlassControl(Circle(), prominent: size >= 60)
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
}

/// The episode after the one playing, offered as it ends.
struct MobileNextEpisodeOffer {
    let code: String?
    let title: String
    let play: () -> Void
}

/// Next Episode: a small panel in the bottom-right corner with the episode's
/// number and name and Play Now in the accent; the cross sends it away.
private struct MobileNextEpisodeCard: View {
    let offer: MobileNextEpisodeOffer
    let play: () -> Void
    let decline: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                LineupIconTile(symbol: "forward.end.fill", size: 24)
                Text("NEXT EPISODE")
                    .font(.inter(12, .heavy)).tracking(0.4)
                    .foregroundStyle(LineupPanelStyle.caption)
                Spacer(minLength: 8)
                Button(action: decline) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(LineupPanelStyle.quiet)
                        .frame(width: 28, height: 28)
                        .background(LineupPanelStyle.well, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Not now")
            }
            VStack(alignment: .leading, spacing: 2) {
                if let code = offer.code {
                    Text(code).font(.inter(13, .semibold)).foregroundStyle(LineupPanelStyle.quiet)
                }
                Text(offer.title).font(.inter(16, .bold)).foregroundStyle(LineupStyle.text)
                    .lineLimit(2)
            }
            Button(action: play) {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill").font(.system(size: 13, weight: .bold, design: .rounded))
                    Text("Play Now").font(.inter(15, .bold))
                }
                .foregroundStyle(LineupStyle.onHighlight)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(LineupStyle.highlight, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 250)
        .background(LineupPanelStyle.fill, in: shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Next episode, \(offer.code.map { $0 + ", " } ?? "")\(offer.title)")
    }
}
