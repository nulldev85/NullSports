import SwiftUI
import UIKit
import VLCKit

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
    @State private var playbackTransitionID: UUID?

    private var dayStart: Date { Calendar.current.startOfDay(for: Date()) }
    private var horizon: Date { Calendar.current.date(byAdding: .day, value: 2, to: dayStart) ?? dayStart }
    private var events: [SportsGame] { library.games(for: selectedLeague).filter { $0.isLive || ($0.start >= dayStart && $0.start < horizon) } }
    private var tickerEvents: [SportsGame] { library.scoreTickerGames() }
    private var liveEvents: [SportsGame] { events.filter { $0.isLive } }
    private var upcomingEvents: [SportsGame] { events.filter { $0.isUpcoming } }

    var body: some View {
        GeometryReader { container in
            NavigationStack {
                Group {
                    if library.isLoading && events.isEmpty {
                        ProgressView("Loading channels…")
                    } else if events.isEmpty {
                        LiveEmptySlateDashboard(
                            tickerEvents: tickerEvents,
                            selectedLeague: $selectedLeague,
                            focusedGame: $focusedGame,
                            isLoading: library.isScheduleLoading,
                            isAvailable: library.scheduleAvailable(for: selectedLeague),
                            errorMessage: library.scheduleErrorMessage
                        )
                    } else {
                        LiveSlateDashboard(
                            events: events,
                            tickerEvents: tickerEvents,
                            selectedLeague: $selectedLeague,
                            focusedGame: $focusedGame,
                            previewStream: previewStream,
                            previewURLs: previewStream.map { library.playbackURLs(for: $0) } ?? [],
                            multiviewPrimaryID: multiviewPrimary?.id,
                            multiviewTitle: multiviewPrimary?.name,
                            isUpdating: library.isScheduleLoading,
                            onPlay: select,
                            onStartMultiview: startMultiview,
                            onCancelMultiview: { multiviewPrimary = nil },
                            onStopPreview: stopPreview
                        )
                    }
                }
                .frame(width: container.size.width, height: container.size.height)
                .clipped()
            }
            .frame(width: container.size.width, height: container.size.height)
            .background(
                ZStack {
                    NullSportsStyle.background
                    RadialGradient(colors: [Color.white.opacity(0.055), .clear], center: .topTrailing, startRadius: 20, endRadius: 720)
                }.ignoresSafeArea()
            )
            .fullScreenCover(item: $selectedStream) { stream in PlayerView(urls: library.playbackURLs(for: stream)) }
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
                    library.refreshSchedule(showsLoading: false)
                }
            }
            .onChange(of: isActive) { _, active in
                if !active { stopPreview() }
            }
#if DEBUG
            .onAppear {
                let tabBounds = container.frame(in: .global)
                print("[LiveLayout] tab content bounds=\(tabBounds) dashboard=\(container.size)")
                assert(abs(tabBounds.width - container.size.width) < 1 && abs(tabBounds.height - container.size.height) < 1)
            }
#endif
        }
        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
        .background(NullSportsStyle.background.ignoresSafeArea())
    }

    private func select(_ game: SportsGame) {
        guard let stream = library.stream(for: game) else { return }
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
            }
            return
        }
        guard primary.id != stream.id else { return }
        multiviewPrimary = nil
        multiviewSession = MultiviewSession(primary: primary, secondary: stream)
    }

    private func startMultiview(_ game: SportsGame) {
        guard let stream = library.stream(for: game) else { return }
        stopPreview()
        multiviewPrimary = stream
    }

    private func stopPreview() {
        playbackTransitionID = nil
        previewStream = nil
        previewGameID = nil
    }
}

private struct LiveEmptySlateDashboard: View {
    let tickerEvents: [SportsGame]
    @Binding var selectedLeague: SportsLeague?
    @Binding var focusedGame: SportsGame?
    let isLoading: Bool
    let isAvailable: Bool
    let errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                LiveLeagueFilterButton(title: "ALL SPORTS", league: nil, selected: selectedLeague == nil, onMoveDown: {}) {
                    selectedLeague = nil
                    focusedGame = nil
                }
                ForEach(SportsLeague.allCases) { league in
                    LiveLeagueFilterButton(title: league.shortName, league: league, selected: selectedLeague == league, onMoveDown: {}) {
                        selectedLeague = league
                        focusedGame = nil
                    }
                }
                Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.system(size: 20, weight: .medium, design: .serif)).italic()
                    .foregroundStyle(NullSportsStyle.secondary)
                Spacer()
                Text("0 LIVE  ·  0 SCHEDULED")
                    .font(.caption.weight(.bold)).tracking(2).foregroundStyle(NullSportsStyle.secondary)
            }
            .padding(.horizontal, 42).frame(height: 62)
            .overlay(alignment: .bottom) { Rectangle().fill(NullSportsStyle.line).frame(height: 1) }

            EmptySchedule(isLoading: isLoading, isAvailable: isAvailable, errorMessage: errorMessage)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            LiveTicker(events: tickerEvents)
                .frame(height: 54)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LiveSlateDashboard: View {
    @State private var requestedGameFocusID: String?
    let events: [SportsGame]
    let tickerEvents: [SportsGame]
    @Binding var selectedLeague: SportsLeague?
    @Binding var focusedGame: SportsGame?
    let previewStream: XtreamStream?
    let previewURLs: [URL]
    let multiviewPrimaryID: Int?
    let multiviewTitle: String?
    let isUpdating: Bool
    let onPlay: (SportsGame) -> Void
    let onStartMultiview: (SportsGame) -> Void
    let onCancelMultiview: () -> Void
    let onStopPreview: () -> Void

    private var featured: SportsGame { focusedGame.flatMap { focused in events.first(where: { $0.id == focused.id }) } ?? events[0] }
    private var liveCount: Int { events.filter(\.isLive).count }
    private var scheduledCount: Int { events.filter(\.isUpcoming).count }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                LiveLeagueFilterButton(title: "ALL SPORTS", league: nil, selected: selectedLeague == nil, onMoveDown: focusFirstGame) {
                    selectedLeague = nil; focusedGame = nil
                }
                ForEach(SportsLeague.allCases) { league in
                    LiveLeagueFilterButton(title: league.shortName, league: league, selected: selectedLeague == league, onMoveDown: focusFirstGame) {
                        selectedLeague = league; focusedGame = nil
                    }
                }
                Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.system(size: 20, weight: .medium, design: .serif)).italic()
                    .foregroundStyle(NullSportsStyle.secondary)
                Spacer()
                if let multiviewTitle {
                    Text("MULTIVIEW · CHOOSE SECOND GAME · \(multiviewTitle)")
                        .font(.caption2.weight(.bold)).tracking(1.2).lineLimit(1)
                    GuideHeaderButton(title: "Cancel", symbol: "xmark", action: onCancelMultiview)
                }
                if isUpdating { ProgressView().controlSize(.small) }
                PulsingLiveDot(size: 8)
                Text("\(liveCount) LIVE  ·  \(scheduledCount) SCHEDULED")
                    .font(.caption.weight(.bold)).tracking(2).foregroundStyle(NullSportsStyle.secondary)
            }
            .padding(.horizontal, 42).frame(height: 62)
            .overlay(alignment: .bottom) { Rectangle().fill(NullSportsStyle.line).frame(height: 1) }

            HStack(spacing: 0) {
                Group {
                    if let previewStream {
                        LiveSelectedPreview(stream: previewStream, urls: previewURLs)
                            .id(previewStream.id)
                    } else {
                        LiveGameHero(game: featured)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                LiveGameSlate(
                    events: events,
                    focusedGame: $focusedGame,
                    requestedFocusID: $requestedGameFocusID,
                    multiviewPrimaryID: multiviewPrimaryID,
                    onPlay: onPlay,
                    onStartMultiview: onStartMultiview
                )
                .frame(width: 580)
            }
            .frame(maxHeight: .infinity)

            LiveTicker(events: tickerEvents)
                .frame(height: 54)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand {
            if previewStream != nil { onStopPreview() }
        }
    }

    private func focusFirstGame() { requestedGameFocusID = events.first?.id }
}

