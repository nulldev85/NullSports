import SwiftUI

struct MobileLiveView: View {
    @EnvironmentObject private var library: SportsLibrary
    @EnvironmentObject private var reminders: GameReminders
    @Environment(\.scenePhase) private var scenePhase
    @State private var league: SportsLeague?
    @State private var choosingChannel: SportsGame?
    @State private var pendingStream: XtreamStream?
    @State private var upcomingGame: SportsGame?
    @State private var showsChannelSyncMessage = false
    @State private var previewStream: XtreamStream?
    @State private var previewGame: SportsGame?
    @State private var failedPreviewStreamIDs: Set<Int> = []
    @State private var playback = MobilePlaybackController()
    @Namespace private var selection
    var isActive = true
    let onPlay: (XtreamStream, SportsGame?, Set<Int>) -> Void

    private var games: [SportsGame] { library.games(for: league) }
    private var live: [SportsGame] { games.filter(\.isLive) }
    private var upcomingDays: [Date] {
        Array(Set(games.filter(\.isUpcoming).map { Calendar.current.startOfDay(for: $0.start) })).sorted()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                masthead
                leagueTabs
                if let stream = previewStream {
                    TimelineView(.periodic(from: .now, by: 30)) { clock in
                        MobileGuidePlayer(
                            controller: playback,
                            stream: stream,
                            program: library.guidePrograms(for: stream).first {
                                $0.start <= clock.date && clock.date < $0.end
                            },
                            expanded: false,
                            showsMetadata: true,
                            videoHeight: UIScreen.main.bounds.width * 9 / 16,
                            onClose: closePreview,
                            onExpand: { onPlay(stream, previewGame, failedPreviewStreamIDs) },
                            onRetry: { playback.start(urls: library.playbackURLs(for: stream)) },
                            onChooseChannel: previewGame.map { game in
                                {
                                    closePreview()
                                    choosingChannel = game
                                }
                            }
                        )
                        .id(ObjectIdentifier(playback))
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        // Channel matching keeps running after the schedule and
                        // library finish, and every game reads as unmatched until
                        // it lands. Say so instead of showing a settled empty row.
                        if library.isScheduleLoading || library.isLoading || !library.automaticMatchingReady {
                            RefreshingStreamsBanner()
                        }
                        if let error = library.scheduleErrorMessage {
                            Label(error, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                                .font(.caption).foregroundStyle(LineupStyle.lightPurple.opacity(0.65))
                                .padding(16)
                        }
                        if !live.isEmpty {
                            Section {
                                ForEach(live) { matchup($0) }
                            } header: { sectionTitle("ON AIR", detail: "\(live.count) LIVE") }
                        }
                        ForEach(upcomingDays, id: \.self) { day in
                            Section {
                                ForEach(games.filter { $0.isUpcoming && Calendar.current.isDate($0.start, inSameDayAs: day) }) {
                                    matchup($0)
                                }
                            } header: {
                                sectionTitle(Calendar.current.isDateInToday(day) ? "UP NEXT" : day.formatted(.dateTime.weekday(.wide)).uppercased(),
                                             detail: day.formatted(.dateTime.month(.abbreviated).day()).uppercased())
                            }
                        }
                        if games.isEmpty && !library.isScheduleLoading {
                            ContentUnavailableView(library.scheduleAvailable(for: league) ? "No games scheduled" : "Schedule unavailable",
                                systemImage: "sportscourt",
                                description: Text("Pull down to refresh, or find your channels in Guide."))
                                .padding(.top, 40)
                        }
                    }
                    .padding(.bottom, 16)
                }
                .refreshable { library.refreshSchedule(showsLoading: true) }
            }
            .background {
                LinearGradient(
                    colors: [LineupStyle.raised.opacity(0.34), LineupStyle.background],
                    startPoint: .topTrailing, endPoint: .center
                ).ignoresSafeArea()
            }
            .toolbar(.hidden, for: .navigationBar)
            .alert("Game has not started yet", isPresented: Binding(
                get: { upcomingGame != nil },
                set: { if !$0 { upcomingGame = nil } }
            )) {
                if let game = upcomingGame {
                    Button(reminders.reminds(game) ? "Remove reminder" : "Remind me") {
                        reminders.toggleGame(game)
                        upcomingGame = nil
                    }
                }
                Button("OK", role: .cancel) { upcomingGame = nil }
            } message: {
                if let game = upcomingGame {
                    Text("\(game.awayTeam) vs. \(game.homeTeam)\nScheduled for \(game.start.formatted(date: .abbreviated, time: .shortened)).")
                }
            }
            .alert("Channels are still syncing", isPresented: $showsChannelSyncMessage) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Please wait for channel syncing to finish, then select the game again.")
            }
            .sheet(item: $choosingChannel, onDismiss: {
                if let stream = pendingStream {
                    pendingStream = nil
                    showPreview(stream)
                }
            }) { game in
                MobileGuideView(game: game) { stream in
                    pendingStream = stream
                    choosingChannel = nil
                }
            }
            .onChange(of: isActive) { _, active in
                if active { playback.resume() } else { closePreview() }
            }
            .onChange(of: scenePhase) { _, phase in
                guard previewStream != nil else { return }
                if phase == .active { playback.resume() } else { playback.suspend() }
            }
            .onReceive(playback.$channelFailed) { failed in
                guard failed, playback.channelFailed,
                      let game = previewGame, let stream = previewStream else { return }
                Task { @MainActor in
                    guard playback.channelFailed, previewStream?.id == stream.id else { return }
                    failedPreviewStreamIDs.insert(stream.id)
                    guard let next = library.nextVerifiedStream(for: game, excluding: failedPreviewStreamIDs) else { return }
                    showPreview(next, game: game, preservingFailures: true)
                }
            }
            .onReceive(playback.$videoPlaying) { playing in
                guard playing, playback.videoPlaying,
                      let game = previewGame, let stream = previewStream else { return }
                library.recordWorkingStream(stream, for: game)
            }
        }
    }

    private var masthead: some View {
        HStack(alignment: .bottom) {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(LineupStyle.lightPurple)
                    .frame(width: 3, height: 31)
                VStack(alignment: .leading, spacing: 1) {
                    Text("LINEUP")
                        .font(.system(size: 20, weight: .black, design: .default))
                        .tracking(-0.5)
                        .foregroundStyle(LineupStyle.text)
                    Text("LIVE SPORTS")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(2.2)
                        .foregroundStyle(LineupStyle.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(Date(), format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.caption2.weight(.medium)).foregroundStyle(LineupStyle.secondary)
                HStack(spacing: 5) {
                    Circle().fill(live.isEmpty ? LineupStyle.secondary : Color(red: 0.98, green: 0.28, blue: 0.34)).frame(width: 5, height: 5)
                    Text(live.isEmpty ? "\(games.count) MATCHUPS" : "\(live.count) LIVE NOW")
                        .font(.system(size: 10, weight: .bold)).tracking(1)
                        .foregroundStyle(LineupStyle.text)
                }
            }
        }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 17)
    }

    private var leagueTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 25) {
                leagueTab(value: nil)
                ForEach(SportsLeague.allCases) { leagueTab(value: $0) }
            }.padding(.horizontal, 20)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(LineupStyle.line).frame(height: 1) }
    }

    private func leagueTab(value: SportsLeague?) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { league = value }
        } label: {
            Group {
                if let value {
                    MobileLeagueLogo(league: value, size: 32)
                } else {
                    Image(systemName: "square.grid.2x2.fill").font(.system(size: 21))
                        .foregroundStyle(LineupStyle.lightPurple)
                }
            }
                .opacity(league == value ? 1 : 0.38)
                .frame(minWidth: 44, minHeight: 48)
                .overlay(alignment: .bottom) {
                    if league == value {
                        Rectangle().fill(LineupStyle.lightPurple).frame(height: 2)
                            .matchedGeometryEffect(id: "leagueUnderline", in: selection)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value?.shortName ?? "All sports")
        .accessibilityAddTraits(league == value ? .isSelected : [])
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        HStack {
            Text(title).tracking(1.8)
            Spacer()
            Text(detail).tracking(1)
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(LineupStyle.secondary)
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 9)
        .background(LineupStyle.background)
    }

    private func matchup(_ game: SportsGame) -> some View {
        Button {
            guard !game.isUpcoming else {
                upcomingGame = game
                return
            }
            if let stream = library.resolvedStream(for: game) {
                showPreview(stream, game: game)
            } else if library.channelsAreSyncing && !library.automaticMatchingReady {
                showsChannelSyncMessage = true
            } else {
                choosingChannel = game
            }
        } label: { MobileMatchupRow(game: game) }
        .buttonStyle(MobileMatchupButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(game.isUpcoming ? "Show scheduled start time" : "Watch game or choose a channel")
    }

    private func showPreview(_ stream: XtreamStream, game: SportsGame? = nil,
                             preservingFailures: Bool = false) {
        playback.shutdown()
        playback = MobilePlaybackController()
        if !preservingFailures { failedPreviewStreamIDs = [] }
        previewGame = game
        previewStream = stream
        playback.start(urls: library.playbackURLs(for: stream))
    }

    private func closePreview() {
        playback.shutdown()
        previewStream = nil
        previewGame = nil
        failedPreviewStreamIDs = []
    }
}

private struct MobileMatchupRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let game: SportsGame

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                team(game.awayTeam, logo: game.awayLogo, record: game.awayRecord, score: game.awayScore)
                team(game.homeTeam, logo: game.homeLogo, record: game.homeRecord, score: game.homeScore)
            }.frame(maxWidth: .infinity)
            Rectangle().fill(LineupStyle.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 6) {
                MobileLeagueLogo(league: game.league, size: 23)
                if game.isLive {
                    HStack(alignment: .center, spacing: 5) {
                        MobileLiveDot()
                        Text(game.status.isEmpty ? "Live now" : game.status)
                            .font(.caption.weight(.semibold)).lineLimit(2)
                    }.accessibilityElement(children: .ignore)
                        .accessibilityLabel("Live. \(game.status)")
                } else {
                    Text(game.start, format: .dateTime.hour().minute())
                        .font(.caption.weight(.semibold)).monospacedDigit()
                }
                if !game.broadcast.isEmpty {
                    Text(game.broadcast.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.5).lineLimit(2)
                        .foregroundStyle(LineupStyle.secondary)
                }
                Image(systemName: "play.fill").font(.system(size: 10))
                    .padding(.top, 2).accessibilityHidden(true)
            }.frame(width: typeSize.isAccessibilitySize ? 100 : 76, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 20).padding(.vertical, 13)
        .background(game.isLive ? LineupStyle.surface : .clear)
        .overlay(alignment: .leading) {
            if game.isLive { Rectangle().fill(Color(red: 0.98, green: 0.28, blue: 0.34)).frame(width: 3) }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(LineupStyle.line).frame(height: 1).padding(.horizontal, 20) }
        .contentShape(Rectangle())
    }

    private func team(_ name: String, logo: String, record: String?, score: String) -> some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.94))
                AsyncImage(url: URL(string: logo)) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit().padding(2)
                    } else {
                        Text(String(name.prefix(3)).uppercased())
                            .font(.system(size: 7, weight: .black)).foregroundStyle(.black.opacity(0.65))
                    }
                }
                .transaction { $0.animation = nil }
            }
            .frame(width: 28, height: 28)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 0.5))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.weight(.semibold))
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    .multilineTextAlignment(.leading)
                if let record = record?.trimmingCharacters(in: .whitespacesAndNewlines), !record.isEmpty {
                    Text(record).font(.caption2).monospacedDigit()
                        .foregroundStyle(LineupStyle.secondary)
                        .accessibilityLabel("Record: \(record)")
                }
            }
            Spacer(minLength: 3)
            if game.isLive {
                Text(score).font(.system(.title3, design: .default, weight: .bold)).monospacedDigit()
            }
        }
    }
}

