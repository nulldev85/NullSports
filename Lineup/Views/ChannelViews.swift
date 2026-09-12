import SwiftUI
import UIKit
import VLCKitSPM

struct LiveView: View {
    @EnvironmentObject private var library: SportsLibrary
    let isActive: Bool
    @State private var selectedLeague: SportsLeague?
    @State private var selectedStream: XtreamStream?
    @State private var multiviewPrimary: XtreamStream?
    @State private var multiviewSession: MultiviewSession?
    @State private var focusedGame: SportsGame?
    @State private var previewStream: XtreamStream?
    @State private var previewGameID: String?
    @State private var previewWasManuallySelected = false
    @State private var playbackTransitionID: UUID?
    @State private var manualChannelGame: SportsGame?
    @State private var showsChannelSyncMessage = false
    @State private var manualSelectionStartsMultiview = false

    private var dayStart: Date { Calendar.current.startOfDay(for: Date()) }
    private var horizon: Date { Calendar.current.date(byAdding: .day, value: 2, to: dayStart) ?? dayStart }
    private var events: [SportsGame] { library.games(for: selectedLeague).filter { $0.isLive || ($0.start >= dayStart && $0.start < horizon) } }
    private var tickerEvents: [SportsGame] { library.scoreTickerGames() }
    private var liveEvents: [SportsGame] { events.filter { $0.isLive } }
    private var upcomingEvents: [SportsGame] { events.filter { $0.isUpcoming } }

    var body: some View {
        GeometryReader { container in
            VStack(spacing: 0) {
                NavigationStack {
                    Group {
                        if events.isEmpty {
                            LiveEmptySlateDashboard(
                                selectedLeague: $selectedLeague,
                                focusedGame: $focusedGame,
                                isLoading: library.isLoading || library.isScheduleLoading,
                                isAvailable: library.scheduleAvailable(for: selectedLeague),
                                errorMessage: library.scheduleErrorMessage
                            )
                        } else {
                            LiveSlateDashboard(
                                events: events,
                                selectedLeague: $selectedLeague,
                                focusedGame: $focusedGame,
                                previewStream: previewStream,
                                previewURLs: previewStream.map { library.playbackURLs(for: $0) } ?? [],
                                multiviewPrimaryID: multiviewPrimary?.id,
                                multiviewTitle: multiviewPrimary?.name,
                                onPlay: select,
                                onStartMultiview: startMultiview,
                                onCancelMultiview: { multiviewPrimary = nil },
                                onStopPreview: stopPreview
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                // The ticker belongs to the full-height Live layout, outside
                // NavigationStack's independently inset content area.
                LiveTicker(events: tickerEvents)
                    .frame(height: 38)
            }
            .frame(width: container.size.width, height: container.size.height, alignment: .top)
            .background(
                ZStack {
                    LineupStyle.background
                    RadialGradient(colors: [LineupStyle.lightPurple.opacity(0.055), .clear], center: .topTrailing, startRadius: 20, endRadius: 720)
                }.ignoresSafeArea()
            )
            .fullScreenCover(item: $selectedStream) { stream in
                PlayerView(
                    urls: library.playbackURLs(for: stream),
                    title: stream.name,
                    program: library.guidePrograms(for: stream).normalizedEPG().first { $0.isLive }
                )
            }
            .sheet(item: $manualChannelGame) { game in
                ManualGameChannelPicker(game: game) { stream in
                    manualChannelGame = nil
                    if manualSelectionStartsMultiview {
                        stopPreview()
                        multiviewPrimary = stream
                    } else {
                        play(game, on: stream, manuallySelected: true)
                    }
                }
            }
            .alert("Channels are still syncing", isPresented: $showsChannelSyncMessage) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Please wait for channel syncing to finish, then select the game again.").foregroundColor(LineupStyle.lightPurple)
            }
            .fullScreenCover(item: $multiviewSession) { session in
                MultiviewView(
                    primary: session.primary,
                    secondary: session.secondary,
                    primaryURLs: library.playbackURLs(for: session.primary),
                    secondaryURLs: library.playbackURLs(for: session.secondary)
                )
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { return }
                    // Live scores need refreshing every 30s; tomorrow's slate does not.
                    library.refreshSchedule(showsLoading: false, includeTomorrow: false)
                }
            }
            .onChange(of: isActive) { _, active in
                if !active { stopPreview() }
            }
        }
        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
        .background(LineupStyle.background.ignoresSafeArea())
    }

    private func select(_ game: SportsGame) {
        if previewGameID == game.id, let previewStream,
           previewWasManuallySelected || library.verifiedStream(for: game)?.id == previewStream.id {
            play(game, on: previewStream)
            return
        }
        stopPreview()
        guard let stream = library.verifiedStream(for: game) else {
            handleUnmatchedSelection(game, startsMultiview: false)
            return
        }
        play(game, on: stream)
    }

    private func play(_ game: SportsGame, on stream: XtreamStream, manuallySelected: Bool = false) {
        guard let primary = multiviewPrimary else {
            if previewGameID == game.id {
                let transitionID = UUID()
                playbackTransitionID = transitionID
                previewStream = nil
                previewGameID = nil
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(180))
                    guard isActive, playbackTransitionID == transitionID else { return }
                    playbackTransitionID = nil
                    selectedStream = stream
                }
            } else {
                playbackTransitionID = nil
                previewStream = stream
                previewGameID = game.id
                previewWasManuallySelected = manuallySelected
            }
            return
        }
        guard primary.id != stream.id else { return }
        multiviewPrimary = nil
        multiviewSession = MultiviewSession(primary: primary, secondary: stream)
    }

    private func startMultiview(_ game: SportsGame) {
        guard let stream = library.verifiedStream(for: game) else {
            handleUnmatchedSelection(game, startsMultiview: true)
            return
        }
        stopPreview()
        multiviewPrimary = stream
    }

    private func handleUnmatchedSelection(_ game: SportsGame, startsMultiview: Bool) {
        // Explain the initial refresh instead of opening a cached event slot.
        if library.channelsAreSyncing && !library.automaticMatchingReady {
            showsChannelSyncMessage = true
        } else {
            manualSelectionStartsMultiview = startsMultiview
            manualChannelGame = game
        }
    }

    private func stopPreview() {
        playbackTransitionID = nil
        previewStream = nil
        previewGameID = nil
        previewWasManuallySelected = false
    }
}

private struct ManualGameChannelPicker: View {
    @EnvironmentObject private var library: SportsLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    let game: SportsGame
    let onSelect: (XtreamStream) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("No verified channel").foregroundColor(LineupStyle.lightPurple).font(.inter(.title2))
                Text("\(game.awayTeam) vs. \(game.homeTeam)").foregroundColor(LineupStyle.lightPurple)
                Text("Listed network: \(game.broadcast.isEmpty ? "Unavailable" : game.broadcast). Choose a channel manually.").foregroundColor(LineupStyle.lightPurple)
                    .foregroundStyle(LineupStyle.secondary)
                TextField("Search channels", text: $query)
                    .textFieldStyle(.plain).focusEffectDisabled()
                List(library.guideStreams(categoryID: nil, favoritesOnly: false, query: query)) { stream in
                    Button(stream.name) { onSelect(stream) }
                }
                Button("Cancel") { dismiss() }
            }
            .padding(40)
            .foregroundStyle(LineupStyle.text)
            .lineupButtonStyle()
            .focusEffectDisabled()
        }
    }
}

private enum LiveBoardStyle {
    static var accent: Color { LineupStyle.lightPurple }
    static var leagueFocus: Color { LineupStyle.focused }
    static var canvas: Color { LineupStyle.background }
    static var panel: Color { LineupStyle.surface }
    static var muted: Color { LineupStyle.lightPurple }
}

private struct LiveBoardRail: View {
    @Binding var selectedLeague: SportsLeague?
    let onChoose: () -> Void
    let onEnterGames: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("EXPLORE").foregroundColor(LineupStyle.lightPurple).font(.inter(12, .bold)).tracking(3)
                .foregroundStyle(LiveBoardStyle.muted).padding(.bottom, 8)
            LiveBoardLeagueButton(title: "All sports", league: nil, selected: selectedLeague == nil,
                onEnterGames: onEnterGames) { selectedLeague = nil; onChoose() }
            ForEach(SportsLeague.allCases) { league in
                LiveBoardLeagueButton(title: league == .ncaaf ? "College" : league.shortName,
                    league: league, selected: selectedLeague == league, onEnterGames: onEnterGames) {
                    selectedLeague = league
                    onChoose()
                }
            }
            Spacer(minLength: 12)
        }
        .frame(width: 156, alignment: .leading)
        .padding(.trailing, 24)
        .overlay(alignment: .trailing) { Rectangle().fill(LineupStyle.lightPurple.opacity(0.08)).frame(width: 1) }
        .focusSection()
    }
}

private struct LiveBoardLeagueButton: View {
    @FocusState private var focused: Bool
    let title: String
    let league: SportsLeague?
    let selected: Bool
    let onEnterGames: () -> Void
    let action: () -> Void

