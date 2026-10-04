import SwiftUI
import UIKit
import VLCKitSPM

struct LiveView: View {
    @EnvironmentObject private var library: SportsLibrary
    let isActive: Bool
    @State private var selectedLeague: SportsLeague?
    @State private var selectedStream: XtreamStream?
    @State private var selectedGame: SportsGame?
    @State private var multiviewPrimary: XtreamStream?
    @State private var multiviewPrimaryGame: SportsGame?
    @State private var multiviewSession: MultiviewSession?
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
                    LiveScreen(
                        events: events,
                        selectedLeague: $selectedLeague,
                        previewStream: previewStream,
                        previewGame: events.first { $0.id == previewGameID },
                        previewURLs: previewStream.map { library.playbackURLs(for: $0) } ?? [],
                        multiviewPrimaryID: multiviewPrimary?.id,
                        multiviewTitle: multiviewPrimary?.name,
                        isScheduleLoading: library.isLoading || library.isScheduleLoading,
                        isScheduleAvailable: library.scheduleAvailable(for: selectedLeague),
                        scheduleErrorMessage: library.scheduleErrorMessage,
                        onPlay: select,
                        onStartMultiview: startMultiview,
                        onCancelMultiview: {
                            multiviewPrimary = nil
                            multiviewPrimaryGame = nil
                        },
                        onStopPreview: stopPreview
                    )
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
            .background(LiveCanvas())
            .fullScreenCover(item: $selectedStream) { stream in
                PlayerView(
                    urls: library.playbackURLs(for: stream),
                    title: stream.name,
                    program: library.guidePrograms(for: stream).normalizedEPG().first { $0.isLive },
                    game: selectedGame,
                    channelID: stream.id
                )
            }
            .sheet(item: $manualChannelGame) { game in
                ManualGameChannelPicker(game: game) { stream in
                    manualChannelGame = nil
                    library.saveGameSelection(stream, for: game)
                    if manualSelectionStartsMultiview {
                        stopPreview()
                        multiviewPrimary = stream
                        multiviewPrimaryGame = game
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
                    secondaryURLs: library.playbackURLs(for: session.secondary),
                    primaryGame: session.primaryGame,
                    secondaryGame: session.secondaryGame
                )
            }
            .task(id: isActive) {
                guard isActive else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch { return }
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
        if previewGameID == game.id, let previewStream {
            let resolved = library.resolvedStream(for: game)
            if let resolved {
                play(game, on: resolved)
                return
            }
            if previewWasManuallySelected {
                play(game, on: previewStream)
                return
            }
        }
        stopPreview()
        guard let stream = library.resolvedStream(for: game) else {
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
                    selectedGame = game
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
        multiviewSession = MultiviewSession(primary: primary, secondary: stream,
                                           primaryGame: multiviewPrimaryGame, secondaryGame: game)
        multiviewPrimaryGame = nil
    }

    private func startMultiview(_ game: SportsGame) {
        guard let stream = library.resolvedStream(for: game) else {
            handleUnmatchedSelection(game, startsMultiview: true)
            return
        }
        stopPreview()
        multiviewPrimary = stream
        multiviewPrimaryGame = game
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
            .foregroundStyle(selected || focused ? LineupStyle.text : LineupStyle.secondary)
            .padding(.horizontal, 12).frame(height: 49)
            .background(focused ? LiveBoardStyle.leagueFocus : (selected ? LineupStyle.lightPurple.opacity(0.07) : .clear))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .leading) {
                if selected && !focused { Rectangle().fill(LiveBoardStyle.accent).frame(width: 3, height: 22) }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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

// MARK: - Live

/// The Live tab's reading of the theme.
///
/// Every colour here comes from LineupStyle's charcoal, light grey and white.
/// The one colour that is not the theme's is broadcast red, and it only ever
/// means on air; the teams bring their own.
private enum LivePalette {
    static var text: Color { LineupStyle.text }
    static var secondary: Color { LineupStyle.secondary }
    static var card: Color { LineupStyle.surface }
    static var rule: Color { LineupStyle.line }
    static var accent: Color { LineupStyle.highlight }
    static var rim: Color { LineupStyle.liveSelectionBorder }
    static var onAir: Color { LineupStyle.liveDot }
    /// How strongly a matchup's colours light the wall behind the monitor.
    static let spill = 0.32
}

/// One grid for the whole tab.
private enum LiveMetrics {
    /// tvOS's own title-safe inset. The stage, the board and the score crawl
    /// all stop on it, so nothing sits in a television's overscan band and no
    /// edge on the screen stops in two places.
    static let margin: CGFloat = 80
    static let railWidth: CGFloat = 380
    static let gutter: CGFloat = 30
    static let columns = 4
    static let cardSpacing: CGFloat = 22
    static let cardHeight: CGFloat = 214
    /// Clear space around anything focusable inside a scroller, which clips:
    /// a focused card's lift and shadow grow into it.
    static let liftRoom: CGFloat = 18
    static let monitorRadius: CGFloat = 24
}

/// Which game the screen is describing.
///
/// The screen holds this in plain `@State`, which keeps it without watching
/// it, and only the views that describe the game observe it: the monitor, the
/// light behind it and the row counter. An arrow press redraws those three and
/// leaves every card and row where it is.
private final class LiveSpotlight: ObservableObject {
    @Published private(set) var gameID: String?
    @Published private(set) var boardRow = 0

    func rest(on game: SportsGame) {
        if gameID != game.id { gameID = game.id }
    }

    func rest(on game: SportsGame, row: Int) {
        rest(on: game)
        if boardRow != row { boardRow = row }
    }

    /// The game under the remote. Before the remote has rested anywhere, the
    /// first game on air, or failing that the first of the night.
    func game(in events: [SportsGame]) -> SportsGame? {
        if let gameID, let game = events.first(where: { $0.id == gameID }) { return game }
        return events.first(where: \.isLive) ?? events.first
    }
}

/// The Live tab: the viewer's teams beside a monitor, every matchup beneath.
///
/// The monitor never sits dark. Resting on a game puts that game's slate on
/// it -- the two crests, the score or the start, the building -- so the night
/// reads like a broadcast while the remote moves. Select cuts the monitor to
/// that game's feed; select again takes it full screen.
private struct LiveScreen: View {
    @EnvironmentObject private var library: SportsLibrary
    let events: [SportsGame]
    @Binding var selectedLeague: SportsLeague?
    let previewStream: XtreamStream?
    let previewGame: SportsGame?
    let previewURLs: [URL]
    let multiviewPrimaryID: Int?
    let multiviewTitle: String?
    let isScheduleLoading: Bool
    let isScheduleAvailable: Bool
    let scheduleErrorMessage: String?
    let onPlay: (SportsGame) -> Void
    let onStartMultiview: (SportsGame) -> Void
    let onCancelMultiview: () -> Void
    let onStopPreview: () -> Void
    @State private var spotlight = LiveSpotlight()

    var body: some View {
        VStack(spacing: 14) {
            stage
            LiveMatchupBoard(events: events, selectedLeague: $selectedLeague, spotlight: spotlight,
                             previewGameID: previewGame?.id, multiviewPrimaryID: multiviewPrimaryID,
                             multiviewTitle: multiviewTitle, isScheduleLoading: isScheduleLoading,
                             isScheduleAvailable: isScheduleAvailable,
                             onPlay: onPlay, onStartMultiview: onStartMultiview,
                             onCancelMultiview: onCancelMultiview)
        }
        .padding(.horizontal, LiveMetrics.margin)
        .padding(.top, 8)
        // The navigation stack insets its content by the safe area again,
        // which pushed the stage and the board in from the crawl's edge. The
        // screen keeps its own margins instead. Only the sides: below, the
        // inset is what keeps the board above the crawl.
        .ignoresSafeArea(.container, edges: .horizontal)
        .onExitCommand { if previewStream != nil { onStopPreview() } }
    }

    /// The viewer's teams and the monitor, sharing the top of the screen. The
    /// matchups run the full width beneath, so Down out of the rail lands in
    /// them.
    ///
    /// The pair is one focus region. The monitor holds nothing to focus, so a
    /// press aimed at it -- Down from the tab bar, Up from the board -- would
    /// otherwise find nothing and be swallowed; as a region it arrives at the
    /// viewer's teams instead.
    private var stage: some View {
        HStack(alignment: .top, spacing: LiveMetrics.gutter) {
            LiveMyTeams(events: events, spotlight: spotlight, previewGameID: previewGame?.id,
                        multiviewPrimaryID: multiviewPrimaryID,
                        onPlay: onPlay, onStartMultiview: onStartMultiview)
                .frame(width: LiveMetrics.railWidth)
            LiveMonitor(spotlight: spotlight, events: events, previewStream: previewStream,
                        previewGame: previewGame, previewURLs: previewURLs,
                        isMultiview: multiviewTitle != nil, isPreparingStreams: isPreparingStreams,
                        isScheduleLoading: isScheduleLoading, isScheduleAvailable: isScheduleAvailable,
                        scheduleErrorMessage: scheduleErrorMessage)
        }
        .frame(maxHeight: .infinity)
        .background {
            HStack(spacing: 0) {
                Color.clear.frame(width: LiveMetrics.railWidth + LiveMetrics.gutter)
                LiveBiasLight(spotlight: spotlight, events: events, previewGame: previewGame)
            }
        }
        .lineupFocusRegion()
    }

    /// The same rule the phone uses, from the same file: work in flight is
    /// only a wait when there is nothing behind it.
    private var isPreparingStreams: Bool {
        let banner = LiveSyncBanner.choose(isInitialProviderSync: library.isInitialProviderSync,
                                           hasContent: library.hasRestoredCache,
                                           isScheduleLoading: library.isScheduleLoading,
                                           isLoading: library.isLoading,
                                           channelsAreSyncing: !library.automaticMatchingReady)
        return banner == .initialSync || banner == .refreshing
    }
}

/// The room the monitor stands in: the theme's ground, lifted a little
/// overhead and falling away towards the corners.
private struct LiveCanvas: View {
    var body: some View {
        ZStack {
            LineupStyle.background
            LinearGradient(colors: [LineupStyle.raised.opacity(0.26), .clear],
                           startPoint: .top, endPoint: .center)
            RadialGradient(colors: [.clear, .black.opacity(0.3)], center: .center,
                           startRadius: 520, endRadius: 1250)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The light a television throws on the wall behind it.
///
/// Each side of the matchup lights its own half in its own colour, so the
/// room changes with the game under the remote -- or with the game on the
/// monitor, while one is. Two gradients and no blur: nothing here costs more
/// than a fill.
private struct LiveBiasLight: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var spotlight: LiveSpotlight
    let events: [SportsGame]
    let previewGame: SportsGame?

    var body: some View {
        let game = previewGame ?? spotlight.game(in: events)
        let teams = game.map { !$0.isEvent } ?? false
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                // Seated low, so the light has faded to nothing before it
                // reaches the tab bar and spills mostly beside and beneath
                // the monitor, where a real set lights a wall.
                glow(liveTeamColor(teams ? game?.awayColor : nil))
                    .frame(width: size.width * 0.95, height: size.height * 1.3)
                    .position(x: size.width * 0.25, y: size.height * 0.62)
                glow(liveTeamColor(teams ? game?.homeColor : nil))
                    .frame(width: size.width * 0.95, height: size.height * 1.3)
                    .position(x: size.width * 0.75, y: size.height * 0.62)
            }
            .id(game?.id ?? "")
            .transition(.opacity)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: game?.id)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func glow(_ color: Color) -> some View {
        EllipticalGradient(colors: [color.opacity(LivePalette.spill), color.opacity(LivePalette.spill * 0.45), .clear],
                           center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
    }
}

/// The monitor. A slate while nothing is playing, the feed while one is.
private struct LiveMonitor: View {
    @EnvironmentObject private var library: SportsLibrary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var spotlight: LiveSpotlight
    let events: [SportsGame]
    let previewStream: XtreamStream?
    let previewGame: SportsGame?
    let previewURLs: [URL]
    let isMultiview: Bool
    let isPreparingStreams: Bool
    let isScheduleLoading: Bool
    let isScheduleAvailable: Bool
    let scheduleErrorMessage: String?

    var body: some View {
        let game = spotlight.game(in: events)
        let shape = RoundedRectangle(cornerRadius: LiveMetrics.monitorRadius, style: .continuous)
        ZStack {
            Color.black
            if let previewStream {
                LiveVideoWall(stream: previewStream, game: previewGame, urls: previewURLs)
                if let game {
                    LiveLowerThird(game: game, isOnScreen: game.id == previewGame?.id)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            } else if let game {
                LiveSlate(game: game, channel: library.stream(for: game)?.name,
                          hint: isPreparingStreams ? .refreshing : (isMultiview ? .secondGame : .preview))
                    .id(game.id)
                    .transition(.opacity)
            } else {
                LiveEmptySlate(isLoading: isScheduleLoading, isAvailable: isScheduleAvailable,
                               errorMessage: scheduleErrorMessage, isPreparingStreams: isPreparingStreams)
            }
            // Looking for channels is what this screen is for while nothing
            // plays, and the screen is where someone waiting is looking.
            if previewStream == nil && isPreparingStreams {
                LiveTVSignalSweep()
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: game?.id)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.05)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .lineupShadow(.overlay)
        .accessibilityLabel(previewStream == nil ? "Matchup slate" : "TV preview")
    }
}

/// What the monitor says it will do when Select is pressed.
private enum LiveHint {
    case preview, secondGame, refreshing
}

/// What the monitor shows for a game while nothing is playing.
///
/// Built like a broadcast's pre-game graphic. The two sides face each other
/// across a centre line, their colours lighting their own halves, and between
/// them is the one fact that matters right now: the score while it is on, the
/// start while it is not.
private struct LiveSlate: View {
    let game: SportsGame
    let channel: String?
    let hint: LiveHint

    var body: some View {
        GeometryReader { proxy in
            let crest = min(150, proxy.size.height * 0.27)
            ZStack {
                LiveSlateBackdrop(away: game.isEvent ? nil : game.awayColor,
                                  home: game.isEvent ? nil : game.homeColor)
                VStack(spacing: 0) {
                    header
                    Spacer(minLength: 10)
                    if game.isEvent {
                        event
                    } else {
                        HStack(alignment: .center, spacing: 0) {
                            LiveCrestColumn(name: game.awayTeam, abbreviation: game.awayAbbreviation,
                                            logo: game.awayLogo, record: game.awayRecord, crest: crest)
                                .frame(maxWidth: .infinity)
                            center
                                .frame(width: min(450, proxy.size.width * 0.34))
                            LiveCrestColumn(name: game.homeTeam, abbreviation: game.homeAbbreviation,
                                            logo: game.homeLogo, record: game.homeRecord, crest: crest)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    Spacer(minLength: 10)
                    footer
                }
                .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 30)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(liveAccessibilityLabel(game))
    }

    /// The broadcast bug: the league and its network on the left, and on the
    /// right a red LIVE tag, or when it starts.
    private var header: some View {
        HStack(spacing: 14) {
            LeagueLogo(league: game.isNFLRedZone ? .nfl : game.league, size: 32)
            Text(game.league.shortName).font(.inter(17, .bold)).tracking(2.4)
                .foregroundStyle(LivePalette.text)
            if let network = nonempty(game.broadcast) {
                Rectangle().fill(LivePalette.secondary.opacity(0.5)).frame(width: 1, height: 18)
                Text(network.uppercased()).font(.inter(17, .bold)).tracking(1.6)
                    .foregroundStyle(LivePalette.secondary).lineLimit(1)
            }
            Spacer(minLength: 20)
            if game.isLive {
                LiveOnAirTag()
            } else {
                Text(liveDayLabel(game.start)).font(.inter(15, .bold)).tracking(2.4)
                    .foregroundStyle(LivePalette.secondary)
            }
        }
    }

    @ViewBuilder private var center: some View {
        if game.isLive && !game.awayScore.isEmpty && !game.homeScore.isEmpty {
            let lead = liveLeader(game)
            VStack(spacing: 22) {
                HStack(alignment: .center, spacing: 22) {
                    Text(game.awayScore)
                        .foregroundStyle(lead == .home ? LivePalette.secondary : LivePalette.text)
                    Capsule().fill(LivePalette.secondary.opacity(0.55)).frame(width: 24, height: 5)
                    Text(game.homeScore)
                        .foregroundStyle(lead == .away ? LivePalette.secondary : LivePalette.text)
                }
                .font(.interDigits(104, .bold))
                .lineLimit(1).minimumScaleFactor(0.5)
                .contentTransition(.numericText())
                LiveStatusCapsule(status: game.status)
            }
        } else if game.isLive {
            LiveStatusCapsule(status: game.status)
        } else {
            let parts = liveTimeParts(game.start)
            VStack(spacing: 4) {
                Text(liveStartWord(game.league)).font(.inter(15, .bold)).tracking(3.2)
                    .foregroundStyle(LivePalette.secondary)
                (Text(parts.time).font(.interDigits(84, .semibold)).foregroundColor(LivePalette.text)
                 + Text(parts.period.map { " " + $0 } ?? "").font(.inter(32, .semibold))
                    .foregroundColor(LivePalette.secondary))
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
        }
    }

    /// A fight card or RedZone: one event rather than two sides, so its mark
    /// and its name take the middle.
    private var event: some View {
        VStack(spacing: 18) {
            LeagueLogo(league: game.isNFLRedZone ? .nfl : game.league, size: 92)
            Text(game.eventName ?? game.league.shortName)
                .font(.inter(46, .bold)).foregroundStyle(LivePalette.text)
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.6)
                .frame(maxWidth: 900)
            if game.isLive {
                LiveStatusCapsule(status: game.status)
            } else {
                Text("\(liveStartWord(game.league))  ·  \(game.startLabel.uppercased())")
                    .font(.interDigits(20, .bold)).tracking(2)
                    .foregroundStyle(LivePalette.secondary)
            }
        }
    }

    /// Where it is played, what Select will do, and the channel it will open.
    /// The two sides are containers even when empty, so a game with no venue
    /// or no matched channel still keeps the hint in the middle.
    private var footer: some View {
        HStack(alignment: .center, spacing: 20) {
            HStack(spacing: 8) {
                if let place = game.placeLine {
                    Image(systemName: "mappin").font(.system(size: 15, weight: .semibold))
                    Text(place).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            LiveActionHint(hint: hint)
            HStack(spacing: 8) {
                if let channel {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 15, weight: .semibold))
                    Text(channel).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.inter(17, .medium))
        .foregroundStyle(LivePalette.secondary)
    }
}

/// The slate's ground: black, each side's colour lifting its own half, and a
/// centre line and circle drawn faintly through the middle, the way every
/// field and floor and rink is marked.
private struct LiveSlateBackdrop: View {
    let away: String?
    let home: String?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                LinearGradient(colors: [Color(white: 0.085), .black], startPoint: .top, endPoint: .bottom)
                wash(liveTeamColor(away))
                    .frame(width: size.width * 0.62, height: size.height * 1.3)
                    .position(x: size.width * 0.15, y: size.height * 0.55)
                wash(liveTeamColor(home))
                    .frame(width: size.width * 0.62, height: size.height * 1.3)
                    .position(x: size.width * 0.85, y: size.height * 0.55)
                LiveCourtLines()
                RadialGradient(colors: [.clear, .black.opacity(0.55)], center: .center,
                               startRadius: size.height * 0.45, endRadius: size.width * 0.62)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func wash(_ color: Color) -> some View {
        EllipticalGradient(colors: [color.opacity(0.32), color.opacity(0.1), .clear],
                           center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
    }
}

/// A centre line and circle. The line fades out through the middle third so
/// it never runs through the score.
private struct LiveCourtLines: View {
    var body: some View {
        GeometryReader { proxy in
            let ring = proxy.size.height * 0.66
            ZStack {
                Rectangle()
                    .fill(LinearGradient(stops: [
                        .init(color: .white.opacity(0.06), location: 0),
                        .init(color: .clear, location: 0.3),
                        .init(color: .clear, location: 0.7),
                        .init(color: .white.opacity(0.06), location: 1)
                    ], startPoint: .top, endPoint: .bottom))
                    .frame(width: 2)
                Circle().strokeBorder(.white.opacity(0.05), lineWidth: 2)
                    .frame(width: ring, height: ring)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One side of a matchup on the slate.
private struct LiveCrestColumn: View {
    let name: String
    let abbreviation: String
    let logo: String
    let record: String?
    let crest: CGFloat

    var body: some View {
        VStack(spacing: 16) {
            LiveCrest(url: logo, fallback: abbreviation.isEmpty ? String(name.prefix(3)).uppercased() : abbreviation,
                      size: crest)
            VStack(spacing: 5) {
                Text(name).font(.inter(30, .semibold)).foregroundStyle(LivePalette.text)
                    .lineLimit(1).minimumScaleFactor(0.6)
                if let record = nonempty(record) {
                    Text(record).font(.interDigits(19, .medium)).foregroundStyle(LivePalette.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
    }
}

/// A crest at slate size, lit by its own silhouette the way TeamBadge lights a
/// small one, with the room around it that the glow needs. Flattened inside
/// its own frame, a blur this wide is cut square at the edges, and a square of
/// light behind a crest reads as a sticker.
private struct LiveCrest: View {
    let url: String
    let fallback: String
    let size: CGFloat

    var body: some View {
        let rim = max(3, size * 0.06)
        LineupArtView(url: URL(string: url), width: size) { loaded in
            if let image = loaded {
                let art = image.resizable().scaledToFit().frame(width: size, height: size)
                ZStack {
                    LineupStyle.logoPlate.mask { art.blur(radius: rim) }.opacity(0.6)
                    art
                }
                .frame(width: size + rim * 6, height: size + rim * 6)
                .drawingGroup()
                .frame(width: size, height: size)
            } else {
                Text(fallback)
                    .font(.inter(max(12, size * 0.28), .black))
                    .foregroundStyle(LivePalette.secondary)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
        }
        .frame(width: size, height: size)
        .transaction { $0.animation = nil }
        .accessibilityHidden(true)
    }
}

/// A broadcast's LIVE bug.
private struct LiveOnAirTag: View {
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(.white).frame(width: 7, height: 7)
            Text("LIVE").font(.inter(14, .heavy)).tracking(2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).frame(height: 30)
        .background(LivePalette.onAir, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Where a game on air stands -- the clock, the inning -- behind its red dot.
private struct LiveStatusCapsule: View {
    let status: String

    var body: some View {
        HStack(spacing: 11) {
            PulsingLiveDot(size: 9)
            Text(status.isEmpty ? "LIVE" : status.uppercased())
                .font(.inter(18, .bold)).tracking(1.8)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .foregroundStyle(LivePalette.text)
        .padding(.horizontal, 20).frame(height: 42)
        .background(Color.black.opacity(0.35), in: Capsule())
        .overlay(Capsule().strokeBorder(LivePalette.onAir.opacity(0.65), lineWidth: 1.5))
    }
}

/// What Select will do, said once, at the foot of the slate.
private struct LiveActionHint: View {
    let hint: LiveHint

    var body: some View {
        if hint == .refreshing {
            RefreshingStreamsLabel(size: .screen)
        } else {
            HStack(spacing: 10) {
                Image(systemName: hint == .secondGame ? "rectangle.split.2x1.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                Text(hint == .secondGame ? "SELECT TO WATCH SIDE BY SIDE" : "SELECT TO PREVIEW")
                    .font(.inter(15, .bold)).tracking(2.2)
            }
            .foregroundStyle(LivePalette.text)
            .padding(.horizontal, 22).frame(height: 44)
            .background(.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .fixedSize()
        }
    }
}

/// The slate with nothing to show: still dressed, never a black rectangle.
private struct LiveEmptySlate: View {
    let isLoading: Bool
    let isAvailable: Bool
    let errorMessage: String?
    let isPreparingStreams: Bool

    var body: some View {
        ZStack {
            LiveSlateBackdrop(away: nil, home: nil)
            VStack(spacing: 18) {
                Image(systemName: isLoading ? "antenna.radiowaves.left.and.right" : "sportscourt")
                    .font(.system(size: 52, weight: .ultraLight))
                    .foregroundStyle(LivePalette.secondary)
                Text(isLoading ? "Setting the board." :
                     (isAvailable ? "A moment between games." : "The schedule is unavailable."))
                    .font(.inter(46, .bold)).foregroundStyle(LivePalette.text)
                    .multilineTextAlignment(.center)
                Text(isLoading ? "Tonight's games will be here in a moment." :
                     (isAvailable ? "Come back for the next matchup." :
                        (errorMessage ?? "We’ll try again shortly.")))
                    .font(.inter(21)).foregroundStyle(LivePalette.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 680)
                if isPreparingStreams {
                    RefreshingStreamsLabel(size: .screen).padding(.top, 6)
                }
            }
            .padding(48)
        }
    }
}

/// The feed, at sixteen by nine, with the score either side of it.
///
/// The monitor is wider than a picture, so a playing feed always left two
/// black bars beside it. They carry each side's crest and score now, the way
/// a stadium hangs its scoreboards either side of the big screen.
private struct LiveVideoWall: View {
    let stream: XtreamStream
    let game: SportsGame?
    let urls: [URL]

    var body: some View {
        GeometryReader { proxy in
            let picture = min(proxy.size.width, proxy.size.height * 16 / 9)
            let flank = max(0, (proxy.size.width - picture) / 2)
            HStack(spacing: 0) {
                LiveFlank(game: game, isHome: false).frame(width: flank)
                LiveSelectedPreview(stream: stream, game: game, urls: urls)
                    .id(stream.id)
                    .frame(width: picture)
                    .overlay(alignment: .topLeading) { LiveTallyChip().padding(20) }
                LiveFlank(game: game, isHome: true).frame(width: flank)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// One side's scoreboard beside a playing feed.
private struct LiveFlank: View {
    let game: SportsGame?
    let isHome: Bool

    var body: some View {
        GeometryReader { proxy in
            if let game, !game.isEvent, proxy.size.width >= 140 {
                let score = isHome ? game.homeScore : game.awayScore
                let abbreviation = isHome ? game.homeAbbreviation : game.awayAbbreviation
                VStack(spacing: 12) {
                    LiveCrest(url: isHome ? game.homeLogo : game.awayLogo, fallback: abbreviation,
                              size: min(92, proxy.size.width * 0.5))
                    Text(abbreviation).font(.inter(20, .bold)).tracking(1.6)
                        .foregroundStyle(LivePalette.secondary)
                    if game.isLive, !score.isEmpty {
                        Text(score).font(.interDigits(56, .bold))
                            .foregroundStyle(LivePalette.text)
                            .contentTransition(.numericText())
                    } else if let record = nonempty(isHome ? game.homeRecord : game.awayRecord) {
                        Text(record).font(.interDigits(17, .medium)).foregroundStyle(LivePalette.secondary)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .background {
                    EllipticalGradient(colors: [liveTeamColor(isHome ? game.homeColor : game.awayColor).opacity(0.3),
                                                .clear],
                                       center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A small tally on the playing feed, so a preview reads as live television.
private struct LiveTallyChip: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(LivePalette.onAir).frame(width: 8, height: 8)
                .shadow(color: LivePalette.onAir.opacity(0.8), radius: 4)
            Text("PREVIEW").font(.inter(13, .bold)).tracking(2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).frame(height: 30)
        .background(.black.opacity(0.55), in: Capsule())
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Over the foot of a playing feed: what the remote is resting on, and what
/// Select will do with it.
private struct LiveLowerThird: View {
    let game: SportsGame
    let isOnScreen: Bool

    var body: some View {
        HStack(spacing: 16) {
            if isOnScreen {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                Text("SELECT AGAIN FOR FULL SCREEN")
                Spacer(minLength: 20)
                Text("MENU STOPS THE PREVIEW").foregroundStyle(.white.opacity(0.6))
            } else {
                LeagueLogo(league: game.isNFLRedZone ? .nfl : game.league, size: 26)
                Text(liveHeadline(game)).font(.inter(20, .semibold)).tracking(0).lineLimit(1)
                if game.isLive {
                    PulsingLiveDot(size: 6)
                    Text(game.status.isEmpty ? "LIVE" : game.status.uppercased())
                        .foregroundStyle(LineupStyle.liveStatus).lineLimit(1)
                } else {
                    Text(game.startLabel.uppercased()).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                Spacer(minLength: 20)
                Image(systemName: "play.fill")
                Text("SELECT TO PREVIEW")
            }
        }
        .font(.inter(14, .bold)).tracking(1.8)
        .foregroundStyle(.white)
        .padding(.horizontal, 28).padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .frame(height: 112, alignment: .bottom)
        // Deep enough under the words that broadcast red and a dimmed line
        // still read over the brightest picture.
        .background(LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black.opacity(0.62), location: 0.45),
            .init(color: .black.opacity(0.92), location: 1)
        ], startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
    }
}

/// The viewer's teams, beside the monitor.
///
/// Followed teams' games only; everything else is on the board beneath. With
/// nobody followed, or nobody of theirs playing, it says which -- and where
/// following happens, because a hold-Select menu is not something anyone finds
/// by accident.
private struct LiveMyTeams: View {
    @EnvironmentObject private var library: SportsLibrary
    let events: [SportsGame]
    let spotlight: LiveSpotlight
    let previewGameID: String?
    let multiviewPrimaryID: Int?
    let onPlay: (SportsGame) -> Void
    let onStartMultiview: (SportsGame) -> Void

    var body: some View {
        let mine = events.filter { library.isFollowing($0) }
        VStack(alignment: .leading, spacing: 14) {
            LiveEyebrow(title: "MY TEAMS", live: mine.filter(\.isLive).count,
                        detail: mine.isEmpty ? nil : "\(mine.count) \(mine.count == 1 ? "GAME" : "GAMES")")
            if mine.isEmpty {
                LiveMyTeamsEmpty(teams: library.followedTeams.teams, hasGames: !events.isEmpty)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 12) {
                        ForEach(mine) { game in
                            LiveTeamRow(game: game, isOnScreen: game.id == previewGameID,
                                        isPrimary: multiviewPrimaryID != nil
                                            && multiviewPrimaryID == library.stream(for: game)?.id,
                                        onFocus: { spotlight.rest(on: game) },
                                        onPlay: { onPlay(game) },
                                        onStartMultiview: { onStartMultiview(game) })
                                .id(game.id)
                        }
                    }
                    .padding(LiveMetrics.liftRoom)
                }
                .scrollIndicators(.hidden)
                .padding(-LiveMetrics.liftRoom)
            }
        }
    }
}

/// A section's small-caps title, with a red count when anything is on air.
private struct LiveEyebrow: View {
    let title: String
    var live = 0
    var detail: String?

    var body: some View {
        HStack(spacing: 9) {
            Text(title).font(.inter(15, .bold)).tracking(2.6).foregroundStyle(LivePalette.secondary)
            Spacer(minLength: 10)
            if live > 0 {
                Circle().fill(LivePalette.onAir).frame(width: 7, height: 7)
                Text("\(live) LIVE").font(.inter(14, .bold)).tracking(1.4)
                    .foregroundStyle(LineupStyle.liveStatus)
            } else if let detail {
                Text(detail).font(.inter(14, .bold)).tracking(1.4).foregroundStyle(LivePalette.secondary)
            }
        }
        .frame(height: 26)
    }
}

/// My Teams with nothing to list: says which empty it is.
private struct LiveMyTeamsEmpty: View {
    let teams: [FollowedTeam]
    let hasGames: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                Circle().fill(LivePalette.accent.opacity(0.16))
                Image(systemName: teams.isEmpty ? "star" : "moon.zzz")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(LivePalette.accent)
            }
            .frame(width: 58, height: 58)
            Text(teams.isEmpty ? "Follow your teams" : "Your teams are off")
                .font(.inter(26, .bold)).foregroundStyle(LivePalette.text)
            Text(teams.isEmpty
                 ? (hasGames ? "Hold Select on any game below and add a team. Its games will wait for you here."
                             : "Follow a team from any matchup once games load.")
                 : "None of your teams play in this range.")
                .font(.inter(18)).foregroundStyle(LivePalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !teams.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(teams.prefix(5))) { team in
                        HStack(spacing: 12) {
                            TeamBadge(url: team.logo, fallback: team.abbreviation, size: 30)
                            Text(team.name).font(.inter(17, .semibold))
                                .foregroundStyle(LivePalette.text).lineLimit(1)
                            Spacer(minLength: 8)
                            Text("NO GAME").font(.inter(12, .bold)).tracking(1.4)
                                .foregroundStyle(LivePalette.secondary)
                        }
                        .padding(.vertical, 10)
                        .overlay(alignment: .top) { Rectangle().fill(LivePalette.rule).frame(height: 1) }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(LivePalette.card.opacity(0.55), in: shape)
        .overlay(shape.strokeBorder(LivePalette.rule, lineWidth: 1))
    }
}

/// One of the viewer's games: both sides, the score, and where it stands.
private struct LiveTeamRow: View {
    @FocusState private var focused: Bool
    let game: SportsGame
    let isOnScreen: Bool
    let isPrimary: Bool
    let onFocus: () -> Void
    let onPlay: () -> Void
    let onStartMultiview: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let lead = liveLeader(game)
        VStack(alignment: .leading, spacing: 9) {
            if game.isEvent {
                HStack(spacing: 12) {
                    LeagueLogo(league: game.isNFLRedZone ? .nfl : game.league, size: 30)
                    Text(game.eventName ?? game.league.shortName).font(.inter(19, .semibold))
                        .foregroundStyle(LivePalette.text).lineLimit(2).minimumScaleFactor(0.8)
                }
            } else {
                side(game.awayTeam, game.awayAbbreviation, game.awayLogo, game.awayScore, dim: lead == .home)
                side(game.homeTeam, game.homeAbbreviation, game.homeLogo, game.homeScore, dim: lead == .away)
            }
            HStack(spacing: 8) {
                if game.isLive {
                    PulsingLiveDot(size: 6)
                    Text(game.status.isEmpty ? "LIVE" : game.status.uppercased())
                        .foregroundStyle(LineupStyle.liveStatus).lineLimit(1)
                } else {
                    Text(game.startLabel.uppercased()).foregroundStyle(LivePalette.text).lineLimit(1)
                }
                Text(game.league.shortName).foregroundStyle(LivePalette.secondary)
                Spacer(minLength: 6)
                if isPrimary {
                    LiveTag(symbol: "rectangle.split.2x1.fill", title: "FIRST GAME")
                } else if isOnScreen {
                    LiveTag(symbol: "tv.fill", title: "ON SCREEN")
                }
            }
            .font(.inter(13, .bold)).tracking(1.3)
        }
        .padding(.leading, 20).padding(.trailing, 18).padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { LiveCardSurface(shape: shape, isLive: game.isLive, tally: .leading) }
        .overlay {
            shape.strokeBorder(isPrimary ? LivePalette.rim : LivePalette.rule, lineWidth: isPrimary ? 2 : 1)
        }
        .lineupFocusLayer(focused, in: shape)
        .contentShape(shape)
        .focusable().focused($focused).focusEffectDisabled()
        .onTapGesture(perform: onPlay)
        .onChange(of: focused) { _, value in if value { onFocus() } }
        .modifier(LiveGameMenu(game: game, isPrimary: isPrimary, onStartMultiview: onStartMultiview))
        .scaleEffect(focused ? LineupStyle.cardLift : 1)
        .lineupShadow(.lifted, on: focused)
        .zIndex(focused ? 1 : 0)
        .animation(.spring(response: 0.26, dampingFraction: 0.82), value: focused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(liveAccessibilityLabel(game))
        .accessibilityAddTraits(.isButton)
    }

    private func side(_ name: String, _ abbreviation: String, _ logo: String, _ score: String,
                      dim: Bool) -> some View {
        HStack(spacing: 12) {
            TeamBadge(url: logo, fallback: abbreviation.isEmpty ? String(name.prefix(3)).uppercased() : abbreviation,
                      size: 30)
            Text(name).font(.inter(18, .semibold))
                .foregroundStyle(dim ? LivePalette.secondary : LivePalette.text)
                .lineLimit(1).minimumScaleFactor(0.75)
            Spacer(minLength: 8)
            if game.isLive, !score.isEmpty {
                Text(score).font(.interDigits(24, .bold))
                    .foregroundStyle(dim ? LivePalette.secondary : LivePalette.text)
                    .contentTransition(.numericText())
            }
        }
    }
}

/// The surface a game sits on: the theme's card, a little light along its top
/// edge, and -- while the game is on air -- a tally strip in broadcast red.
private struct LiveCardSurface: View {
    enum Tally { case top, leading }
    let shape: RoundedRectangle
    let isLive: Bool
    var tally: Tally = .top

    var body: some View {
        ZStack(alignment: tally == .top ? .top : .leading) {
            LivePalette.card
            if isLive {
                if tally == .top {
                    LivePalette.onAir.frame(height: 3)
                } else {
                    LivePalette.onAir.frame(width: 3)
                }
            }
        }
        .clipShape(shape)
    }
}

/// A small filled tag: this game is on the monitor, or is multiview's first.
private struct LiveTag: View {
    let symbol: String
    let title: String
    /// The symbol alone, where the row needs the room.
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
            if !compact {
                Text(title).font(.inter(12, .heavy)).tracking(1.4)
            }
        }
        .foregroundStyle(LineupStyle.background)
        .padding(.horizontal, 9).frame(height: 24)
        .background(LivePalette.accent, in: Capsule())
        .fixedSize()
    }
}

/// Hold Select on any game: a reminder, either side into My Teams, or
/// multiview. The same on the board and in the rail, so following is offered
/// wherever a game is -- the rail is empty until somebody is followed, so a
/// follow that lived only there could never be reached on a fresh install.
private struct LiveGameMenu: ViewModifier {
    @EnvironmentObject private var library: SportsLibrary
    @EnvironmentObject private var reminders: GameReminders
    let game: SportsGame
    let isPrimary: Bool
    let onStartMultiview: () -> Void

    func body(content: Content) -> some View {
        content.contextMenu {
            if game.isUpcoming {
                Button(reminders.reminds(game) ? "Remove Reminder" : "Remind Me",
                       systemImage: reminders.reminds(game) ? "bell.slash" : "bell") {
                    reminders.toggleGame(game)
                }
            }
            ForEach(library.followableSides(of: game)) { team in
                let following = library.isFollowing(team.key)
                Button(following ? "Remove \(team.name) from My Teams"
                                 : "Add \(team.name) to My Teams",
                       systemImage: following ? "star.slash" : "star") {
                    library.toggleFollow(team)
                }
            }
            if library.stream(for: game) != nil {
                Button("Start Multiview", systemImage: "rectangle.split.2x1", action: onStartMultiview)
                    .disabled(isPrimary)
            }
        }
    }
}

/// Every matchup, four across, beneath the monitor.
///
/// One row shows at a time and Down brings the next four. Every row stays in
/// the focus tree rather than being built on demand, because a row that does
/// not exist yet is a row Up cannot find.
private struct LiveMatchupBoard: View {
    @EnvironmentObject private var library: SportsLibrary
    let events: [SportsGame]
    @Binding var selectedLeague: SportsLeague?
    let spotlight: LiveSpotlight
    let previewGameID: String?
    let multiviewPrimaryID: Int?
    let multiviewTitle: String?
    let isScheduleLoading: Bool
    let isScheduleAvailable: Bool
    let onPlay: (SportsGame) -> Void
    let onStartMultiview: (SportsGame) -> Void
    let onCancelMultiview: () -> Void

    private var rows: Int { (events.count + LiveMetrics.columns - 1) / LiveMetrics.columns }

    /// Multiview's first game, named by its matchup rather than by whatever
    /// the provider calls the channel carrying it.
    private var firstGame: SportsGame? {
        guard let multiviewPrimaryID else { return nil }
        return events.first { library.stream(for: $0)?.id == multiviewPrimaryID }
    }

    /// The board's word on an empty night. The monitor above carries the
    /// mood and any error, so this says what to do next.
    private var emptyLane: LiveEmptyLane {
        if isScheduleLoading {
            return LiveEmptyLane(title: "Games are loading…", detail: "The board fills in as each league answers.")
        }
        guard isScheduleAvailable else {
            return LiveEmptyLane(title: "No matchups to show.", detail: "Your channels are still in Guide.")
        }
        guard let selectedLeague else {
            return LiveEmptyLane(title: "No games in this range.", detail: "Your channels are still in Guide.")
        }
        return LiveEmptyLane(title: "No \(liveLeagueName(selectedLeague)) games in this range.",
                             detail: "Switch to All sports to see every league.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if events.isEmpty {
                emptyLane
            } else {
                LiveMatchupGrid(events: events, spotlight: spotlight, previewGameID: previewGameID,
                                multiviewPrimaryID: multiviewPrimaryID,
                                onPlay: onPlay, onStartMultiview: onStartMultiview)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            if let multiviewTitle {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose a second game").font(.inter(26, .bold)).foregroundStyle(LivePalette.text)
                    Text("MULTIVIEW  ·  FIRST GAME  \((firstGame.map(liveHeadline) ?? multiviewTitle).uppercased())")
                        .font(.inter(13, .bold)).tracking(1.6)
                        .foregroundStyle(LivePalette.secondary).lineLimit(1)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text("Matchups").font(.inter(26, .bold)).foregroundStyle(LivePalette.text)
                    LiveBoardCount(total: events.count, live: events.filter(\.isLive).count)
                }
            }
            Spacer(minLength: 20)
            LiveRowPager(spotlight: spotlight, rows: rows)
            if multiviewTitle != nil {
                TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: onCancelMultiview) {
                    LiveChipLabel(symbol: "xmark", title: "Cancel multiview")
                }
            } else {
                LiveLeagueFilter(selectedLeague: $selectedLeague)
            }
        }
        .frame(height: 56)
    }
}

/// The board with nothing on it: a dashed lane where the cards go, so the
/// screen keeps its shape and says why it is empty.
private struct LiveEmptyLane: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "calendar").font(.system(size: 28, weight: .light))
                .foregroundStyle(LivePalette.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.inter(22, .semibold)).foregroundStyle(LivePalette.text)
                Text(detail).font(.inter(17)).foregroundStyle(LivePalette.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: LiveMetrics.cardHeight)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(LivePalette.rule, style: StrokeStyle(lineWidth: 1.5, dash: [7, 7]))
        }
        .padding(.vertical, LiveMetrics.liftRoom)
    }
}

/// "24 GAMES · 6 LIVE", beside the board's title.
private struct LiveBoardCount: View {
    let total: Int
    let live: Int

    var body: some View {
        HStack(spacing: 10) {
            Text("\(total) \(total == 1 ? "GAME" : "GAMES")")
            if live > 0 {
                Circle().fill(LivePalette.onAir).frame(width: 7, height: 7)
                Text("\(live) LIVE").foregroundStyle(LineupStyle.liveStatus)
            }
        }
        .font(.inter(14, .bold)).tracking(1.5)
        .foregroundStyle(LivePalette.secondary)
    }
}

/// Which row of the board is showing, and that there are more beneath it.
private struct LiveRowPager: View {
    @ObservedObject var spotlight: LiveSpotlight
    let rows: Int

    private var current: Int { min(max(spotlight.boardRow, 0), max(rows - 1, 0)) }

    var body: some View {
        if rows > 1 {
            HStack(spacing: 7) {
                if rows <= 10 {
                    ForEach(0..<rows, id: \.self) { row in
                        Capsule()
                            .fill(row == current ? LivePalette.text : LivePalette.secondary.opacity(0.35))
                            .frame(width: row == current ? 22 : 7, height: 7)
                    }
                } else {
                    Text("\(current + 1) / \(rows)").font(.interDigits(15, .bold))
                        .foregroundStyle(LivePalette.secondary)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.82), value: current)
            .accessibilityHidden(true)
        }
    }
}

/// The sport filter: one chip, at the head of the board it filters.
private struct LiveLeagueFilter: View {
    @Binding var selectedLeague: SportsLeague?
    @State private var choosing = false

    private var title: String {
        selectedLeague.map(liveLeagueName) ?? "All sports"
    }

    var body: some View {
        // TVSelectable over a confirmation dialog, the shape the rest of the
        // app uses: a menu would draw the television's own focus plate over a
        // chip that already draws its own.
        TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: { choosing = true }) {
            LiveChipLabel(symbol: "line.3.horizontal.decrease", title: title,
                          league: selectedLeague, trailing: "chevron.down")
        }
        .confirmationDialog("Show which sport?", isPresented: $choosing, titleVisibility: .visible) {
            Button("All sports") { selectedLeague = nil }
            ForEach(SportsLeague.allCases) { league in
                Button(liveLeagueName(league)) { selectedLeague = league }
            }
        }
        .accessibilityLabel("Filter by sport")
    }
}

/// A chip's face. Focus fills it, the way the app's other action pills mark
/// focus, rather than drawing a second frame around it.
private struct LiveChipLabel: View {
    @Environment(\.lineupTVSelectableFocused) private var focused
    let symbol: String
    let title: String
    var league: SportsLeague?
    var trailing: String?

    var body: some View {
        HStack(spacing: 10) {
            if let league {
                LeagueLogo(league: league, size: 24)
            } else {
                Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
            }
            Text(title).font(.inter(17, .semibold)).lineLimit(1)
            if let trailing {
                Image(systemName: trailing).font(.system(size: 13, weight: .bold)).opacity(0.7)
            }
        }
        .foregroundStyle(LivePalette.text)
        .padding(.horizontal, 20).frame(height: 46)
        .background(LivePalette.card, in: Capsule())
        .overlay(Capsule().strokeBorder(LivePalette.rule, lineWidth: 1))
        .lineupFocusLayer(focused, in: Capsule())
        .lineupShadow(.lifted, on: focused)
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: focused)
    }
}

/// The board itself: rows of four, one row tall, scrolled a whole row at a
/// time so the focused card is never cut off at either edge.
private struct LiveMatchupGrid: View {
    let events: [SportsGame]
    let spotlight: LiveSpotlight
    let previewGameID: String?
    let multiviewPrimaryID: Int?
    let onPlay: (SportsGame) -> Void
    let onStartMultiview: (SportsGame) -> Void

    private var rowStarts: [Int] {
        Array(stride(from: 0, to: events.count, by: LiveMetrics.columns))
    }

    var body: some View {
        GeometryReader { shelf in
            let columns = LiveMetrics.columns
            let room = LiveMetrics.liftRoom
            let cardWidth = max(1, (shelf.size.width - room * 2
                                    - LiveMetrics.cardSpacing * CGFloat(columns - 1)) / CGFloat(columns))
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(rowStarts, id: \.self) { rowStart in
                            HStack(spacing: LiveMetrics.cardSpacing) {
                                ForEach(0..<columns, id: \.self) { column in
                                    let index = rowStart + column
                                    if events.indices.contains(index) {
                                        let game = events[index]
                                        LiveMatchupCard(game: game, isOnScreen: game.id == previewGameID,
                                                        multiviewPrimaryID: multiviewPrimaryID,
                                                        onFocus: {
                                                            spotlight.rest(on: game, row: rowStart / columns)
                                                            proxy.scrollTo(rowStart, anchor: .top)
                                                        },
                                                        onPlay: { onPlay(game) },
                                                        onStartMultiview: { onStartMultiview(game) })
                                            .frame(width: cardWidth, height: LiveMetrics.cardHeight)
                                            .id(game.id)
                                    } else {
                                        Color.clear
                                            .frame(width: cardWidth, height: LiveMetrics.cardHeight)
                                            .accessibilityHidden(true)
                                    }
                                }
                            }
                            .padding(.horizontal, room)
                            .padding(.vertical, room)
                            .frame(height: LiveMetrics.cardHeight + room * 2)
                            .id(rowStart)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .focusSection()
            }
        }
        .frame(height: LiveMetrics.cardHeight + LiveMetrics.liftRoom * 2)
        // A television's scroll view does not clip, so the next row would show
        // beneath this one. The mask stops just past the row's own lift room:
        // a focused card's shadow fits inside it, the next row's edge does not.
        .mask(alignment: .top) {
            Rectangle()
                .frame(height: LiveMetrics.cardHeight + LiveMetrics.liftRoom * 2 + 14)
                .padding(.horizontal, -60)
        }
        .padding(.horizontal, -LiveMetrics.liftRoom)
    }
}

/// One matchup on the board.
private struct LiveMatchupCard: View {
    @EnvironmentObject private var library: SportsLibrary
    @FocusState private var focused: Bool
    let game: SportsGame
    let isOnScreen: Bool
    let multiviewPrimaryID: Int?
    let onFocus: () -> Void
    let onPlay: () -> Void
    let onStartMultiview: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let isPrimary = multiviewPrimaryID != nil && multiviewPrimaryID == library.stream(for: game)?.id
        VStack(alignment: .leading, spacing: 0) {
            topLine
            Spacer(minLength: 8)
            if game.isEvent {
                HStack(spacing: 16) {
                    LeagueLogo(league: game.isNFLRedZone ? .nfl : game.league, size: 56)
                    Text(game.eventName ?? game.league.shortName)
                        .font(.inter(22, .semibold)).foregroundStyle(LivePalette.text)
                        .lineLimit(3).minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                let lead = liveLeader(game)
                VStack(spacing: 10) {
                    team(game.awayTeam, game.awayAbbreviation, game.awayLogo, game.awayRecord, game.awayScore,
                         dim: lead == .home)
                    team(game.homeTeam, game.homeAbbreviation, game.homeLogo, game.homeRecord, game.homeScore,
                         dim: lead == .away)
                }
            }
            Spacer(minLength: 8)
            footer(isPrimary: isPrimary)
        }
        .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { LiveCardSurface(shape: shape, isLive: game.isLive) }
        .overlay {
            shape.strokeBorder(isPrimary ? LivePalette.rim : LivePalette.rule, lineWidth: isPrimary ? 2 : 1)
        }
        .lineupFocusLayer(focused, in: shape)
        .contentShape(shape)
        .focusable().focused($focused).focusEffectDisabled()
        .onTapGesture(perform: onPlay)
        .onChange(of: focused) { _, value in if value { onFocus() } }
        .modifier(LiveGameMenu(game: game, isPrimary: isPrimary, onStartMultiview: onStartMultiview))
        .scaleEffect(focused ? LineupStyle.cardLift : 1)
        .lineupShadow(.lifted, on: focused)
        .zIndex(focused ? 1 : 0)
        .animation(.spring(response: 0.26, dampingFraction: 0.82), value: focused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(liveAccessibilityLabel(game))
        .accessibilityAddTraits(.isButton)
    }

    private var topLine: some View {
        HStack(spacing: 10) {
            LeagueLogo(league: game.isNFLRedZone ? .nfl : game.league, size: 26)
            Text(game.league.shortName).font(.inter(15, .bold)).tracking(1.6)
                .foregroundStyle(LivePalette.secondary)
            Spacer(minLength: 0)
        }
        .frame(height: 26)
    }

    /// The game clock, or the start, in the bottom corner where a scoreboard
    /// keeps it.
    @ViewBuilder private var clock: some View {
        if game.isLive {
            HStack(spacing: 8) {
                PulsingLiveDot(size: 7)
                Text(game.status.isEmpty ? "LIVE" : game.status.uppercased())
                    .font(.inter(15, .bold)).tracking(1.2)
                    .foregroundStyle(LineupStyle.liveStatus)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        } else {
            Text(game.startLabel).font(.interDigits(17, .semibold)).tracking(0)
                .foregroundStyle(LivePalette.text).lineLimit(1)
        }
    }

    private func team(_ name: String, _ abbreviation: String, _ logo: String, _ record: String?,
                      _ score: String, dim: Bool) -> some View {
        HStack(spacing: 14) {
            TeamBadge(url: logo, fallback: abbreviation.isEmpty ? String(name.prefix(3)).uppercased() : abbreviation,
                      size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.inter(22, .semibold))
                    .foregroundStyle(dim ? LivePalette.secondary : LivePalette.text)
                    .lineLimit(1).minimumScaleFactor(0.72)
                if let record = nonempty(record) {
                    Text(record).font(.interDigits(16, .medium)).foregroundStyle(LivePalette.secondary)
                }
            }
            Spacer(minLength: 8)
            if game.isLive, !score.isEmpty {
                Text(score).font(.interDigits(34, .bold))
                    .foregroundStyle(dim ? LivePalette.secondary : LivePalette.text)
                    .contentTransition(.numericText())
            }
        }
    }

    /// What Select will do here, said only while the card has focus. Nothing
    /// for multiview's first game: choosing it again as the second does not
    /// start anything.
    private func actionHint(isPrimary: Bool) -> (symbol: String, title: String)? {
        guard focused else { return nil }
        if multiviewPrimaryID != nil {
            return isPrimary ? nil : ("rectangle.split.2x1.fill", "SIDE BY SIDE")
        }
        return isOnScreen ? ("arrow.up.left.and.arrow.down.right", "FULL SCREEN") : ("play.fill", "PREVIEW")
    }

    /// Where to watch and what Select will do on the left, the clock on the
    /// right. When room runs short the network gives way first; the clock
    /// never does.
    private func footer(isPrimary: Bool) -> some View {
        let hint = actionHint(isPrimary: isPrimary)
        return HStack(spacing: 14) {
            if isPrimary {
                LiveTag(symbol: "rectangle.split.2x1.fill", title: "FIRST GAME")
            } else if isOnScreen {
                // Focused, the tag keeps its colour and gives its words to the
                // hint beside it.
                LiveTag(symbol: "tv.fill", title: "ON SCREEN", compact: hint != nil)
            } else if let network = nonempty(game.broadcast) {
                Text(network.uppercased()).foregroundStyle(LivePalette.secondary).lineLimit(1)
            } else if hint == nil {
                Text("NO LISTED NETWORK").foregroundStyle(LivePalette.secondary).lineLimit(1)
            }
            if let hint {
                HStack(spacing: 7) {
                    Image(systemName: hint.symbol).font(.system(size: 12, weight: .bold))
                    Text(hint.title).lineLimit(1)
                }
                .layoutPriority(1)
            }
            Spacer(minLength: 8)
            clock.layoutPriority(2)
        }
        .font(.inter(13, .bold)).tracking(1.4)
        .foregroundStyle(LivePalette.text)
        .frame(height: 24)
    }
}

/// Which side is ahead, for dimming the other.
private enum LiveLead { case away, home, level }

private func liveLeader(_ game: SportsGame) -> LiveLead {
    guard game.isLive, let away = Int(game.awayScore), let home = Int(game.homeScore),
          away != home else { return .level }
    return away > home ? .away : .home
}

/// A team's colour, lifted until it can glow on a dark screen; the theme's own
/// colour stands in for a side the schedule has no colour for.
private func liveTeamColor(_ hex: String?) -> Color {
    sportsReadableTeamColor(hex) ?? LineupStyle.highlight
}

/// "8:20 PM" as "8:20" and "PM", so the period can be set smaller than the
/// time. A clock with no period, in a 24-hour locale, comes back whole.
private func liveTimeParts(_ date: Date) -> (time: String, period: String?) {
    let text = date.formatted(.dateTime.hour().minute())
    guard let letter = text.firstIndex(where: \.isLetter), letter != text.startIndex else { return (text, nil) }
    let time = text[..<letter].trimmingCharacters(in: .whitespaces)
    let period = text[letter...].trimmingCharacters(in: .whitespaces)
    return time.isEmpty ? (text, nil) : (time, period.isEmpty ? nil : period)
}

private func liveDayLabel(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return calendar.component(.hour, from: date) >= 17 ? "TONIGHT" : "TODAY" }
    if calendar.isDateInTomorrow(date) { return "TOMORROW" }
    return date.formatted(.dateTime.weekday(.wide)).uppercased()
}

/// What each sport calls its start.
private func liveStartWord(_ league: SportsLeague) -> String {
    switch league {
    case .nfl, .ncaaf: "KICKOFF"
    case .nba: "TIP-OFF"
    case .nhl: "PUCK DROP"
    case .mlb: "FIRST PITCH"
    case .ufc: "MAIN CARD"
    }
}

/// A league as the sport filter names it.
private func liveLeagueName(_ league: SportsLeague) -> String {
    league == .ncaaf ? "College" : league.shortName
}

/// The matchup in a line: "BOS 3 – NYY 5", "BOS @ MIL", or an event's name.
private func liveHeadline(_ game: SportsGame) -> String {
    if game.isEvent { return game.eventName ?? game.league.shortName }
    if game.isLive && !game.awayScore.isEmpty && !game.homeScore.isEmpty {
        return "\(game.awayAbbreviation) \(game.awayScore)  –  \(game.homeAbbreviation) \(game.homeScore)"
    }
    return "\(game.awayAbbreviation) @ \(game.homeAbbreviation)"
}

private func liveAccessibilityLabel(_ game: SportsGame) -> String {
    let matchup = game.isEvent ? (game.eventName ?? game.league.shortName) : "\(game.awayTeam) at \(game.homeTeam)"
    guard game.isLive else { return "\(matchup), \(game.start.formatted(date: .abbreviated, time: .shortened))" }
    let score = game.awayScore.isEmpty || game.homeScore.isEmpty ? "" : ", \(game.awayScore) to \(game.homeScore)"
    return "\(matchup)\(score), \(game.status.isEmpty ? "live" : game.status)"
}

private struct LiveSelectedPreview: View {
    @EnvironmentObject private var library: SportsLibrary
    @StateObject private var controller = VLCPlaybackController()
    @State private var choosingGame: SportsGame?
    let stream: XtreamStream
    let game: SportsGame?
    let urls: [URL]

    var body: some View {
        VLCVideoSurface(player: controller.player).overlay { TVPlaybackStatus(controller: controller) }.background(Color.black)
        .onAppear {
            if let game {
                configureGameFailover(controller, game: game, library: library) { choosingGame = game }
            }
            controller.start(urls: urls, muted: false, channelID: stream.id)
        }
        .sheet(item: $choosingGame) { game in
            ManualGameChannelPicker(game: game) { chosen in
                library.saveGameSelection(chosen, for: game)
                choosingGame = nil
                controller.start(urls: library.playbackURLs(for: chosen), channelID: chosen.id)
            }
        }
        .onDisappear { controller.stop() }
    }
}
/// A steady broadcast-red core with a slow halo around it. The core never
/// blinks or changes size, so it remains a crisp status mark; only the light
/// it casts breathes. That reads as an illuminated indicator rather than a
/// generic animated circle.
/// On air, as a small red dot.
///
/// It was a glossy bead -- a gradient, a rim, a glow and a halo -- which at
/// these sizes read as a smudge of red rather than a mark. Flat and smaller,
/// its edge stays crisp from across a room, and a slow breath is what says
/// *now*: a still dot is a bullet point.
private struct PulsingLiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let size: CGFloat
    @State private var breathing = false

    /// Three quarters of what each caller asked for: every live dot in the
    /// app gets smaller at once, without reworking the rows that hold them.
    private var diameter: CGFloat { (size * 0.72).rounded() }

    var body: some View {
        Circle()
            .fill(LineupStyle.liveDot)
            .frame(width: diameter, height: diameter)
            .opacity(breathing ? 0.45 : 1)
            .animation(reduceMotion ? nil
                : .easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: breathing)
            .onAppear { breathing = !reduceMotion }
            .onDisappear { breathing = false }
            .onChange(of: reduceMotion) { _, reduced in breathing = !reduced }
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
            // The crawl's bug, in the theme's own colour, the way a broadcast
            // brands the corner its scores come in from.
            Text("SCORES")
                .font(.inter(13, .heavy)).tracking(2.4)
                .foregroundStyle(LineupStyle.background)
                .padding(.horizontal, 12).frame(height: 26)
                .background(LineupStyle.highlight, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.bottom, 5)
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
                // Scores fade in and out at the ends rather than being cut
                // off by the edge of the strip.
                .mask {
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                        .init(color: .black, location: 0.94), .init(color: .clear, location: 1)
                    ], startPoint: .leading, endPoint: .trailing)
                }
            }
        }
        .padding(.horizontal, LiveMetrics.margin).padding(.bottom, 2)
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
                Text("NO LIVE OR FINAL SCORES YET")
                    .font(.inter(16, .bold)).tracking(2.2)
                    .foregroundStyle(LineupStyle.secondary).lineLimit(1)
                    .frame(width: 400, alignment: .leading)
            } else {
                // Every column keeps its fixed width: the scroll arithmetic
                // above counts in whole items of `cardWidth`.
                ForEach(displayedEvents) { game in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(game.league.shortName)
                            .font(.inter(14, .bold)).tracking(1.6)
                            .foregroundStyle(LineupStyle.secondary)
                            .frame(width: 62, alignment: .leading)
                        Text(game.awayAbbreviation)
                            .font(.inter(21, .bold))
                            .foregroundStyle(sportsReadableTeamColor(game.awayColor) ?? LineupStyle.text)
                            .frame(width: 72, alignment: .leading)
                        Text(game.awayScore)
                            .font(.interDigits(22, .bold)).foregroundStyle(LineupStyle.text)
                            .frame(width: 48, alignment: .trailing)
                        Text("–").font(.inter(19, .medium)).foregroundStyle(LineupStyle.secondary)
                        Text(game.homeAbbreviation)
                            .font(.inter(21, .bold))
                            .foregroundStyle(sportsReadableTeamColor(game.homeColor) ?? LineupStyle.text)
                            .frame(width: 72, alignment: .leading)
                        Text(game.homeScore)
                            .font(.interDigits(22, .bold)).foregroundStyle(LineupStyle.text)
                            .frame(width: 48, alignment: .trailing)
                        Text(game.isLive ? game.status.uppercased() : "FINAL")
                            .font(.inter(14, .bold)).tracking(1.4)
                            .foregroundStyle(game.isLive ? LineupStyle.liveStatus : LineupStyle.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .lineLimit(1)
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
    case .ufc: "figure.martial.arts"
    }
}

private struct LeagueLogo: View {
    let league: SportsLeague
    let size: CGFloat

    private var logoURL: URL? {
        guard league != .ncaaf && league != .ufc else { return nil }
        return URL(string: "https://a.espncdn.com/i/teamlogos/leagues/500/\(league.rawValue).png")
    }

    var body: some View {
        Group {
            if league == .ufc {
                Image("League-ufc").resizable().scaledToFit()
            } else {
                LineupArtView(url: logoURL, width: size) { loaded in
                    if let image = loaded {
                        image.resizable().scaledToFit().colorMultiply(LineupStyle.lightPurple)
                    } else {
                        Image(systemName: sportsSymbol(league))
                            .resizable().scaledToFit()
                            .padding(size * 0.18)
                            .foregroundStyle(LineupStyle.secondary)
                    }
                }
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
        VStack(alignment: .leading, spacing: 7) {
            Rectangle().fill(LineupStyle.highlight).frame(width: 42, height: 4)
            Text(title).font(.inter(44, .bold)).tracking(-1).foregroundStyle(LineupStyle.text)
            Text(detail).font(.inter(.callout, .medium)).foregroundStyle(LineupStyle.secondary)
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
                    if event.isEvent {
                        Text(event.eventName ?? "")
                            .font(.inter(20, .semibold)).foregroundStyle(LineupStyle.text)
                            .lineLimit(2).minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        GameTeamLine(logo: event.awayLogo, name: event.awayTeam, score: event.isLive ? event.awayScore : nil)
                        Text("@").foregroundColor(LineupStyle.lightPurple).font(.inter(.caption, .bold)).foregroundStyle(LineupStyle.secondary).padding(.leading, 20)
                        GameTeamLine(logo: event.homeLogo, name: event.homeTeam, score: event.isLive ? event.homeScore : nil)
                    }
                    if let place = event.placeLine {
                        Text(place).font(.inter(.caption))
                            .foregroundStyle(LineupStyle.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
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
            // Following is offered wherever a game is, not only in the rail.
            // The rail is empty until somebody is followed, so a follow action
            // that lived only there could never be reached from a fresh install.
            ForEach(library.followableSides(of: event)) { team in
                let following = library.isFollowing(team.key)
                Button(following ? "Remove \(team.name) from My Teams"
                                 : "Add \(team.name) to My Teams",
                       systemImage: following ? "star.slash" : "star") {
                    library.toggleFollow(team)
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
            if event.isLive { PulsingLiveDot(size: 7) }
            Text(title).font(.inter(.caption, .bold)).tracking(1.1)
        }
        .foregroundStyle(event.isLive ? LineupStyle.liveStatus : LineupStyle.text)
        .padding(.horizontal, 13).frame(height: 34)
        .background(event.isLive ? LineupStyle.liveDot.opacity(0.12) : LineupStyle.lightPurple.opacity(0.06))
        .clipShape(Capsule())
        .nullGlass(clear: event.isLive, cornerRadius: 17)
    }
}

private struct MatchupArtwork: View {
    let event: SportsGame
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(LineupStyle.raised)
            // An event is one card, not two sides. Two crests either side of a
            // "VS" is a promise the fixture does not make, so it gets the
            // league's own mark instead.
            if event.isEvent {
                LeagueLogo(league: event.league, size: 76)
            } else {
                HStack(spacing: 16) {
                    TeamBadge(url: event.awayLogo, fallback: event.awayAbbreviation, size: 58)
                    Text("VS").foregroundColor(LineupStyle.lightPurple).font(.inter(.caption2, .bold)).foregroundStyle(LineupStyle.secondary)
                        .frame(width: 32, height: 32).background(LineupStyle.background).clipShape(Circle())
                    TeamBadge(url: event.homeLogo, fallback: event.homeAbbreviation, size: 58)
                }
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
        LineupArtView(url: URL(string: url ?? ""), width: width) { loaded in
            if let image = loaded { image.resizable().scaledToFit().colorMultiply(LineupStyle.lightPurple) }
            else { Image(systemName: "tv").font(.caption).foregroundStyle(LineupStyle.secondary) }
        }
        .transaction { $0.animation = nil }
        .padding(4).frame(width: width, height: height).background(LineupStyle.raised)
    }
}

/// The guide's colours: charcoal, light grey and white, and red for now.
private enum GuidePalette {
    static var background: Color { LineupStyle.background }
    /// The channel column and the sidebar, a step darker than the grid so the
    /// names read as a margin rather than as more programmes.
    static var rail: Color { LineupStyle.sidebarRow }
    static var surface: Color { LineupStyle.surface }
    static var raised: Color { LineupStyle.raised }
    static var line: Color { LineupStyle.line }
    static var text: Color { LineupStyle.text }
    static var secondary: Color { LineupStyle.secondary }
    /// A programme still to come, and the one on the air, a step lighter: on
    /// now and coming up are told apart at a glance without a word of ink.
    static var card: Color { LineupStyle.surface }
    static var cardNow: Color { LineupStyle.raised }
    /// How far the programme on now has run, on its track.
    static var progress: Color { LineupStyle.text }
    static var track: Color { LineupStyle.text.opacity(0.14) }
    /// Now, and on air: broadcast red, the only colour the guide has.
    static var now: Color { LineupStyle.liveDot }
}

struct GuideView: View {
    @EnvironmentObject private var library: SportsLibrary
    var isActive = true
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
            let layout = GuideLayout(width: container.size.width - 2 * GuideLayout.margin)
            NavigationStack {
                VStack(alignment: .leading, spacing: 18) {
                    GuideControlBar(
                        title: selectedTitle,
                        channelCount: filtered.count,
                        searchActive: $searchActive,
                        query: $query,
                        multiviewTitle: multiviewPrimary?.name,
                        isLoading: GuideSyncStatus.isWaiting(hasListings: !library.programsByChannel.isEmpty,
                                                            isLoading: library.isLoading,
                                                            isGuideLoading: library.isGuideLoading),
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
                        .frame(height: 216)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    ZStack(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 0) {
                            GuideTimelineHeader(now: guideNow)
                            if filtered.isEmpty {
                                Label(favoritesOnly ? "Your favorite channels will appear here." : "No channels in this category.",
                                      systemImage: favoritesOnly ? "star" : "rectangle.stack")
                                    .font(.inter(22, .medium)).foregroundStyle(GuidePalette.secondary)
                                    .padding(.top, 28).padding(.leading, 14)
                                    .focusable()
                                    .focused($gridFocus, equals: GuideGridFocus(streamID: -1, programStart: nil))
                                    .modifier(GuideLeftBoundary(enabled: !sidebarVisible && !searchActive, onOpen: openSidebar))
                            } else {
                                ScrollViewReader { proxy in
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 0) {
                                        ForEach(filtered) { stream in
                                            GuideChannelRow(
                                                stream: stream,
                                                favoritesMode: favoritesOnly && !searchActive,
                                                now: guideNow,
                                                gridFocus: $gridFocus,
                                                multiviewPrimaryID: multiviewPrimary?.id,
                                                onPlay: { select(stream) },
                                                onStartMultiview: { multiviewPrimary = stream },
                                                onReorderFavorites: { reorderingFavorites = true },
                                                onMoveFocus: { direction, focus in
                                                    moveGuideFocus(direction, from: focus)
                                                },
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
                        .overlay(alignment: .topLeading) {
                            if !filtered.isEmpty { GuideNowLine(now: guideNow) }
                        }
                        .disabled(sidebarVisible && !searchActive)

                        if sidebarVisible && !searchActive {
                            GuideSidebar(
                                selectedCategoryID: $selectedCategoryID,
                                favoritesOnly: $favoritesOnly,
                                focus: $sidebarFocus,
                                onCollapse: closeSidebar
                            )
                            .frame(width: layout.channelWidth)
                            .frame(maxHeight: .infinity)
                            .background(GuidePalette.rail)
                            .overlay(alignment: .trailing) {
                                Rectangle().fill(GuidePalette.line).frame(width: 1)
                            }
                            .lineupShadow(.overlayFromEdge)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                            .focusSection()
                        }
                    }
                    // The grid sits straight on the ground, clipped square so
                    // rows leave cleanly under the time bar rather than
                    // drawing past it.
                    .clipShape(Rectangle())
                }
                .padding(.horizontal, GuideLayout.margin).padding(.top, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .ignoresSafeArea(.container, edges: .bottom)
                .background(GuidePalette.background.ignoresSafeArea())
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
                        secondaryURLs: library.playbackURLs(for: session.secondary),
                        primaryGame: session.primaryGame,
                        secondaryGame: session.secondaryGame
                    )
                }
                .fullScreenCover(isPresented: $reorderingFavorites) {
                    TVFavoritesOrderView()
                }
                .task(id: isActive) {
                    guard isActive else { return }
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

    /// Keep vertical remote movement on what is airing now.
    ///
    /// Program blocks have different widths from channel to channel. Native
    /// geometric focus therefore sometimes treats a future block as the
    /// nearest target when moving up or down. Vertical movement is channel
    /// browsing, so it always lands on the adjacent channel's on-air block.
    /// Horizontal movement remains schedule browsing and walks every visible
    /// listing in the current row.
    private func moveGuideFocus(_ direction: MoveCommandDirection, from source: GuideGridFocus) {
        guard let row = filtered.firstIndex(where: { $0.id == source.streamID }) else { return }

        switch direction {
        case .up, .down:
            let targetRow = direction == .up ? row - 1 : row + 1
            guard filtered.indices.contains(targetRow) else { return }
            focusOnAirProgram(for: filtered[targetRow])

        case .left, .right:
            let stream = filtered[row]
            let programs = visibleGuidePrograms(for: stream)
            guard !programs.isEmpty else {
                if direction == .left { openSidebar() }
                return
            }
            let current = source.programStart.flatMap { start in
                programs.firstIndex(where: { $0.start == start })
            } ?? 0
            let target = direction == .left ? current - 1 : current + 1
            guard programs.indices.contains(target) else {
                if direction == .left { openSidebar() }
                return
            }
            gridFocus = GuideGridFocus(streamID: stream.id, programStart: programs[target].start)

        default:
            return
        }
    }

    private func focusOnAirProgram(for stream: XtreamStream) {
        let programs = visibleGuidePrograms(for: stream)
        let onAir = programs.first { $0.start <= guideNow && guideNow < $0.end }
        gridFocus = GuideGridFocus(streamID: stream.id, programStart: (onAir ?? programs.first)?.start)
    }

    private func visibleGuidePrograms(for stream: XtreamStream) -> [CurrentProgram] {
        let start = guideTimelineAnchor(guideNow)
        let end = start.addingTimeInterval(Double(guideVisibleSlotCount) * 1800)
        return library.guidePrograms(for: stream)
            .filter { $0.end > start && $0.start < end }
            .sorted { $0.start < $1.start }
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
        multiviewSession = MultiviewSession(primary: primary, secondary: stream,
                                           primaryGame: nil, secondaryGame: nil)
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
        HStack(alignment: .center, spacing: 20) {
            if let multiviewTitle {
                GuideTitleBlock(eyebrow: "MULTIVIEW  ·  CHOOSE A SECOND CHANNEL", title: multiviewTitle)
            } else if searchActive {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(GuidePalette.secondary)
                    TextField("Search channels", text: $query)
                        .textFieldStyle(.plain).focusEffectDisabled()
                        .font(.inter(22, .medium))
                }
                .padding(.horizontal, 18).frame(maxWidth: 620, minHeight: 52)
                .background(GuidePalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(GuidePalette.line, lineWidth: 1))
            } else {
                GuideTitleBlock(eyebrow: "GUIDE", title: title)
            }
            Spacer(minLength: 12)
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("UPDATING").font(.inter(13, .bold)).tracking(1.6)
                }
                .foregroundStyle(GuidePalette.secondary)
            }
            Text("\(channelCount) CHANNELS")
                .font(.inter(13, .bold)).tracking(1.6)
                .foregroundStyle(GuidePalette.secondary)
            Rectangle().fill(GuidePalette.line).frame(width: 1, height: 26)
            Text(now.formatted(date: .omitted, time: .shortened))
                .font(.interDigits(24, .semibold))
                .foregroundStyle(GuidePalette.text)
                .fixedSize()
                .accessibilityLabel("Current time, \(now.formatted(date: .omitted, time: .shortened))")
            GuideHeaderButton(title: searchActive ? "Close" : "Search", symbol: searchActive ? "xmark" : "magnifyingglass") {
                searchActive.toggle()
                if !searchActive { query = "" }
            }
            if multiviewTitle != nil { GuideHeaderButton(title: "Cancel", symbol: "xmark", action: onCancelMultiview) }
        }
        .foregroundStyle(GuidePalette.text)
        .frame(height: 64)
    }
}

/// A screen's name with a quiet line over it.
private struct GuideTitleBlock: View {
    let eyebrow: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(eyebrow)
                .font(.inter(13, .bold)).tracking(2.2)
                .foregroundStyle(GuidePalette.secondary).lineLimit(1)
            Text(title)
                .font(.inter(32, .bold))
                .foregroundStyle(GuidePalette.text).lineLimit(1)
        }
    }
}

/// What the remote is on, larger: the picture or the channel's mark, and the
/// programme under it, in type that reads from the sofa.
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

    /// "23 MIN LEFT", while the programme is on.
    private var remaining: String? {
        guard item.program.isLive else { return nil }
        let minutes = Int((item.program.end.timeIntervalSince(now) / 60).rounded(.up))
        guard minutes > 0 else { return nil }
        return minutes >= 60 ? "\(minutes / 60) HR \(minutes % 60) MIN LEFT" : "\(minutes) MIN LEFT"
    }

    var body: some View {
        let frame = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(alignment: .center, spacing: 34) {
            Group {
                if let previewURLs {
                    GuidePreviewVideo(urls: previewURLs)
                        .id(item.stream.id)
                } else {
                    GuidePreviewArtwork(stream: item.stream)
                }
            }
            .frame(width: 352, height: 198)
            .clipShape(frame)
            .overlay(frame.strokeBorder(GuidePalette.line, lineWidth: 1))

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    if item.program.isLive { GuideLiveTag() }
                    Text(item.stream.name.uppercased())
                        .font(.inter(14, .bold)).tracking(1.6)
                        .foregroundStyle(GuidePalette.text).lineLimit(1)
                    Text(categoryName.uppercased())
                        .font(.inter(14, .bold)).tracking(1.6)
                        .foregroundStyle(GuidePalette.secondary).lineLimit(1)
                    if let quality { GuideTinyBadge(title: quality) }
                    if item.program.isNew == true { GuideTinyBadge(title: "NEW") }
                }
                Text(item.program.title.isEmpty ? "Untitled" : item.program.title)
                    .font(.inter(38, .bold))
                    .foregroundStyle(GuidePalette.text)
                    .lineLimit(1).minimumScaleFactor(0.8)
                HStack(spacing: 16) {
                    Text(guideTimeRange(item.program))
                        .font(.interDigits(18, .semibold))
                        .foregroundStyle(GuidePalette.secondary)
                    if item.program.isLive {
                        GuideProgressBar(progress: progress).frame(width: 220, height: 4)
                        if let remaining {
                            Text(remaining)
                                .font(.inter(13, .bold)).tracking(1.4)
                                .foregroundStyle(GuidePalette.secondary)
                        }
                    }
                }
                Text(item.program.detail.isEmpty ? "No description for this program." : item.program.detail)
                    .font(.inter(19))
                    .foregroundStyle(GuidePalette.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 980, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("MENU HIDES THE PREVIEW")
                .font(.inter(12, .bold)).tracking(1.6)
                .foregroundStyle(GuidePalette.secondary.opacity(0.8))
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 8)
        }
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

/// The channel's mark on a dark plate, for a channel that is not playing.
private struct GuidePreviewArtwork: View {
    let stream: XtreamStream
    var body: some View {
        ZStack {
            GuidePalette.surface
            LineupArtView(url: stream.streamIcon.flatMap(URL.init(string:)), width: 420) { loaded in
                if let image = loaded {
                    image.resizable().scaledToFit().padding(40)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "tv").font(.system(size: 38, weight: .light))
                        Text(stream.name).font(.inter(18, .semibold))
                            .lineLimit(2).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(GuidePalette.secondary)
                    .padding(24)
                }
            }
            .transaction { $0.animation = nil }
        }
    }
}

/// HD, NEW and the like: a small outlined tag, never a coloured one.
private struct GuideTinyBadge: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.inter(12, .bold)).tracking(1.2)
            .foregroundStyle(GuidePalette.secondary)
            .padding(.horizontal, 7).frame(height: 22)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(GuidePalette.secondary.opacity(0.5), lineWidth: 1))
            .fixedSize()
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
    let primaryGame: SportsGame?
    let secondaryGame: SportsGame?
}

private struct GuideSidebar: View {
    @EnvironmentObject private var library: SportsLibrary
    @Binding var selectedCategoryID: String?
    @Binding var favoritesOnly: Bool
    let focus: FocusState<String?>.Binding
    let onCollapse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GuideSidebarHeading(title: "BROWSE")
            GuideSidebarButton(title: "All channels", symbol: "square.grid.2x2", selected: selectedCategoryID == nil && !favoritesOnly, focus: focus, focusID: "all") {
                selectedCategoryID = nil; favoritesOnly = false
            }
            GuideSidebarButton(title: "Favorites", symbol: "star", selected: favoritesOnly, focus: focus, focusID: "favorites") {
                selectedCategoryID = nil; favoritesOnly = true
            }
            GuideSidebarHeading(title: "CATEGORIES").padding(.top, 10)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(library.categories) { category in
                        GuideSidebarButton(title: category.categoryName, symbol: "rectangle.grid.1x2", selected: selectedCategoryID == category.id && !favoritesOnly, focus: focus, focusID: "category-" + category.id) {
                            selectedCategoryID = category.id; favoritesOnly = false
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(.horizontal, 12).padding(.top, 6)
        .onMoveCommand { direction in
            if direction == .right { onCollapse() }
        }
        .task {
            // All channels is always mounted; do not target an offscreen lazy category.
            focus.wrappedValue = favoritesOnly ? "favorites" : "all"
        }
    }
}

private struct GuideSidebarHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.inter(13, .bold)).tracking(2.2)
            .foregroundStyle(GuidePalette.secondary)
            .lineLimit(1)
            .padding(.leading, 16)
            .frame(height: 40, alignment: .bottomLeading)
            .padding(.bottom, 4)
    }
}

/// A sidebar row. The chosen one is white with a bar at its edge; the one the
/// remote is on wears the focus layer, so the two can never be confused.
private struct GuideSidebarButton: View {
    let title: String
    let symbol: String
    let selected: Bool
    let focus: FocusState<String?>.Binding
    let focusID: String
    private var isFocused: Bool { focus.wrappedValue == focusID }
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 24)
            Text(title)
                .font(.inter(21, selected ? .semibold : .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(selected || isFocused ? GuidePalette.text : GuidePalette.secondary)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minHeight: 50)
        .background(selected ? GuidePalette.surface : Color.clear, in: shape)
        .overlay(alignment: .leading) {
            if selected {
                Capsule().fill(GuidePalette.text).frame(width: 3, height: 22)
            }
        }
        .lineupFocusLayer(isFocused, in: shape)
        .contentShape(Rectangle()).focusable().focused(focus, equals: focusID).focusEffectDisabled().onTapGesture(perform: action)
        .animation(.easeOut(duration: 0.16), value: isFocused)
    }
}

private struct GuideHeaderButton: View {
    @FocusState private var isFocused: Bool
    let title: String
    let symbol: String
    var onMoveDown: (() -> Void)? = nil
    let action: () -> Void
    var body: some View {
        let shape = Capsule()
        Label(title, systemImage: symbol)
            .font(.inter(18, .semibold))
            .foregroundStyle(GuidePalette.text)
            .padding(.horizontal, 22).frame(height: 48)
            .background(GuidePalette.surface, in: shape)
            .overlay(shape.strokeBorder(GuidePalette.line, lineWidth: 1))
            .lineupFocusLayer(isFocused, in: shape)
            .contentShape(shape).focusable().focused($isFocused).focusEffectDisabled().onTapGesture(perform: action)
            .focusLift(isFocused, scale: LineupStyle.controlLift)
            .onMoveCommand { direction in if direction == .down { onMoveDown?() } }
    }
}

/// The day over the channels, and a tick and a time at every half hour.
private struct GuideTimelineHeader: View {
    @Environment(\.guideLayout) private var layout
    let now: Date

    var body: some View {
        let anchor = guideTimelineAnchor(now)
        HStack(spacing: 0) {
            Text(now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).uppercased())
                .font(.inter(14, .bold)).tracking(1.6)
                .foregroundStyle(GuidePalette.text)
                .lineLimit(1)
                .frame(width: layout.channelWidth, alignment: .leading)
            ForEach(0..<guideVisibleSlotCount, id: \.self) { step in
                HStack(spacing: 10) {
                    Rectangle().fill(GuidePalette.secondary.opacity(0.5)).frame(width: 1, height: 14)
                    Text(anchor.addingTimeInterval(Double(step) * 1800)
                        .formatted(date: .omitted, time: .shortened))
                        .font(.interDigits(16, .semibold))
                        .foregroundStyle(GuidePalette.secondary)
                        .lineLimit(1)
                }
                .frame(width: layout.slotWidth, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: guideHeaderHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(GuidePalette.line).frame(height: 1)
        }
    }
}

/// The time bar's height, which is also where the line for now begins.
private let guideHeaderHeight: CGFloat = 48

private let guideVisibleSlotCount = 6

// Grow the grid cells in both dimensions without scaling typography or artwork.
// Keep the original channel/half-hour widths and row aspect ratio in sync.
private struct GuideLayout {
    /// Keeps the grid clear of a television's overscan without giving up a
    /// column: tighter than the Live tab's margin, wide enough to be safe.
    static let margin: CGFloat = 60
    let width: CGFloat
    var slotWidth: CGFloat { max(1, width - 28) / CGFloat(guideVisibleSlotCount + 1) }
    var channelWidth: CGFloat { slotWidth }
    // A guide is worth having in proportion to how much of it you can see at
    // once, and at 132 this showed four channels on a 1080 screen. Ninety-two
    // is what a row needs for a title and a time under it at this type size
    // and no more, which is six or seven channels -- enough to scan without
    // the rows becoming a list of hairlines.
    var rowHeight: CGFloat { 92 * slotWidth / 245 }
}

private struct GuideLayoutKey: EnvironmentKey {
    static let defaultValue = GuideLayout(width: 1800)
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
    let multiviewPrimaryID: Int?
    let onPlay: () -> Void
    let onStartMultiview: () -> Void
    let onReorderFavorites: () -> Void
    let onMoveFocus: (MoveCommandDirection, GuideGridFocus) -> Void
    let onFocusProgram: (CurrentProgram) -> Void
    private var programs: [CurrentProgram] { library.guidePrograms(for: stream) }

    private var visiblePrograms: [CurrentProgram] {
        let start = guideTimelineAnchor(now)
        let end = start.addingTimeInterval(Double(guideVisibleSlotCount) * 1800)
        return programs.filter { $0.end > start && $0.start < end }
            .sorted { $0.start < $1.start }
    }

    var body: some View {
        HStack(spacing: 0) {
            GuideChannelArtwork(stream: stream, isFavorite: library.isFavorite(stream))
            .frame(width: layout.channelWidth - 8, height: layout.rowHeight - 8)
            .background(GuidePalette.rail, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.vertical, 4)
            .padding(.trailing, 8)
            .clipped()

            ZStack(alignment: .leading) {
                GuideTimelineGrid()
                if visiblePrograms.isEmpty {
                    let focusID = GuideGridFocus(streamID: stream.id, programStart: nil)
                    GuideProgramCell(program: nil, empty: "No guide information", quality: guideQuality(stream), now: now, showsTime: true, onPlay: onPlay, onFocus: {}, gridFocus: gridFocus, focusID: focusID, onMove: { onMoveFocus($0, focusID) })
                        .frame(width: layout.slotWidth - 6, alignment: .leading)
                } else {
                    ForEach(Array(visiblePrograms.enumerated()), id: \.offset) { _, program in
                        let width = guideProgramWidth(program, now: now, layout: layout)
                        let focusID = GuideGridFocus(streamID: stream.id, programStart: program.start)
                        GuideProgramCell(program: program, empty: "", quality: guideQuality(stream), now: now, showsTime: width >= 110, onPlay: onPlay, onFocus: { onFocusProgram(program) }, gridFocus: gridFocus, focusID: focusID, onMove: { onMoveFocus($0, focusID) })
                            .frame(width: width, alignment: .leading)
                            .offset(x: guideProgramX(program, now: now, layout: layout))
                    }
                }
            }
            .frame(width: layout.slotWidth * CGFloat(guideVisibleSlotCount), alignment: .leading)
            .clipped()
        }
        .padding(.horizontal, 14)
        .frame(width: layout.width, height: layout.rowHeight, alignment: .leading)
        // Multiview's first channel keeps a white frame while the second is
        // chosen, so it is never mistaken for where the remote is.
        .overlay {
            if multiviewPrimaryID == stream.id {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(GuidePalette.text, lineWidth: 2)
                    .padding(.horizontal, 8)
            }
        }
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

/// Fine, fixed half-hour rules give the schedule the precision of a broadcast
/// rundown without adding another stack of views to every visible row.
private struct GuideTimelineGrid: View {
    @Environment(\.guideLayout) private var layout

    var body: some View {
        Canvas { context, size in
            var path = Path()
            for step in 0...guideVisibleSlotCount {
                let x = CGFloat(step) * layout.slotWidth
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            context.stroke(path, with: .color(GuidePalette.line.opacity(0.4)), lineWidth: 1)
        }
        .frame(width: layout.slotWidth * CGFloat(guideVisibleSlotCount), height: layout.rowHeight)
        .accessibilityHidden(true)
    }
}

/// A channel's number, its mark, and a star if it is a favourite. The name is
/// shown only where there is no mark to show; the preview above names the
/// channel the remote is on in type read from across the room.
private struct GuideChannelArtwork: View {
    let stream: XtreamStream
    let isFavorite: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(stream.num.map { "\($0)" } ?? "")
                .font(.interDigits(15, .semibold))
                .foregroundStyle(GuidePalette.secondary)
                .frame(width: 42, alignment: .leading)
            GeometryReader { proxy in
                LineupArtView(url: stream.streamIcon.flatMap(URL.init(string:)), width: max(1, proxy.size.width)) { loaded in
                    if let image = loaded {
                        image.resizable().scaledToFit()
                    } else {
                        Text(stream.name)
                            .font(.inter(15, .semibold))
                            .lineLimit(2).minimumScaleFactor(0.6)
                            .allowsTightening(true)
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(GuidePalette.text)
                    }
                }
                .transaction { $0.animation = nil }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            if isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(GuidePalette.secondary)
            }
        }
        .padding(.leading, 14).padding(.trailing, 12).padding(.vertical, 14)
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

            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .center, spacing: 32) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("YOUR CHANNELS")
                            .font(.inter(13, .bold)).tracking(2.2)
                            .foregroundStyle(LineupStyle.secondary)
                        Text("Arrange Favorites")
                            .font(.inter(46, .bold))
                        Text(instruction)
                            .font(.inter(.title3))
                            .foregroundStyle(LineupStyle.secondary)
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
                .background(GuidePalette.rail, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(GuidePalette.line, lineWidth: 1))
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
                Circle().fill(isPicked ? LineupStyle.text : LineupStyle.raised)
                Text("\(position)").font(.interDigits(.callout, .bold))
                    .foregroundStyle(isPicked ? GuidePalette.background : LineupStyle.secondary)
            }
            .frame(width: 44, height: 44)
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LineupStyle.raised.opacity(0.82))
                LineupArtView(url: stream.streamIcon.flatMap(URL.init(string:)), width: 100) { loaded in
                    if let image = loaded {
                        image.resizable().scaledToFit().padding(10)
                    } else {
                        Image(systemName: "tv").foregroundStyle(LineupStyle.secondary)
                    }
                }
                .transaction { $0.animation = nil }
            }
            .frame(width: 100, height: 60)
            VStack(alignment: .leading, spacing: 5) {
                Text(stream.name).font(.inter(.title3, .semibold)).lineLimit(1)
                Text(isPicked ? "Ready to move" : "Favorite channel")
                    .font(.inter(.caption)).foregroundStyle(LineupStyle.secondary)
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
        .background(isPicked ? GuidePalette.raised : GuidePalette.surface,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(
            isPicked ? LineupStyle.text : LineupStyle.line,
            lineWidth: isPicked ? 2 : 1
        ))
        .lineupFocusLayer(isFocused && !isPicked, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .leading) {
            if pickedStreamID != nil && isFocused && !isPicked {
                Capsule().fill(LineupStyle.text).frame(width: 4, height: 44).offset(x: -2)
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
        .lineupShadow(.lifted, on: isPicked || isFocused)
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
            .padding(.horizontal, 22).frame(height: 48)
            .background(LineupStyle.surface, in: Capsule())
            .foregroundStyle(LineupStyle.text)
            .overlay(Capsule().strokeBorder(LineupStyle.line, lineWidth: 1))
            .lineupFocusLayer(focused, in: Capsule())
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

/// A programme block. Coming up is a quiet card; on now is a step lighter
/// with a hairline of progress along its foot; the one the remote is on wears
/// the focus layer.
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
    let onMove: (MoveCommandDirection) -> Void
    private var isFocused: Bool { gridFocus.wrappedValue == focusID }

    private var isOnNow: Bool {
        guard let program else { return false }
        return program.start <= now && now < program.end
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 5) {
            if let program {
                HStack(spacing: 8) {
                    Text(program.title.isEmpty ? "Untitled" : program.title)
                        .font(.inter(20, isOnNow ? .semibold : .medium))
                        .foregroundStyle(isOnNow || isFocused ? GuidePalette.text : GuidePalette.text.opacity(0.82))
                        .lineLimit(1)
                    if program.isNew == true { GuideTinyBadge(title: "NEW") }
                }
                if showsTime {
                    HStack(spacing: 8) {
                        Text(guideTimeRange(program))
                            .font(.interDigits(15, .medium))
                            .foregroundStyle(GuidePalette.secondary)
                            .lineLimit(1)
                        if let quality { GuideTinyBadge(title: quality) }
                    }
                }
            } else {
                Text(empty).font(.inter(18)).foregroundStyle(GuidePalette.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: layout.rowHeight - 8, alignment: .topLeading)
        .background(isOnNow ? GuidePalette.cardNow : GuidePalette.card, in: shape)
        .overlay {
            if let program, isOnNow {
                GeometryReader { geometry in
                    let played = GuideProgress.playedWidth(
                        start: program.start, end: program.end, now: now,
                        visibleStart: guideTimelineAnchor(now),
                        pointsPerSecond: Double(layout.slotWidth) / 1800,
                        cellWidth: Double(geometry.size.width))
                    ZStack(alignment: .leading) {
                        Rectangle().fill(GuidePalette.track)
                        Rectangle().fill(GuidePalette.progress.opacity(0.85)).frame(width: CGFloat(played))
                    }
                    .frame(height: 3)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .clipShape(shape)
                .allowsHitTesting(false)
            }
        }
        .lineupFocusLayer(isFocused, in: shape)
        .zIndex(isFocused ? 2 : 0)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .contentShape(Rectangle()).focusable().focused(gridFocus, equals: focusID).focusEffectDisabled().onTapGesture(perform: onPlay)
        .onMoveCommand(perform: onMove)
        .accessibilityValue(isOnNow ? "On now" : "")
        // Keep the focused block in timeline coordinates so its fill stays aligned.
        .onChange(of: isFocused) { focused in if focused { onFocus() } }
    }
}

/// On air, as the app's small red dot.
private struct GuideLiveDot: View {
    var size: CGFloat = 10

    var body: some View {
        PulsingLiveDot(size: size)
    }
}

/// The dot and the word, for the preview of a programme on now.
private struct GuideLiveTag: View {
    var body: some View {
        HStack(spacing: 7) {
            GuideLiveDot(size: 10)
            Text("LIVE")
                .font(.inter(14, .heavy)).tracking(1.6)
                .foregroundStyle(LineupStyle.liveStatus)
        }
    }
}

private struct GuideProgressBar: View {
    let progress: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(GuidePalette.track)
                Capsule().fill(GuidePalette.progress)
                    .frame(width: proxy.size.width * min(max(progress, 0), 1))
            }
        }
    }
}

/// Now, as a red line down the grid from a mark on the time bar.
private struct GuideNowLine: View {
    @Environment(\.guideLayout) private var layout
    let now: Date

    var body: some View {
        let x = 14 + layout.channelWidth
            + CGFloat(now.timeIntervalSince(guideTimelineAnchor(now)) / 1800) * layout.slotWidth
        ZStack(alignment: .topLeading) {
            Rectangle().fill(GuidePalette.now)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
                .padding(.top, guideHeaderHeight)
                .offset(x: x - 1)
            Circle().fill(GuidePalette.now)
                .frame(width: 10, height: 10)
                .offset(x: x - 5, y: guideHeaderHeight - 5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The Account screen: what the app is connected to, and how it is doing.
///
/// Two sources side by side -- the provider that fills Live and the Guide, and
/// the media server behind Library -- each a card that says what it is,
/// whether it answers, what it holds and what can be done with it. Below them
/// the library, diagnostics and the app itself, on the same two columns, so
/// every edge on the screen lines up with another.
struct AccountView: View {
    @Binding var selectedTab: Int
    @EnvironmentObject private var library: SportsLibrary
    @EnvironmentObject private var media: MediaLibrary
    @EnvironmentObject private var cloud: CloudSettingsSync
    @State private var addingProvider = false
    @State private var addingMediaServer = false
    @State private var configuringMDBList = false

    private let columnWidth: CGFloat = 1400
    private let gutter: CGFloat = 24

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 56) {
                    header
                    sources
                    libraryAndCatalogs
                    diagnostics
                    about
                }
                .frame(width: columnWidth, alignment: .topLeading)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 56)
            }
            .background(LineupStyle.background)
            // The store decides and the store owns it, as on the Media
            // Servers tab: a load tied to this screen was cancelled by
            // leaving it, and left the flag raised behind.
            .onAppear {
                media.loadShelvesIfNeeded()
                media.loadMDBListIntegrationIfNeeded()
            }
            .onChange(of: media.activeProfile?.id) { _, _ in media.loadShelvesIfNeeded() }
            .sheet(isPresented: $addingProvider) {
                ProfileSetupView().environmentObject(library)
            }
            .sheet(isPresented: $addingMediaServer) {
                MediaServerSetupView().environmentObject(media)
            }
            .sheet(isPresented: $configuringMDBList) {
                MDBListIntegrationView().environmentObject(media)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SETTINGS")
                .font(.inter(13, .bold)).tracking(2.2)
                .foregroundStyle(LineupStyle.secondary)
            Text("Account")
                .font(.inter(52, .bold))
                .foregroundStyle(LineupStyle.text)
            Text("Your sources, your library, and how the app is running.")
                .font(.inter(21))
                .foregroundStyle(LineupStyle.secondary)
        }
    }

    // MARK: Sources

    private var sources: some View {
        VStack(alignment: .leading, spacing: 22) {
            AccountSectionHeading("SOURCES")
            HStack(alignment: .top, spacing: gutter) {
                providerCard
                mediaCard
            }
            .fixedSize(horizontal: false, vertical: true)
            // Switching between servers is a list, not a card: a viewer with
            // one server -- almost everyone -- should not be shown a chooser
            // for it. It appears when there is a choice to make.
            if media.profiles.count > 1 {
                VStack(spacing: 0) {
                    ForEach(media.profiles) { profile in
                        AccountServerChoice(profile: profile,
                                            active: media.activeProfile?.id == profile.id)
                    }
                }
                .background(LineupStyle.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    @ViewBuilder private var providerCard: some View {
        if let profile = library.activeProfile {
            AccountSourceCard(
                symbol: "antenna.radiowaves.left.and.right",
                kind: "IPTV PROVIDER",
                title: profile.name,
                subtitle: "\(profile.username) · \(URL(string: profile.serverURL)?.host ?? profile.serverURL)",
                status: library.channelsAreSyncing ? .busy("Updating")
                    : (library.streams.isEmpty ? .offline : .connected),
                stats: [
                    AccountStat("Channels", library.streams.count),
                    AccountStat("Favorites", library.favoriteStreamOrder.count),
                    AccountStat("Teams", library.teamPreferences.listed().count)
                ],
                refreshed: library.lastRefreshedAt
            ) {
                AccountButton(title: "Refresh", symbol: "arrow.clockwise") {
                    Task { await library.reload() }
                }
                .disabled(library.channelsAreSyncing || library.isSwitchingProfile)
                AccountButton(title: "Guide", symbol: "list.bullet.rectangle") { selectedTab = 1 }
                AccountButton(title: "Remove", symbol: "trash", quiet: true) {
                    library.removeActiveProfile()
                }
            }
        } else {
            AccountEmptySource(
                symbol: "antenna.radiowaves.left.and.right",
                kind: "IPTV PROVIDER",
                title: "No provider",
                detail: "Add your IPTV login to fill Live and the guide."
            ) {
                // The first-run screen is the only other place to sign in, and
                // it never returns once a media server is saved.
                AccountButton(title: "Add IPTV Provider", symbol: "plus", prominent: true) {
                    addingProvider = true
                }
            }
        }
    }

    @ViewBuilder private var mediaCard: some View {
        if let profile = media.activeProfile {
            AccountSourceCard(
                symbol: "play.square.stack",
                kind: "MEDIA SERVER",
                title: profile.name,
                subtitle: "\(profile.username) · \(URL(string: profile.serverURL)?.host ?? profile.serverURL)",
                status: media.isLoading ? .busy("Connecting") : (media.isConnected ? .connected : .offline),
                stats: [
                    AccountStat("Movies", media.libraryCounts?.movies),
                    AccountStat("Shows", media.libraryCounts?.shows),
                    AccountStat("Episodes", media.libraryCounts?.episodes)
                ],
                refreshed: media.lastRefreshedAt
            ) {
                AccountButton(title: "Reload", symbol: "arrow.clockwise") {
                    Task { await media.reload() }
                }
                .disabled(media.isLoading)
                AccountButton(title: "Browse", symbol: "square.grid.2x2") { selectedTab = 2 }
                AccountButton(title: "Add", symbol: "plus") { addingMediaServer = true }
                if media.profiles.count == 1 {
                    AccountButton(title: "Remove", symbol: "trash", quiet: true) {
                        media.remove(profile)
                    }
                }
            }
        } else {
            AccountEmptySource(
                symbol: "play.square.stack",
                kind: "MEDIA SERVER",
                title: "No media server",
                detail: "Connect a Jellyfin-compatible server to watch your own library."
            ) {
                AccountButton(title: "Add Media Server", symbol: "plus", prominent: true) {
                    addingMediaServer = true
                }
            }
        }
    }

    // MARK: Library

    private var libraryAndCatalogs: some View {
        VStack(alignment: .leading, spacing: 22) {
            AccountSectionHeading("LIBRARY")
            HStack(alignment: .top, spacing: gutter) {
                AccountTile(
                    title: "Library Hero",
                    detail: media.heroCatalog.map { "Top 10 from \($0.title)" }
                        ?? "Choose the catalog shown across the top of Library",
                    symbol: "sparkles.rectangle.stack"
                ) {
                    LibraryHeroSettingsView().environmentObject(media)
                }
                .disabled(media.activeProfile == nil)
                catalogs
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// MDBList, which turns the viewer's lists into Library shelves.
    @ViewBuilder private var catalogs: some View {
        if media.isMDBListConnected {
            let account = media.mdbListAccount
            AccountSourceCard(
                symbol: "rectangle.stack.badge.play",
                kind: "CATALOGS",
                title: "MDBList",
                subtitle: account.map { "@\($0.username) · \($0.plan ?? "Connected")" } ?? "Catalog discovery",
                status: media.isMDBListLoading ? .busy("Updating") : .connected,
                stats: [
                    AccountStat("Catalogs", media.mdbListCatalogs.count),
                    AccountStat("Requests Left", account?.requestsRemaining),
                    AccountStat("Daily Limit", account?.dailyLimit)
                ],
                refreshed: nil
            ) {
                AccountButton(title: "Configure", symbol: "gearshape") { configuringMDBList = true }
                AccountButton(title: "Refresh", symbol: "arrow.clockwise") {
                    Task { await media.loadMDBListIntegration() }
                }
                .disabled(media.isMDBListLoading)
            }
        } else {
            AccountEmptySource(
                symbol: "rectangle.stack.badge.play",
                kind: "CATALOGS",
                title: "MDBList",
                detail: "Connect MDBList to use your movie and show lists as Library shelves."
            ) {
                AccountButton(title: "Connect MDBList", symbol: "link", prominent: true) {
                    configuringMDBList = true
                }
            }
        }
    }

    // MARK: Diagnostics and about

    /// The two screens that answer "why did it do that", side by side.
    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 22) {
            AccountSectionHeading("DIAGNOSTICS")
            HStack(alignment: .top, spacing: gutter) {
                AccountTile(title: "Channel matching", detail: "Why each game chose its channel",
                            symbol: "point.3.connected.trianglepath.dotted") { MatchDiagnosticsView() }
                AccountTile(title: "Launch timing", detail: "Where the last start spent its time",
                            symbol: "speedometer") { TVStartupTraceView() }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 22) {
            AccountSectionHeading("ABOUT")
            HStack(spacing: gutter) {
                AccountRow(label: "iCloud", value: cloud.status)
                AccountRow(label: "Version",
                           value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.1")
            }
        }
    }
}

/// A section's name, small and spaced, with a hairline running out from it.
private struct AccountSectionHeading: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        HStack(spacing: 18) {
            Text(title)
                .font(.inter(13, .bold)).tracking(2.4)
                .foregroundStyle(LineupStyle.secondary)
            Rectangle().fill(LineupStyle.line).frame(height: 1)
        }
    }
}

/// One figure on a card: a number over its name.
private struct AccountStat: Identifiable {
    let label: String
    let count: Int?
    var id: String { label }

    init(_ label: String, _ count: Int?) {
        self.label = label
        self.count = count
    }
}

/// Whether a source answers, in words with a mark beside them.
private enum AccountSourceStatus {
    case connected, offline
    case busy(String)

    var title: String {
        switch self {
        case .connected: "Connected"
        case .offline: "Offline"
        case .busy(let word): word
        }
    }
}

private struct AccountStatusMark: View {
    let status: AccountSourceStatus

    var body: some View {
        HStack(spacing: 9) {
            switch status {
            case .connected:
                Circle().fill(LineupStyle.text).frame(width: 8, height: 8)
            case .offline:
                Circle().strokeBorder(LineupStyle.secondary, lineWidth: 1.5).frame(width: 9, height: 9)
            case .busy:
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 9, height: 9)
            }
            Text(status.title.uppercased())
                .font(.inter(13, .bold)).tracking(1.6)
        }
        .foregroundStyle(tint)
        .fixedSize()
    }

    private var tint: Color {
        if case .connected = status { return LineupStyle.text }
        return LineupStyle.secondary
    }
}

/// A connected source: what it is, whether it answers, what it holds, and
/// what can be done with it, in that order from the top.
private struct AccountSourceCard<Actions: View>: View {
    let symbol: String
    let kind: String
    let title: String
    let subtitle: String
    let status: AccountSourceStatus
    let stats: [AccountStat]
    let refreshed: Date?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .top, spacing: 18) {
                AccountGlyph(symbol: symbol)
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind)
                        .font(.inter(12, .bold)).tracking(2)
                        .foregroundStyle(LineupStyle.secondary)
                    Text(title)
                        .font(.inter(28, .bold)).foregroundStyle(LineupStyle.text)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text(subtitle)
                        .font(.inter(17)).foregroundStyle(LineupStyle.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                AccountStatusMark(status: status)
            }
            HStack(spacing: 0) {
                ForEach(Array(stats.enumerated()), id: \.element.id) { index, stat in
                    if index > 0 {
                        Rectangle().fill(LineupStyle.line).frame(width: 1, height: 52)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(stat.count.map { $0.formatted() } ?? "—")
                            .font(.interDigits(34, .bold)).foregroundStyle(LineupStyle.text)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text(stat.label.uppercased())
                            .font(.inter(12, .bold)).tracking(1.6)
                            .foregroundStyle(LineupStyle.secondary)
                            .lineLimit(1)
                    }
                    .padding(.leading, index > 0 ? 24 : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 12) { actions }
            if let refreshed {
                Text("Updated \(refreshed, style: .relative) ago")
                    .font(.inter(14)).foregroundStyle(LineupStyle.secondary)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LineupStyle.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(LineupStyle.line, lineWidth: 1))
    }
}

/// A source that is not connected, in the shape of the card that would be
/// there if it were, holding the one action that connects it.
private struct AccountEmptySource<Action: View>: View {
    let symbol: String
    let kind: String
    let title: String
    let detail: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .top, spacing: 18) {
                AccountGlyph(symbol: symbol)
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind)
                        .font(.inter(12, .bold)).tracking(2)
                        .foregroundStyle(LineupStyle.secondary)
                    Text(title)
                        .font(.inter(28, .bold)).foregroundStyle(LineupStyle.text)
                    Text(detail)
                        .font(.inter(17)).foregroundStyle(LineupStyle.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            HStack(spacing: 12) { action }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LineupStyle.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(LineupStyle.line, style: StrokeStyle(lineWidth: 1, dash: [6, 6])))
    }
}

/// A card's symbol, on a raised disc.
private struct AccountGlyph: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(LineupStyle.text)
            .frame(width: 64, height: 64)
            .background(LineupStyle.raised, in: Circle())
    }
}

/// A media server to switch to, in the list that appears when there is more
/// than one.
private struct AccountServerChoice: View {
    @EnvironmentObject private var media: MediaLibrary
    @FocusState private var isFocused: Bool
    let profile: MediaServerProfile
    let active: Bool

    var body: some View {
        HStack(spacing: 20) {
            Circle().fill(active && media.isConnected ? LineupStyle.text : LineupStyle.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name).font(.inter(22, .semibold)).foregroundStyle(LineupStyle.text)
                Text(URL(string: profile.serverURL)?.host ?? profile.serverURL)
                    .font(.inter(16)).foregroundStyle(LineupStyle.secondary)
            }
            Spacer(minLength: 20)
            Text(active ? "ACTIVE" : "SELECT")
                .font(.inter(13, .bold)).tracking(1.6)
                .foregroundStyle(active ? LineupStyle.text : LineupStyle.secondary)
            Button("Remove", role: .destructive) { media.remove(profile) }
                .lineupButtonStyle()
        }
        .padding(.horizontal, 30).padding(.vertical, 22)
        .lineupFocusLayer(isFocused, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
        .focusable().focused($isFocused).focusEffectDisabled()
        .onTapGesture { if !active { Task { await media.select(profile) } } }
    }
}

/// A tile that goes somewhere, sized like its neighbour so a row of them reads
/// as a row rather than as whatever length each title happened to be.
private struct AccountTile<Destination: View>: View {
    @Environment(\.isEnabled) private var enabled
    @FocusState private var isFocused: Bool
    let title: String
    let detail: String
    let symbol: String
    @ViewBuilder var destination: Destination

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        NavigationLink { destination } label: {
            HStack(spacing: 20) {
                AccountGlyph(symbol: symbol)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.inter(24, .bold)).foregroundStyle(LineupStyle.text)
                    Text(detail).font(.inter(17)).lineLimit(2)
                        .foregroundStyle(LineupStyle.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(LineupStyle.secondary)
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .frame(minHeight: 132)
            .background(LineupStyle.surface, in: shape)
            .overlay(shape.strokeBorder(LineupStyle.line, lineWidth: 1))
            .lineupFocusLayer(isFocused, in: shape)
            .scaleEffect(isFocused ? LineupStyle.cardLift : 1)
            .lineupShadow(.lifted, on: isFocused)
            .opacity(enabled ? 1 : 0.45)
        }
        .lineupFlatButton()
        .focused($isFocused)
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

/// A button on a card. Standard is a raised capsule, prominent adds a white
/// edge for the one thing a card is asking for, and quiet is an outline for
/// what removes something.
private struct AccountButton: View {
    @Environment(\.isEnabled) private var enabled
    @FocusState private var isFocused: Bool
    let title: String
    let symbol: String
    var prominent = false
    var quiet = false
    let action: () -> Void

    var body: some View {
        let shape = Capsule()
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.inter(18, .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(quiet && !isFocused ? LineupStyle.secondary : LineupStyle.text)
                .padding(.horizontal, 24).frame(height: 56)
                .frame(maxWidth: .infinity)
                .background(quiet ? Color.clear : LineupStyle.raised, in: shape)
                .overlay(shape.strokeBorder(prominent ? LineupStyle.text.opacity(0.7) : LineupStyle.line,
                                            lineWidth: prominent ? 1.5 : 1))
                .lineupFocusLayer(isFocused, in: shape)
                .scaleEffect(isFocused ? LineupStyle.controlLift : 1)
                .opacity(enabled ? 1 : 0.45)
        }
        .lineupFlatButton()
        .focused($isFocused)
        .animation(.easeOut(duration: 0.18), value: isFocused)
        .frame(maxWidth: .infinity)
    }
}

/// The last launch, step by step -- the same trace the phone shows.
///
/// It was being recorded on the television all along and thrown away, because
/// only the phone had a screen to read it on. Which meant the one question
/// worth asking about a slow start on a set -- which part is slow -- could
/// only be guessed at, and guessing is what cost days on the phone.
private struct TVStartupTraceView: View {
    @ObservedObject private var trace = StartupTrace.shared

    var body: some View {
        ScrollView {
            Text(trace.report)
                .font(.system(size: 21, design: .monospaced))
                .foregroundStyle(LineupStyle.lightPurple)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(40)
        }
        .focusable()
        .background(LineupStyle.background)
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
        .background(LineupStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .lineupFocusLayer(focused, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .focusable().focused($focused).focusEffectDisabled()
        .accessibilityElement(children: .combine)
    }
}

private struct AccountRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text(label.uppercased())
                .font(.inter(13, .bold)).tracking(1.8)
                .foregroundStyle(LineupStyle.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.inter(19, .medium)).foregroundStyle(LineupStyle.text)
                .multilineTextAlignment(.trailing).lineLimit(2)
        }
        .padding(.horizontal, 28).padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .background(LineupStyle.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
    let primaryGame: SportsGame?
    let secondaryGame: SportsGame?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let expandedPane {
                MultiviewPane(
                    stream: expandedPane == 0 ? primary : secondary,
                    game: expandedPane == 0 ? primaryGame : secondaryGame,
                    urls: expandedPane == 0 ? primaryURLs : secondaryURLs,
                    audible: true,
                    expanded: true,
                    onExpand: {}
                )
            } else {
                HStack(spacing: 2) {
                    MultiviewPane(stream: primary, game: primaryGame, urls: primaryURLs,
                                  audible: focusedPane == 0, expanded: false) {
                        expandedPane = 0
                    }
                    .focusable().focused($focusedPane, equals: 0).focusEffectDisabled()

                    MultiviewPane(stream: secondary, game: secondaryGame, urls: secondaryURLs,
                                  audible: focusedPane == 1, expanded: false) {
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
    @EnvironmentObject private var library: SportsLibrary
    @StateObject private var controller = VLCPlaybackController()
    @State private var choosingGame: SportsGame?
    @State private var chosenTitle: String?
    let stream: XtreamStream
    let game: SportsGame?
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
                    Text("Stream unavailable").foregroundColor(LineupStyle.mediaText).font(.inter(.headline))
                }
                .foregroundStyle(LineupStyle.mediaText).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 10) {
                Image(systemName: audible ? "speaker.wave.2.fill" : "speaker.slash.fill")
                Text(controller.activeChannelName ?? chosenTitle ?? stream.name)
                    .foregroundColor(LineupStyle.mediaText).font(.inter(.callout, .semibold)).lineLimit(1)
                Spacer()
                if !expanded { Text("SELECT TO EXPAND").foregroundColor(LineupStyle.mediaText).font(.inter(.caption2, .bold)).tracking(1.1) }
            }
            .foregroundStyle(LineupStyle.mediaText)
            .padding(.horizontal, 18).frame(height: 50)
            .background(Color.black.opacity(0.56))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 0, style: .continuous))
        .overlay {
            if !expanded {
                RoundedRectangle(cornerRadius: 0, style: .continuous)
                    .stroke(audible ? LineupStyle.mediaAccent.opacity(0.92) : LineupStyle.mediaAccent.opacity(0.18), lineWidth: audible ? 3 : 1)
            }
        }
        .scaleEffect(!expanded && audible ? 1.012 : 1)
        .shadow(color: !expanded && audible ? LineupStyle.mediaAccent.opacity(0.16) : .clear, radius: 18)
        .animation(.easeOut(duration: 0.18), value: audible)
        .contentShape(Rectangle()).onTapGesture(perform: onExpand)
        .contextMenu {
            Button("Retry Stream", systemImage: "arrow.clockwise") {
                controller.retry()
            }
        }
        .sheet(item: $choosingGame) { game in
            ManualGameChannelPicker(game: game) { chosen in
                library.saveGameSelection(chosen, for: game)
                choosingGame = nil
                chosenTitle = chosen.name
                controller.start(urls: library.playbackURLs(for: chosen), muted: !audible,
                                 channelID: chosen.id)
            }
        }
        .onAppear {
            if let game {
                configureGameFailover(controller, game: game, library: library) { choosingGame = game }
            }
            controller.start(urls: urls, muted: !audible, channelID: stream.id)
        }
        .onChange(of: audible) { _, value in controller.setMuted(!value) }
        .onDisappear { controller.stop() }
    }
}

struct PlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: SportsLibrary
    let urls: [URL]
    var title: String = "Live TV"
    var program: CurrentProgram?
    var isLive = true
    var initialPosition: TimeInterval? = nil
    var onProgress: ((TimeInterval, TimeInterval) -> Void)? = nil
    var game: SportsGame? = nil
    var channelID: Int? = nil
    @StateObject private var controller = VLCPlaybackController()
    @State private var choosingGame: SportsGame?
    @State private var chosenTitle: String?
    @State private var controlsVisible = true
    @State private var hideControlsTask: Task<Void, Never>?
    @FocusState private var focusedControl: TVPlayerControl?
    @FocusState private var surfaceFocused: Bool
    @State private var lastReportedPosition: TimeInterval = 0

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
                TVPlayerChrome(title: controller.activeChannelName ?? chosenTitle ?? title,
                    program: program, isLive: isLive, controller: controller,
                    focusedControl: $focusedControl, onInteraction: keepControlsVisible)
                    .transition(.opacity)
            }
            if urls.isEmpty {
                Text("This stream is unavailable").font(.inter(.title2))
                    .foregroundStyle(LineupStyle.mediaText).padding(60)
            }
        }
        .background(Color.black)
        .sheet(item: $choosingGame) { game in
            ManualGameChannelPicker(game: game) { chosen in
                library.saveGameSelection(chosen, for: game)
                choosingGame = nil
                chosenTitle = chosen.name
                controller.start(urls: library.playbackURLs(for: chosen), channelID: chosen.id)
            }
        }
        .onPlayPauseCommand { controller.togglePlayback(); revealControls() }
        .onExitCommand { reportProgress(force: true); controller.stop(); dismiss() }
        .onAppear {
            if let game {
                configureGameFailover(controller, game: game, library: library) { choosingGame = game }
            }
            controller.start(urls: urls, initialPosition: isLive ? nil : initialPosition,
                             channelID: channelID)
            revealControls(focus: true)
        }
        .onDisappear { reportProgress(force: true); hideControlsTask?.cancel(); controller.stop() }
        .onChange(of: controller.elapsed) { _, _ in reportProgress() }
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

    private func reportProgress(force: Bool = false) {
        guard !isLive, controller.duration > 0 else { return }
        guard force || abs(controller.elapsed - lastReportedPosition) >= 5 else { return }
        lastReportedPosition = controller.elapsed
        onProgress?(controller.elapsed, controller.duration)
    }

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

private enum TVPlayerControl: Hashable { case scrubber, playPause, goLive, mute, subtitles, quality }

private struct TVPlayerChrome: View {
    @State private var showingQuality = false
    @State private var showingSubtitles = false
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
                            if isLive { PulsingLiveDot(size: 8) }
                            Text(isLive ? (controller.isAtLiveEdge ? "LIVE" : "BEHIND LIVE") : "NOW PLAYING")
                                .font(.inter(15, .bold)).tracking(1.5)
                                .foregroundStyle(isLive ? LineupStyle.liveStatus : LineupStyle.mediaText)
                        }
                        Text(nowPlayingTitle).font(.inter(36, .semibold)).lineLimit(1)
                        if let subtitle { Text(subtitle).font(.inter(19, .medium)).opacity(0.78).lineLimit(1) }
                        if let detail = program?.detail, !detail.isEmpty {
                            Text(detail).font(.inter(16)).opacity(0.62).lineLimit(1)
                        }
                    }
                    .foregroundStyle(LineupStyle.mediaText)
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
                        if !isLive && controller.subtitleTracks.count > 1 {
                            TVSelectable(scale: LineupStyle.controlLift, action: { showingSubtitles = true }) {
                                TVPlayerMenuLabel(title: "Subtitles · \(controller.selectedSubtitleTitle)",
                                                  symbol: "captions.bubble.fill",
                                                  focused: focusedControl.wrappedValue == .subtitles)
                            }
                            .focused(focusedControl, equals: .subtitles)
                            .confirmationDialog("Subtitles", isPresented: $showingSubtitles,
                                                titleVisibility: .visible) {
                                ForEach(controller.subtitleTracks) { track in
                                    Button(track.title + (track.id == controller.selectedSubtitleID ? "  ✓" : "")) {
                                        controller.selectSubtitle(track)
                                        onInteraction()
                                    }
                                }
                                Button("Cancel", role: .cancel) { onInteraction() }
                            }
                        }
                        // A Menu renders through tvOS's own chrome, so this is a
                        // plain selectable with a dialog, like every other control.
                        TVSelectable(scale: LineupStyle.controlLift, action: { showingQuality = true }) {
                            TVPlayerMenuLabel(title: "Quality · \(controller.qualityLabel)",
                                              symbol: "gearshape.fill",
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
            .background(prominent ? LineupStyle.raised : LineupStyle.surface.opacity(0.88),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(LineupStyle.line, lineWidth: 1))
            .lineupFocusLayer(selected, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
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
    let symbol: String
    let focused: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 17, weight: .bold))
            Text(title).font(.inter(18, .semibold)).fixedSize()
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .bold)).opacity(0.72)
        }
        .foregroundStyle(LineupStyle.lightPurple)
        .padding(.horizontal, 18).frame(height: 52)
        .background(LineupStyle.surface.opacity(0.88),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(LineupStyle.line, lineWidth: 1))
        .lineupFocusLayer(focused, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
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
    @Published private(set) var activeChannelName: String?
    @Published private(set) var failoverNotice: String?
    @Published private(set) var subtitleTracks: [PlaybackSubtitleTrack] = [.off]
    @Published private(set) var selectedSubtitleID = PlaybackSubtitleTrack.off.id
    /// Seconds. Zero duration means the item is not seekable, which is how a
    /// live channel presents, so the seek bar simply does not appear for it.
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    private var monitor: Task<Void, Never>?
    private var urls: [URL] = []
    private var urlIndex = 0
    private var muted = false
    private var pausedByUser = false
    private var requestedInitialPosition: TimeInterval?
    private var appliedInitialPosition = false
    private var health = LivePlaybackHealth(now: ProcessInfo.processInfo.systemUptime)
    private var retries = LivePlaybackRetry()
    private var retryAt: TimeInterval?
    struct FailoverContext {
        let plan: @MainActor () -> [FailoverChannel]
        let urls: @MainActor (Int) -> [URL]
        let didPlay: @MainActor (Int) -> Void
        let chooseChannel: @MainActor () -> Void
    }
    var failover: FailoverContext?
    private var currentChannelID: Int?
    private var pendingWorkingChannelID: Int?
    private var failoverState = StreamFailoverState()
    private var noticeTask: Task<Void, Never>?

    var isAtLiveEdge: Bool { isPlaying && !pausedByUser }
    var selectedSubtitleTitle: String {
        subtitleTracks.first(where: { $0.id == selectedSubtitleID })?.title ?? "Off"
    }
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

    func start(urls: [URL], muted: Bool = false, initialPosition: TimeInterval? = nil,
               channelID: Int? = nil, resetFailover: Bool = true) {
        stop()
        self.urls = Array(urls.reversed())
        self.muted = muted
        currentChannelID = channelID
        if resetFailover {
            failoverState.reset()
            activeChannelName = nil
            failoverNotice = nil
        }
        requestedInitialPosition = initialPosition
        appliedInitialPosition = false
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
        resetSubtitles()
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
        if duration > 0, !appliedInitialPosition, let requestedInitialPosition,
           requestedInitialPosition >= 10, requestedInitialPosition < duration - 30 {
            let target = min(max(requestedInitialPosition, 0), duration - 1)
            player.position = Float(target / duration)
            elapsed = target
            appliedInitialPosition = true
            return
        }
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
        refreshSubtitleTracks()
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
        if health.isStable(now: now) {
            retries.reset()
            if let id = pendingWorkingChannelID, id == currentChannelID {
                pendingWorkingChannelID = nil
                failover?.didPlay(id)
            }
        }
        isPlaying = player.isPlaying
        if player.isPlaying && player.hasVideoOut {
            reconnecting = false
            let height = Int(player.videoSize.height)
            if height > 0 { videoHeight = height }
        }
        guard recover else { return }
        player.stop()
        guard let delay = retries.nextDelay() else {
            if switchToNextChannel() { return }
            error = "The stream disconnected. Select Retry to reconnect."
            reconnecting = false
            return
        }
        // Retry the current transport once, then try the channel's alternatives.
        if retries.attempts > 1 { urlIndex = (urlIndex + 1) % urls.count }
        reconnecting = true
        retryAt = now + delay
    }

    private func switchToNextChannel() -> Bool {
        guard let failover else { return false }
        while let next = failoverState.next(from: failover.plan(), current: currentChannelID) {
            let nextURLs = failover.urls(next.streamID)
            guard !nextURLs.isEmpty else { continue }
            start(urls: nextURLs, muted: muted, channelID: next.streamID, resetFailover: false)
            activeChannelName = next.name
            pendingWorkingChannelID = next.streamID
            failoverNotice = next.notice
            noticeTask?.cancel()
            noticeTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self?.failoverNotice = nil
            }
            return true
        }
        return false
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
        isMuted = muted
        player.audio?.isMuted = muted
    }
    func toggleMute() { setMuted(!muted) }
    func retry() { start(urls: Array(urls.reversed()), muted: muted, channelID: currentChannelID) }
    func goLive() {
        guard !urls.isEmpty else { return }
        start(urls: Array(urls.reversed()), muted: muted, channelID: currentChannelID)
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

    func selectSubtitle(_ track: PlaybackSubtitleTrack) {
        player.currentVideoSubTitleIndex = Int32(track.engineIndex ?? -1)
        selectedSubtitleID = track.id
    }

    /// VLCKit discovers tracks only after the container starts parsing. The
    /// playback monitor is already the one place sampled on that cadence, so
    /// refresh here and publish only when the list or selection actually
    /// changes. No second timer and no UI churn while a film is playing.
    private func refreshSubtitleTracks() {
        let names = (player.videoSubTitlesNames as? [String]) ?? []
        let indexes = ((player.videoSubTitlesIndexes as? [NSNumber]) ?? []).map(\.intValue)
        let discovered = PlaybackSubtitleTrack.vlcTracks(names: names, indexes: indexes)
        if discovered != subtitleTracks { subtitleTracks = discovered }
        let current = Int(player.currentVideoSubTitleIndex)
        let selected = discovered.first(where: { $0.engineIndex == current })?.id
            ?? PlaybackSubtitleTrack.off.id
        if selected != selectedSubtitleID { selectedSubtitleID = selected }
    }

    private func resetSubtitles() {
        subtitleTracks = [.off]
        selectedSubtitleID = PlaybackSubtitleTrack.off.id
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        retryAt = nil
        pendingWorkingChannelID = nil
        urls = []
        pausedByUser = false
        reconnecting = false
        isPlaying = false
        videoHeight = 0
        duration = 0
        elapsed = 0
        resetSubtitles()
        player.stop()
        player.media = nil
    }
}

@MainActor private func configureGameFailover(_ controller: VLCPlaybackController,
                                               game: SportsGame, library: SportsLibrary,
                                               chooseChannel: @escaping @MainActor () -> Void) {
    controller.failover = VLCPlaybackController.FailoverContext(
        plan: { library.failoverPlan(for: game) },
        urls: { id in library.stream(withID: id).map { library.playbackURLs(for: $0) } ?? [] },
        didPlay: { id in
            if let working = library.stream(withID: id) {
                library.saveGameSelection(working, for: game)
            }
        },
        chooseChannel: chooseChannel)
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
                if let choose = controller.failover?.chooseChannel {
                    Button("Choose Another Channel", action: choose).lineupButtonStyle()
                }
            }
            .padding(24).background(Color.black.opacity(0.8))
        } else if let notice = controller.failoverNotice {
            Text(notice).font(.inter(.callout)).foregroundStyle(LineupStyle.mediaText)
                .padding(14).background(Color.black.opacity(0.8))
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
