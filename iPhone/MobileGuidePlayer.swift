import SwiftUI

/// Both compact and expanded layouts keep this same surface and controller.
/// Resizing must not open a second provider connection or restart the stream —
/// and neither may entering Picture in Picture, which rides on the very same
/// `AVPlayerLayer` this surface already owns.
///
/// Changing channel keeps them too. The screen that owns the player starts
/// the next channel on this same controller, so the picture is swapped in
/// place: no new surface, no new layout, and full screen stays full screen.
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
    /// Nil hides the control: on its side the phone itself does the job.
    let onExpand: (() -> Void)?
    let onRetry: () -> Void
    /// Live supplies this to reopen the channel picker for the game on screen.
    /// The Guide leaves it nil, and the control does not appear there.
    var onChooseChannel: (() -> Void)? = nil
    /// Steps along the owning screen's lineup: +1 for the next channel, down
    /// the list, and -1 for the one before. Nil where there is no lineup to
    /// step through, which takes the channel buttons and the sideways swipe
    /// with it. Both work only while the picture fills the screen.
    var onStepChannel: ((Int) -> Void)? = nil
    /// The channel Last Channel goes back to, by name, and the way back to
    /// it. Both or neither.
    var lastChannelName: String? = nil
    var onLastChannel: (() -> Void)? = nil
    /// The channel just tuned to, named over the picture for a moment. The
    /// owning screen sets it and clears it.
    var channelBanner: MobileChannelBannerInfo? = nil
    /// The game on screen, which an alert about it would be no news of.
    var watchingGameID: String? = nil
    /// Opens one of the viewer's teams' games from an alert. Nil: the owning
    /// screen has no way to, and alerts are not shown.
    var onWatchGame: ((SportsGame) -> Void)? = nil
    /// Live stats for the game on screen, opened and closed from the top
    /// bar. Nil where there are none to show.
    var onToggleStats: (() -> Void)? = nil
    var statsShown = false
    @State private var controlsVisible = true
    @State private var editingTimeline = false
    @State private var timelineBounds = CGRect.zero
    @State private var measuredHeaderHeight: CGFloat = 76
    @ScaledMetric(relativeTo: .caption2) private var previewInfoHeight: CGFloat = 32
    @State private var hideControlsTask: Task<Void, Never>?
    @ObservedObject private var alerts = GameAlertCenter.shared

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
                            .lineupProminentButton()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .lineupLiquidGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.horizontal, 52)
                } else if controller.loading {
                    ProgressView(controller.loadingMessage).font(.inter(.caption))
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .lineupLiquidGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                if let notice = controller.failoverNotice {
                    VStack {
                        Spacer()
                        PlaybackEngineText(notice, style: .caption)
                            .font(.inter(.caption, .semibold))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .lineupLiquidGlass(Capsule(), fallback: Color.black.opacity(0.62))
                            .padding(.bottom, !expanded && controlsVisible ? 48 : 12)
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
                // Over a full-screen picture only: inline, there is no room
                // beside the controls, and the channel only changes full
                // screen anyway.
                if expanded && (channelBanner != nil || visibleAlert != nil) {
                    messages
                }
                if controlsVisible {
                    topBar
                    if !expanded {
                        VStack {
                            Spacer(minLength: 0)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) { playbackDetails }
                            }
                            .frame(height: previewInfoHeight)
                        }
                        .padding(10)
                    }
                    transport
                    if expanded && (onStepChannel != nil || (lastChannelName != nil && onLastChannel != nil)) {
                        channelButtons
                    }
                    if expanded && controller.catchUpSource != nil && controller.error == nil {
                        catchUpControls
                    }
                }
            }
            .foregroundStyle(LineupStyle.mediaText)
            .animation(.easeInOut(duration: 0.2), value: controlsVisible)
            .animation(.easeInOut(duration: 0.2), value: controller.failoverNotice)
            .animation(.easeInOut(duration: 0.2), value: controller.catchUpSource != nil)
            .animation(.easeInOut(duration: 0.25), value: channelBanner)
            .animation(.easeInOut(duration: 0.3), value: visibleAlert?.id)
            .frame(height: videoHeight).background(.black).clipped()
            // Sideways across a full-screen picture changes channel. Beside
            // the tap above it, which a drag this long cancels, and beside
            // the screen's downward pull to close, which `MobileChannelSwipe`
            // keeps clear of: each drag is one or the other or neither. Off
            // inline, where the picture is a preview over the guide.
            .coordinateSpace(name: "GuidePlayer")
            .simultaneousGesture(channelSwipe, including: canSwipe ? .all : .subviews)
            if !expanded && controller.catchUpSource != nil && controller.error == nil {
                MobileCatchUpBar(controller: controller, compact: true) {
                    showControls()
                    controller.startOver()
                }
                .frame(height: MobilePlayerLayout.inlineTimelineHeight - 20)
                .padding(10).background(LineupStyle.background)
            }
            if !expanded && showsMetadata {
                let replay = controller.catchUp
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(LineupStyle.lightPurple.opacity(0.7))
                        .frame(width: 3, height: 72)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(replay == nil ? "NOW SHOWING" : "REPLAY")
                                .font(.inter(9, .bold))
                                .tracking(1.5)
                                .foregroundStyle(LineupStyle.lightPurple.opacity(0.65))
                            if replay == nil && program?.isNew == true {
                                Text("NEW")
                                    .font(.inter(9, .bold))
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(LineupStyle.raised, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            }
                            Spacer(minLength: 4)
                            if let replay {
                                timeRange(replay.programmeStart, replay.programmeEnd)
                            } else if let program {
                                timeRange(program.start, program.end)
                            }
                        }
                        // A recording names the programme it is playing, which
                        // is not the one on now.
                        Text(replay?.title ?? program?.title ?? "Live channel · No guide information")
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
        // A programme from the past played to its end closes the player, as
        // the end of a film does. Nothing else this player shows can finish.
        .onChange(of: controller.finished) { _, finished in
            if finished { onClose() }
        }
        .onDisappear { hideControlsTask?.cancel() }
    }

    // MARK: Controls

    private var topBar: some View {
        VStack {
            LineupGlassGroup {
            MobilePlayerHeader {
            HStack(spacing: 8) {
                control("xmark", label: "Close player", action: onClose)
                Spacer(minLength: 8)
                if let onToggleStats {
                    control(statsShown ? "chart.bar.fill" : "chart.bar", label: statsShown ? "Hide stats" : "Show stats") {
                        showControls()
                        onToggleStats()
                    }
                }
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
                if let onExpand {
                    control(expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                            label: expanded ? "Return to guide" : "Expand player") {
                        showControls()
                        onExpand()
                    }
                }
            }
            } details: {
                if expanded { playbackDetails }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measuredHeaderHeight = $0 }
            }
            Spacer()
        }
        .padding(.horizontal, expanded ? 24 : 10)
        .padding(.vertical, expanded ? 20 : 10)
        .padding(.leading, expanded ? screenInsets.leading : 0)
        .padding(.trailing, expanded ? screenInsets.trailing : 0)
        .padding(.top, expanded ? screenInsets.top : 0)
        .transition(.opacity)
    }

    @ViewBuilder
    private var playbackDetails: some View {
        if controller.error == nil && !controller.loading {
            MobilePlaybackEngineBadge(engine: controller.engine)
            statusBadge.fixedSize()
            if controller.catchUp == nil, let quality = controller.streamQualityLabel {
                qualityBadge(quality).fixedSize()
            }
            ForEach(controller.mediaInfo.badges, id: \.self) { PlaybackFormatBadge(text: $0) }
        }
    }

    /// A ZStack-centered sibling of the top bar, not nested in it, so it lands
    /// dead-center on screen, matching every other player. On a channel the
    /// provider records, ten seconds back and on sit either side of play.
    @ViewBuilder
    private var transport: some View {
        if !controller.loading && controller.error == nil {
            LineupGlassGroup {
                HStack(spacing: MobilePlayerLayout.channelTransportSpacing(expanded: expanded)) {
                    if controller.catchUpSource != nil {
                        control("gobackward.10", label: "Back 10 seconds") {
                            showControls()
                            controller.skip(by: -CatchUpPolicy.skip)
                        }
                    }
                    control(controller.isPlaying ? "pause.fill" : "play.fill",
                            label: controller.isPlaying ? "Pause" : "Play", size: expanded ? 48 : 42) {
                        controller.toggle()
                    }
                    if controller.catchUpSource != nil {
                        // Live there is nowhere further on to go; only a
                        // recording has.
                        control("goforward.10", label: "Forward 10 seconds") {
                            showControls()
                            controller.skip(by: CatchUpPolicy.skip)
                        }
                        .disabled(controller.catchUp == nil)
                        .opacity(controller.catchUp == nil ? 0.4 : 1)
                    }
                }
            }
            .transition(.opacity)
        }
    }

    /// The channel buttons a remote has, at the trailing edge and halfway
    /// down, clear of the centre cluster on any iPhone: up the list, down
    /// it, and back to the last channel.
    private var channelButtons: some View {
        VStack(spacing: 10) {
            if let onStepChannel {
                control("chevron.up", label: "Previous channel") {
                    showControls()
                    onStepChannel(-1)
                }
                control("chevron.down", label: "Next channel") {
                    showControls()
                    onStepChannel(1)
                }
            }
            if let lastChannelName, let onLastChannel {
                control("arrow.uturn.backward", label: "Last channel, \(lastChannelName)") {
                    showControls()
                    onLastChannel()
                }
                .padding(.top, onStepChannel == nil ? 0 : 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .padding(.trailing, 24 + screenInsets.trailing)
        .transition(.opacity)
    }

    /// The recorded channel's timeline and Start Over, along the bottom.
    private var catchUpControls: some View {
        MobileCatchUpBar(controller: controller, compact: !expanded, onEditingChanged: { editing in
            editingTimeline = editing
            controlsVisible = true
            if editing { hideControlsTask?.cancel() }
            else { scheduleAutoHide() }
        }) {
            showControls()
            controller.startOver()
        }
        .frame(maxWidth: expanded ? CGFloat(520) : CGFloat.infinity)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("GuidePlayer")) }) { timelineBounds = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.horizontal, expanded ? 24 : 10)
        .padding(.bottom, expanded ? 20 : 10)
        .padding(.leading, expanded ? screenInsets.leading : 0)
        .padding(.trailing, expanded ? screenInsets.trailing : 0)
        .padding(.bottom, expanded ? screenInsets.bottom : 0)
        .transition(.opacity)
    }

    // MARK: Messages

    /// An alert about a game other than the one on screen, while the picture
    /// fills the screen and the screen holding it can open a game.
    private var visibleAlert: GameAlert? {
        guard expanded, onWatchGame != nil, let alert = alerts.current,
              alert.game.id != watchingGameID else { return nil }
        return alert
    }

    /// The channel just tuned to, and an alert, stacked under the top bar.
    /// Always at the same height, whether or not the bar is showing, so
    /// nothing jumps as the controls come and go.
    private var messages: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let channelBanner {
                MobileChannelBanner(info: channelBanner)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if let alert = visibleAlert, let onWatchGame {
                MobileGameAlertBanner(alert: alert,
                                      onWatch: { onWatchGame(alert.game) },
                                      onDismiss: { alerts.dismiss() })
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 24)
        .padding(.leading, screenInsets.leading)
        .padding(.trailing, screenInsets.trailing)
        // Below the top bar: its own padding, then a control's height.
        .padding(.top, screenInsets.top + 20 + measuredHeaderHeight + 10)
    }

    // MARK: Gestures

    private var canSwipe: Bool { expanded && onStepChannel != nil }

    private var channelSwipe: some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .named("GuidePlayer"))
            .onEnded { value in
                guard !timelineBounds.contains(value.startLocation),
                      !editingTimeline, !controller.isScrubbing, let onStepChannel,
                      let swipe = MobileChannelSwipe.direction(width: Double(value.translation.width),
                                                               height: Double(value.translation.height))
                else { return }
                onStepChannel(swipe.step)
            }
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
        guard controller.isPlaying, !editingTimeline else { return }
        hideControlsTask = Task {
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard !Task.isCancelled, !editingTimeline else { return }
            controlsVisible = false
        }
    }

    /// A round glass button that gives under a finger, as the system's own
    /// player controls do. Play and pause, the large one, sits a shade
    /// brighter than the rest.
    private func control(_ symbol: String, label: String, size: CGFloat = 36,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size >= 42 ? 17 : 14, weight: .semibold, design: .rounded))
                .frame(width: size, height: size)
                .contentShape(Circle())
                .lineupGlassControl(Circle(), fallback: Color.black.opacity(0.48), prominent: size >= 42)
        }.buttonStyle(.plain).accessibilityLabel(label)
    }

    private func timeRange(_ start: Date, _ end: Date) -> some View {
        Text("\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))")
            .font(.inter(.caption2))
            .foregroundStyle(LineupStyle.lightPurple.opacity(0.65))
            .lineLimit(1)
    }

    // Doubles as a jump-back-to-live action: reopens the stream fresh, so a
    // viewer who paused for a few seconds (or hit a stall) can snap back to
    // the live edge instead of waiting or guessing why nothing's happening.
    // From a recording it is the way back to the channel live.
    private var statusBadge: some View {
        Button { controller.goLive() } label: {
            HStack(spacing: 6) {
                if controller.catchUp == nil && controller.isPlaying { MobileLiveDot() }
                Text(badgeText).font(.inter(.caption2, .bold))
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .lineupGlassControl(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badgeAccessibilityLabel)
    }

    /// LIVE or PAUSED on the channel; REPLAY on its recording, with how far
    /// behind -- or, for a programme from the past, which day -- full screen.
    /// Inline, the timeline under the picture says how far behind instead.
    private var badgeText: String {
        guard let catchUp = controller.catchUp else { return controller.isPlaying ? "LIVE" : "PAUSED" }
        guard expanded else { return "REPLAY" }
        // A programme from the past is a replay of a day, not a delay.
        if controller.recordingEndsWithProgramme {
            return "REPLAY · " + catchUp.programmeStart
                .formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased()
        }
        let behind = MobileCatchUpLabel.minutesBehind(position: controller.catchUpPosition ?? Date(), now: Date())
        return behind < 1 ? "REPLAY" : "REPLAY · \(MobileCatchUpLabel.duration(minutes: behind)) BEHIND"
    }

    private var badgeAccessibilityLabel: String {
        guard let catchUp = controller.catchUp else {
            return controller.isPlaying ? "Live. Tap to jump back to live." : "Paused. Tap to jump back to live."
        }
        if controller.recordingEndsWithProgramme {
            return "Replay from \(catchUp.programmeStart.formatted(date: .complete, time: .omitted)). Tap to watch the channel live."
        }
        let behind = MobileCatchUpLabel.minutesBehind(position: controller.catchUpPosition ?? Date(), now: Date())
        return behind < 1 ? "Replay. Tap to go back to live."
            : "Replay, \(behind) minute\(behind == 1 ? "" : "s") behind live. Tap to go back to live."
    }

    private func qualityBadge(_ text: String) -> some View {
        Text(text).font(.inter(.caption2, .semibold)).lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 7)
            .lineupLiquidGlass(Capsule())
    }
}