    var body: some View {
        Group {
            HStack(spacing: 12) {
                if let league {
                    LeagueLogo(league: league, size: 26)
                } else {
                    Image(systemName: "square.grid.2x2.fill").frame(width: 26)
                }
                Text(title).foregroundColor(LineupStyle.lightPurple).font(.inter(17, .semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(LineupStyle.lightPurple)
            .padding(.horizontal, 12).frame(height: 49)
            .background(focused ? LiveBoardStyle.leagueFocus : (selected ? LineupStyle.lightPurple.opacity(0.07) : .clear))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .leading) {
                if selected && !focused { Capsule().fill(LiveBoardStyle.accent).frame(width: 3, height: 22) }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .focusable().focused($focused).focusEffectDisabled()
        .onTapGesture(perform: action)
        .accessibilityAddTraits(.isButton)
        .onMoveCommand { if $0 == .right { onEnterGames() } }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The date, and nothing else. Refreshing used to sit out at the right of it,
/// which is the far corner of a television from where anyone is looking.
private struct LiveBoardHeading: View {
    var body: some View {
        HStack(alignment: .center) {
            Text(Date().formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                .font(.inter(16, .medium))
                .foregroundStyle(LiveBoardStyle.muted)
            Spacer()
        }
        .foregroundStyle(LineupStyle.lightPurple)
        .frame(height: 28)
    }
}

/// Matches are unavailable while channels, guide or matching are in flight, so
/// the board says so rather than showing every game as having no channel.
private struct RefreshingStreamsLabel: View {
    /// Where it is standing. In a heading it is a footnote beside other text;
    /// alone in the middle of a dark screen it is the only thing there, and a
    /// footnote sized for a heading reads as a fault rather than an answer.
    enum Size { case inline, screen }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false
    @State private var pinging = false
    var size: Size = .inline

    private var isScreen: Bool { size == .screen }
    private var dot: CGFloat { isScreen ? 9 : 7 }
    private var type: CGFloat { isScreen ? 18 : 13 }

    var body: some View {
        HStack(spacing: isScreen ? 15 : 10) {
            mark
            // Monospaced, because the rest of the app reads a number that way
            // and this is the set reporting on itself rather than talking.
            Text("REFRESHING STREAMS")
                // The one deliberate exception to Inter: on the screen this
                // line is the app reporting on itself, and a monospaced cut is
                // what makes it read that way. Inline, where it sits beside
                // ordinary text, it matches everything else.
                .font(isScreen ? .system(size: type, weight: .bold, design: .monospaced)
                               : .inter(type, .bold))
                .tracking(isScreen ? 3.5 : 2)
        }
        .foregroundStyle(LineupStyle.lightPurple.opacity(isScreen ? 0.92 : 0.75))
        // On the screen the dot carries the motion. Dimming the words as well
        // was two things blinking out of step with each other.
        .opacity(isScreen || reduceMotion || !dimmed ? 1 : 0.32)
        .animation(reduceMotion || isScreen ? nil
                   : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dimmed)
        .onAppear { dimmed = true; pinging = true }
        .accessibilityLabel("Refreshing streams")
    }

    /// A ping rather than a blink: a ring leaves the dot and fades, which is
    /// what looking for something looks like.
    @ViewBuilder private var mark: some View {
        if isScreen {
            ZStack {
                Circle().stroke(LineupStyle.live, lineWidth: 1.5)
                    .frame(width: dot, height: dot)
                    .scaleEffect(pinging && !reduceMotion ? 3.2 : 1)
                    .opacity(pinging && !reduceMotion ? 0 : 0.85)
                    .animation(reduceMotion ? nil
                               : .easeOut(duration: 1.8).repeatForever(autoreverses: false),
                               value: pinging)
                Circle().fill(LineupStyle.live).frame(width: dot, height: dot)
                    .shadow(color: LineupStyle.live.opacity(0.6), radius: 7)
            }
            .frame(width: dot * 3.2, height: dot * 3.2)
        } else {
            Circle().fill(LineupStyle.live).frame(width: dot, height: dot)
        }
    }
}

/// A band of the theme's colour crossing the dark screen, over and over.
///
/// The app's own mark is a line travelling across a guide, and so is the line
/// down the guide itself. A set looking for its channels is the same idea in
/// motion, and it reads as equipment working rather than as a spinner bolted
/// onto a television.
private struct LiveTVSignalSweep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweeping = false

    var body: some View {
        GeometryReader { geometry in
            let band = geometry.size.width * 0.3
            LinearGradient(
                colors: [.clear, LineupStyle.live.opacity(0.05),
                         LineupStyle.live.opacity(0.34), LineupStyle.live.opacity(0.05), .clear],
                startPoint: .leading, endPoint: .trailing)
                .frame(width: band)
                .blur(radius: 10)
                .offset(x: sweeping ? geometry.size.width : -band)
                .animation(.linear(duration: 2.6).repeatForever(autoreverses: false), value: sweeping)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { if !reduceMotion { sweeping = true } }
    }
}

private struct LiveEmptySlateDashboard: View {
    @Binding var selectedLeague: SportsLeague?
    @Binding var focusedGame: SportsGame?
    let isLoading: Bool
    let isAvailable: Bool
    let errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            LiveBoardHeading()
            HStack(spacing: 30) {
                LiveBoardRail(selectedLeague: $selectedLeague, onChoose: { focusedGame = nil }, onEnterGames: {})
                VStack(alignment: .leading, spacing: 22) {
                    Image(systemName: isLoading ? "antenna.radiowaves.left.and.right" : "sportscourt")
                        .font(.inter(56, .ultraLight)).foregroundStyle(LiveBoardStyle.muted)
                    Text(isLoading ? "Setting the board." : (isAvailable ? "A moment between games." : "The schedule is unavailable.")).foregroundColor(LineupStyle.lightPurple)
                        .font(.inter(38, .bold))
                    Text(isLoading ? "Your games will appear here shortly." :
                        (isAvailable ? "Explore another sport, or come back for the next matchup." :
                            (errorMessage ?? "We’ll try again shortly. Your saved channels are still available in Guide."))).foregroundColor(LineupStyle.lightPurple)
                        .font(.inter(20)).foregroundStyle(LiveBoardStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(44)
                .background(LiveBoardStyle.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 38).padding(.bottom, 26)
        .background(LiveBoardStyle.canvas)
    }
}

private struct LiveSlateDashboard: View {
    @EnvironmentObject private var library: SportsLibrary
    @State private var gameFocusRequest: UUID?
    let events: [SportsGame]
    @Binding var selectedLeague: SportsLeague?
    @Binding var focusedGame: SportsGame?
    let previewStream: XtreamStream?
    let previewURLs: [URL]
    let multiviewPrimaryID: Int?
    let multiviewTitle: String?
    let onPlay: (SportsGame) -> Void
    let onStartMultiview: (SportsGame) -> Void
    let onCancelMultiview: () -> Void
    let onStopPreview: () -> Void

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 4) {
                LiveBoardHeading()
                HStack(alignment: .top, spacing: 28) {
                    ScrollView(.vertical) {
                        LiveBoardRail(selectedLeague: $selectedLeague, onChoose: {
                            focusedGame = nil
                            gameFocusRequest = nil
                        }, onEnterGames: { gameFocusRequest = UUID() })
                    }
                    .frame(width: 180)
                    HStack {
                        Spacer(minLength: 0)
                        ZStack {
                            Color.black
                            if let previewStream {
                                LiveSelectedPreview(stream: previewStream, urls: previewURLs)
                                    .id(previewStream.id)
                            } else {
                                LinearGradient(colors: [LineupStyle.lightPurple.opacity(0.025), .clear, .black],
                                    startPoint: .topLeading, endPoint: .bottomTrailing)
                                // Waiting is what this screen is for while it
                                // is dark, and the dark screen is the one place
                                // the viewer is already looking. Tucked into
                                // the corner of the heading it was easy to miss
                                // and easier to mistake for nothing happening.
                                if isPreparingStreams {
                                    LiveTVSignalSweep()
                                    RefreshingStreamsLabel(size: .screen)
                                }
                            }
                        }
                        .frame(width: screenHeight(in: geometry.size) * 16 / 9,
                               height: screenHeight(in: geometry.size))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(4)
                        .background(
                            LinearGradient(colors: [LineupStyle.focused, LineupStyle.surface],
                                startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(LineupStyle.lightPurple.opacity(0.08), lineWidth: 1)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if previewStream == nil && !isPreparingStreams {
                                LiveTVStandbyLight().padding(.trailing, 17).padding(.bottom, 1)
                            }
                        }
                        .lineupShadow(.resting)
                        .accessibilityLabel(previewStream == nil ? "TV screen off" : "TV preview")
                        Spacer(minLength: 0)
                    }
                }
                .frame(height: screenHeight(in: geometry.size) + 8)
                HStack(spacing: 14) {
                    Text(multiviewTitle == nil ? "THE MATCHUPS" : "CHOOSE YOUR SECOND GAME").foregroundColor(LineupStyle.lightPurple)
                        .font(.inter(12, .bold)).tracking(2.5)
                    Text("\(events.count)").foregroundColor(LineupStyle.lightPurple).font(.interDigits(12, .bold))
                        .foregroundStyle(LiveBoardStyle.muted)
                    Spacer()
                    if multiviewTitle != nil {
                        GuideHeaderButton(title: "Cancel multiview", symbol: "xmark", action: onCancelMultiview)
                    } else {
                        Text("Select to preview  ·  Hold for multiview").foregroundColor(LineupStyle.lightPurple)
                            .font(.inter(13)).foregroundStyle(LiveBoardStyle.muted)
                    }
                }
                .foregroundStyle(LineupStyle.lightPurple)
                .padding(.top, 4).padding(.bottom, 8)
                LiveGameSlate(events: events, focusedGame: $focusedGame, focusRequest: $gameFocusRequest,
                    multiviewPrimaryID: multiviewPrimaryID, columns: 4,
                    onPlay: onPlay, onStartMultiview: onStartMultiview)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, 38).padding(.bottom, 10)
        }
        .background(LiveBoardStyle.canvas)
        .onExitCommand { if previewStream != nil { onStopPreview() } }
    }

    // Matching keeps running after the schedule and library finish, and every
    // game reads as unmatched until it lands. Cover that window too, so it is
    // not mistaken for a settled answer of "no channel".
    private var isPreparingStreams: Bool {
        library.isScheduleLoading || library.isLoading || !library.automaticMatchingReady
    }

    private func screenHeight(in size: CGSize) -> CGFloat {
        // Fill the upper area while reserving room for the heading and a full
        // matchup row. Width grows with height so the screen stays 16:9.
        let availableHeight = max(0, size.height - 300)
        let availableWidth = max(0, size.width - 300)
        return min(availableHeight, availableWidth * 9 / 16)
    }
}

private struct LiveTVStandbyLight: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glowing = false

    var body: some View {
        Circle()
            .fill(LineupStyle.liveDot)
            .frame(width: 4, height: 4)
            .opacity(reduceMotion || glowing ? 0.85 : 0.3)
            .shadow(color: LineupStyle.liveDot.opacity(reduceMotion || glowing ? 0.35 : 0.1), radius: 3)
            .animation(reduceMotion ? nil : .easeInOut(duration: 2).repeatForever(autoreverses: true), value: glowing)
            .onAppear { glowing = true }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

private struct LiveBoardTeam: View {
    let name: String
    let logo: String
    let abbreviation: String
    let record: String?
    let score: String?
    var large = false

    var body: some View {
        HStack(spacing: large ? 14 : 10) {
            TeamBadge(url: logo, fallback: abbreviation, size: large ? 44 : 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).foregroundColor(LineupStyle.lightPurple).font(.inter(large ? 25 : 23, .semibold))
                    .foregroundStyle(LineupStyle.lightPurple).lineLimit(1).minimumScaleFactor(0.7)
                if let record = nonempty(record) {
                    Text(record).foregroundColor(LineupStyle.lightPurple).font(.interDigits(17, .medium)).foregroundStyle(LiveBoardStyle.muted)
                }
            }
            Spacer(minLength: 6)
            if let score, !score.isEmpty {
                Text(score).foregroundColor(LineupStyle.lightPurple).font(.interDigits(large ? 33 : 25, .bold))
                    .foregroundStyle(LineupStyle.lightPurple)
            }
        }
    }
}

private struct LiveSelectedPreview: View {
    @StateObject private var controller = VLCPlaybackController()
    let stream: XtreamStream
    let urls: [URL]

    var body: some View {
        VLCVideoSurface(player: controller.player).overlay { TVPlaybackStatus(controller: controller) }.background(Color.black)
        .onAppear { controller.start(urls: urls, muted: false) }
        .onDisappear { controller.stop() }
    }
}

private struct LiveGameSlate: View {
    let events: [SportsGame]
    @Binding var focusedGame: SportsGame?
    @Binding var focusRequest: UUID?
    @FocusState private var focusedRowID: String?
    let multiviewPrimaryID: Int?
    let columns: Int
    let onPlay: (SportsGame) -> Void
    let onStartMultiview: (SportsGame) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: columns), spacing: 18) {
                    ForEach(events) { game in
                        LiveSlateRow(game: game, rowFocus: $focusedRowID, selected: focusedGame?.id == game.id,
                            multiviewPrimaryID: multiviewPrimaryID,
                            onFocus: { focusedGame = game; focusRequest = nil },
                            onPlay: { onPlay(game) }, onStartMultiview: { onStartMultiview(game) })
                        .id(game.id)
                        .onAppear {
                            if focusRequest != nil, game.id == events.first?.id { focusedRowID = game.id }
                        }
                    }
                }
                .padding(5)
            }
            .focusSection()
            .task(id: focusRequest) {
                guard let request = focusRequest, let firstID = events.first?.id else { return }
                proxy.scrollTo(firstID, anchor: .top)
                await Task.yield()
                guard !Task.isCancelled, focusRequest == request, events.first?.id == firstID else { return }
                focusedRowID = firstID
            }
        }
    }
}

private struct LiveSlateRow: View {
    @EnvironmentObject private var library: SportsLibrary
    @EnvironmentObject private var reminders: GameReminders
    let game: SportsGame
    let rowFocus: FocusState<String?>.Binding
    private var isFocused: Bool { rowFocus.wrappedValue == game.id }
    let selected: Bool
    let multiviewPrimaryID: Int?
    let onFocus: () -> Void
    let onPlay: () -> Void
    let onStartMultiview: () -> Void
    private var stream: XtreamStream? { library.stream(for: game) }
    private var isPrimary: Bool { multiviewPrimaryID != nil && multiviewPrimaryID == stream?.id }

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    LeagueLogo(league: game.league, size: 28)
                    Text(game.league.shortName).foregroundColor(LineupStyle.lightPurple).font(.inter(17, .semibold)).tracking(1)
                        .foregroundStyle(LineupStyle.lightPurple)
                    Spacer()
                    if game.isLive {
                        PulsingLiveDot(size: 6)
                        Text(game.status.uppercased()).foregroundColor(LineupStyle.lightPurple).lineLimit(1).minimumScaleFactor(0.7)
                    } else {
                        Text(game.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())).foregroundColor(LineupStyle.lightPurple)
                            .font(.interDigits(17, .semibold))
                            .foregroundStyle(LineupStyle.lightPurple).lineLimit(1)
                    }
                }
                .font(.inter(11, .semibold)).foregroundStyle(LiveBoardStyle.muted)
                LiveBoardTeam(name: game.awayTeam, logo: game.awayLogo, abbreviation: game.awayAbbreviation,
                    record: game.awayRecord, score: game.isLive ? game.awayScore : nil)
                LiveBoardTeam(name: game.homeTeam, logo: game.homeLogo, abbreviation: game.homeAbbreviation,
                    record: game.homeRecord, score: game.isLive ? game.homeScore : nil)
                HStack {
                    Text(isPrimary ? "MULTIVIEW · FIRST GAME" : (game.broadcast.isEmpty ? "Channel selection available" : game.broadcast)).foregroundColor(LineupStyle.lightPurple)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: isFocused ? "play.fill" : "arrow.up.right")
                }
                .font(.inter(11, .semibold)).foregroundStyle(isFocused ? LiveBoardStyle.accent : LiveBoardStyle.muted)
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(isFocused ? LineupStyle.focused : LiveBoardStyle.panel,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isFocused || isPrimary ? LineupStyle.liveSelectionBorder : LineupStyle.lightPurple.opacity(selected ? 0.22 : 0.06),
                                  lineWidth: isFocused ? 2.5 : 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .focusable().focused(rowFocus, equals: game.id).focusEffectDisabled()
        .onTapGesture(perform: onPlay)
        .accessibilityAddTraits(.isButton)
        .onChange(of: isFocused) { value in if value { onFocus() } }
        .contextMenu {
            if game.isUpcoming {
                Button(reminders.reminds(game) ? "Remove Reminder" : "Remind Me",
                       systemImage: reminders.reminds(game) ? "bell.slash" : "bell") {
                    reminders.toggleGame(game)
                }
            }
            if stream != nil {
                Button("Start Multiview", systemImage: "rectangle.split.2x1", action: onStartMultiview)
                    .disabled(isPrimary)
            }
        }
        .accessibilityLabel("\(game.awayTeam) at \(game.homeTeam), \(game.isLive ? game.status : game.start.formatted(date: .abbreviated, time: .shortened))")
    }
}


private struct PulsingLiveDot: View {
    let size: CGFloat
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(LineupStyle.live)
            .frame(width: size, height: size)
            .scaleEffect(isPulsing ? 1.22 : 0.92)
            .opacity(isPulsing ? 0.58 : 1)
            .shadow(color: LineupStyle.live.opacity(isPulsing ? 0.25 : 0.72), radius: isPulsing ? 7 : 3)
            .animation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
            .accessibilityHidden(true)
    }
}

private struct LiveTicker: View {
    let events: [SportsGame]
    @State private var displayedEvents: [SportsGame] = []
    @State private var epoch = ProcessInfo.processInfo.systemUptime
    private let speed: Double = 54
    private let cardWidth: CGFloat = 620
    private let cardSpacing: CGFloat = 38
    private let loopSpacing: CGFloat = 72

    private func cycleWidth(for count: Int) -> CGFloat {
        count == 0 ? 400 + loopSpacing : CGFloat(count) * (cardWidth + cardSpacing) - cardSpacing + loopSpacing
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 24) {
            Text("SCORE").foregroundColor(LineupStyle.lightPurple).font(.inter(.caption2, .bold)).tracking(3).foregroundStyle(LineupStyle.secondary)
            Rectangle().fill(LineupStyle.line).frame(width: 1, height: 28)
            GeometryReader { viewport in
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
                    let distance = max(0, ProcessInfo.processInfo.systemUptime - epoch) * speed
                    let cycle = cycleWidth(for: displayedEvents.count)
                    let copies = max(2, Int(ceil(viewport.size.width / cycle)) + 1)
                    HStack(spacing: loopSpacing) {
                        ForEach(0..<copies, id: \.self) { _ in tickerContent }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(x: -CGFloat(distance.truncatingRemainder(dividingBy: Double(cycle))))
                    .frame(width: viewport.size.width, height: viewport.size.height, alignment: .bottomLeading)
                }
                .clipped()
            }
        }
        .padding(.horizontal, 42).padding(.bottom, 2)
        .background(Color.black.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(LineupStyle.line).frame(height: 1) }
        .transaction { $0.animation = nil }
        .allowsHitTesting(false)
        .onAppear { updateScores(events) }
        .onChange(of: events) { _, updated in updateScores(updated) }
    }

    private func updateScores(_ updated: [SportsGame]) {
        guard updated != displayedEvents else { return }
        if displayedEvents.map(\.id) != updated.map(\.id) {
            let uptime = ProcessInfo.processInfo.systemUptime
            let oldOffset = CGFloat(max(0, uptime - epoch) * speed)
                .truncatingRemainder(dividingBy: cycleWidth(for: displayedEvents.count))
            let stride = cardWidth + cardSpacing
            let oldIndex = min(Int(oldOffset / stride), max(0, displayedEvents.count - 1))
            var newOffset: CGFloat = 0
            if displayedEvents.indices.contains(oldIndex),
               let newIndex = updated.firstIndex(where: { $0.id == displayedEvents[oldIndex].id }) {
                newOffset = CGFloat(newIndex) * stride + oldOffset - CGFloat(oldIndex) * stride
            }
            epoch = uptime - Double(newOffset) / speed
        }
        // Score/status changes update in place without resetting the scroll phase.
        displayedEvents = updated
    }

    private var tickerContent: some View {
        HStack(spacing: cardSpacing) {
            if displayedEvents.isEmpty {
                Text("NO LIVE OR FINAL SCORES").foregroundColor(LineupStyle.lightPurple)
                    .font(.callout.monospaced()).foregroundStyle(LineupStyle.secondary).lineLimit(1)
                    .frame(width: 400, alignment: .leading)
            } else {
                ForEach(displayedEvents) { game in
                    HStack(spacing: 12) {
                        Text(game.league.shortName).foregroundColor(LineupStyle.lightPurple)
                            .font(.inter(.caption2, .bold)).tracking(1.5)
                            .foregroundStyle(LineupStyle.secondary)
                            .frame(width: 62, alignment: .leading)
                        Text(game.awayAbbreviation)
                            .foregroundStyle(sportsReadableTeamColor(game.awayColor) ?? LineupStyle.text)
                            .frame(width: 72, alignment: .leading)
                        Text(game.awayScore).foregroundColor(LineupStyle.lightPurple).fontWeight(.bold).foregroundStyle(LineupStyle.text)
                            .frame(width: 48, alignment: .trailing)
                        Text("–").foregroundColor(LineupStyle.lightPurple).foregroundStyle(LineupStyle.secondary)
                        Text(game.homeAbbreviation)
                            .foregroundStyle(sportsReadableTeamColor(game.homeColor) ?? LineupStyle.text)
                            .frame(width: 72, alignment: .leading)
                        Text(game.homeScore).foregroundColor(LineupStyle.lightPurple).fontWeight(.bold).foregroundStyle(LineupStyle.text)
                            .frame(width: 48, alignment: .trailing)
                        Text(game.isLive ? game.status.uppercased() : "FINAL").foregroundColor(LineupStyle.lightPurple)
                            .font(.inter(.caption2, .bold)).tracking(1.2)
                            .foregroundStyle(game.isLive ? LineupStyle.live : LineupStyle.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout.monospaced()).lineLimit(1)
                    .frame(width: cardWidth, alignment: .leading)
                }
            }
        }
    }
}