private struct LiveSelectedPreview: View {
    @StateObject private var controller = VLCPlaybackController()
    let stream: XtreamStream
    let urls: [URL]

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            VLCVideoSurface(player: controller.player).background(Color.black)
            HStack(spacing: 10) {
                Circle().fill(NullSportsStyle.live).frame(width: 8, height: 8)
                Text("NOW PLAYING").font(.caption2.weight(.bold)).tracking(2)
                Text(stream.name).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                Text("Select this game again for full screen")
                    .font(.caption).foregroundStyle(NullSportsStyle.secondary)
            }
            .padding(.horizontal, 24).frame(height: 54)
            .background(Color.black.opacity(0.82))
        }
        .onAppear { controller.start(urls: urls, muted: false) }
        .onDisappear { controller.stop() }
    }
}

private struct LiveLeagueFilterButton: View {
    @FocusState private var isFocused: Bool
    let title: String
    let league: SportsLeague?
    let selected: Bool
    let onMoveDown: () -> Void
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let league { LeagueLogo(league: league, size: 23) }
            Text(title).font(.caption.weight(.bold)).tracking(1.4)
        }
        .foregroundStyle(selected || isFocused ? Color.black : Color.white)
        .padding(.horizontal, 15).frame(height: 40)
        .background(selected || isFocused ? Color.white : Color.white.opacity(0.09))
        .clipShape(Capsule())
        .contentShape(Capsule())
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onTapGesture(perform: action)
        .onMoveCommand { direction in if direction == .down { onMoveDown() } }
    }
}

private struct LiveGameHero: View {
    let game: SportsGame

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                sportsTeamColor(game.awayColor)?.opacity(0.28) ?? Color.clear
                sportsTeamColor(game.homeColor)?.opacity(0.28) ?? Color.clear
            }
            LinearGradient(colors: [Color.black.opacity(0.08), Color.black.opacity(0.64)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(game.league.fullName.uppercased())  ·  \(game.isLive ? "LIVE" : "SCHEDULED")")
                            .font(.caption.weight(.bold)).tracking(3).foregroundStyle(NullSportsStyle.secondary)
                        if let location = nonempty(game.location) {
                            Text(location).font(.system(size: 23, weight: .medium, design: .serif)).italic()
                        }
                        if let venue = nonempty(game.venue) {
                            Text(venue).font(.callout).foregroundStyle(NullSportsStyle.secondary)
                        }
                    }
                    Spacer()
                    Text(game.isLive ? game.status.uppercased() : game.start.formatted(date: .omitted, time: .shortened).uppercased())
                        .font(.caption.weight(.bold).monospacedDigit()).tracking(2)
                        .padding(.horizontal, 18).frame(height: 38)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(NullSportsStyle.secondary, lineWidth: 1))
                }
                Spacer()
                HStack(alignment: .center, spacing: 34) {
                    LiveHeroTeam(name: game.awayTeam, logo: game.awayLogo, abbreviation: game.awayAbbreviation, record: game.awayRecord)
                    Text("at").font(.system(size: 22, weight: .medium, design: .serif)).italic().foregroundStyle(NullSportsStyle.secondary)
                    LiveHeroTeam(name: game.homeTeam, logo: game.homeLogo, abbreviation: game.homeAbbreviation, record: game.homeRecord)
                }
                .frame(maxWidth: .infinity)
                Spacer()
                if !game.broadcast.isEmpty {
                    Text(game.broadcast.uppercased()).font(.caption.weight(.bold)).tracking(2).foregroundStyle(NullSportsStyle.secondary)
                }
            }
            .padding(38)
        }
        .clipped()
    }
}

private struct LiveHeroTeam: View {
    let name: String
    let logo: String
    let abbreviation: String
    let record: String?
    var body: some View {
        VStack(spacing: 14) {
            TeamLogo(url: logo, fallback: abbreviation).frame(width: 126, height: 126)
            Text(name).font(.system(size: 34, weight: .medium, design: .serif)).lineLimit(2).multilineTextAlignment(.center)
            if let record = nonempty(record) { Text(record).font(.callout.monospacedDigit()).foregroundStyle(NullSportsStyle.secondary) }
        }
        .frame(maxWidth: 330)
    }
}

