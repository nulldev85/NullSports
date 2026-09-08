import SwiftUI

struct MobileLiveView: View {
    @EnvironmentObject private var library: SportsLibrary
    @State private var league: SportsLeague?
    @State private var choosingChannel: SportsGame?
    @State private var pendingStream: XtreamStream?
    @State private var upcomingGame: SportsGame?
    @Namespace private var selection
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
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        if library.isScheduleLoading || library.isLoading {
                            ProgressView("Updating…").font(.caption).padding(12)
                        }
                        if let error = library.scheduleErrorMessage {
                            Label(error, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                                .font(.caption).foregroundStyle(NullSportsStyle.lightPurple.opacity(0.65))
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
            .background(NullSportsStyle.background)
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
                if let stream = pendingStream { pendingStream = nil; onPlay(stream) }
            }) { game in
                MobileGuideView(game: game) { stream in
                    pendingStream = stream
                    choosingChannel = nil
                }
            }
        }
    }

    private var masthead: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("NULLSPORTS").font(.system(size: 11, weight: .black)).tracking(3)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text(Date(), format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.caption2.weight(.medium)).foregroundStyle(NullSportsStyle.lightPurple.opacity(0.6))
                HStack(spacing: 5) {
                    Circle().fill(NullSportsStyle.lightPurple).frame(width: 5, height: 5)
                    Text(live.isEmpty ? "\(games.count) MATCHUPS" : "\(live.count) LIVE NOW")
                        .font(.system(size: 10, weight: .bold)).tracking(1)
                }
            }
        }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 15)
    }

    private var leagueTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 25) {
                leagueTab("ALL", value: nil)
                ForEach(SportsLeague.allCases) { leagueTab($0.shortName, value: $0) }
            }.padding(.horizontal, 20)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(NullSportsStyle.line).frame(height: 1) }
    }

    private func leagueTab(_ title: String, value: SportsLeague?) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { league = value }
        } label: {
            Text(title).font(.system(size: 12, weight: .bold)).tracking(1)
                .foregroundStyle(NullSportsStyle.lightPurple.opacity(league == value ? 1 : 0.45))
                .frame(minWidth: 32, minHeight: 44)
                .overlay(alignment: .bottom) {
                    if league == value {
                        Capsule().fill(NullSportsStyle.lightPurple).frame(height: 2)
                            .matchedGeometryEffect(id: "leagueUnderline", in: selection)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(league == value ? .isSelected : [])
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        HStack {
            Text(title).tracking(1.8)
            Spacer()
            Text(detail).tracking(1)
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(NullSportsStyle.lightPurple.opacity(0.55))
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 9)
        .background(NullSportsStyle.background)
    }

    private func matchup(_ game: SportsGame) -> some View {
        Button {
            guard !game.isUpcoming else {
                upcomingGame = game
                return
            }
            if let stream = library.verifiedStream(for: game) { onPlay(stream) }
            else { choosingChannel = game }
        } label: { MobileMatchupRow(game: game) }
        .buttonStyle(MobileMatchupButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(game.isUpcoming ? "Show scheduled start time" : "Watch game or choose a channel")
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
            Rectangle().fill(NullSportsStyle.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(game.league.shortName).font(.system(size: 9, weight: .bold)).tracking(1.5)
                    .foregroundStyle(NullSportsStyle.lightPurple.opacity(0.5))
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
                        .foregroundStyle(NullSportsStyle.lightPurple.opacity(0.5))
                }
                Image(systemName: "play.fill").font(.system(size: 10))
                    .padding(.top, 2).accessibilityHidden(true)
            }.frame(width: typeSize.isAccessibilitySize ? 100 : 76, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 20).padding(.vertical, 13)
        .background(game.isLive ? NullSportsStyle.lightPurple.opacity(0.025) : .clear)
        .overlay(alignment: .leading) {
            if game.isLive { Rectangle().fill(NullSportsStyle.lightPurple.opacity(0.7)).frame(width: 2).padding(.vertical, 18) }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(NullSportsStyle.line).frame(height: 1).padding(.horizontal, 20) }
        .contentShape(Rectangle())
    }

    private func team(_ name: String, logo: String, record: String?, score: String) -> some View {
        HStack(spacing: 9) {
            AsyncImage(url: URL(string: logo)) { image in image.resizable().scaledToFit() }
                placeholder: { Image(systemName: "sportscourt").font(.caption).opacity(0.4) }
                .frame(width: 25, height: 25).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.weight(.semibold))
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    .multilineTextAlignment(.leading)
                if let record = record?.trimmingCharacters(in: .whitespacesAndNewlines), !record.isEmpty {
                    Text(record).font(.caption2).monospacedDigit()
                        .foregroundStyle(NullSportsStyle.lightPurple.opacity(0.5))
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
            .background(configuration.isPressed ? NullSportsStyle.raised : .clear)
    }
}

private struct MobileLiveDot: View {
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