private func sportsTeamColor(_ value: String?) -> Color? {
    guard var value = nonempty(value) else { return nil }
    value = value.replacingOccurrences(of: "#", with: "")
    guard value.count == 6, let hex = UInt64(value, radix: 16) else { return nil }
    return Color(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
}

private func sportsReadableTeamColor(_ value: String?) -> Color? {
    guard var value = nonempty(value) else { return nil }
    value = value.replacingOccurrences(of: "#", with: "")
    guard value.count == 6, let hex = UInt64(value, radix: 16) else { return nil }
    var red = Double((hex >> 16) & 0xff) / 255
    var green = Double((hex >> 8) & 0xff) / 255
    var blue = Double(hex & 0xff) / 255
    // Provider colors can contain white too; keep those ticker labels on theme.
    if min(red, green, blue) > 0.75 && max(red, green, blue) - min(red, green, blue) < 0.12 {
        return LineupStyle.lightPurple
    }
    let luminance = (red * 0.2126) + (green * 0.7152) + (blue * 0.0722)
    if luminance < 0.50 {
        let whiteMix = (0.50 - luminance) / max(0.01, 1 - luminance)
        red += (1 - red) * whiteMix
        green += (1 - green) * whiteMix
        blue += (1 - blue) * whiteMix
    }
    return Color(red: red, green: green, blue: blue)
}

private func nonempty(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return value
}

private func sportsSymbol(_ league: SportsLeague) -> String {
    switch league {
    case .nfl, .ncaaf: "football.fill"
    case .nba: "basketball.fill"
    case .nhl: "hockey.puck.fill"
    case .mlb: "baseball.fill"
    }
}

private struct LeagueLogo: View {
    let league: SportsLeague
    let size: CGFloat

    private var logoURL: URL? {
        guard league != .ncaaf else { return nil }
        return URL(string: "https://a.espncdn.com/i/teamlogos/leagues/500/\(league.rawValue).png")
    }

    var body: some View {
        AsyncImage(url: logoURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit().colorMultiply(LineupStyle.lightPurple)
            } else {
                Image(systemName: sportsSymbol(league))
                    .resizable().scaledToFit()
                    .padding(size * 0.18)
                    .foregroundStyle(LineupStyle.secondary)
            }
        }
        .transaction { $0.animation = nil }
        .frame(width: size, height: size)
        .clipped()
    }
}

private struct LiveFilterButton: View {
    @FocusState private var isFocused: Bool
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Text(title).foregroundColor(LineupStyle.lightPurple).font(.inter(.callout, .semibold)).padding(.horizontal, 20).frame(height: 42)
            .foregroundStyle(selected || isFocused ? LineupStyle.text : LineupStyle.secondary)
            .background(selected ? LineupStyle.lightPurple.opacity(0.10) : Color.clear)
            .clipShape(Capsule()).nullGlass(cornerRadius: 22)
            .overlay(alignment: .bottom) { if selected { Capsule().fill(LineupStyle.field).frame(width: 28, height: 3).offset(y: -4) } }
            .contentShape(Capsule()).focusable().focused($isFocused).focusEffectDisabled().onTapGesture(perform: action)
            .focusLift(isFocused, scale: LineupStyle.controlLift)
    }
}

private struct ScheduleSection: View {
    let title: String
    let events: [SportsGame]
    let multiviewPrimaryID: Int?
    let onPlay: (SportsGame) -> Void
    let onStartMultiview: (SportsGame) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if title == "Live now" { Circle().fill(LineupStyle.text).frame(width: 9, height: 9) }
                Text(title.uppercased()).foregroundColor(LineupStyle.lightPurple).font(.inter(.caption, .bold)).tracking(1.5)
                    .foregroundStyle(title == "Live now" ? LineupStyle.text : LineupStyle.secondary)
                Text("(\(events.count))").foregroundColor(LineupStyle.lightPurple).font(.inter(.caption)).foregroundStyle(LineupStyle.secondary)
                Rectangle().fill(LineupStyle.line).frame(height: 1)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)], spacing: 18) {
                ForEach(events) { event in
                    GameEventCard(
                        event: event,
                        multiviewPrimaryID: multiviewPrimaryID,
                        onPlay: { onPlay(event) },
                        onStartMultiview: { onStartMultiview(event) }
                    )
                }
            }
        }
    }
}

private struct ScreenHeading: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).foregroundColor(LineupStyle.lightPurple).font(.inter(42, .semibold)).foregroundStyle(LineupStyle.text)
            Text(detail).foregroundColor(LineupStyle.lightPurple).font(.inter(.callout)).foregroundStyle(LineupStyle.secondary)
        }
    }
}

private struct EmptySchedule: View {
    let isLoading: Bool
    let isAvailable: Bool
    let errorMessage: String?
    var body: some View {
        HStack(spacing: 16) {
            if isLoading { ProgressView() } else { Image(systemName: isAvailable ? "calendar" : "wifi.exclamationmark") }
            Text(isLoading ? "Checking official schedules…" : (isAvailable ? "No games scheduled today or tomorrow" : (errorMessage ?? "Schedule unavailable — try Refresh"))).foregroundColor(LineupStyle.lightPurple)
        }
        .font(.inter(.title3)).foregroundStyle(LineupStyle.secondary)
        .padding(.vertical, 46)
    }
}

private struct GameEventCard: View {
    @EnvironmentObject private var library: SportsLibrary
    @EnvironmentObject private var reminders: GameReminders
    @FocusState private var isFocused: Bool
    let event: SportsGame
    let multiviewPrimaryID: Int?
    let onPlay: () -> Void
    let onStartMultiview: () -> Void
    private var stream: XtreamStream? { library.stream(for: event) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                MatchupArtwork(event: event)
                VStack(alignment: .leading, spacing: 8) {
                    GameTeamLine(logo: event.awayLogo, name: event.awayTeam, score: event.isLive ? event.awayScore : nil)
                    Text("@").foregroundColor(LineupStyle.lightPurple).font(.inter(.caption, .bold)).foregroundStyle(LineupStyle.secondary).padding(.leading, 20)
                    GameTeamLine(logo: event.homeLogo, name: event.homeTeam, score: event.isLive ? event.homeScore : nil)
                    HStack(spacing: 12) {
                        Text(event.league.shortName).foregroundColor(LineupStyle.lightPurple)
                            .font(.inter(.caption, .bold)).padding(.horizontal, 10).frame(height: 28)
                            .background(LineupStyle.selected).clipShape(Capsule())
                        Text(event.start.formatted(date: .abbreviated, time: .shortened)).foregroundColor(LineupStyle.lightPurple)
                            .font(.interDigits(.caption)).foregroundStyle(LineupStyle.secondary).lineLimit(1)
                        Spacer(minLength: 118)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .overlay(alignment: .bottomTrailing) {
                GameStatusBadge(event: event)
                    .padding(.trailing, 18).padding(.bottom, 16)
            }
                Rectangle().fill(LineupStyle.line).frame(height: 1)
                HStack(spacing: 12) {
                    Image(systemName: stream == nil ? "tv.slash" : "checkmark.circle.fill")
                        .foregroundStyle(stream == nil ? LineupStyle.warning : LineupStyle.positive)
                    Text(stream?.name ?? (event.broadcast.isEmpty ? "No matching channel" : event.broadcast)).foregroundColor(LineupStyle.lightPurple)
                        .font(.inter(.callout, .medium)).foregroundStyle(LineupStyle.lightPurple).lineLimit(1)
                    Spacer()
                    if isFocused, stream != nil {
                        Label("Watch", systemImage: "play.fill")
                            .font(.inter(.caption, .bold)).foregroundStyle(LineupStyle.text)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                    if stream == nil {
                        Label("No channel", systemImage: "display").font(.inter(.caption, .semibold)).foregroundStyle(LineupStyle.secondary)
                    }
                }
                .padding(.horizontal, 18).frame(height: 46)
                .nullGlass(clear: event.isLive, cornerRadius: 0)
        }
        .background(isFocused ? LineupStyle.focused : (event.isLive ? LineupStyle.selected : LineupStyle.surface))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).inset(by: 1).stroke(event.isLive ? LineupStyle.text.opacity(0.28) : LineupStyle.line, lineWidth: 1))
        .overlay {
            if multiviewPrimaryID == stream?.id {
                RoundedRectangle(cornerRadius: 14, style: .continuous).inset(by: 2).stroke(LineupStyle.liveSelectionBorder.opacity(0.8), lineWidth: 3)
            }
        }
        .contentShape(Rectangle()).focusable().focused($isFocused).focusEffectDisabled().onTapGesture(perform: onPlay)
        .contextMenu {
            if event.isUpcoming {
                Button(reminders.reminds(event) ? "Remove Reminder" : "Remind Me",
                       systemImage: reminders.reminds(event) ? "bell.slash" : "bell") {
                    reminders.toggleGame(event)
                }
            }
            if stream != nil {
                Button(multiviewPrimaryID == stream?.id ? "First Multiview Game" : "Start Multiview", systemImage: "rectangle.split.2x1") {
                    onStartMultiview()
                }
                .disabled(multiviewPrimaryID == stream?.id)
            }
        }
        .focusLift(isFocused)
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

private struct GameStatusBadge: View {
    let event: SportsGame

    private var title: String {
        if event.isLive { return "LIVE" }
        return Calendar.current.isDateInToday(event.start) ? "TODAY" : "TOMORROW"
    }

    var body: some View {
        HStack(spacing: 7) {
            if event.isLive { Circle().fill(LineupStyle.live).frame(width: 7, height: 7) }
            Text(title).foregroundColor(LineupStyle.lightPurple).font(.inter(.caption, .bold)).tracking(1.1)
        }
        .foregroundStyle(event.isLive ? LineupStyle.lightPurple : LineupStyle.text)
        .padding(.horizontal, 13).frame(height: 34)
        .background(event.isLive ? LineupStyle.live.opacity(0.28) : LineupStyle.lightPurple.opacity(0.06))
        .clipShape(Capsule())
        .nullGlass(clear: event.isLive, cornerRadius: 17)
    }
}

private struct MatchupArtwork: View {
    let event: SportsGame
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(LineupStyle.raised)
            HStack(spacing: 16) {
                TeamBadge(url: event.awayLogo, fallback: event.awayAbbreviation, size: 58)
                Text("VS").foregroundColor(LineupStyle.lightPurple).font(.inter(.caption2, .bold)).foregroundStyle(LineupStyle.secondary)
                    .frame(width: 32, height: 32).background(LineupStyle.background).clipShape(Circle())
                TeamBadge(url: event.homeLogo, fallback: event.homeAbbreviation, size: 58)
            }
        }.frame(width: 190, height: 126)
    }
}

private struct GameTeamLine: View {
    let logo: String
    let name: String
    let score: String?
    var body: some View {
        HStack(spacing: 12) {
            TeamBadge(url: logo, fallback: String(name.prefix(3)).uppercased(), size: 34)
            Text(name).foregroundColor(LineupStyle.lightPurple)
                .font(.inter(18, .semibold))
                .foregroundStyle(LineupStyle.text)
                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(0.68)
                .layoutPriority(1)
            Spacer(minLength: 12)
            if let score, !score.isEmpty {
                Text(score).foregroundColor(LineupStyle.lightPurple).font(.interDigits(.title2, .bold)).foregroundStyle(LineupStyle.text)
            }
        }
    }
}

private struct ChannelLogo: View {
    let url: String?
    var width: CGFloat = 74
    var height: CGFloat = 54
    var body: some View {
        AsyncImage(url: URL(string: url ?? "")) { $0.resizable().scaledToFit().colorMultiply(LineupStyle.lightPurple) } placeholder: {
            Image(systemName: "tv").font(.caption).foregroundStyle(LineupStyle.secondary)
        }
        .transaction { $0.animation = nil }
        .padding(4).frame(width: width, height: height).background(LineupStyle.raised)
    }
}

// Theme surfaces shared across the Guide.
/// The guide's own names for the theme's colours. The four that used to be
/// called purple, pink, green and yellow were all the text tint, because
/// Velvet has no colour of its own -- so the names described nothing and a
/// theme that did have one could not reach them. They say what they mark now,
/// and the marks read from the theme's highlight.
private enum GuidePalette {
    static var background: Color { LineupStyle.background }
    static var panel: Color { LineupStyle.surface.opacity(0.74) }
    static var surface: Color { LineupStyle.surface }
    static var raised: Color { LineupStyle.raised }
    static var channelTile: Color { LineupStyle.selected }
    static var line: Color { LineupStyle.line }
    static var text: Color { LineupStyle.lightPurple }
    static var secondary: Color { LineupStyle.lightPurple }
    /// An eyebrow over a panel, the line down the grid: the theme speaking.
    static var highlight: Color { LineupStyle.highlight }
    /// How far a programme has run, filled in behind the line. Lighter than
    /// the line, because it covers area and the line is one line wide.
    static var progressFill: Color { LineupStyle.highlightSoft }
    /// A programme's card, and the same card with the remote on it. Both are
    /// a step up from the row they sit in, so a card reads as a card and the
    /// blue over it has something to read against.
    static var card: Color { LineupStyle.raised }
    static var cardFocused: Color { LineupStyle.focused }
    /// The on-air badge.
    static var liveMark: Color { LineupStyle.highlight }
    /// The edge and glow on whatever the remote is sitting on.
    static var focusRing: Color { LineupStyle.highlight }
    /// A badge for something that has not started, which must not be mistaken
    /// for the on-air one, so it stays the quiet text tint.
    static var upcomingMark: Color { LineupStyle.lightPurple }
}