private struct LiveGameSlate: View {
    let events: [SportsGame]
    @Binding var focusedGame: SportsGame?
    @Binding var requestedFocusID: String?
    let multiviewPrimaryID: Int?
    let onPlay: (SportsGame) -> Void
    let onStartMultiview: (SportsGame) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Today's slate").font(.system(size: 27, weight: .medium, design: .serif))
                Spacer()
                Text("\(events.count) GAMES  ·  \(events.filter(\.isLive).count) LIVE")
                    .font(.caption2.weight(.bold)).tracking(2).foregroundStyle(NullSportsStyle.secondary)
            }
            .padding(.horizontal, 28).frame(height: 72)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(events) { game in
                        LiveSlateRow(
                            game: game,
                            requestFocus: requestedFocusID == game.id,
                            selected: focusedGame?.id == game.id,
                            multiviewPrimaryID: multiviewPrimaryID,
                            onFocus: { focusedGame = game; requestedFocusID = nil },
                            onPlay: { onPlay(game) },
                            onStartMultiview: { onStartMultiview(game) }
                        )
                    }
                }
            }
        }
        .background(NullSportsStyle.surface.opacity(0.72))
    }
}

private struct LiveSlateRow: View {
    @EnvironmentObject private var library: SportsLibrary
    @FocusState private var isFocused: Bool
    let game: SportsGame
    let requestFocus: Bool
    let selected: Bool
    let multiviewPrimaryID: Int?
    let onFocus: () -> Void
    let onPlay: () -> Void
    let onStartMultiview: () -> Void
    private var stream: XtreamStream? { library.stream(for: game) }
    private var isTomorrow: Bool {
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) else { return false }
        return Calendar.current.isDate(game.start, inSameDayAs: tomorrow)
    }

    var body: some View {
        HStack(spacing: 16) {
            if game.isLive {
                PulsingLiveDot(size: 9)
                    .frame(width: 12)
                    .accessibilityLabel("Live")
            }
            LeagueLogo(league: game.league, size: 32).frame(width: 38)
            Text(game.awayAbbreviation).foregroundStyle(sportsReadableTeamColor(game.awayColor) ?? NullSportsStyle.text)
            Text("at").font(.system(size: 17, design: .serif)).italic().foregroundStyle(NullSportsStyle.secondary)
            Text(game.homeAbbreviation).foregroundStyle(sportsReadableTeamColor(game.homeColor) ?? NullSportsStyle.text)
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(game.start.formatted(date: .omitted, time: .shortened).uppercased())
                    .font(.callout.monospacedDigit()).foregroundStyle(NullSportsStyle.secondary)
                if isTomorrow && !game.isLive {
                    Text("Tomorrow")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(NullSportsStyle.secondary.opacity(0.72))
                }
            }
        }
        .font(.system(size: 24, weight: .bold, design: .serif))
        .padding(.horizontal, 28).frame(height: 76)
        .background(isFocused || selected ? Color.white.opacity(0.10) : Color.clear)
        .overlay(alignment: .leading) {
            if multiviewPrimaryID == stream?.id { Rectangle().fill(Color.white).frame(width: 3) }
        }
        .contentShape(Rectangle()).focusable().focused($isFocused).focusEffectDisabled()
        .onTapGesture(perform: onPlay)
        .onChange(of: isFocused) { value in if value { onFocus() } }
        .onChange(of: requestFocus) { value in if value { isFocused = true } }
        .contextMenu {
            if stream != nil {
                Button("Start Multiview", systemImage: "rectangle.split.2x1", action: onStartMultiview)
                    .disabled(multiviewPrimaryID == stream?.id)
            }
        }
        .focusLift(isFocused, scale: 1.018)
    }
}

private struct PulsingLiveDot: View {
    let size: CGFloat
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(NullSportsStyle.live)
            .frame(width: size, height: size)
            .scaleEffect(isPulsing ? 1.22 : 0.92)
            .opacity(isPulsing ? 0.58 : 1)
            .shadow(color: NullSportsStyle.live.opacity(isPulsing ? 0.25 : 0.72), radius: isPulsing ? 7 : 3)
            .animation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
            .accessibilityHidden(true)
    }
}

private struct LiveTicker: View {
    let events: [SportsGame]
    @State private var contentWidth: CGFloat = 1
    @State private var epoch = Date()

    var body: some View {
        HStack(spacing: 24) {
            Text("SCORE").font(.caption2.weight(.bold)).tracking(3).foregroundStyle(NullSportsStyle.secondary)
            Rectangle().fill(NullSportsStyle.line).frame(width: 1, height: 28)
            GeometryReader { viewport in
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    let distance = timeline.date.timeIntervalSince(epoch) * 34
                    let cycle = max(contentWidth + 72, viewport.size.width)
                    HStack(spacing: 72) {
                        tickerContent
                        tickerContent
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(x: -CGFloat(distance.truncatingRemainder(dividingBy: cycle)))
                }
                .clipped()
            }
        }
        .padding(.horizontal, 42).background(Color.black.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(NullSportsStyle.line).frame(height: 1) }
        .onPreferenceChange(TickerWidthKey.self) { if $0 > 1 { contentWidth = $0 } }
        .onChange(of: events.map(\.id)) { _ in epoch = Date() }
    }

    private var tickerContent: some View {
        HStack(spacing: 38) {
            if events.isEmpty {
                Text("NO LIVE OR FINAL SCORES")
                    .font(.callout.monospaced()).foregroundStyle(NullSportsStyle.secondary).lineLimit(1)
            } else {
                ForEach(events) { game in
                    HStack(spacing: 12) {
                        Text(game.league.shortName)
                            .font(.caption2.weight(.bold)).tracking(1.5)
                            .foregroundStyle(NullSportsStyle.secondary)
                        Text(game.awayAbbreviation)
                            .foregroundStyle(sportsReadableTeamColor(game.awayColor) ?? NullSportsStyle.text)
                        Text(game.awayScore).fontWeight(.bold).foregroundStyle(NullSportsStyle.text)
                        Text("–").foregroundStyle(NullSportsStyle.secondary)
                        Text(game.homeAbbreviation)
                            .foregroundStyle(sportsReadableTeamColor(game.homeColor) ?? NullSportsStyle.text)
                        Text(game.homeScore).fontWeight(.bold).foregroundStyle(NullSportsStyle.text)
                        Text(game.isLive ? game.status.uppercased() : "FINAL")
                            .font(.caption2.weight(.bold)).tracking(1.2)
                            .foregroundStyle(game.isLive ? NullSportsStyle.live : NullSportsStyle.secondary)
                    }
                    .font(.callout.monospaced()).lineLimit(1)
                }
            }
        }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: TickerWidthKey.self, value: proxy.size.width)
        })
    }
}

