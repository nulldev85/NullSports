import SwiftUI

struct MobileLiveView: View {
    @EnvironmentObject private var library: SportsLibrary
    @Environment(\.scenePhase) private var scenePhase
    @State private var league: SportsLeague?
    @State private var choosingChannel: SportsGame?
    @State private var pendingStream: XtreamStream?
    @State private var upcomingGame: SportsGame?
    @State private var previewStream: XtreamStream?
    @State private var playback = MobilePlaybackController()
    @Namespace private var selection
    var isActive = true
    let onPlay: (XtreamStream) -> Void

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
                            onExpand: { onPlay(stream) },
                            onRetry: { playback.start(urls: library.playbackURLs(for: stream)) }
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
            .background(LineupStyle.background)
            .toolbar(.hidden, for: .navigationBar)
            .alert("Game has not started yet", isPresented: Binding(
                get: { upcomingGame != nil },
                set: { if !$0 { upcomingGame = nil } }
            )) {
                Button("OK", role: .cancel) { upcomingGame = nil }
            } message: {
                if let game = upcomingGame {
                    Text("\(game.awayTeam) vs. \(game.homeTeam)\nScheduled for \(game.start.formatted(date: .abbreviated, time: .shortened)).")
                }
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
        }
    }

    private var masthead: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("LINEUP").font(.system(size: 11, weight: .black)).tracking(3)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text(Date(), format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.caption2.weight(.medium)).foregroundStyle(LineupStyle.lightPurple.opacity(0.6))
                HStack(spacing: 5) {
                    Circle().fill(LineupStyle.lightPurple).frame(width: 5, height: 5)
                    Text(live.isEmpty ? "\(games.count) MATCHUPS" : "\(live.count) LIVE NOW")
                        .font(.system(size: 10, weight: .bold)).tracking(1)
                }
            }
        }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 15)
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
                .opacity(league == value ? 1 : 0.55)
                .frame(minWidth: 44, minHeight: 48)
                .overlay(alignment: .bottom) {
                    if league == value {
                        Capsule().fill(LineupStyle.lightPurple).frame(height: 2)
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
        .foregroundStyle(LineupStyle.lightPurple.opacity(0.55))
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 9)
        .background(LineupStyle.background)
    }

    private func matchup(_ game: SportsGame) -> some View {
        Button {
            guard !game.isUpcoming else {
                upcomingGame = game
                return
            }
            if let stream = library.verifiedStream(for: game) { showPreview(stream) }
            else { choosingChannel = game }
        } label: { MobileMatchupRow(game: game) }
        .buttonStyle(MobileMatchupButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(game.isUpcoming ? "Show scheduled start time" : "Watch game or choose a channel")
    }

    private func showPreview(_ stream: XtreamStream) {
        playback.shutdown()
        playback = MobilePlaybackController()
        previewStream = stream
        playback.start(urls: library.playbackURLs(for: stream))
    }

    private func closePreview() {
        playback.shutdown()
        previewStream = nil
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
                MobileLeagueLogo(league: game.league, size: 25)
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
                    Text(game.broadcast).font(.system(size: 10)).lineLimit(2)
                        .foregroundStyle(LineupStyle.lightPurple.opacity(0.5))
                }
                Image(systemName: "play.fill").font(.system(size: 10))
                    .padding(.top, 2).accessibilityHidden(true)
            }.frame(width: typeSize.isAccessibilitySize ? 100 : 76, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 20).padding(.vertical, 13)
        .background(game.isLive ? LineupStyle.lightPurple.opacity(0.025) : .clear)
        .overlay(alignment: .leading) {
            if game.isLive { Rectangle().fill(LineupStyle.lightPurple.opacity(0.7)).frame(width: 2).padding(.vertical, 18) }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(LineupStyle.line).frame(height: 1).padding(.horizontal, 20) }
        .contentShape(Rectangle())
    }

    private func team(_ name: String, logo: String, record: String?, score: String) -> some View {
        HStack(spacing: 9) {
            // A near-opaque white disc read as a sticker pasted on the card.
            // The logo now sits on the card itself, lifted by a brighter ring.
            // The initials fallback follows the theme, since the white it used
            // to be drawn against is gone.
            AsyncImage(url: URL(string: logo)) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit().padding(3)
                } else {
                    Text(String(name.prefix(3)).uppercased())
                        .font(.system(size: 7, weight: .black))
                        .foregroundStyle(LineupStyle.lightPurple.opacity(0.7))
                }
            }
            .transaction { $0.animation = nil }
            .frame(width: 28, height: 28)
            .overlay(Circle().strokeBorder(LineupStyle.lightPurple.opacity(0.34), lineWidth: 1))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.weight(.semibold))
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    .multilineTextAlignment(.leading)
                if let record = record?.trimmingCharacters(in: .whitespacesAndNewlines), !record.isEmpty {
                    Text(record).font(.caption2).monospacedDigit()
                        .foregroundStyle(LineupStyle.lightPurple.opacity(0.5))
                        .accessibilityLabel("Record: \(record)")
                }
            }
            Spacer(minLength: 3)
            if game.isLive {
                Text(score).font(.system(.title3, design: .rounded, weight: .semibold)).monospacedDigit()
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
    private var red: Color { LineupStyle.liveDot }

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