struct GuideView: View {
    @EnvironmentObject private var library: SportsLibrary
    @FocusState private var gridFocus: GuideGridFocus?
    @FocusState private var sidebarFocus: String?
    @State private var returnGridFocus: GuideGridFocus?
    @State private var selectedCategoryID: String?
    @State private var favoritesOnly = true
    @State private var searchActive = false
    @State private var query = ""
    @State private var selectedStream: XtreamStream?
    @State private var multiviewPrimary: XtreamStream?
    @State private var multiviewSession: MultiviewSession?
    @State private var guideNow = Date()
    @State private var focusedGuideItem: GuideFocusItem?
    @State private var previewPlaybackStream: XtreamStream?
    @State private var pinnedPreviewItem: GuideFocusItem?
    @State private var playbackTransitionID: UUID?
    /// What the preview goes back to playing when full screen closes.
    ///
    /// Going full screen tears the preview's player down first -- two players
    /// on one channel is two connections to the provider for one picture --
    /// so on the way back there is nothing left running to return to. This is
    /// what was pinned when it left, kept so it can be put back.
    @State private var resumeAfterFullscreen: GuideFocusItem?
    @State private var previewHidden = false
    @State private var sidebarVisible = false
    @State private var reorderingFavorites = false
    private var filtered: [XtreamStream] {
        library.guideStreams(categoryID: searchActive ? nil : selectedCategoryID, favoritesOnly: searchActive ? false : favoritesOnly, query: query)
    }
    private var selectedTitle: String {
        if favoritesOnly { return "Favorites" }
        return library.categories.first { $0.id == selectedCategoryID }?.categoryName ?? "All channels"
    }
    private var previewItem: GuideFocusItem? {
        if let focusedGuideItem, filtered.contains(where: { $0.id == focusedGuideItem.stream.id }) {
            return focusedGuideItem
        }
        for stream in filtered {
            if let program = library.guidePrograms(for: stream).first(where: { $0.start <= guideNow && guideNow < $0.end }) {
                return GuideFocusItem(stream: stream, program: program)
            }
        }
        return nil
    }
    private var displayedPreviewItem: GuideFocusItem? {
        previewPlaybackStream == nil ? previewItem : pinnedPreviewItem
    }

    var body: some View {
        GeometryReader { container in
            let layout = GuideLayout(width: container.size.width - 40)
            NavigationStack {
                VStack(alignment: .leading, spacing: 7) {
                    GuideControlBar(
                        title: selectedTitle,
                        channelCount: filtered.count,
                        searchActive: $searchActive,
                        query: $query,
                        multiviewTitle: multiviewPrimary?.name,
                        isLoading: library.isGuideLoading,
                        now: guideNow,
                        onCancelMultiview: { multiviewPrimary = nil }
                    )

                    if !previewHidden, let previewItem = displayedPreviewItem {
                        GuidePreviewPanel(
                            item: previewItem,
                            categoryName: library.categories.first(where: { $0.id == previewItem.stream.categoryID })?.categoryName ?? "Live TV",
                            quality: guideQuality(previewItem.stream),
                            previewURLs: previewPlaybackStream?.id == previewItem.stream.id ? library.playbackURLs(for: previewItem.stream) : nil,
                            now: guideNow
                        )
                        .frame(height: 204)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    ZStack(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 7) {
                            GuideTimelineHeader(now: guideNow)
                            if filtered.isEmpty {
                                Text(favoritesOnly ? "Your favorite channels will appear here." : "No channels in this category.").foregroundColor(LineupStyle.lightPurple)
                                    .font(.inter(.title3)).foregroundStyle(GuidePalette.secondary).padding(.top, 24)
                                    .focusable()
                                    .focused($gridFocus, equals: GuideGridFocus(streamID: -1, programStart: nil))
                                    .modifier(GuideLeftBoundary(enabled: !sidebarVisible && !searchActive, onOpen: openSidebar))
                            } else {
                                ScrollViewReader { proxy in
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 8) {
                                        ForEach(filtered) { stream in
                                            GuideChannelRow(
                                                stream: stream,
                                                favoritesMode: favoritesOnly && !searchActive,
                                                now: guideNow,
                                                gridFocus: $gridFocus,
                                                canOpenSidebar: !sidebarVisible && !searchActive,
                                                onOpenSidebar: openSidebar,
                                                multiviewPrimaryID: multiviewPrimary?.id,
                                                onPlay: { select(stream) },
                                                onStartMultiview: { multiviewPrimary = stream },
                                                onReorderFavorites: { reorderingFavorites = true },
                                                onFocusProgram: { program in
                                                    withAnimation(.easeOut(duration: 0.18)) {
                                                        focusedGuideItem = GuideFocusItem(stream: stream, program: program)
                                                        previewHidden = false
                                                    }
                                                }
                                            )
                                            .id(stream.id)
                                        }
                                    }.padding(.top, 2)
                                }
                                .onChange(of: sidebarVisible) { _, visible in
                                    guard !visible, let target = gridFocus else { return }
                                    proxy.scrollTo(target.streamID, anchor: .center)
                                    Task { @MainActor in
                                        await Task.yield()
                                        guard !sidebarVisible else { return }
                                        gridFocus = target
                                    }
                                }
                                }
                            }
                        }
                        .disabled(sidebarVisible && !searchActive)
                        // Above the grid and below the header, where it reads as
                        // one mark rather than a mark per row. The sidebar
                        // covers the channel column when it is out, and the line
                        // would stand on top of it saying nothing.
                        .overlay(alignment: .topLeading) {
                            if !(sidebarVisible && !searchActive), !filtered.isEmpty {
                                GuideNowLine(now: guideNow).padding(.top, 52)
                            }
                        }

                        if sidebarVisible && !searchActive {
                            GuideSidebar(
                                selectedCategoryID: $selectedCategoryID,
                                favoritesOnly: $favoritesOnly,
                                focus: $sidebarFocus,
                                onCollapse: closeSidebar
                            )
                            .frame(width: layout.channelWidth)
                            .frame(maxHeight: .infinity)
                            .background(GuidePalette.panel)
                            .overlay(alignment: .trailing) {
                                Rectangle()
                                    .fill(LinearGradient(colors: [GuidePalette.text.opacity(0.14), GuidePalette.text.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                                    .frame(width: 1)
                            }
                            .lineupShadow(.overlayFromEdge)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                            .focusSection()
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.top, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .ignoresSafeArea(.container, edges: .bottom)
                // Two washes across the whole screen, for depth in the corners.
                // They were written against a theme whose highlight was its text
                // tint, so what they added was light. Pointed at a real accent
                // they became six hundred points of blue in each corner, which
                // is the ground of the busiest screen in the app going navy.
                // Light is what they were for, so light is what they use.
                .background(
                    ZStack {
                        GuidePalette.background
                        RadialGradient(colors: [GuidePalette.text.opacity(0.05), .clear], center: .topLeading, startRadius: 0, endRadius: 680)
                        RadialGradient(colors: [GuidePalette.text.opacity(0.03), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 720)
                    }.ignoresSafeArea()
                )
                .fullScreenCover(item: $selectedStream, onDismiss: resumePreview) { stream in
                    PlayerView(
                        urls: library.playbackURLs(for: stream),
                        title: stream.name,
                        program: library.guidePrograms(for: stream).normalizedEPG().first { $0.isLive }
                    )
                }
                .fullScreenCover(item: $multiviewSession) { session in
                    MultiviewView(
                        primary: session.primary,
                        secondary: session.secondary,
                        primaryURLs: library.playbackURLs(for: session.primary),
                        secondaryURLs: library.playbackURLs(for: session.secondary)
                    )
                }
                .fullScreenCover(isPresented: $reorderingFavorites) {
                    TVFavoritesOrderView()
                }
                .task {
                    while !Task.isCancelled {
                        guideNow = Date()
                        do { try await Task.sleep(for: .seconds(5)) }
                        catch { return }
                    }
                }
                .onExitCommand {
                    if playbackTransitionID != nil {
                        // Menu during the handover: full screen never opens, so
                        // there is nothing to come back from and nothing to
                        // keep. Left set, this would hold a channel that was
                        // never handed anywhere.
                        playbackTransitionID = nil
                        resumeAfterFullscreen = nil
                    } else if previewPlaybackStream != nil {
                        previewPlaybackStream = nil
                        pinnedPreviewItem = nil
                    } else if !previewHidden {
                        previewHidden = true
                    }
                }
            }
            .environment(\.guideLayout, layout)
            .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
        }
        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
    }

    private func openSidebar() {
        guard !sidebarVisible, !searchActive else { return }
        returnGridFocus = gridFocus
        gridFocus = nil
        withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible = true }
    }

    private func closeSidebar() {
        sidebarFocus = nil
        withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible = false }
        let channels = filtered
        let stream = returnGridFocus.flatMap { previous in channels.first { $0.id == previous.streamID } } ?? channels.first
        guard let stream else {
            gridFocus = GuideGridFocus(streamID: -1, programStart: nil)
            return
        }
        let anchor = guideTimelineAnchor(guideNow)
        let end = anchor.addingTimeInterval(Double(guideVisibleSlotCount) * 1800)
        let programs = library.guidePrograms(for: stream).filter { $0.end > anchor && $0.start < end }
        let restored = programs.first { $0.start == returnGridFocus?.programStart } ?? programs.first
        gridFocus = GuideGridFocus(streamID: stream.id, programStart: restored?.start)
    }

    /// Put the preview back on the channel that was just full screen.
    ///
    /// It keeps playing there until a different channel is chosen, which is
    /// the branch below that pins a new one. Choosing the same channel again
    /// goes back to full screen, as it did before.
    ///
    /// The stream is opened again rather than handed over: the full-screen
    /// player and the preview are separate players, so there is a moment of
    /// reconnecting rather than an unbroken picture.
    private func resumePreview() {
        previewHidden = false
        guard let resume = resumeAfterFullscreen else { return }
        resumeAfterFullscreen = nil
        pinnedPreviewItem = resume
        previewPlaybackStream = resume.stream
    }

    private func select(_ stream: XtreamStream) {
        guard let primary = multiviewPrimary else {
            if previewPlaybackStream?.id == stream.id {
                let transitionID = UUID()
                playbackTransitionID = transitionID
                // Remember what is being handed to full screen, so closing it
                // comes back to this channel still playing rather than to a
                // dark panel and a channel that has to be chosen again.
                resumeAfterFullscreen = pinnedPreviewItem
                previewPlaybackStream = nil
                pinnedPreviewItem = nil
                previewHidden = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(180))
                    guard playbackTransitionID == transitionID else { return }
                    playbackTransitionID = nil
                    selectedStream = stream
                }
            } else {
                playbackTransitionID = nil
                let selectedProgram = focusedGuideItem.flatMap { $0.stream.id == stream.id ? $0.program : nil }
                    ?? library.guidePrograms(for: stream).normalizedEPG().first(where: { $0.start <= guideNow && guideNow < $0.end })
                    ?? library.guidePrograms(for: stream).normalizedEPG().first
                    ?? CurrentProgram(
                        channelID: stream.epgChannelID ?? String(stream.id),
                        title: stream.name,
                        detail: "Live channel preview",
                        start: guideNow,
                        end: guideNow.addingTimeInterval(3600)
                    )
                pinnedPreviewItem = GuideFocusItem(stream: stream, program: selectedProgram)
                previewPlaybackStream = stream
                previewHidden = false
            }
            return
        }
        guard primary.id != stream.id else { return }
        multiviewPrimary = nil
        multiviewSession = MultiviewSession(primary: primary, secondary: stream)
    }
}

private struct GuideFocusItem: Equatable {
    let stream: XtreamStream
    let program: CurrentProgram
}

private struct GuideControlBar: View {
    let title: String
    let channelCount: Int
    @Binding var searchActive: Bool
    @Binding var query: String
    let multiviewTitle: String?
    let isLoading: Bool
    let now: Date
    let onCancelMultiview: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let multiviewTitle {
                VStack(alignment: .leading, spacing: 1) {
                    Text("MULTIVIEW · CHOOSE SECOND CHANNEL").foregroundColor(LineupStyle.lightPurple).font(.inter(.caption2, .bold)).tracking(1.3).foregroundStyle(GuidePalette.secondary)
                    Text(multiviewTitle).foregroundColor(LineupStyle.lightPurple).font(.inter(.callout, .semibold)).lineLimit(1)
                }
            } else if searchActive {
                TextField("Search channels", text: $query)
                    .textFieldStyle(.plain).focusEffectDisabled()
                    .font(.inter(22, .medium))
                    .padding(.horizontal, 14).frame(maxWidth: 520, minHeight: 40)
                    .background(GuidePalette.raised).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Text(title).foregroundColor(LineupStyle.lightPurple).font(.inter(24, .semibold)).lineLimit(1)
            }
            Spacer()
            if isLoading { ProgressView().controlSize(.small) }
            Text("\(channelCount) CHANNELS").foregroundColor(LineupStyle.lightPurple).font(.inter(.caption2, .bold)).tracking(1.4).foregroundStyle(GuidePalette.secondary)
            Rectangle().fill(GuidePalette.line).frame(width: 1, height: 22)
            Label(now.formatted(date: .omitted, time: .shortened), systemImage: "clock")
                .font(.interDigits(18, .medium))
                .foregroundStyle(GuidePalette.text)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Current time, \(now.formatted(date: .omitted, time: .shortened))")
            GuideHeaderButton(title: searchActive ? "Close" : "Search", symbol: searchActive ? "xmark" : "magnifyingglass") {
                searchActive.toggle()
                if !searchActive { query = "" }
            }
            if multiviewTitle != nil { GuideHeaderButton(title: "Cancel", symbol: "xmark", action: onCancelMultiview) }
        }
        .foregroundStyle(GuidePalette.text)
        .frame(height: 44)
    }

}

private struct GuidePreviewPanel: View {
    let item: GuideFocusItem
    let categoryName: String
    let quality: String?
    let previewURLs: [URL]?
    let now: Date