private struct TickerWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
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
    case .nfl: "football.fill"
    case .nba: "basketball.fill"
    case .nhl: "hockey.puck.fill"
    case .mlb: "baseball.fill"
    }
}

private struct LeagueLogo: View {
    let league: SportsLeague
    let size: CGFloat

    private var logoURL: URL? {
        URL(string: "https://a.espncdn.com/i/teamlogos/leagues/500/\(league.rawValue).png")
    }

    var body: some View {
        AsyncImage(url: logoURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
            } else {
                Image(systemName: sportsSymbol(league))
                    .resizable().scaledToFit()
                    .padding(size * 0.18)
                    .foregroundStyle(NullSportsStyle.secondary)
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
        Text(title).font(.callout.weight(.semibold)).padding(.horizontal, 20).frame(height: 42)
            .foregroundStyle(selected || isFocused ? NullSportsStyle.text : NullSportsStyle.secondary)
            .background(selected ? Color.white.opacity(0.10) : Color.clear)
            .clipShape(Capsule()).nullGlass(cornerRadius: 22)
            .overlay(alignment: .bottom) { if selected { Capsule().fill(NullSportsStyle.field).frame(width: 28, height: 3).offset(y: -4) } }
            .contentShape(Capsule()).focusable().focused($isFocused).focusEffectDisabled().onTapGesture(perform: action)
            .focusLift(isFocused, scale: 1.06)
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
                if title == "Live now" { Circle().fill(Color(red: 0.92, green: 0.25, blue: 0.23)).frame(width: 9, height: 9) }
                Text(title.uppercased()).font(.caption.weight(.bold)).tracking(1.5)
                    .foregroundStyle(title == "Live now" ? Color(red: 0.95, green: 0.33, blue: 0.30) : NullSportsStyle.secondary)
                Text("(\(events.count))").font(.caption).foregroundStyle(NullSportsStyle.secondary)
                Rectangle().fill(NullSportsStyle.line).frame(height: 1)
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
            Text(title).font(.system(size: 42, weight: .semibold)).foregroundStyle(NullSportsStyle.text)
            Text(detail).font(.callout).foregroundStyle(NullSportsStyle.secondary)
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
            Text(isLoading ? "Checking official schedules…" : (isAvailable ? "No games scheduled today or tomorrow" : (errorMessage ?? "Schedule unavailable — try Refresh")))
        }
        .font(.title3).foregroundStyle(NullSportsStyle.secondary)
        .padding(.vertical, 46)
    }
}

private struct GameEventCard: View {
    @EnvironmentObject private var library: SportsLibrary
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
                    Text("@").font(.caption.weight(.bold)).foregroundStyle(NullSportsStyle.secondary).padding(.leading, 20)
                    GameTeamLine(logo: event.homeLogo, name: event.homeTeam, score: event.isLive ? event.homeScore : nil)
                    HStack(spacing: 12) {
                        Text(event.league.shortName)
                            .font(.caption.weight(.bold)).padding(.horizontal, 10).frame(height: 28)
                            .background(NullSportsStyle.selected).clipShape(Capsule())
                        Text(event.start.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption.monospacedDigit()).foregroundStyle(NullSportsStyle.secondary).lineLimit(1)
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
                Rectangle().fill(NullSportsStyle.line).frame(height: 1)
                HStack(spacing: 12) {
                    Image(systemName: stream == nil ? "tv.slash" : "checkmark.circle.fill")
                        .foregroundStyle(stream == nil ? NullSportsStyle.warning : Color(red: 0.42, green: 0.78, blue: 0.48))
                    Text(stream?.name ?? (event.broadcast.isEmpty ? "No matching channel" : event.broadcast))
                        .font(.callout.weight(.medium)).foregroundStyle(stream == nil ? NullSportsStyle.secondary : Color(red: 0.50, green: 0.82, blue: 0.55)).lineLimit(1)
                    Spacer()
                    if isFocused, stream != nil {
                        Label("Watch", systemImage: "play.fill")
                            .font(.caption.weight(.bold)).foregroundStyle(NullSportsStyle.text)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                    if stream == nil {
                        Label("No channel", systemImage: "display").font(.caption.weight(.semibold)).foregroundStyle(NullSportsStyle.secondary)
                    }
                }
                .padding(.horizontal, 18).frame(height: 46)
                .nullGlass(clear: event.isLive, cornerRadius: 0)
        }
        .background(isFocused ? NullSportsStyle.focused : (event.isLive ? Color(red: 0.15, green: 0.065, blue: 0.065) : NullSportsStyle.surface))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).inset(by: 1).stroke(event.isLive ? Color.red.opacity(0.42) : NullSportsStyle.line, lineWidth: 1))
        .overlay {
            if multiviewPrimaryID == stream?.id {
                RoundedRectangle(cornerRadius: 14).inset(by: 2).stroke(NullSportsStyle.text.opacity(0.8), lineWidth: 3)
            }
        }
        .contentShape(Rectangle()).focusable(stream != nil).focused($isFocused).focusEffectDisabled().onTapGesture(perform: onPlay)
        .contextMenu {
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
            if event.isLive { Circle().fill(NullSportsStyle.live).frame(width: 7, height: 7) }
            Text(title).font(.caption.weight(.bold)).tracking(1.1)
        }
        .foregroundStyle(event.isLive ? Color.white : NullSportsStyle.text)
        .padding(.horizontal, 13).frame(height: 34)
        .background(event.isLive ? NullSportsStyle.live.opacity(0.28) : Color.white.opacity(0.06))
        .clipShape(Capsule())
        .nullGlass(clear: event.isLive, cornerRadius: 17)
    }
}

