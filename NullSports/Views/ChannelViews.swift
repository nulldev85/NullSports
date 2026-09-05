import SwiftUI
import UIKit
import VLCKit

struct LiveView: View {
    @EnvironmentObject private var library: SportsLibrary
    @State private var selectedLeague: SportsLeague?
    @State private var selectedDay = 0
    @State private var selectedStream: XtreamStream?

    private var dayStart: Date { Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: selectedDay, to: Date()) ?? Date()) }
    private var nextDayStart: Date { Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart }
    private var events: [SportsGame] { library.games(for: selectedLeague).filter { $0.start >= dayStart && $0.start < nextDayStart } }
    private var liveEvents: [SportsGame] { events.filter { $0.isLive } }
    private var upcomingEvents: [SportsGame] { events.filter { $0.isUpcoming } }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    LiveFilterButton(title: "Today", selected: selectedDay == 0) { selectedDay = 0 }
                    LiveFilterButton(title: "Tomorrow", selected: selectedDay == 1) { selectedDay = 1 }
                    Spacer()
                    Text(scheduleDetail).font(.caption).foregroundStyle(NullSportsStyle.secondary)
                    GuideHeaderButton(title: "Refresh", symbol: "arrow.clockwise") { Task { await library.reload() } }
                }
                HStack(spacing: 8) {
                    LiveFilterButton(title: "All", selected: selectedLeague == nil) { selectedLeague = nil }
                    ForEach(SportsLeague.allCases) { league in
                        LiveFilterButton(title: league.shortName, selected: selectedLeague == league) { selectedLeague = league }
                    }
                    Spacer()
                }
                if library.isLoading {
                    ProgressView("Loading channels…")
                } else if events.isEmpty {
                    EmptySchedule(isLoading: library.isScheduleLoading, isAvailable: library.scheduleAvailable(for: selectedLeague), errorMessage: library.scheduleErrorMessage)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            if !liveEvents.isEmpty {
                                ScheduleSection(title: "Live now", events: liveEvents) { game in play(game) }
                            }
                            if !upcomingEvents.isEmpty {
                                ScheduleSection(title: selectedDay == 0 ? "Later today" : "Tomorrow", events: upcomingEvents) { game in play(game) }
                            }
                        }.padding(.horizontal, 10).padding(.vertical, 8)
                    }
                }
            }
            .padding(.horizontal, 42).padding(.top, 12).padding(.bottom, 18)
            .background(
                ZStack {
                    NullSportsStyle.background
                    RadialGradient(colors: [Color.white.opacity(0.055), .clear], center: .topTrailing, startRadius: 20, endRadius: 720)
                }.ignoresSafeArea()
            )
            .fullScreenCover(item: $selectedStream) { stream in PlayerView(urls: library.playbackURLs(for: stream)) }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { return }
                    library.refreshSchedule(showsLoading: false)
                }
            }
        }
    }

    private var scheduleDetail: String {
        library.isScheduleLoading ? "Updating official schedules…" : "Today and tomorrow"
    }

    private func play(_ game: SportsGame) {
        selectedStream = library.stream(for: game)
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
    let onPlay: (SportsGame) -> Void

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
                ForEach(events) { event in GameEventCard(event: event) { onPlay(event) } }
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
    let onPlay: () -> Void
    private var stream: XtreamStream? { library.stream(for: event) }

    var body: some View {
        VStack(spacing: 0) {
                HStack(spacing: 18) {
                    MatchupArtwork(event: event)
                    VStack(alignment: .leading, spacing: 10) {
                        GameTeamLine(logo: event.awayLogo, name: event.awayTeam, score: event.isLive ? event.awayScore : nil)
                        Text("@").font(.caption.weight(.bold)).foregroundStyle(NullSportsStyle.secondary).padding(.leading, 20)
                        GameTeamLine(logo: event.homeLogo, name: event.homeTeam, score: event.isLive ? event.homeScore : nil)
                        HStack(spacing: 12) {
                            Text(event.league.shortName)
                                .font(.caption.weight(.bold)).padding(.horizontal, 10).frame(height: 28)
                                .background(NullSportsStyle.selected).clipShape(Capsule())
                            Text(event.status).font(.caption).foregroundStyle(NullSportsStyle.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 20)
                    VStack(alignment: .trailing, spacing: 18) {
                        Text(event.isLive ? "●  LIVE" : event.start.formatted(date: .omitted, time: .shortened))
                            .font(.callout.weight(.bold)).foregroundStyle(event.isLive ? Color(red: 0.96, green: 0.36, blue: 0.32) : NullSportsStyle.text)
                            .padding(.horizontal, 15).frame(height: 38)
                            .background(event.isLive ? Color(red: 0.30, green: 0.10, blue: 0.10) : NullSportsStyle.raised)
                            .clipShape(Capsule()).overlay(Capsule().stroke(event.isLive ? Color.red.opacity(0.65) : NullSportsStyle.line, lineWidth: 1))
                        Image(systemName: "play.fill")
                            .font(.title3.weight(.semibold)).foregroundStyle(Color.black)
                            .frame(width: 48, height: 48).background(NullSportsStyle.field).clipShape(Circle())
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 16)
                Rectangle().fill(NullSportsStyle.line).frame(height: 1)
                HStack(spacing: 12) {
                    Image(systemName: stream == nil ? "tv.slash" : "checkmark.circle.fill")
                        .foregroundStyle(stream == nil ? NullSportsStyle.warning : Color(red: 0.42, green: 0.78, blue: 0.48))
                    Text(stream?.name ?? (event.broadcast.isEmpty ? "No matching channel" : event.broadcast))
                        .font(.callout.weight(.medium)).foregroundStyle(stream == nil ? NullSportsStyle.secondary : Color(red: 0.50, green: 0.82, blue: 0.55)).lineLimit(1)
                    Spacer()
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
        .contentShape(Rectangle()).focusable(stream != nil).focused($isFocused).focusEffectDisabled().onTapGesture(perform: onPlay)
        .focusLift(isFocused)
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
            Text(name).font(.title3.weight(.semibold)).foregroundStyle(NullSportsStyle.text).lineLimit(1)
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
        .padding(3).frame(width: 60, height: 44).background(NullSportsStyle.raised)
    }
}

struct GuideView: View {
    @EnvironmentObject private var library: SportsLibrary
    @State private var selectedCategoryID: String?
    @State private var favoritesOnly = false
    @State private var searchActive = false
    @State private var query = ""
    @State private var selectedStream: XtreamStream?
    private var filtered: [XtreamStream] {
        library.guideStreams(categoryID: searchActive ? nil : selectedCategoryID, favoritesOnly: searchActive ? false : favoritesOnly, query: query)
    }
    private var selectedTitle: String {
        if favoritesOnly { return "Favorites" }
        return library.categories.first { $0.id == selectedCategoryID }?.categoryName ?? "All channels"
    }

    var body: some View {
        NavigationStack {
            HStack(alignment: .top, spacing: 22) {
                GuideSidebar(selectedCategoryID: $selectedCategoryID, favoritesOnly: $favoritesOnly)
                    .frame(width: 286)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 18) {
                        if searchActive {
                            TextField("Channel name", text: $query)
                                .textFieldStyle(.plain)
                                .focusEffectDisabled()
                                .font(.system(size: 28, weight: .medium))
                                .foregroundStyle(NullSportsStyle.text)
                                .padding(.horizontal, 16).frame(maxWidth: 560, minHeight: 44)
                                .background(NullSportsStyle.raised)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            Text(selectedTitle)
                                .font(.system(size: 30, weight: .semibold))
                                .foregroundStyle(NullSportsStyle.text)
                                .lineLimit(1)
                        }
                        Spacer()
                        if library.isGuideLoading { ProgressView().controlSize(.small) }
                        Text("\(filtered.count) channels")
                            .font(.caption.weight(.bold)).tracking(1.3)
                            .foregroundStyle(NullSportsStyle.secondary)
                        GuideHeaderButton(title: searchActive ? "Close" : "Search", symbol: searchActive ? "xmark" : "magnifyingglass") {
                            searchActive.toggle()
                            if !searchActive { query = "" }
                        }
                    }
                    .frame(height: 52)
                    GuideTimelineHeader()
                    if filtered.isEmpty {
                        Text(favoritesOnly ? "Your favorite channels will appear here." : "No channels in this category.")
                            .font(.title3).foregroundStyle(NullSportsStyle.secondary).padding(.top, 24)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 7) {
                                ForEach(filtered) { stream in
                                    GuideChannelRow(stream: stream, favoritesMode: favoritesOnly && !searchActive) { selectedStream = stream }
                                }
                            }.padding(.vertical, 2)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 42).padding(.top, 12).padding(.bottom, 18)
            .background(
                ZStack {
                    NullSportsStyle.background
                    RadialGradient(colors: [Color.white.opacity(0.045), .clear], center: .topLeading, startRadius: 0, endRadius: 680)
                }.ignoresSafeArea()
            )
            .fullScreenCover(item: $selectedStream) { stream in PlayerView(urls: library.playbackURLs(for: stream)) }
        }
    }
}

private struct GuideSidebar: View {
    @EnvironmentObject private var library: SportsLibrary
    @Binding var selectedCategoryID: String?
    @Binding var favoritesOnly: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CHANNELS").font(.caption2.weight(.bold)).tracking(1.5).foregroundStyle(NullSportsStyle.secondary)
                .lineLimit(1).padding(.leading, 14).frame(height: 24)
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
    }
}

private struct GuideTimelineHeader: View {
    var body: some View {
        HStack(spacing: 0) {
            Text("CHANNEL").frame(width: 330, alignment: .leading)
            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { step in
                        Text(context.date.addingTimeInterval(Double(step) * 1800).formatted(date: .omitted, time: .shortened))
                            .frame(width: 270, alignment: .leading)
                    }
                }
            }
        }
        .font(.caption2.weight(.bold)).tracking(1.4).foregroundStyle(NullSportsStyle.secondary)
        .padding(.horizontal, 14).frame(height: 38)
        .overlay(alignment: .leading) {
            HStack(spacing: 7) {
                Rectangle().fill(NullSportsStyle.live).frame(width: 2)
                Text("NOW").font(.caption2.weight(.bold)).tracking(1.2).foregroundStyle(NullSportsStyle.live)
            }.offset(x: 343)
        }
    }
}

private struct GuideChannelRow: View {
    @EnvironmentObject private var library: SportsLibrary
    @FocusState private var isFocused: Bool
    let stream: XtreamStream
    let favoritesMode: Bool
    let onPlay: () -> Void
    private var programs: [CurrentProgram] { library.guidePrograms(for: stream) }
    private var current: CurrentProgram? { programs.first(where: \.isLive) }
    private var next: CurrentProgram? { programs.first { $0.start > Date() } }

    var body: some View {
        HStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(stream.num.map(String.init) ?? "—")
                        .font(.caption2.monospacedDigit()).foregroundStyle(NullSportsStyle.secondary).lineLimit(1)
                        .minimumScaleFactor(0.7).frame(width: 58, alignment: .trailing)
                    ChannelLogo(url: stream.streamIcon)
                    Text(stream.name).font(.callout.weight(.semibold)).foregroundStyle(NullSportsStyle.text).lineLimit(1)
                }.frame(width: 330, alignment: .leading)
                HStack(spacing: 6) {
                    ForEach(Array(programs.prefix(4).enumerated()), id: \.offset) { index, program in
                        GuideProgramCell(program: program, empty: "No listing", showsProgress: index == 0 && program.isLive, onPlay: onPlay)
                            .frame(width: 264, alignment: .leading)
                    }
                    if programs.isEmpty {
                        GuideProgramCell(program: nil, empty: "No guide information", showsProgress: false, onPlay: onPlay)
                            .frame(width: 264, alignment: .leading)
                    }
                }
        }
        .padding(.horizontal, 14).frame(height: 72)
        .background(isFocused ? NullSportsStyle.focused : NullSportsStyle.surface.opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .leading) {
            Rectangle().fill(NullSportsStyle.live.opacity(0.82)).frame(width: 2).offset(x: 343)
        }
        .overlay(alignment: .bottom) { if !isFocused { Rectangle().fill(NullSportsStyle.line).frame(height: 1) } }
        .contentShape(Rectangle())
        .contextMenu {
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

private struct GuideProgramCell: View {
    @FocusState private var isFocused: Bool
    let program: CurrentProgram?
    let empty: String
    let showsProgress: Bool
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let program {
                Text(program.title.isEmpty ? "Untitled" : program.title).font(.callout).foregroundStyle(NullSportsStyle.text).lineLimit(1)
                HStack(spacing: 10) {
                    Text(program.start.formatted(date: .omitted, time: .shortened))
                        .font(.caption.monospacedDigit()).foregroundStyle(NullSportsStyle.secondary)
                    if showsProgress {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(NullSportsStyle.raised)
                                Capsule().fill(NullSportsStyle.field).frame(width: proxy.size.width * progress(program))
                            }
                        }.frame(width: 72, height: 4)
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
        .contentShape(Rectangle()).focusable().focused($isFocused).focusEffectDisabled().onTapGesture(perform: onPlay)
        .focusLift(isFocused, scale: 1.035)
    }

    private func progress(_ program: CurrentProgram) -> CGFloat {
        let duration = program.end.timeIntervalSince(program.start)
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(Date().timeIntervalSince(program.start) / duration, 0), 1))
    }
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
    func start(urls: [URL]) {
        guard let url = urls.last ?? urls.first else { return }; stop()
        guard let media = VLCMedia(url: url) else { return }
        media.addOption(":network-caching=5000"); media.addOption(":live-caching=5000"); media.addOption(":http-reconnect=true")
        player.media = media; player.play()
    }
    func togglePlayback() { player.isPlaying ? player.pause() : player.play() }
    func stop() { player.stop(); player.media = nil }
}

private struct VLCVideoSurface: UIViewRepresentable {
    let player: VLCMediaPlayer
    func makeUIView(context: Context) -> UIView { let view = UIView(); view.backgroundColor = .black; player.drawable = view; return view }
    func updateUIView(_ uiView: UIView, context: Context) { if player.drawable == nil { player.drawable = uiView } }
}