    private var progress: CGFloat {
        let duration = item.program.end.timeIntervalSince(item.program.start)
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(now.timeIntervalSince(item.program.start) / duration, 0), 1))
    }

    var body: some View {
        HStack(spacing: 24) {
            Group {
                if let previewURLs {
                    GuidePreviewVideo(urls: previewURLs)
                        .id(item.stream.id)
                } else {
                    GuidePreviewArtwork(stream: item.stream)
                }
            }
                .frame(width: 330, height: 174)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .top) {
                    LinearGradient(colors: [GuidePalette.text.opacity(0.14), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 46)
                        .allowsHitTesting(false)
                }
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(GuidePalette.line, lineWidth: 1))

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    Text("‹ \(categoryName.uppercased())  ·  \(item.stream.name.uppercased())").foregroundColor(LineupStyle.lightPurple)
                        .font(.inter(.caption2, .bold)).tracking(1.15).foregroundStyle(GuidePalette.highlight).lineLimit(1)
                    if let quality { GuideTinyBadge(title: quality, color: GuidePalette.raised) }
                    if item.program.isLive { GuideLiveDot(size: 11) }
                }
                HStack(spacing: 10) {
                    Text(item.program.title.isEmpty ? "Untitled" : item.program.title).foregroundColor(LineupStyle.lightPurple)
                        .font(.inter(27, .semibold)).lineLimit(1)
                    if item.program.isNew == true { GuideTinyBadge(title: "NEW", color: GuidePalette.raised) }
                }
                HStack(spacing: 12) {
                    Text(guideTimeRange(item.program)).foregroundColor(LineupStyle.lightPurple).font(.interDigits(.callout)).foregroundStyle(GuidePalette.secondary)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(GuidePalette.raised)
                            Capsule().fill(GuidePalette.highlight).frame(width: proxy.size.width * progress)
                        }
                    }.frame(width: 170, height: 4)
                }
                Text(item.program.detail.isEmpty ? "No program description available." : item.program.detail).foregroundColor(LineupStyle.lightPurple)
                    .font(.inter(.callout)).foregroundStyle(GuidePalette.secondary).lineLimit(1)
                Text("Press Menu to hide preview").foregroundColor(LineupStyle.lightPurple)
                    .font(.inter(.caption2, .medium)).foregroundStyle(LineupStyle.lightPurple)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(LinearGradient(colors: [GuidePalette.text.opacity(0.05), GuidePalette.text.opacity(0.015)], startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(GuidePalette.text.opacity(0.08), lineWidth: 1))
        .lineupShadow(.overlay)
    }
}

private struct GuidePreviewVideo: View {
    @StateObject private var controller = VLCPlaybackController()
    let urls: [URL]

    var body: some View {
        VLCVideoSurface(player: controller.player).overlay { TVPlaybackStatus(controller: controller) }
            .background(Color.black)
            .onAppear { controller.start(urls: urls, muted: false) }
            .onDisappear { controller.stop() }
    }
}

private struct GuidePreviewArtwork: View {
    let stream: XtreamStream
    var body: some View {
        ZStack {
            GuidePalette.panel
            AsyncImage(url: stream.streamIcon.flatMap(URL.init(string:))) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit().colorMultiply(LineupStyle.lightPurple).padding(24)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "tv").font(.system(size: 38, weight: .light))
                        Text(stream.name).foregroundColor(LineupStyle.lightPurple).font(.inter(.callout, .semibold)).lineLimit(2).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(GuidePalette.secondary)
                    .padding(24)
                }
            }
            .transaction { $0.animation = nil }
        }
    }
}

private struct GuideTinyBadge: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title).font(.inter(10, .bold)).tracking(0.8)
            .foregroundStyle(LineupStyle.lightPurple.opacity(0.78))
            .padding(.horizontal, 8).frame(height: 19)
            .background(color, in: Capsule())
            .overlay(Capsule().stroke(LineupStyle.lightPurple.opacity(0.12), lineWidth: 0.5))
    }
}

private func guideQuality(_ stream: XtreamStream) -> String? {
    let value = stream.name.uppercased()
    if value.contains("4K") || value.contains("UHD") { return "UHD" }
    if value.contains("FHD") || value.contains("1080") { return "FHD" }
    if value.contains("HD") || value.contains("720") { return "HD" }
    return nil
}

private func guideTimeRange(_ program: CurrentProgram) -> String {
    "\(program.start.formatted(date: .omitted, time: .shortened)) — \(program.end.formatted(date: .omitted, time: .shortened))"
}

private struct MultiviewSession: Identifiable {
    let id = UUID()
    let primary: XtreamStream
    let secondary: XtreamStream
}

private struct GuideSidebar: View {
    @EnvironmentObject private var library: SportsLibrary
    @Binding var selectedCategoryID: String?
    @Binding var favoritesOnly: Bool
    let focus: FocusState<String?>.Binding
    let onCollapse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("CHANNELS").foregroundColor(LineupStyle.lightPurple).font(.inter(.caption2, .bold)).tracking(1.5).foregroundStyle(GuidePalette.highlight)
                Spacer()

            }
            .padding(.leading, 14).frame(height: 42)
            GuideSidebarButton(title: "All channels", symbol: "rectangle.stack", selected: selectedCategoryID == nil && !favoritesOnly, focus: focus, focusID: "all") {
                selectedCategoryID = nil; favoritesOnly = false
            }
            GuideSidebarButton(title: "Favorites", symbol: "star.fill", selected: favoritesOnly, focus: focus, focusID: "favorites") {
                selectedCategoryID = nil; favoritesOnly = true
            }
            Text("CATEGORIES").foregroundColor(LineupStyle.lightPurple).font(.inter(.caption2, .bold)).tracking(1.5).foregroundStyle(GuidePalette.highlight)
                .lineLimit(1).padding(.leading, 14).padding(.top, 8).frame(height: 30)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(library.categories) { category in
                        GuideSidebarButton(title: category.categoryName, symbol: "rectangle.grid.1x2", selected: selectedCategoryID == category.id && !favoritesOnly, focus: focus, focusID: "category-" + category.id) {
                            selectedCategoryID = category.id; favoritesOnly = false
                        }
                    }
                }
            }
        }
        .padding(.trailing, 8)
        .onMoveCommand { direction in
            if direction == .right { onCollapse() }
        }
        .task {
            // All channels is always mounted; do not target an offscreen lazy category.
            focus.wrappedValue = favoritesOnly ? "favorites" : "all"
        }
    }
}

private struct GuideSidebarButton: View {
    let title: String
    let symbol: String
    let selected: Bool
    let focus: FocusState<String?>.Binding
    let focusID: String
    private var isFocused: Bool { focus.wrappedValue == focusID }
    let action: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: symbol).font(.caption).frame(width: 22)
            Text(title).foregroundColor(LineupStyle.lightPurple)
                .font(.inter(22, .medium))
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(selected || isFocused ? GuidePalette.text : GuidePalette.secondary)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(minHeight: 46)
        .background(isFocused ? GuidePalette.raised : (selected ? GuidePalette.text.opacity(0.075) : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(isFocused ? GuidePalette.focusRing.opacity(0.85) : Color.clear, lineWidth: 1.5))
        .nullGlass(cornerRadius: 12)
        .contentShape(Rectangle()).focusable().focused(focus, equals: focusID).focusEffectDisabled().onTapGesture(perform: action)
        .shadow(color: isFocused ? GuidePalette.focusRing.opacity(0.32) : .clear, radius: 18, y: 8)
        .scaleEffect(isFocused ? LineupStyle.cardLift : 1)
        .offset(y: isFocused ? -2 : 0)
        .animation(.spring(response: 0.25, dampingFraction: 0.78), value: isFocused)
    }
}

private struct GuideHeaderButton: View {
    @FocusState private var isFocused: Bool
    let title: String
    let symbol: String
    var onMoveDown: (() -> Void)? = nil
    let action: () -> Void
    var body: some View {
        Label(title, systemImage: symbol)
            .font(.inter(.callout, .semibold))
            .foregroundStyle(LineupStyle.text)
            .padding(.horizontal, 18).frame(height: 42)
            .background(isFocused ? LineupStyle.lightPurple.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)).nullGlass(cornerRadius: 14)
            .contentShape(Rectangle()).focusable().focused($isFocused).focusEffectDisabled().onTapGesture(perform: action)
            .focusLift(isFocused, scale: LineupStyle.controlLift)
            .onMoveCommand { direction in if direction == .down { onMoveDown?() } }
    }
}

private struct GuideTimelineHeader: View {
    @Environment(\.guideLayout) private var layout
    let now: Date

    var body: some View {
        let anchor = guideTimelineAnchor(now)
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                Text("TODAY").foregroundColor(LineupStyle.lightPurple)
                    .foregroundStyle(GuidePalette.highlight)
                    .frame(width: layout.channelWidth, alignment: .leading)
                ForEach(0..<guideVisibleSlotCount, id: \.self) { step in
                    Text(anchor.addingTimeInterval(Double(step) * 1800).formatted(date: .omitted, time: .shortened)).foregroundColor(LineupStyle.lightPurple)
                        .foregroundStyle(GuidePalette.secondary)
                        .frame(width: layout.slotWidth, alignment: .leading)
                }
            }
            .padding(.top, 24)
        }
        .font(.inter(.caption2, .bold)).tracking(1.4)
        .padding(.horizontal, 14).frame(height: 58)
        .background(
            LinearGradient(colors: [GuidePalette.panel.opacity(0.72), GuidePalette.surface.opacity(0.38)],
                startPoint: .leading, endPoint: .trailing),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(GuidePalette.line).frame(height: 1).padding(.horizontal, 14)
        }
    }
}

/// The line marking this moment, standing across the grid.
///
/// The guide shaded each programme up to now inside its own cell, which says
/// how far along one programme is but never where the hour itself has got to.
/// A single line down the whole grid does, and it is the one thing every guide
/// worth reading has.
///
/// It fades as it descends rather than running at full strength to the bottom:
/// the top of the grid is where the eye is, and a hard bar the height of the
/// screen would compete with the programme that is actually focused.
private struct GuideNowLine: View {
    @Environment(\.guideLayout) private var layout
    let now: Date

    /// The row and the header lay out identically -- fourteen points of
    /// padding, then the channel column, then half-hour slots -- so the line
    /// can be placed from the same three numbers and stay true to both.
    private var x: CGFloat {
        let elapsed = now.timeIntervalSince(guideTimelineAnchor(now))
        return 14 + layout.channelWidth + CGFloat(elapsed / 1800) * layout.slotWidth
    }

    var body: some View {
        // No cap on top. A dot there was a handle on something nobody drags,
        // and it drew the eye to the ceiling of the grid rather than down it.
        Rectangle()
            .fill(LinearGradient(
                colors: [GuidePalette.highlight.opacity(0.9), GuidePalette.highlight.opacity(0.16)],
                startPoint: .top, endPoint: .bottom))
            .frame(width: 2)
            .shadow(color: GuidePalette.highlight.opacity(0.45), radius: 7)
            .offset(x: x - 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private let guideVisibleSlotCount = 6

// Grow the grid cells in both dimensions without scaling typography or artwork.
// Keep the original channel/half-hour widths and row aspect ratio in sync.
private struct GuideLayout {
    let width: CGFloat
    var slotWidth: CGFloat { max(1, width - 28) / CGFloat(guideVisibleSlotCount + 1) }
    var channelWidth: CGFloat { slotWidth }
    var rowHeight: CGFloat { 132 * slotWidth / 245 }
}

private struct GuideLayoutKey: EnvironmentKey {
    static let defaultValue = GuideLayout(width: 1743)
}

private extension EnvironmentValues {
    var guideLayout: GuideLayout {
        get { self[GuideLayoutKey.self] }
        set { self[GuideLayoutKey.self] = newValue }
    }
}

private func guideTimelineAnchor(_ date: Date) -> Date {
    let calendar = Calendar.current
    var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    components.minute = ((components.minute ?? 0) / 30) * 30
    components.second = 0
    let floor = calendar.date(from: components) ?? date
    return calendar.date(byAdding: .minute, value: -30, to: floor) ?? floor
}

private struct GuideGridFocus: Hashable {
    let streamID: Int
    let programStart: Date?
}

// Only the first reachable cell receives a directional handler. Other cells
// remain entirely under the native tvOS focus engine's control.
private struct GuideLeftBoundary: ViewModifier {
    let enabled: Bool
    let onOpen: () -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.onMoveCommand { direction in
                if direction == .left { onOpen() }
            }
        } else {
            content
        }
    }
}

private struct GuideChannelRow: View {
    @Environment(\.guideLayout) private var layout
    @EnvironmentObject private var library: SportsLibrary
    let stream: XtreamStream
    let favoritesMode: Bool
    let now: Date
    let gridFocus: FocusState<GuideGridFocus?>.Binding
    let canOpenSidebar: Bool
    let onOpenSidebar: () -> Void
    let multiviewPrimaryID: Int?
    let onPlay: () -> Void
    let onStartMultiview: () -> Void
    let onReorderFavorites: () -> Void
    let onFocusProgram: (CurrentProgram) -> Void
    private var programs: [CurrentProgram] { library.guidePrograms(for: stream) }

    private var visiblePrograms: [CurrentProgram] {
        let start = guideTimelineAnchor(now)
        let end = start.addingTimeInterval(Double(guideVisibleSlotCount) * 1800)
        return programs.filter { $0.end > start && $0.start < end }
    }