private struct MatchupArtwork: View {
    let event: SportsGame
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(NullSportsStyle.raised)
            HStack(spacing: 16) {
                TeamLogo(url: event.awayLogo, fallback: event.awayAbbreviation).frame(width: 58, height: 58)
                Text("VS").font(.caption2.weight(.bold)).foregroundStyle(NullSportsStyle.secondary)
                    .frame(width: 32, height: 32).background(NullSportsStyle.background).clipShape(Circle())
                TeamLogo(url: event.homeLogo, fallback: event.homeAbbreviation).frame(width: 58, height: 58)
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
            TeamLogo(url: logo, fallback: String(name.prefix(3)).uppercased()).frame(width: 34, height: 34)
            Text(name)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(NullSportsStyle.text)
                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(0.68)
                .layoutPriority(1)
            Spacer(minLength: 12)
            if let score, !score.isEmpty {
                Text(score).font(.title2.weight(.bold)).monospacedDigit().foregroundStyle(NullSportsStyle.text)
            }
        }
    }
}

private struct TeamLogo: View {
    let url: String
    let fallback: String
    var body: some View {
        AsyncImage(url: URL(string: url)) { image in image.resizable().scaledToFit() } placeholder: {
            Text(fallback).font(.caption2.weight(.bold)).foregroundStyle(NullSportsStyle.secondary)
        }.transaction { $0.animation = nil }
    }
}

private struct ChannelLogo: View {
    let url: String?
    var body: some View {
        AsyncImage(url: URL(string: url ?? "")) { $0.resizable().scaledToFit() } placeholder: {
            Image(systemName: "tv").font(.caption).foregroundStyle(NullSportsStyle.secondary)
        }
        .transaction { $0.animation = nil }
        .padding(4).frame(width: 74, height: 54).background(NullSportsStyle.raised)
    }
}

struct GuideView: View {
    @EnvironmentObject private var library: SportsLibrary
    @FocusState private var sidebarToggleFocused: Bool
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
    @State private var previewHidden = false
    @State private var sidebarVisible = true
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
        NavigationStack {
            VStack(alignment: .leading, spacing: 7) {
                GuideControlBar(
                    title: selectedTitle,
                    channelCount: filtered.count,
                    searchActive: $searchActive,
                    query: $query,
                    multiviewTitle: multiviewPrimary?.name,
                    isLoading: library.isGuideLoading,
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
                    .frame(height: 178)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 7) {
                        GuideTimelineHeader(now: guideNow)
                        if filtered.isEmpty {
                            Text(favoritesOnly ? "Your favorite channels will appear here." : "No channels in this category.")
                                .font(.title3).foregroundStyle(NullSportsStyle.secondary).padding(.top, 24)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 5) {
                                    ForEach(filtered) { stream in
                                        GuideChannelRow(
                                            stream: stream,
                                            favoritesMode: favoritesOnly && !searchActive,
                                            now: guideNow,
                                            multiviewPrimaryID: multiviewPrimary?.id,
                                            onPlay: { select(stream) },
                                            onStartMultiview: { multiviewPrimary = stream },
                                            onFocusProgram: { program in
                                                withAnimation(.easeOut(duration: 0.18)) {
                                                    focusedGuideItem = GuideFocusItem(stream: stream, program: program)
                                                    previewHidden = false
                                                }
                                            }
                                        )
                                    }
                                }.padding(.vertical, 2)
                            }
                        }
                    }

                    if sidebarVisible && !searchActive {
                        GuideSidebar(
                            selectedCategoryID: $selectedCategoryID,
                            favoritesOnly: $favoritesOnly,
                            toggleFocus: $sidebarToggleFocused,
                            onCollapse: { withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible = false } }
                        )
                        .frame(width: guideChannelWidth)
                        .frame(maxHeight: .infinity)
                        .background(NullSportsStyle.background)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .focusSection()
                    } else if !searchActive {
                        GuideSidebarExpandButton(toggleFocus: $sidebarToggleFocused) {
                            withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible = true }
                        }
                    }
                }
            }
            .padding(.horizontal, 32).padding(.top, 8).padding(.bottom, 12)
            .background(
                ZStack {
                    NullSportsStyle.background
                    RadialGradient(colors: [Color.white.opacity(0.045), .clear], center: .topLeading, startRadius: 0, endRadius: 680)
                }.ignoresSafeArea()
            )
            .fullScreenCover(item: $selectedStream, onDismiss: { previewHidden = false }) { stream in
                PlayerView(urls: library.playbackURLs(for: stream))
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
                    try? await Task.sleep(for: .seconds(60))
                    guideNow = Date()
                }
            }
            .onExitCommand {
                if playbackTransitionID != nil {
                    playbackTransitionID = nil
                } else if previewPlaybackStream != nil {
                    previewPlaybackStream = nil
                    pinnedPreviewItem = nil
                } else if !previewHidden {
                    previewHidden = true
                }
            }
        }
    }

    private func select(_ stream: XtreamStream) {
        guard let primary = multiviewPrimary else {
            if previewPlaybackStream?.id == stream.id {
                let transitionID = UUID()
                playbackTransitionID = transitionID
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
    let onCancelMultiview: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let multiviewTitle {
                VStack(alignment: .leading, spacing: 1) {
                    Text("MULTIVIEW · CHOOSE SECOND CHANNEL").font(.caption2.weight(.bold)).tracking(1.3).foregroundStyle(NullSportsStyle.secondary)
                    Text(multiviewTitle).font(.callout.weight(.semibold)).lineLimit(1)
                }
            } else if searchActive {
                TextField("Search channels", text: $query)
                    .textFieldStyle(.plain).focusEffectDisabled()
                    .font(.system(size: 22, weight: .medium))
                    .padding(.horizontal, 14).frame(maxWidth: 520, minHeight: 40)
                    .background(NullSportsStyle.raised).clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Text(title).font(.system(size: 24, weight: .semibold)).lineLimit(1)
            }
            Spacer()
            if isLoading { ProgressView().controlSize(.small) }
            Text("\(channelCount) CHANNELS").font(.caption2.weight(.bold)).tracking(1.4).foregroundStyle(NullSportsStyle.secondary)
            GuideHeaderButton(title: searchActive ? "Close" : "Search", symbol: searchActive ? "xmark" : "magnifyingglass") {
                searchActive.toggle()
                if !searchActive { query = "" }
            }
            if multiviewTitle != nil { GuideHeaderButton(title: "Cancel", symbol: "xmark", action: onCancelMultiview) }
        }
        .foregroundStyle(NullSportsStyle.text)
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
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(NullSportsStyle.line, lineWidth: 1))

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    Text("‹ \(categoryName.uppercased())  ·  \(item.stream.name.uppercased())")
                        .font(.caption2.weight(.bold)).tracking(1.15).foregroundStyle(NullSportsStyle.secondary).lineLimit(1)
                    if let quality { GuideTinyBadge(title: quality, color: NullSportsStyle.raised) }
                    if item.program.isLive { GuideTinyBadge(title: "LIVE", color: NullSportsStyle.live) }
                }
                HStack(spacing: 10) {
                    Text(item.program.title.isEmpty ? "Untitled" : item.program.title)
                        .font(.system(size: 27, weight: .semibold)).lineLimit(1)
                    if item.program.isNew == true { GuideTinyBadge(title: "NEW", color: NullSportsStyle.raised) }
                }
                HStack(spacing: 12) {
                    Text(guideTimeRange(item.program)).font(.callout.monospacedDigit()).foregroundStyle(NullSportsStyle.secondary)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(NullSportsStyle.raised)
                            Capsule().fill(NullSportsStyle.live).frame(width: proxy.size.width * progress)
                        }
                    }.frame(width: 170, height: 4)
                }
                Text(item.program.detail.isEmpty ? "No program description available." : item.program.detail)
                    .font(.callout).foregroundStyle(NullSportsStyle.secondary).lineLimit(1)
                Text("Press Menu to hide preview")
                    .font(.caption2.weight(.medium)).foregroundStyle(NullSportsStyle.secondary.opacity(0.7))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .background(NullSportsStyle.background)
    }
}