private struct MobileMatchupButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? LineupStyle.raised : .clear)
    }
}

/// Small pulsing red dot used to mark something as live. Shared across the
/// schedule list and the player controls (MobilePlayerView/MobileGuidePlayer).
struct MobileLiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false
    private let red = Color(red: 0.98, green: 0.28, blue: 0.34)

    var body: some View {
        ZStack {
            Circle().fill(red.opacity(0.4))
                .scaleEffect(pulsing && !reduceMotion ? 1.8 : 1)
                .opacity(pulsing && !reduceMotion ? 0 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 1.6).repeatForever(autoreverses: false), value: pulsing)
            Circle().fill(red).frame(width: 5, height: 5)
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
        .onAppear { pulsing = !reduceMotion }
        .onDisappear { pulsing = false }
        .onChange(of: reduceMotion) { _, reduced in pulsing = !reduced }
    }
}

private struct MobileLeagueLogo: View {
    let league: SportsLeague
    let size: CGFloat
    var body: some View {
        Image("League-\(league.rawValue)")
            .resizable().scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel(league.shortName)
    }
}

/// Shown while channels, guide or matching are still in flight. Matching is what
/// decides a game's channel, so it stays up until that settles — otherwise a game
/// with no channel yet is indistinguishable from one with no channel at all.
private struct RefreshingStreamsBanner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(LineupStyle.live).frame(width: 6, height: 6)
            Text("REFRESHING STREAMS").font(.system(size: 10, weight: .bold)).tracking(1.6)
        }
        .foregroundStyle(LineupStyle.lightPurple.opacity(0.75))
        .opacity(reduceMotion || !dimmed ? 1 : 0.32)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dimmed)
        .onAppear { dimmed = true }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .accessibilityLabel("Refreshing streams")
    }
}