    var body: some View {
        HStack(spacing: 0) {
            GuideChannelArtwork(stream: stream, isFavorite: library.isFavorite(stream))
            .frame(width: layout.channelWidth - 8, height: layout.rowHeight - 8)
            .background(
                LinearGradient(colors: [GuidePalette.channelTile.opacity(0.9), GuidePalette.panel.opacity(0.72)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.trailing, 8)
            .clipped()

            ZStack(alignment: .leading) {
                if visiblePrograms.isEmpty {
                    GuideProgramCell(program: nil, empty: "No guide information", quality: guideQuality(stream), now: now, showsTime: true, onPlay: onPlay, onFocus: {}, gridFocus: gridFocus, focusID: GuideGridFocus(streamID: stream.id, programStart: nil), opensSidebar: canOpenSidebar, onOpenSidebar: onOpenSidebar)
                        .frame(width: layout.slotWidth - 6, alignment: .leading)
                } else {
                    ForEach(Array(visiblePrograms.enumerated()), id: \.offset) { index, program in
                        let width = guideProgramWidth(program, now: now, layout: layout)
                        GuideProgramCell(program: program, empty: "", quality: guideQuality(stream), now: now, showsTime: width >= 110, onPlay: onPlay, onFocus: { onFocusProgram(program) }, gridFocus: gridFocus, focusID: GuideGridFocus(streamID: stream.id, programStart: program.start), opensSidebar: canOpenSidebar && index == 0, onOpenSidebar: onOpenSidebar)
                            .frame(width: width, alignment: .leading)
                            .clipped()
                            .offset(x: guideProgramX(program, now: now, layout: layout))
                    }
                }
            }
            .frame(width: layout.slotWidth * CGFloat(guideVisibleSlotCount), alignment: .leading)
            .clipped()
        }
        .padding(.horizontal, 14)
        .frame(width: layout.width, height: layout.rowHeight, alignment: .leading)
        .background(GuidePalette.surface.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(GuidePalette.line.opacity(0.72), lineWidth: 1))
        .overlay {
            if multiviewPrimaryID == stream.id {
                RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(GuidePalette.focusRing.opacity(0.9), lineWidth: 2)
            }
        }
        .lineupShadow(.restingQuiet)
        .contentShape(Rectangle())
        .contextMenu {
            Button(multiviewPrimaryID == stream.id ? "First Multiview Channel" : "Start Multiview", systemImage: "rectangle.split.2x1") {
                onStartMultiview()
            }
            .disabled(multiviewPrimaryID == stream.id)
            if favoritesMode {
                Button("Reorder Favorites", systemImage: "arrow.up.arrow.down") { onReorderFavorites() }
                Button("Move Up", systemImage: "arrow.up") { library.moveFavorite(stream, offset: -1) }
                    .disabled(!library.canMoveFavorite(stream, offset: -1))
                Button("Move Down", systemImage: "arrow.down") { library.moveFavorite(stream, offset: 1) }
                    .disabled(!library.canMoveFavorite(stream, offset: 1))
                Button("Remove from Favorites", systemImage: "star.slash", role: .destructive) { library.removeFavorite(stream) }
            } else if library.isFavorite(stream) {
                Button("Reorder Favorites", systemImage: "arrow.up.arrow.down") { onReorderFavorites() }
                Button("Remove from Favorites", systemImage: "star.slash", role: .destructive) { library.removeFavorite(stream) }
            } else {
                Button("Add to Favorites", systemImage: "star") { library.addFavorite(stream) }
            }
        }
    }
}

/// Artwork stays prominent, while the full channel name remains visible below
/// it so regional, quality, and alternate feeds are never ambiguous.
private struct GuideChannelArtwork: View {
    let stream: XtreamStream
    let isFavorite: Bool

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 3) {
                AsyncImage(url: stream.streamIcon.flatMap(URL.init(string:))) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                            .frame(width: max(1, proxy.size.width - 22),
                                   height: max(1, proxy.size.height - 45))
                    } else {
                        Image(systemName: "tv")
                            .font(.inter(24, .light))
                            .foregroundStyle(GuidePalette.secondary)
                            .frame(width: max(1, proxy.size.width - 22),
                                   height: max(1, proxy.size.height - 45))
                    }
                }
                .transaction { $0.animation = nil }
                Text(stream.name)
                    .font(.inter(12, .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.4)
                    .allowsTightening(true)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: proxy.size.width - 14, minHeight: 32, maxHeight: 36)
                    .foregroundStyle(GuidePalette.text)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.inter(10, .bold))
                        .padding(7)
                        .background(GuidePalette.background.opacity(0.88), in: Circle())
                        .padding(6)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Remote-friendly freeform ordering: select a channel to pick it up, focus any
/// destination, then select again to drop it at that position.
private struct TVFavoritesOrderView: View {
    @EnvironmentObject private var library: SportsLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var pickedStreamID: Int?
    @FocusState private var focusedStreamID: Int?

    private var favorites: [XtreamStream] {
        library.guideStreams(categoryID: nil, favoritesOnly: true, query: "")
    }

    var body: some View {
        ZStack {
            LineupStyle.background.ignoresSafeArea()
            RadialGradient(colors: [LineupStyle.lightPurple.opacity(0.11), .clear],
                center: .topLeading, startRadius: 0, endRadius: 940).ignoresSafeArea()
            RadialGradient(colors: [LineupStyle.lightPurple.opacity(0.055), .clear],
                center: .bottomTrailing, startRadius: 0, endRadius: 820).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .center, spacing: 32) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("YOUR CHANNELS")
                            .font(.inter(.caption, .bold)).tracking(3)
                            .foregroundStyle(LineupStyle.lightPurple.opacity(0.62))
                        Text("Arrange Favorites")
                            .font(.inter(46, .semibold))
                        Text(instruction)
                            .font(.inter(.title3))
                            .foregroundStyle(LineupStyle.lightPurple.opacity(0.72))
                            .contentTransition(.opacity)
                    }
                    Spacer()
                    HStack(spacing: 10) {
                        Label("\(favorites.count) FAVORITES", systemImage: "star.fill")
                            .font(.inter(.caption, .bold)).tracking(1.2)
                            .padding(.horizontal, 16).frame(height: 46)
                            .nullGlass(clear: true, cornerRadius: 23)
                        TVReorderDoneButton { dismiss() }
                    }
                }

                Group {
                    if favorites.isEmpty {
                        ContentUnavailableView("No favorites", systemImage: "star",
                            description: Text("Add channels to Favorites from the Guide."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 12) {
                                    ForEach(Array(favorites.enumerated()), id: \.element.id) { index, stream in
                                        favoriteRow(stream, position: index + 1)
                                            .id(stream.id)
                                    }
                                }
                                .padding(.horizontal, 28).padding(.vertical, 26)
                            }
                            .scrollClipDisabled()
                            .onChange(of: focusedStreamID) { _, streamID in
                                guard let streamID else { return }
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                    proxy.scrollTo(streamID, anchor: .center)
                                }
                            }
                        }
                    }
                }
                .background(GuidePalette.panel.opacity(0.82), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(LineupStyle.lightPurple.opacity(0.1), lineWidth: 1))
                .lineupShadow(.overlay)
            }
            .padding(.horizontal, 86).padding(.vertical, 58)
        }
        .foregroundStyle(LineupStyle.lightPurple)
        .task {
            if focusedStreamID == nil { focusedStreamID = favorites.first?.id }
        }
        .onExitCommand {
            if pickedStreamID != nil { pickedStreamID = nil }
            else { dismiss() }
        }
    }

    private var instruction: String {
        if let pickedStreamID, let stream = favorites.first(where: { $0.id == pickedStreamID }) {
            return "Moving \(stream.name)  ·  Choose any destination and press Select to place it."
        }
        return "Select a channel, move anywhere in the list, then Select again to place it."
    }

    private func favoriteRow(_ stream: XtreamStream, position: Int) -> some View {
        let isPicked = pickedStreamID == stream.id
        let isFocused = focusedStreamID == stream.id
        return HStack(spacing: 22) {
            ZStack {
                Circle().fill(isPicked ? LineupStyle.lightPurple : LineupStyle.lightPurple.opacity(0.08))
                Text("\(position)").font(.interDigits(.callout, .bold))
                    .foregroundStyle(isPicked ? GuidePalette.background : LineupStyle.lightPurple.opacity(0.64))
            }
            .frame(width: 44, height: 44)
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LineupStyle.raised.opacity(0.82))
                AsyncImage(url: stream.streamIcon.flatMap(URL.init(string:))) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit().colorMultiply(LineupStyle.lightPurple).padding(10)
                    } else {
                        Image(systemName: "tv").foregroundStyle(LineupStyle.lightPurple.opacity(0.5))
                    }
                }
                .transaction { $0.animation = nil }
            }
            .frame(width: 100, height: 60)
            VStack(alignment: .leading, spacing: 5) {
                Text(stream.name).font(.inter(.title3, .semibold)).lineLimit(1)
                Text(isPicked ? "Ready to move" : "Favorite channel")
                    .font(.inter(.caption)).foregroundStyle(LineupStyle.lightPurple.opacity(0.5))
            }
            Spacer()
            if isPicked {
                Label("PICKED UP", systemImage: "hand.draw.fill")
                    .font(.inter(.caption, .bold)).tracking(1.2)
                    .padding(.horizontal, 14).frame(height: 36)
                    .background(LineupStyle.lightPurple, in: Capsule())
                    .foregroundStyle(GuidePalette.background)
            } else if pickedStreamID != nil && isFocused {
                Label("PLACE HERE", systemImage: "arrow.down.to.line")
                    .font(.inter(.caption, .bold)).tracking(1.2)
                    .padding(.horizontal, 14).frame(height: 36)
                    .background(LineupStyle.lightPurple.opacity(0.12), in: Capsule())
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 88)
        .background(
            LinearGradient(colors: isPicked
                ? [LineupStyle.focused, LineupStyle.lightPurple.opacity(0.13)]
                : [isFocused ? LineupStyle.focused : GuidePalette.surface, GuidePalette.surface],
                startPoint: .leading, endPoint: .trailing),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(
            isPicked ? LineupStyle.lightPurple.opacity(0.92) : (isFocused ? LineupStyle.lightPurple.opacity(0.42) : LineupStyle.line),
            lineWidth: isPicked ? 2 : 1
        ))
        .overlay(alignment: .leading) {
            if pickedStreamID != nil && isFocused && !isPicked {
                Capsule().fill(LineupStyle.lightPurple).frame(width: 5, height: 48).offset(x: -2)
            }
        }
        .contentShape(Rectangle())
        .focusable()
        .focused($focusedStreamID, equals: stream.id)
        .focusEffectDisabled()
        .onTapGesture { select(stream) }
        // Smaller than either standard step, and deliberately so: these cells
        // sit shoulder to shoulder in a grid, and a card step here would push
        // one over its neighbours rather than above them.
        .scaleEffect(isPicked ? 1.025 : (isFocused ? 1.012 : 1))
        .offset(y: isPicked ? -3 : 0)
        // Two cues, so two shadows: a pale one while a row is being carried,
        // and the standard lifted step while the remote is merely on it. As
        // one ternary they shared a radius, so the carried row's glow and the
        // focused row's depth had to meet in the middle at fourteen and
        // neither got what it wanted.
        .shadow(color: isPicked ? LineupStyle.lightPurple.opacity(0.2) : .clear, radius: 24, y: 8)
        .lineupShadow(.lifted, on: isFocused && !isPicked)
        .zIndex(isPicked ? 2 : (isFocused ? 1 : 0))
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isFocused)
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: isPicked)
    }

    private func select(_ stream: XtreamStream) {
        guard let pickedStreamID else {
            self.pickedStreamID = stream.id
            return
        }
        guard pickedStreamID != stream.id else {
            self.pickedStreamID = nil
            return
        }
        guard let source = favorites.firstIndex(where: { $0.id == pickedStreamID }),
              let destination = favorites.firstIndex(where: { $0.id == stream.id }) else {
            self.pickedStreamID = nil
            return
        }
        library.moveFavorites(favorites, fromOffsets: IndexSet(integer: source),
            toOffset: destination > source ? destination + 1 : destination)
        self.pickedStreamID = nil
        focusedStreamID = pickedStreamID
    }
}

private struct TVReorderDoneButton: View {
    @FocusState private var focused: Bool
    let action: () -> Void

    var body: some View {
        Label("Done", systemImage: "checkmark")
            .font(.inter(.callout, .semibold))
            .padding(.horizontal, 20).frame(height: 46)
            .background(LineupStyle.lightPurple.opacity(0.09), in: Capsule())
            .foregroundStyle(LineupStyle.lightPurple)
            .overlay(Capsule().stroke(LineupStyle.lightPurple.opacity(0.16), lineWidth: 1))
            .contentShape(Capsule())
            .focusable().focused($focused).focusEffectDisabled()
            .onTapGesture(perform: action)
            .focusLift(focused, scale: LineupStyle.controlLift)
    }
}

private func guideProgramX(_ program: CurrentProgram, now: Date, layout: GuideLayout) -> CGFloat {
    let anchor = guideTimelineAnchor(now)
    let visibleStart = max(program.start, anchor)
    return max(0, CGFloat(visibleStart.timeIntervalSince(anchor) / 1800) * layout.slotWidth)
}

private func guideProgramWidth(_ program: CurrentProgram, now: Date, layout: GuideLayout) -> CGFloat {
    let anchor = guideTimelineAnchor(now)
    let windowEnd = anchor.addingTimeInterval(Double(guideVisibleSlotCount) * 1800)
    let visibleStart = max(program.start, anchor)
    let visibleEnd = min(program.end, windowEnd)
    let durationWidth = CGFloat(max(0, visibleEnd.timeIntervalSince(visibleStart)) / 1800) * layout.slotWidth
    return max(1, durationWidth - 6)
}

private struct GuideProgramCell: View {
    @Environment(\.guideLayout) private var layout
    let program: CurrentProgram?
    let empty: String
    let quality: String?
    let now: Date
    let showsTime: Bool
    let onPlay: () -> Void
    let onFocus: () -> Void
    let gridFocus: FocusState<GuideGridFocus?>.Binding
    let focusID: GuideGridFocus
    let opensSidebar: Bool
    let onOpenSidebar: () -> Void
    private var isFocused: Bool { gridFocus.wrappedValue == focusID }

    private var isOnNow: Bool {
        guard let program else { return false }
        return program.start <= now && now < program.end
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let program {
                HStack(spacing: 6) {
                    Text(program.title.isEmpty ? "Untitled" : program.title).foregroundColor(LineupStyle.lightPurple).font(.inter(.callout, .medium)).foregroundStyle(GuidePalette.text).lineLimit(1)
                    if isOnNow { GuideLiveDot() }
                    else if program.isNew == true { GuideInlineStatus(title: "NEW") }
                }
                if showsTime {
                    HStack(spacing: 7) {
                        Text(guideTimeRange(program)).foregroundColor(LineupStyle.lightPurple)
                            .font(.interDigits(.callout)).foregroundStyle(GuidePalette.secondary)
                        if let quality { GuideTinyBadge(title: quality, color: GuidePalette.raised) }
                    }
                }
            } else {
                Text(empty).foregroundColor(LineupStyle.lightPurple).font(.inter(.callout)).foregroundStyle(GuidePalette.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: layout.rowHeight - 8, alignment: .topLeading)
        .background {
            GeometryReader { geometry in
                LinearGradient(
                    colors: isFocused
                        ? [GuidePalette.cardFocused, GuidePalette.cardFocused.opacity(0.88)]
                        : [GuidePalette.card, GuidePalette.card.opacity(0.88)],
                    startPoint: .top, endPoint: .bottom)
                // Filled in behind the line, in a lighter shade of it. The
                // accent itself was tried here and covers most of every cell
                // in an evening, which read as the ground having gone blue.
                // Lighter, and over a card that is itself a step lighter, the
                // same colour reads as fill.
                if let program {
                    let elapsedWidth = GuideProgress.playedWidth(
                        start: program.start, end: program.end, now: now,
                        visibleStart: guideTimelineAnchor(now),
                        pointsPerSecond: Double(layout.slotWidth) / 1800,
                        cellWidth: Double(geometry.size.width))
                    GuidePalette.progressFill.opacity(0.16)
                        .frame(width: CGFloat(elapsedWidth))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(
            isFocused ? GuidePalette.focusRing.opacity(0.9) : GuidePalette.line.opacity(0.55),
            lineWidth: isFocused ? 2 : 0.5
        ))
        .shadow(color: isFocused ? GuidePalette.focusRing.opacity(0.14) : .clear, radius: 12, y: 5)
        .contentShape(Rectangle()).focusable().focused(gridFocus, equals: focusID).focusEffectDisabled().onTapGesture(perform: onPlay)
        // Keep the focused block in timeline coordinates so its fill stays aligned.
        .onChange(of: isFocused) { focused in if focused { onFocus() } }
        .modifier(GuideLeftBoundary(enabled: opensSidebar, onOpen: onOpenSidebar))
    }
}

/// On now, as a dot that breathes.
///
/// This was a pill reading LIVE: a word, a capsule, a border and a tint,
/// repeated down every row of a grid whose whole left-hand column is on now.
/// Four pieces of ink for one fact, and the word competed with the programme
/// title beside it. A dot says it instead, and the pulse is the part that
/// means *now* -- a still dot is a bullet point.
private struct GuideLiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(GuidePalette.highlight)
            .frame(width: size, height: size)
            // Reduced motion keeps the dot, at the brighter end of the pulse.
            .opacity(reduceMotion || pulsing ? 1 : 0.38)
            .shadow(color: GuidePalette.highlight.opacity(reduceMotion || pulsing ? 0.55 : 0.12),
                    radius: size * 0.55)
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.6).repeatForever(autoreverses: true),
                       value: pulsing)
            .onAppear { pulsing = true }
            .accessibilityLabel("On now")
    }
}