private struct GuidePreviewVideo: View {
    @StateObject private var controller = VLCPlaybackController()
    let urls: [URL]

    var body: some View {
        VLCVideoSurface(player: controller.player)
            .background(Color.black)
            .onAppear { controller.start(urls: urls, muted: false) }
            .onDisappear { controller.stop() }
    }
}

private struct GuidePreviewArtwork: View {
    let stream: XtreamStream
    var body: some View {
        ZStack {
            Color.black
            AsyncImage(url: stream.streamIcon.flatMap(URL.init(string:))) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit().padding(24)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "tv").font(.system(size: 38, weight: .light))
                        Text(stream.name).font(.callout.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(NullSportsStyle.secondary)
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
        Text(title).font(.system(size: 9, weight: .bold)).tracking(0.8)
            .padding(.horizontal, 7).frame(height: 18)
            .background(color).clipShape(Capsule())
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
    let toggleFocus: FocusState<Bool>.Binding
    let onCollapse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("CHANNELS").font(.caption2.weight(.bold)).tracking(1.5).foregroundStyle(NullSportsStyle.secondary)
                Spacer()
                Button(action: onCollapse) {
                    Image(systemName: "sidebar.left").font(.callout.weight(.semibold))
                        .frame(width: 40, height: 36).background(NullSportsStyle.raised).clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain).focused(toggleFocus).accessibilityLabel("Hide channel sidebar")
            }
            .padding(.leading, 14).frame(height: 42)
            GuideSidebarButton(title: "All channels", symbol: "rectangle.stack", selected: selectedCategoryID == nil && !favoritesOnly) {
                selectedCategoryID = nil; favoritesOnly = false
            }
            GuideSidebarButton(title: "Favorites", symbol: "star.fill", selected: favoritesOnly) {
                selectedCategoryID = nil; favoritesOnly = true
            }
            Text("CATEGORIES").font(.caption2.weight(.bold)).tracking(1.5).foregroundStyle(NullSportsStyle.secondary)
                .lineLimit(1).padding(.leading, 14).padding(.top, 8).frame(height: 30)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(library.categories) { category in
                        GuideSidebarButton(title: category.categoryName, symbol: "rectangle.grid.1x2", selected: selectedCategoryID == category.id && !favoritesOnly) {
                            selectedCategoryID = category.id; favoritesOnly = false
                        }
                    }
                }
            }
        }
        .padding(.trailing, 8)
    }
}

private struct GuideSidebarExpandButton: View {
    let toggleFocus: FocusState<Bool>.Binding
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.right")
                .font(.callout.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(NullSportsStyle.raised)
                .clipShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain).focused(toggleFocus)
        .accessibilityLabel("Show channel sidebar")
        .padding(.top, 2)
    }
}

private struct GuideSidebarButton: View {
    @FocusState private var isFocused: Bool
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: symbol).font(.caption).frame(width: 22)
            Text(title).font(.callout.weight(.medium)).lineLimit(1).minimumScaleFactor(0.78)
            Spacer()
        }
        .foregroundStyle(selected || isFocused ? NullSportsStyle.text : NullSportsStyle.secondary)
        .padding(.horizontal, 14).frame(height: 46)
        .background(selected ? Color.white.opacity(0.09) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .nullGlass(cornerRadius: 12)
        .contentShape(Rectangle()).focusable().focused($isFocused).focusEffectDisabled().onTapGesture(perform: action)
        .focusLift(isFocused, scale: 1.045)
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
            .font(.callout.weight(.semibold))
            .foregroundStyle(isFocused ? Color.black : NullSportsStyle.text)
            .padding(.horizontal, 18).frame(height: 42)
            .background(isFocused ? Color.white.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)).nullGlass(cornerRadius: 14)
            .contentShape(Rectangle()).focusable().focused($isFocused).focusEffectDisabled().onTapGesture(perform: action)
            .focusLift(isFocused, scale: 1.055)
            .onMoveCommand { direction in if direction == .down { onMoveDown?() } }
    }
}

