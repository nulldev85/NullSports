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
    var nativeSiloPlayback: SiloPlaybackSession? = nil
    var providerName: String? = nil
    var onPlaybackStarted: (() -> Void)? = nil
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
    /// An episode's show, whose sound and subtitles are kept from one
    /// episode to the next (`MobileTrackMemory.showKey`).
    var trackMemoryShow: String? = nil
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
    var onTrackingSample: ((LibraryPlaybackSample) -> Void)? = nil
    /// Lineup chooses the episode; verified credits can show the offer earlier.
    var nextEpisode: MobileNextEpisodeOffer? = nil
    /// Told when the title plays to its end, before the player closes.
    var onReachedEnd: (() -> Void)? = nil
    /// Sent away for this episode: it does not come back.
    @State private var nextEpisodeDeclined = false
    @State private var isScrubbing = false
    @State private var lastReportedPosition: TimeInterval = 0
    @State private var showingSubtitles = false
    @State private var showingAudio = false
    @State private var showingOnlineSubtitles = false
    @State private var showingSubtitleSettings = false
    @State private var onlineSubtitleSession = UUID()
    /// The synopsis, opened from the toolbar's Info button.
    @State private var showingInfo = false

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
                        if let nativeSiloPlayback { nativeSiloPlayback.retry(); return }
                        // A title picks up where it was when it stopped, not
                        // where it was when the player opened.
                        controller.start(urls: nativeSiloPlayback?.asset.map { [$0.url] } ?? urls,
                            initialPosition: nativeSiloPlayback?.asset?.lease.playerStart ?? (isLive ? nil
                            : (lastReportedPosition > 0 ? lastReportedPosition : initialPosition)))
                    }
                        .lineupProminentButton()
                }
                .padding(24)
                .lineupPlayerPanelGlass(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(32)
            } else if controller.loading {
                ProgressView(controller.loadingMessage).padding(24)
                    .lineupPlayerPanelGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            if let notice = controller.failoverNotice {
                VStack {
                    Spacer()
                    PlaybackEngineText(notice, style: .subheadline)
                        .font(.inter(.subheadline, .semibold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .lineupPlayerPanelGlass(Capsule())
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
                // A shade at the top and the foot, so white controls read on
                // any picture without a panel behind them.
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 170)
                    Spacer(minLength: 0)
                    LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 240)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .transition(.opacity)
                VStack(alignment: .leading, spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    bottomBar
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .transition(.opacity)
                // A ZStack-centered sibling, so it lands dead-center on screen
                // -- the same spot every other player in the app puts its
                // play/pause control.
                if !controller.loading && controller.error == nil {
                    LineupGlassGroup(spacing: 28) {
                        HStack(spacing: 28) {
                            if showsTransport {
                                control("gobackward.15", label: "Back 15 seconds", size: 56) {
                                    showControls()
                                    controller.skip(by: -15)
                                }
                            }
                            control(controller.isPlaying ? "pause.fill" : "play.fill",
                                    label: controller.isPlaying ? "Pause" : "Play", size: 76) { controller.toggle() }
                            if showsTransport {
                                control("goforward.15", label: "Forward 15 seconds", size: 56) {
                                    showControls()
                                    controller.skip(by: 15)
                                }
                            }
                        }
                    }
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
        .lineupChoices("Audio", symbol: "waveform", isPresented: $showingAudio, message: trackMemoryMessage) {
            controller.audioTracks.map { track in
                MobileMenuItem(track.title, id: track.id, isSelected: track.id == controller.selectedAudioID) {
                    controller.selectAudioTrack(track)
                    showControls()
                }
            }
        } onCancel: { showControls() }
        .lineupChoices("Subtitles", symbol: "captions.bubble", isPresented: $showingSubtitles,
                       message: trackMemoryMessage) {
            var items = controller.subtitleTracks.map { track in
                MobileMenuItem(track.title, id: "\(track.id)",
                               isSelected: track.id == controller.selectedSubtitleID) {
                    controller.selectSubtitle(track)
                    showControls()
                }
            }
            if offersOnlineSubtitles {
                let title = controller.canAttachOnlineSubtitles ? "Find Subtitles Online"
                    : "Use AetherEngine, VLC, or MPVKit for Online Subtitles"
                items.append(MobileMenuItem(title,
                    symbol: "magnifyingglass", id: "online-subtitles",
                    isEnabled: controller.canAttachOnlineSubtitles,
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
        .lineupSheet(isPresented: $showingOnlineSubtitles, onDismiss: { showControls() }) {
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
        .lineupSheet(isPresented: $showingSubtitleSettings, onDismiss: { showControls() }) {
            MobileSubtitleSettingsSheet(controller: controller)
        }
        .onAppear {
            controller.libraryTrackingEvent = onTrackingSample
            controller.isLive = isLive
            controller.configureSiloPlayback(nativeSiloPlayback)
            controller.remembersTracks(forShow: isLive ? nil : trackMemoryShow)
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
            if playing { onPlaybackStarted?(); scheduleAutoHide() }
            else { hideControlsTask?.cancel(); controlsVisible = true }
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

    /// Said where a choice will outlast the episode.
    private var trackMemoryMessage: String? {
        controller.remembersShowTracks ? "Kept for every episode of this show." : nil
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
                .lineupPlayerControlGlass(Capsule())
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
            .lineupPlayerPanelGlass(Capsule())
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
            .lineupPlayerControlGlass(Capsule())
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

    // MARK: Chrome

    /// Close on the left; on the right, what a viewer reaches for least
    /// often -- the picture-in-picture button and, for a channel, its live
    /// state. Under them, what is playing and how.
    private var topBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                control("xmark", label: "Close player") { exit() }
                Spacer(minLength: 8)
                LineupGlassGroup(spacing: 10) {
                    HStack(spacing: 10) {
                        if isLive, controller.error == nil, !controller.loading { statusBadge }
                        if controller.canOfferPictureInPicture {
                            control("pip.enter", label: "Picture in Picture") {
                                showControls()
                                controller.togglePictureInPicture()
                            }
                        }
                    }
                }
            }
            if controller.error == nil && !controller.loading {
                PlaybackBadgeFlow {
                    MobilePlaybackEngineBadge(engine: controller.engine)
                    if let detail = badgeDetail { qualityBadge(detail).fixedSize() }
                    ForEach(controller.mediaInfo.badges, id: \.self) { PlaybackFormatBadge(text: $0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let providerName {
                Label("Provider: \(providerName)", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.inter(.caption2, .semibold)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(LineupStyle.mediaText.opacity(0.86))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .lineupPlayerPanelGlass(Capsule())
                    .accessibilityLabel("IPTV provider: \(providerName)")
                    .accessibilityIdentifier("lineup.playback.provider").allowsHitTesting(false)
            }
        }
    }

    /// The title on the left with nothing behind it, the toolbar on the
    /// right, and the scrubber across the foot.
    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            if skipAction != nil {
                HStack { Spacer(); skipSegmentButton }
            } else if showsPostCreditsNotice {
                HStack { Spacer(); postCreditsNotice }
            }
            if showingInfo, let overview = synopsis?.overview, !overview.isEmpty {
                infoPanel(overview)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            HStack(alignment: .bottom, spacing: 12) {
                titleBlock
                Spacer(minLength: 8)
                toolbar
            }
            if showsTransport, let progress = controller.progress {
                MobileLibrarySeekBar(controller: controller, progress: progress, preview: seekPreview,
                                     inline: true) { editing in
                    isScrubbing = editing
                    if editing { hideControlsTask?.cancel() } else { scheduleAutoHide() }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showingInfo)
    }

    /// What is playing, set straight on the picture: its name, and the line
    /// of facts under it.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(synopsis?.heading.flatMap { $0.isEmpty ? nil : $0 } ?? name)
                .font(.inter(.headline, .bold))
                .lineLimit(2)
            if let detail = synopsis?.detail, !detail.isEmpty {
                Text(detail)
                    .font(.inter(.caption, .semibold))
                    .foregroundStyle(LineupStyle.mediaText.opacity(0.78))
                    .lineLimit(1)
            }
        }
        .shadow(color: .black.opacity(0.6), radius: 8, y: 1)
        .frame(maxWidth: 460, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var hasOverview: Bool { !(synopsis?.overview ?? "").isEmpty }

    private var offersSubtitles: Bool {
        !isLive && (controller.subtitleTracks.count > 1 || offersOnlineSubtitles || subtitleIdentityLookup != nil)
    }

    private var offersAudio: Bool { !isLive && controller.audioTracks.count > 1 }

    private var offersNext: Bool {
        nextEpisode != nil && !isLive && controller.error == nil && !controller.loading
    }

    /// One sheet of glass holding everything about what is playing rather
    /// than the playing of it: its synopsis, its subtitles, its sound and
    /// the episode after it.
    @ViewBuilder
    private var toolbar: some View {
        if hasOverview || offersSubtitles || offersAudio || offersNext {
            HStack(spacing: 2) {
                if hasOverview {
                    toolButton(showingInfo ? "info.circle.fill" : "info.circle", label: "Info") {
                        showingInfo.toggle()
                        showControls()
                    }
                }
                if offersSubtitles {
                    toolButton(controller.selectedSubtitleID == PlaybackSubtitleTrack.off.id
                               ? "captions.bubble" : "captions.bubble.fill",
                               label: "Subtitles, \(controller.selectedSubtitleTitle)") {
                        showControls()
                        showingSubtitles = true
                    }
                }
                if offersAudio {
                    toolButton("waveform", label: "Audio, \(controller.selectedAudioTitle)") {
                        showControls()
                        showingAudio = true
                    }
                }
                if offersNext, let offer = nextEpisode {
                    toolButton("forward.end.fill", label: "Next episode") { playNext(offer) }
                }
            }
            .padding(.horizontal, 6)
            .lineupPlayerControlGlass(Capsule())
        }
    }

    private func toolButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .frame(width: 44, height: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func infoPanel(_ overview: String) -> some View {
        Text(overview)
            .font(.inter(.subheadline))
            .foregroundStyle(LineupStyle.mediaText.opacity(0.9))
            .lineLimit(verticalSizeClass == .compact ? 3 : 6)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: 520, alignment: .leading)
            .lineupPlayerPanelGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func qualityBadge(_ text: String) -> some View {
        Text(text).font(.inter(.caption2, .semibold)).lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .lineupPlayerPanelGlass(Capsule())
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
            Image(systemName: symbol).font(.system(size: size >= 70 ? 30 : (size >= 50 ? 22 : 18), weight: .bold, design: .rounded))
                .frame(width: size, height: size)
                .contentShape(Circle())
                .lineupPlayerControlGlass(Circle(), prominent: size >= 70)
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
        .lineupPlayerPanelGlass(shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Next episode, \(offer.code.map { $0 + ", " } ?? "")\(offer.title)")
    }
}