private struct GuideInlineStatus: View {
    let title: String
    // Only NEW reaches this now that being on the air is a dot.
    private var accent: Color { GuidePalette.upcomingMark }
    var body: some View {
        Text(title)
            .font(.inter(10, .heavy)).tracking(1.3)
            .foregroundStyle(accent)
            .padding(.horizontal, 8).frame(height: 20)
            .background(accent.opacity(0.14), in: Capsule())
            .overlay(Capsule().stroke(accent.opacity(0.34), lineWidth: 0.75))
    }
}

struct AccountView: View {
    @EnvironmentObject private var library: SportsLibrary
    @EnvironmentObject private var media: MediaLibrary
    @EnvironmentObject private var reminders: GameReminders
    @EnvironmentObject private var cloud: CloudSettingsSync
    @State private var addingMediaServer = false
    @AppStorage(LineupTheme.storageKey) private var selectedTheme = LineupTheme.signal.rawValue
    var body: some View {
        NavigationStack {
            // Scrolling, because the panels already filled the screen before
            // appearance was one of them.
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    ScreenHeading(title: "Account", detail: "Provider and app details")
                    DetailPanel(title: "FOLLOW TEAMS") {
                        if reminders.availableTeams(in: library.games(for: nil)).isEmpty {
                            AccountRow(label: "Teams", value: "Teams appear when a schedule is available")
                        }
                        ForEach(reminders.availableTeams(in: library.games(for: nil))) { team in
                            Button {
                                reminders.toggleTeam(team)
                            } label: {
                                AccountRow(label: "\(team.name) · \(team.league.shortName)",
                                           value: reminders.follows(team) ? "Following" : "Follow")
                            }
                            .buttonStyle(.plain)
                        }
                        if let message = reminders.authorizationMessage {
                            AccountRow(label: "Notifications", value: message)
                        }
                    }
                    DetailPanel(title: "APPEARANCE") {
                        HStack(spacing: 20) {
                            ForEach(LineupTheme.allCases) { theme in
                                TVSelectable(scale: LineupStyle.cardLift, fill: LineupStyle.focused, fillRadius: 14,
                                    action: { selectedTheme = theme.rawValue }) {
                                    ThemeCard(theme: theme, active: selectedTheme == theme.rawValue)
                                }
                            }
                        }
                    }
                    if let profile = library.activeProfile {
                        DetailPanel(title: "PROVIDER") {
                            AccountRow(label: "Profile", value: profile.name)
                            Divider().overlay(LineupStyle.line)
                            AccountRow(label: "Server", value: profile.serverURL)
                            Divider().overlay(LineupStyle.line)
                            AccountRow(label: "Username", value: profile.username)
                        }
                        Button("Remove provider", role: .destructive) { library.removeActiveProfile() }
                            .lineupButtonStyle()
                    }
                    DetailPanel(title: "MEDIA SERVERS") {
                        if media.profiles.isEmpty {
                            AccountRow(label: "Status", value: "Not connected")
                        } else {
                            ForEach(media.profiles) { profile in
                                HStack(spacing: 20) {
                                    Button {
                                        Task { await media.select(profile) }
                                    } label: {
                                        AccountRow(label: profile.name,
                                            value: media.activeProfile?.id == profile.id ? "Active" : "Select")
                                    }
                                    .lineupFlatButton()
                                    Button("Remove", role: .destructive) { media.remove(profile) }
                                        .lineupButtonStyle()
                                }
                            }
                        }
                    }
                    Button("Add Media Server", systemImage: "plus") { addingMediaServer = true }
                        .lineupButtonStyle()
                    NavigationLink("Channel matching") { MatchDiagnosticsView() }
                        .lineupButtonStyle()
                    DetailPanel(title: "ABOUT") {
                        AccountRow(label: "iCloud", value: cloud.status)
                        AccountRow(label: "Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.1")
                    }
                }
                .padding(.horizontal, 120).padding(.vertical, 48)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(LineupStyle.background)
            .onChange(of: selectedTheme) { _, _ in CloudSettingsSync.shared.localSettingsChanged() }
            .sheet(isPresented: $addingMediaServer) {
                MediaServerSetupView().environmentObject(media)
            }
        }
    }
}

/// A theme is a set of colours, so the card is painted in them rather than
/// named in the current one: the choice looks like what it does.
private struct ThemeCard: View {
    let theme: LineupTheme
    let active: Bool

    var body: some View {
        HStack(spacing: 16) {
            LineupThemeSwatch(theme: theme)
            VStack(alignment: .leading, spacing: 3) {
                Text(theme.name).font(.inter(21, .semibold))
                Text(theme.detail).font(.inter(14)).opacity(0.6)
            }
            Spacer(minLength: 12)
            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                .font(.inter(22, .semibold))
                .foregroundStyle(active ? LineupStyle.highlight : LineupStyle.lightPurple.opacity(0.28))
        }
        .foregroundStyle(LineupStyle.lightPurple)
        .padding(.horizontal, 22).padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(active ? LineupStyle.raised : LineupStyle.surface,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(active ? LineupStyle.highlight.opacity(0.55) : LineupStyle.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(theme.name + ", " + theme.detail)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

/// Why each game matched the channel it did. A game that opens the wrong feed
/// should be able to name the rule that chose it, without a device log.
private struct MatchDiagnosticsView: View {
    @EnvironmentObject private var library: SportsLibrary

    private var games: [SportsGame] {
        library.games(for: nil).filter { $0.isLive || $0.isUpcoming }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                ScreenHeading(title: "Channel matching", detail: "The rule that chose each game's channel")
                Spacer()
                if !library.automaticMatchingReady { RefreshingStreamsLabel() }
            }
            if games.isEmpty {
                Text("No live or upcoming games to match.").foregroundColor(LineupStyle.lightPurple)
                    .font(.inter(.title3)).foregroundStyle(LineupStyle.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(games) { MatchDiagnosticsRow(game: $0) }
                }.padding(.vertical, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 120).padding(.vertical, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LineupStyle.background)
    }
}

private struct MatchDiagnosticsRow: View {
    @EnvironmentObject private var library: SportsLibrary
    @FocusState private var focused: Bool
    let game: SportsGame

    private var stream: XtreamStream? { library.stream(for: game) }
    private var evidence: SportsLibrary.MatchEvidence? { library.matchEvidence(for: game) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(game.awayTeam) at \(game.homeTeam)").foregroundColor(LineupStyle.lightPurple)
                .font(.inter(24, .semibold))
            Text("\(game.league.shortName)  ·  \(game.broadcast.isEmpty ? "No network listed" : game.broadcast)")
                .foregroundColor(LineupStyle.lightPurple)
                .font(.inter(16)).foregroundStyle(LineupStyle.secondary)
            if let stream {
                Text(stream.name).foregroundColor(LineupStyle.lightPurple)
                    .font(.inter(17, .medium)).lineLimit(1)
                if let rejection = library.playbackRejection(for: game) {
                    Text(rejection.rawValue).foregroundColor(LineupStyle.warning).font(.inter(15))
                } else {
                    Text(evidence?.rawValue ?? "Matched earlier, evidence not recorded yet")
                        .foregroundColor(evidence == .dedicatedFeed ? LineupStyle.lightPurple : LineupStyle.warning)
                        .font(.inter(15))
                }
            } else {
                Text("No match — opens the channel picker").foregroundColor(LineupStyle.lightPurple)
                    .font(.inter(15)).foregroundStyle(LineupStyle.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(focused ? LineupStyle.focused : LineupStyle.surface,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .focusable().focused($focused).focusEffectDisabled()
        .accessibilityElement(children: .combine)
    }
}

private struct DetailPanel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).foregroundColor(LineupStyle.lightPurple).font(.inter(.caption, .bold)).tracking(1.5).foregroundStyle(LineupStyle.secondary)
            VStack(spacing: 0) { content }.padding(.horizontal, 24).background(LineupStyle.surface)
        }
    }
}

private struct AccountRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .top, spacing: 30) {
            Text(label).foregroundColor(LineupStyle.lightPurple).foregroundStyle(LineupStyle.text); Spacer()
            Text(value).foregroundColor(LineupStyle.lightPurple).foregroundStyle(LineupStyle.secondary).multilineTextAlignment(.trailing).lineLimit(3)
        }.padding(.vertical, 18)
    }
}

private struct MultiviewView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedPane: Int?
    @State private var expandedPane: Int?
    let primary: XtreamStream
    let secondary: XtreamStream
    let primaryURLs: [URL]
    let secondaryURLs: [URL]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let expandedPane {
                MultiviewPane(
                    title: expandedPane == 0 ? primary.name : secondary.name,
                    urls: expandedPane == 0 ? primaryURLs : secondaryURLs,
                    audible: true,
                    expanded: true,
                    onExpand: {}
                )
            } else {
                HStack(spacing: 2) {
                    MultiviewPane(title: primary.name, urls: primaryURLs, audible: focusedPane == 0, expanded: false) {
                        expandedPane = 0
                    }
                    .focusable().focused($focusedPane, equals: 0).focusEffectDisabled()

                    MultiviewPane(title: secondary.name, urls: secondaryURLs, audible: focusedPane == 1, expanded: false) {
                        expandedPane = 1
                    }
                    .focusable().focused($focusedPane, equals: 1).focusEffectDisabled()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            }
        }
        .onAppear { focusedPane = 0 }
        .onExitCommand {
            if expandedPane != nil { expandedPane = nil }
            else { dismiss() }
        }
    }
}

private struct MultiviewPane: View {
    @StateObject private var controller = VLCPlaybackController()
    let title: String
    let urls: [URL]
    let audible: Bool
    let expanded: Bool
    let onExpand: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            VLCVideoSurface(player: controller.player).overlay { TVPlaybackStatus(controller: controller) }.background(Color.black)
            if urls.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle").font(.title2)
                    Text("Stream unavailable").foregroundColor(LineupStyle.lightPurple).font(.inter(.headline))
                }
                .foregroundStyle(LineupStyle.lightPurple).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 10) {
                Image(systemName: audible ? "speaker.wave.2.fill" : "speaker.slash.fill")
                Text(title).foregroundColor(LineupStyle.lightPurple).font(.inter(.callout, .semibold)).lineLimit(1)
                Spacer()
                if !expanded { Text("SELECT TO EXPAND").foregroundColor(LineupStyle.lightPurple).font(.inter(.caption2, .bold)).tracking(1.1) }
            }
            .foregroundStyle(LineupStyle.lightPurple)
            .padding(.horizontal, 18).frame(height: 50)
            .background(Color.black.opacity(0.56))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 0, style: .continuous))
        .overlay {
            if !expanded {
                RoundedRectangle(cornerRadius: 0, style: .continuous)
                    .stroke(audible ? LineupStyle.lightPurple.opacity(0.92) : LineupStyle.lightPurple.opacity(0.18), lineWidth: audible ? 3 : 1)
            }
        }
        .scaleEffect(!expanded && audible ? 1.012 : 1)
        .shadow(color: !expanded && audible ? LineupStyle.lightPurple.opacity(0.16) : .clear, radius: 18)
        .animation(.easeOut(duration: 0.18), value: audible)
        .contentShape(Rectangle()).onTapGesture(perform: onExpand)
        .contextMenu {
            Button("Retry Stream", systemImage: "arrow.clockwise") {
                controller.start(urls: urls, muted: !audible)
            }
        }
        .onAppear { controller.start(urls: urls, muted: !audible) }
        .onChange(of: audible) { _, value in controller.setMuted(!value) }
        .onDisappear { controller.stop() }
    }
}

struct PlayerView: View {
    @Environment(\.dismiss) private var dismiss
    let urls: [URL]
    var title: String = "Live TV"
    var program: CurrentProgram?
    var isLive = true
    @StateObject private var controller = VLCPlaybackController()
    @State private var controlsVisible = true
    @State private var hideControlsTask: Task<Void, Never>?
    @FocusState private var focusedControl: TVPlayerControl?
    @FocusState private var surfaceFocused: Bool

    var body: some View {
        ZStack {
            VLCVideoSurface(player: controller.player)
                .overlay { TVPlaybackStatus(controller: controller) }
                .background(Color.black).ignoresSafeArea()
            // Hiding the chrome removes every focusable view, and the remote
            // only reaches a view that holds focus, so this stands in for it
            // and summons the chrome back on any press.
            //
            // It is a sibling of the video rather than a set of modifiers on
            // their shared container. A modifier that comes and goes gives the
            // container a new identity, which rebuilds the video surface with
            // it, and a rebuilt surface loses the drawable VLC is decoding
            // into: the picture stops while the audio carries on. Siblings
            // appear and disappear without disturbing the surface, which is
            // why the chrome itself has always been safe to toggle.
            //
            // Nothing consumes a direction while the chrome is up either, so
            // focus can move between the seek bar and the buttons.
            if !controlsVisible {
                Color.clear
                    .contentShape(Rectangle())
                    .focusable()
                    .focused($surfaceFocused)
                    .onMoveCommand { _ in revealControls(focus: true) }
                    .onTapGesture { revealControls(focus: true) }
            }
            if controlsVisible && controller.error == nil {
                TVPlayerChrome(title: title, program: program, isLive: isLive, controller: controller,
                    focusedControl: $focusedControl, onInteraction: keepControlsVisible)
                    .transition(.opacity)
            }
            if urls.isEmpty {
                Text("This stream is unavailable").font(.inter(.title2))
                    .foregroundStyle(LineupStyle.lightPurple).padding(60)
            }
        }
        .background(Color.black)
        .onPlayPauseCommand { controller.togglePlayback(); revealControls() }
        .onExitCommand { controller.stop(); dismiss() }
        .onAppear { controller.start(urls: urls); revealControls(focus: true) }
        .onDisappear { hideControlsTask?.cancel(); controller.stop() }
        .onChange(of: controller.isPlaying) { _, playing in
            if playing { scheduleAutoHide() }
            else { hideControlsTask?.cancel(); controlsVisible = true }
        }
        .animation(.easeInOut(duration: 0.22), value: controlsVisible)
    }