private struct GuideTimelineHeader: View {
    let now: Date

    var body: some View {
        let anchor = guideTimelineAnchor(now)
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                Text("TODAY").frame(width: guideChannelWidth, alignment: .leading)
                ForEach(0..<guideVisibleSlotCount, id: \.self) { step in
                    Text(anchor.addingTimeInterval(Double(step) * 1800).formatted(date: .omitted, time: .shortened))
                        .frame(width: guideSlotWidth, alignment: .leading)
                }
            }
            .padding(.top, 24)

            Image(systemName: "triangle.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(NullSportsStyle.live)
                .rotationEffect(.degrees(180))
                .offset(x: guidePlayheadX(now) - 6, y: 42)
        }
        .font(.caption2.weight(.bold)).tracking(1.4).foregroundStyle(NullSportsStyle.secondary)
        .padding(.horizontal, 14).frame(height: 58)
    }
}

private let guideChannelWidth: CGFloat = 245
private let guideSlotWidth: CGFloat = 245
private let guideVisibleSlotCount = 6
private let guideGridWidth: CGFloat = guideChannelWidth + (guideSlotWidth * CGFloat(guideVisibleSlotCount))

private func guideTimelineAnchor(_ date: Date) -> Date {
    let calendar = Calendar.current
    var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    components.minute = ((components.minute ?? 0) / 30) * 30
    components.second = 0
    let floor = calendar.date(from: components) ?? date
    return calendar.date(byAdding: .minute, value: -30, to: floor) ?? floor
}

private func guidePlayheadX(_ date: Date) -> CGFloat {
    let elapsed = date.timeIntervalSince(guideTimelineAnchor(date))
    return guideChannelWidth + CGFloat(elapsed / 1800) * guideSlotWidth
}

private struct GuideChannelRow: View {
    @EnvironmentObject private var library: SportsLibrary
    let stream: XtreamStream
    let favoritesMode: Bool
    let now: Date
    let multiviewPrimaryID: Int?
    let onPlay: () -> Void
    let onStartMultiview: () -> Void
    let onFocusProgram: (CurrentProgram) -> Void
    private var programs: [CurrentProgram] { library.guidePrograms(for: stream) }

    private var visiblePrograms: [CurrentProgram] {
        let start = guideTimelineAnchor(now)
        let end = start.addingTimeInterval(Double(guideVisibleSlotCount) * 1800)
        return programs.filter { $0.end > start && $0.start < end }
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 12) {
                ChannelLogo(url: stream.streamIcon)
                Text(stream.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(NullSportsStyle.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .allowsTightening(true)
                    .minimumScaleFactor(0.78)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: guideChannelWidth, alignment: .leading)
            .clipped()

            ZStack(alignment: .leading) {
                if visiblePrograms.isEmpty {
                    GuideProgramCell(program: nil, empty: "No guide information", quality: guideQuality(stream), now: now, showsTime: true, onPlay: onPlay, onFocus: {})
                        .frame(width: guideSlotWidth - 6, alignment: .leading)
                } else {
                    ForEach(Array(visiblePrograms.enumerated()), id: \.offset) { _, program in
                        let width = guideProgramWidth(program, now: now)
                        GuideProgramCell(program: program, empty: "", quality: guideQuality(stream), now: now, showsTime: width >= 110, onPlay: onPlay, onFocus: { onFocusProgram(program) })
                            .frame(width: width, alignment: .leading)
                            .clipped()
                            .offset(x: guideProgramX(program, now: now))
                    }
                }
            }
            .frame(width: guideSlotWidth * CGFloat(guideVisibleSlotCount), alignment: .leading)
            .clipped()
        }
        .padding(.horizontal, 14)
        .frame(width: guideGridWidth + 28, height: 76, alignment: .leading)
        .background(NullSportsStyle.surface.opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .bottom) { Rectangle().fill(NullSportsStyle.line).frame(height: 1) }
        .overlay {
            if multiviewPrimaryID == stream.id {
                RoundedRectangle(cornerRadius: 12).stroke(NullSportsStyle.focusGlow.opacity(0.9), lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button(multiviewPrimaryID == stream.id ? "First Multiview Channel" : "Start Multiview", systemImage: "rectangle.split.2x1") {
                onStartMultiview()
            }
            .disabled(multiviewPrimaryID == stream.id)
            if favoritesMode {
                Button("Move Up", systemImage: "arrow.up") { library.moveFavorite(stream, offset: -1) }
                    .disabled(!library.canMoveFavorite(stream, offset: -1))
                Button("Move Down", systemImage: "arrow.down") { library.moveFavorite(stream, offset: 1) }
                    .disabled(!library.canMoveFavorite(stream, offset: 1))
                Button("Remove from Favorites", systemImage: "star.slash", role: .destructive) { library.removeFavorite(stream) }
            } else if library.isFavorite(stream) {
                Button("Remove from Favorites", systemImage: "star.slash", role: .destructive) { library.removeFavorite(stream) }
            } else {
                Button("Add to Favorites", systemImage: "star") { library.addFavorite(stream) }
            }
        }
    }
}

private func guideProgramX(_ program: CurrentProgram, now: Date) -> CGFloat {
    let anchor = guideTimelineAnchor(now)
    let visibleStart = max(program.start, anchor)
    return max(0, CGFloat(visibleStart.timeIntervalSince(anchor) / 1800) * guideSlotWidth)
}

private func guideProgramWidth(_ program: CurrentProgram, now: Date) -> CGFloat {
    let anchor = guideTimelineAnchor(now)
    let windowEnd = anchor.addingTimeInterval(Double(guideVisibleSlotCount) * 1800)
    let visibleStart = max(program.start, anchor)
    let visibleEnd = min(program.end, windowEnd)
    let durationWidth = CGFloat(max(0, visibleEnd.timeIntervalSince(visibleStart)) / 1800) * guideSlotWidth
    return max(1, durationWidth - 6)
}

private struct GuideProgramCell: View {
    @FocusState private var isFocused: Bool
    let program: CurrentProgram?
    let empty: String
    let quality: String?
    let now: Date
    let showsTime: Bool
    let onPlay: () -> Void
    let onFocus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let program {
                HStack(spacing: 6) {
                    Text(program.title.isEmpty ? "Untitled" : program.title).font(.callout.weight(.medium)).foregroundStyle(NullSportsStyle.text).lineLimit(1)
                    if program.isLive { GuideInlineStatus(title: "LIVE") }
                    else if program.isNew == true { GuideInlineStatus(title: "NEW") }
                }
                if showsTime {
                    HStack(spacing: 7) {
                        Text(guideTimeRange(program))
                            .font(.caption.monospacedDigit()).foregroundStyle(NullSportsStyle.secondary)
                        if let quality { GuideTinyBadge(title: quality, color: NullSportsStyle.raised) }
                    }
                }
            } else {
                Text(empty).font(.callout).foregroundStyle(NullSportsStyle.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(isFocused ? Color.white.opacity(0.18) : (program?.isLive == true ? Color.white.opacity(0.065) : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isFocused ? NullSportsStyle.focusGlow.opacity(0.75) : Color.clear, lineWidth: 1.5))
        .overlay(alignment: .bottomTrailing) {
            if let program, program.isLive {
                Text(guideTimeRemaining(program, now: now))
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).frame(height: 18)
                    .background(NullSportsStyle.live).clipShape(Capsule())
                    .padding(7)
            }
        }
        .contentShape(Rectangle()).focusable().focused($isFocused).focusEffectDisabled().onTapGesture(perform: onPlay)
        .focusLift(isFocused, scale: 1.035)
        .onChange(of: isFocused) { focused in if focused { onFocus() } }
    }
}

private struct GuideInlineStatus: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 8, weight: .bold)).tracking(1.5).foregroundStyle(NullSportsStyle.secondary)
    }
}

private func guideTimeRemaining(_ program: CurrentProgram, now: Date) -> String {
    let minutes = max(0, Int(ceil(program.end.timeIntervalSince(now) / 60)))
    if minutes >= 120 { return "\(minutes / 60)h \(minutes % 60)m left" }
    return "\(minutes)m left"
}

struct AccountView: View {
    @EnvironmentObject private var library: SportsLibrary
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 30) {
                ScreenHeading(title: "Account", detail: "Provider and app details")
                if let profile = library.activeProfile {
                    DetailPanel(title: "PROVIDER") {
                        AccountRow(label: "Profile", value: profile.name)
                        Divider().overlay(NullSportsStyle.line)
                        AccountRow(label: "Server", value: profile.serverURL)
                        Divider().overlay(NullSportsStyle.line)
                        AccountRow(label: "Username", value: profile.username)
                    }
                    Button("Remove provider", role: .destructive) { library.removeActiveProfile() }
                }
                DetailPanel(title: "ABOUT") {
                    AccountRow(label: "Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.1")
                }
                Spacer()
            }
            .padding(.horizontal, 120).padding(.vertical, 48).background(NullSportsStyle.background)
        }
    }
}

private struct DetailPanel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.caption.weight(.bold)).tracking(1.5).foregroundStyle(NullSportsStyle.secondary)
            VStack(spacing: 0) { content }.padding(.horizontal, 24).background(NullSportsStyle.surface)
        }
    }
}

private struct AccountRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .top, spacing: 30) {
            Text(label).foregroundStyle(NullSportsStyle.text); Spacer()
            Text(value).foregroundStyle(NullSportsStyle.secondary).multilineTextAlignment(.trailing).lineLimit(3)
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
            VLCVideoSurface(player: controller.player).background(Color.black)
            if urls.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle").font(.title2)
                    Text("Stream unavailable").font(.headline)
                }
                .foregroundStyle(.white.opacity(0.8)).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 10) {
                Image(systemName: audible ? "speaker.wave.2.fill" : "speaker.slash.fill")
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                if !expanded { Text("SELECT TO EXPAND").font(.caption2.weight(.bold)).tracking(1.1) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18).frame(height: 50)
            .background(Color.black.opacity(0.56))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 0, style: .continuous))
        .overlay {
            if !expanded {
                RoundedRectangle(cornerRadius: 0)
                    .stroke(audible ? Color.white.opacity(0.92) : Color.white.opacity(0.18), lineWidth: audible ? 3 : 1)
            }
        }
        .scaleEffect(!expanded && audible ? 1.012 : 1)
        .shadow(color: !expanded && audible ? Color.white.opacity(0.16) : .clear, radius: 18)
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
    @StateObject private var controller = VLCPlaybackController()
    var body: some View {
        ZStack(alignment: .topLeading) {
            VLCVideoSurface(player: controller.player).background(Color.black).ignoresSafeArea()
            if urls.isEmpty { Text("This stream is unavailable").font(.title2).foregroundStyle(.white).padding(60) }
        }
        .background(Color.black).focusable()
        .onPlayPauseCommand { controller.togglePlayback() }
        .onExitCommand { controller.stop(); dismiss() }
        .onAppear { controller.start(urls: urls) }.onDisappear { controller.stop() }
    }
}

@MainActor private final class VLCPlaybackController: ObservableObject {
    let player = VLCMediaPlayer()
    func start(urls: [URL], muted: Bool = false) {
        stop()
        guard let url = urls.last ?? urls.first else { return }
        guard let media = VLCMedia(url: url) else { return }
        media.addOption(":network-caching=5000"); media.addOption(":live-caching=5000"); media.addOption(":http-reconnect=true")
        if muted { media.addOption(":no-audio") }
        player.media = media; player.play(); setMuted(muted)
    }
    func setMuted(_ muted: Bool) { player.audio?.isMuted = muted }
    func togglePlayback() { player.isPlaying ? player.pause() : player.play() }
    func stop() { player.stop(); player.media = nil }
}

private struct VLCVideoSurface: UIViewRepresentable {
    let player: VLCMediaPlayer
    func makeUIView(context: Context) -> UIView { let view = UIView(); view.backgroundColor = .black; player.drawable = view; return view }
    func updateUIView(_ uiView: UIView, context: Context) { if player.drawable == nil { player.drawable = uiView } }
}