    private func revealControls(focus: Bool = false) {
        controlsVisible = true
        if focus {
            Task { @MainActor in await Task.yield(); focusedControl = .playPause }
        }
        scheduleAutoHide()
    }

    private func keepControlsVisible() { controlsVisible = true; scheduleAutoHide() }

    private func scheduleAutoHide() {
        hideControlsTask?.cancel()
        guard controller.isPlaying else { return }
        hideControlsTask = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard !Task.isCancelled else { return }
            controlsVisible = false
            // Hand focus to the video surface as the chrome leaves, so the next
            // press on the remote has somewhere to arrive.
            await Task.yield()
            surfaceFocused = true
        }
    }
}

private enum TVPlayerControl: Hashable { case scrubber, playPause, goLive, mute, quality }

private struct TVPlayerChrome: View {
    @State private var showingQuality = false
    let title: String
    let program: CurrentProgram?
    let isLive: Bool
    @ObservedObject var controller: VLCPlaybackController
    let focusedControl: FocusState<TVPlayerControl?>.Binding
    let onInteraction: () -> Void

    private var nowPlayingTitle: String {
        guard let program, !program.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return title }
        return program.title
    }
    private var subtitle: String? {
        guard let program else { return title == nowPlayingTitle ? nil : title }
        let time = "\(program.start.formatted(date: .omitted, time: .shortened)) – \(program.end.formatted(date: .omitted, time: .shortened))"
        return title == nowPlayingTitle ? time : "\(title)  ·  \(time)"
    }

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.72), .black.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 230)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 9) {
                            Circle().fill(LineupStyle.lightPurple).frame(width: 8, height: 8)
                            Text(isLive ? (controller.isAtLiveEdge ? "LIVE" : "BEHIND LIVE") : "NOW PLAYING")
                                .font(.inter(15, .bold)).tracking(1.5)
                        }
                        Text(nowPlayingTitle).font(.inter(36, .semibold)).lineLimit(1)
                        if let subtitle { Text(subtitle).font(.inter(19, .medium)).opacity(0.78).lineLimit(1) }
                        if let detail = program?.detail, !detail.isEmpty {
                            Text(detail).font(.inter(16)).opacity(0.62).lineLimit(1)
                        }
                    }
                    .foregroundStyle(LineupStyle.lightPurple)
                    .padding(.horizontal, 72).padding(.top, 48)
                }
            Spacer()
            LinearGradient(colors: [.clear, .black.opacity(0.34), .black.opacity(0.88)], startPoint: .top, endPoint: .bottom)
                .frame(height: 270)
                .overlay(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 26) {
                    if !isLive && controller.duration > 0 {
                        TVSeekBar(controller: controller, focus: focusedControl,
                                  onInteraction: onInteraction)
                    }
                    HStack(spacing: 14) {
                        TVPlayerButton(title: controller.isPlaying ? "Pause" : "Play",
                            symbol: controller.isPlaying ? "pause.fill" : "play.fill", prominent: true,
                            focus: focusedControl, id: .playPause) { controller.togglePlayback(); onInteraction() }
                        TVPlayerButton(title: isLive ? (controller.isAtLiveEdge ? "Live" : "Go Live") : "Restart",
                            symbol: isLive ? "dot.radiowaves.left.and.right" : "backward.end.fill",
                            badge: isLive && controller.isAtLiveEdge, focus: focusedControl, id: .goLive) {
                                controller.goLive(); onInteraction()
                            }
                        TVPlayerButton(title: controller.isMuted ? "Unmute" : "Mute",
                            symbol: controller.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                            focus: focusedControl, id: .mute) { controller.toggleMute(); onInteraction() }
                        // A Menu renders through tvOS's own chrome, so this is a
                        // plain selectable with a dialog, like every other control.
                        TVSelectable(scale: LineupStyle.controlLift, action: { showingQuality = true }) {
                            TVPlayerMenuLabel(title: "Quality · \(controller.qualityLabel)",
                                              focused: focusedControl.wrappedValue == .quality)
                        }
                        .focused(focusedControl, equals: .quality)
                        .confirmationDialog("Quality · \(controller.qualityLabel)",
                                            isPresented: $showingQuality, titleVisibility: .visible) {
                            Button(isLive ? "Refresh stream" : "Restart playback") {
                                controller.goLive(); onInteraction()
                            }
                            Button("Cancel", role: .cancel) { onInteraction() }
                        }
                        Spacer(minLength: 0)
                    }
                    }
                    .padding(.horizontal, 72).padding(.bottom, 52)
                }
        }
        .ignoresSafeArea()
    }
}

/// A minimal transport bar for recorded media.
///
/// Left and right step ten seconds, and because tvOS repeats a held
/// direction the same press scrubs continuously. Down hands focus back to the
/// controls explicitly: onMoveCommand consumes the press, so without that the
/// bar would keep focus and trap the viewer on it.
private struct TVSeekBar: View {
    @ObservedObject var controller: VLCPlaybackController
    let focus: FocusState<TVPlayerControl?>.Binding
    let onInteraction: () -> Void

    private var progress: Double {
        guard controller.duration > 0 else { return 0 }
        return min(max(controller.elapsed / controller.duration, 0), 1)
    }

    var body: some View {
        let selected = focus.wrappedValue == .scrubber
        VStack(spacing: 10) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(LineupStyle.lightPurple.opacity(0.18))
                    Capsule().fill(LineupStyle.lightPurple)
                        .frame(width: max(0, geometry.size.width * progress))
                }
            }
            .frame(height: selected ? 10 : 6)
            HStack {
                Text(Self.clock(controller.elapsed))
                Spacer(minLength: 0)
                Text("-" + Self.clock(max(0, controller.duration - controller.elapsed)))
            }
            .font(.interDigits(15, .semibold))
            .foregroundStyle(LineupStyle.lightPurple.opacity(selected ? 1 : 0.68))
        }
        .contentShape(Rectangle())
        .focusable()
        .focused(focus, equals: .scrubber)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .left: controller.seek(by: -10)
            case .right: controller.seek(by: 10)
            case .down, .up: focus.wrappedValue = .playPause
            default: break
            }
            onInteraction()
        }
        .animation(.easeOut(duration: 0.18), value: selected)
        .accessibilityLabel("Playback position")
        .accessibilityValue(Self.clock(controller.elapsed) + " of " + Self.clock(controller.duration))
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

private struct TVPlayerButton: View {
    let title: String
    let symbol: String
    var prominent = false
    var badge = false
    let focus: FocusState<TVPlayerControl?>.Binding
    let id: TVPlayerControl
    let action: () -> Void

    var body: some View {
        let selected = focus.wrappedValue == id
        Button(action: action) {
            HStack(spacing: 10) {
                if badge { Circle().fill(LineupStyle.lightPurple).frame(width: 7, height: 7) }
                Image(systemName: symbol).font(.system(size: 18, weight: .bold)).frame(width: 22)
                Text(title).font(.inter(18, .semibold)).fixedSize()
            }
            .foregroundStyle(LineupStyle.lightPurple)
            .padding(.horizontal, 18).frame(height: 52)
            .background(selected || prominent ? LineupStyle.focused : LineupStyle.surface.opacity(0.88),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(LineupStyle.lightPurple.opacity(0.16), lineWidth: 1))
            .lineupShadow(.resting)
            .scaleEffect(selected ? LineupStyle.controlLift : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.76), value: selected)
        }
        // The button draws its own focus state, so tvOS's plate would sit on top
        // of it as a second, larger highlight.
        .lineupFlatButton().focused(focus, equals: id).focusEffectDisabled()
        .accessibilityLabel(title)
    }
}

private struct TVPlayerMenuLabel: View {
    let title: String
    let focused: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "gearshape.fill").font(.system(size: 17, weight: .bold))
            Text(title).font(.inter(18, .semibold)).fixedSize()
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .bold)).opacity(0.72)
        }
        .foregroundStyle(LineupStyle.lightPurple)
        .padding(.horizontal, 18).frame(height: 52)
        .background(focused ? LineupStyle.focused : LineupStyle.surface.opacity(0.88),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .stroke(LineupStyle.lightPurple.opacity(0.16), lineWidth: 1))
        .scaleEffect(focused ? LineupStyle.controlLift : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.76), value: focused)
    }
}

@MainActor private final class VLCPlaybackController: ObservableObject {
    let player = VLCMediaPlayer()
    @Published private(set) var reconnecting = false
    @Published private(set) var error: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var isMuted = false
    @Published private(set) var videoHeight = 0
    /// Seconds. Zero duration means the item is not seekable, which is how a
    /// live channel presents, so the seek bar simply does not appear for it.
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    private var monitor: Task<Void, Never>?
    private var urls: [URL] = []
    private var urlIndex = 0
    private var muted = false
    private var pausedByUser = false
    private var health = LivePlaybackHealth(now: ProcessInfo.processInfo.systemUptime)
    private var retries = LivePlaybackRetry()
    private var retryAt: TimeInterval?

    var isAtLiveEdge: Bool { isPlaying && !pausedByUser }
    var qualityLabel: String {
        switch videoHeight {
        case 2160...: "4K"
        case 1440...: "1440p"
        case 1080...: "1080p"
        case 720...: "720p"
        case 480...: "480p"
        case 1...: "\(videoHeight)p"
        default: "Auto"
        }
    }

    func start(urls: [URL], muted: Bool = false) {
        stop()
        self.urls = Array(urls.reversed())
        self.muted = muted
        retries.reset()
        urlIndex = 0
        error = nil
        guard !self.urls.isEmpty else { error = "This stream is unavailable."; return }
        openCurrent()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self else { return }
                self.checkPlayback()
            }
        }
    }

    private func openCurrent() {
        player.stop()
        let media = VLCMedia(url: urls[urlIndex])
        media.addOption(":network-caching=5000")
        media.addOption(":live-caching=5000")
        media.addOption(":http-reconnect=true")
        player.media = media
        health = LivePlaybackHealth(now: ProcessInfo.processInfo.systemUptime)
        retryAt = nil
        setMuted(muted)
        player.play()
        setMuted(muted)
    }

    /// Position has to keep updating while paused too, so the bar still reads
    /// correctly after a seek that the viewer makes without resuming.
    private func updateProgress() {
        let length = Double(player.media?.length.intValue ?? 0) / 1000
        if length > 0 { duration = length }
        let time = Double(player.time.intValue) / 1000
        elapsed = duration > 0 ? min(max(time, 0), duration) : max(time, 0)
    }

    /// Steps by `seconds` and clamps inside the item. Uses `position` rather
    /// than a time jump because it is the one seek API this VLCKit exposes
    /// consistently.
    func seek(by seconds: TimeInterval) {
        guard duration > 0 else { return }
        let target = min(max(elapsed + seconds, 0), max(duration - 1, 0))
        player.position = Float(target / duration)
        elapsed = target
    }

    private func checkPlayback() {
        updateProgress()
        guard !pausedByUser, error == nil, !urls.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard UIApplication.shared.applicationState == .active else {
            health = LivePlaybackHealth(now: now)
            return
        }
        if let retryAt {
            if now >= retryAt { openCurrent() }
            return
        }
        let failed = player.state == .error || player.state == .ended || player.state == .stopped
        player.audio?.isMuted = muted
        let recover = health.observe(now: now, playing: player.isPlaying, video: player.hasVideoOut,
            time: player.time.intValue, frames: player.media?.numberOfDisplayedPictures, failed: failed)
        if health.isStable(now: now) { retries.reset() }
        isPlaying = player.isPlaying
        if player.isPlaying && player.hasVideoOut {
            reconnecting = false
            let height = Int(player.videoSize.height)
            if height > 0 { videoHeight = height }
        }
        guard recover else { return }
        player.stop()
        guard let delay = retries.nextDelay() else {
            error = "The stream disconnected. Select Retry to reconnect."
            reconnecting = false
            return
        }
        // Retry the current transport once, then try the channel's alternatives.
        if retries.attempts > 1 { urlIndex = (urlIndex + 1) % urls.count }
        reconnecting = true
        retryAt = now + delay
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
        isMuted = muted
        player.audio?.isMuted = muted
    }
    func toggleMute() { setMuted(!muted) }
    func retry() { start(urls: Array(urls.reversed()), muted: muted) }
    func goLive() {
        guard !urls.isEmpty else { return }
        start(urls: Array(urls.reversed()), muted: muted)
    }
    func togglePlayback() {
        pausedByUser.toggle()
        if pausedByUser { player.pause() }
        else {
            health = LivePlaybackHealth(now: ProcessInfo.processInfo.systemUptime)
            if retryAt == nil { player.play() }
        }
        isPlaying = player.isPlaying
    }
    func stop() {
        monitor?.cancel()
        monitor = nil
        retryAt = nil
        urls = []
        pausedByUser = false
        reconnecting = false
        isPlaying = false
        videoHeight = 0
        player.stop()
        player.media = nil
    }
}
private struct TVPlaybackStatus: View {
    @ObservedObject var controller: VLCPlaybackController
    var body: some View {
        if let error = controller.error {
            VStack(spacing: 16) {
                Text(error).multilineTextAlignment(.center)
                // Over video this is the one thing focusable, so it carries the
                // app's own focus rather than a plate laid over the picture.
                Button("Retry", action: controller.retry).lineupButtonStyle()
            }
            .padding(24).background(Color.black.opacity(0.8))
        } else if controller.reconnecting {
            ProgressView("Reconnecting…").padding(24).background(Color.black.opacity(0.8))
        }
    }
}

private struct VLCVideoSurface: UIViewRepresentable {
    let player: VLCMediaPlayer
    func makeUIView(context: Context) -> UIView { let view = UIView(); view.backgroundColor = .black; player.drawable = view; return view }
    func updateUIView(_ uiView: UIView, context: Context) { if player.drawable == nil { player.drawable = uiView } }
}
