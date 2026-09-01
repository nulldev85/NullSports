import SwiftUI
import UIKit
import VLCKit

struct LiveView: View {
    @EnvironmentObject private var library: SportsLibrary
    @State private var selectedLeague: SportsLeague?

    private var events: [SportsGame] { library.games(for: selectedLeague) }

    private var liveEvents: [SportsGame] { events.filter { $0.isLive } }
    private var laterEvents: [SportsGame] { events.filter { $0.isUpcoming } }

    var body: some View {
        NavigationStack {
            HStack(alignment: .top, spacing: 54) {
                SportsSidebar(title: "MY SPORTS", selectedLeague: $selectedLeague, includeAll: true)
                    .frame(width: 285)
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top) {
                        ScreenHeading(title: selectedLeague?.fullName ?? "My Sports", detail: scheduleDetail)
                        Spacer()
                        Text("TODAY")
                            .font(.caption.weight(.bold)).tracking(1.4)
                            .foregroundStyle(NullSportsStyle.text)
                            .padding(.horizontal, 24).frame(height: 46)
                            .background(NullSportsStyle.selected)
                            .clipShape(Capsule())
                    }
                    if library.isLoading {
                        ProgressView("Loading channels…")
                    } else if events.isEmpty {
                        EmptySchedule(isLoading: library.isScheduleLoading)
                    } else {
                        ScrollView { LazyVStack(alignment: .leading, spacing: 24) {
                            if !liveEvents.isEmpty { ScheduleSection(title: "Live now", events: liveEvents) }
                            if !laterEvents.isEmpty { ScheduleSection(title: "Later today", events: laterEvents) }
                        }.padding(.vertical, 8) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 66).padding(.vertical, 42)
            .background(NullSportsStyle.background)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await library.reload() } } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
    }

    private var scheduleDetail: String {
        library.isScheduleLoading ? "Updating official schedules…" : "Verified game times and opponents"
    }
}

private struct SportsSidebar: View {
    let title: String
    @Binding var selectedLeague: SportsLeague?
    let includeAll: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if includeAll {
                Button { selectedLeague = nil } label: {
                    HStack(spacing: 13) {
                        Image(systemName: "sportscourt.fill")
                        Text("All Sports").font(.headline)
                        Spacer()
                    }
                    .foregroundStyle(.black).padding(.horizontal, 20).frame(height: 58)
                    .background(NullSportsStyle.field)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 10)
            }
            Text(title).font(.caption.weight(.bold)).tracking(1.6).foregroundStyle(NullSportsStyle.secondary)
                .padding(.leading, 18)
            if includeAll { SidebarButton(title: "All leagues", symbol: "star.fill", selected: selectedLeague == nil) { selectedLeague = nil } }
            Text("LEAGUES").font(.caption.weight(.bold)).tracking(1.6).foregroundStyle(NullSportsStyle.secondary)
                .padding(.leading, 18).padding(.top, 10)
            ForEach(SportsLeague.allCases) { league in
                SidebarButton(title: league.shortName, symbol: league.symbol, selected: selectedLeague == league) { selectedLeague = league }
            }
            Spacer()
        }
    }
}

private struct SidebarButton: View {
    @Environment(\.isFocused) private var isFocused
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 15) {
                Image(systemName: symbol).frame(width: 28)
                Text(title).font(.headline)
                Spacer()
            }
            .foregroundStyle(selected || isFocused ? NullSportsStyle.text : NullSportsStyle.secondary)
            .padding(.horizontal, 18).frame(height: 56)
            .background(isFocused ? NullSportsStyle.focused : (selected ? NullSportsStyle.selected : NullSportsStyle.sidebarRow))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(alignment: .leading) {
                if selected { Capsule().fill(NullSportsStyle.field).frame(width: 4, height: 34).padding(.leading, 5) }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ScheduleSection: View {
    let title: String
    let events: [SportsGame]

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 14) {
                Text(title).font(.headline).foregroundStyle(NullSportsStyle.text)
                Rectangle().fill(NullSportsStyle.line).frame(height: 1)
            }
            ForEach(events) { event in GameRow(event: event) }
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
    var body: some View {
        HStack(spacing: 16) {
            if isLoading { ProgressView() } else { Image(systemName: "calendar") }
            Text(isLoading ? "Checking today’s guide…" : "No games scheduled for today")
        }
        .font(.title3).foregroundStyle(NullSportsStyle.secondary)
        .padding(.vertical, 46)
    }
}

private struct GameRow: View {
    @EnvironmentObject private var library: SportsLibrary
    let event: SportsGame
    @State private var showPlayer = false
    private var stream: XtreamStream? { library.stream(for: event) }

    var body: some View {
        Button { showPlayer = true } label: {
            HStack(spacing: 22) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.isLive ? "LIVE NOW" : event.start.formatted(date: .omitted, time: .shortened))
                        .font(.headline.weight(.bold)).foregroundStyle(event.isLive ? .white : NullSportsStyle.text)
                        .lineLimit(2)
                    Text(event.status.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(event.isLive ? .white.opacity(0.75) : NullSportsStyle.secondary)
                }
                .frame(width: 98, alignment: .leading)
                Rectangle().fill(event.isLive ? NullSportsStyle.field : event.league.color).frame(width: 3, height: 72)
                VStack(alignment: .leading, spacing: 9) {
                    TeamLine(name: event.awayTeam, abbreviation: event.awayAbbreviation, league: event.league, secondary: false)
                    TeamLine(name: event.homeTeam, abbreviation: event.homeAbbreviation, league: event.league, secondary: true)
                }
                Spacer(minLength: 20)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(event.league.shortName).font(.caption.weight(.bold)).foregroundStyle(NullSportsStyle.text)
                    Text(event.broadcast.isEmpty ? (stream?.name ?? "No matching channel") : event.broadcast)
                        .font(.caption).foregroundStyle(NullSportsStyle.secondary).lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                .frame(width: 210, alignment: .trailing)
                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(NullSportsStyle.text)
            }
            .padding(.horizontal, 24).frame(minHeight: 108)
            .background(event.isLive ? NullSportsStyle.liveSurface : NullSportsStyle.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(event.isLive ? NullSportsStyle.liveBorder : NullSportsStyle.line, lineWidth: 1))
        }
        .buttonStyle(.card)
        .disabled(stream == nil)
        .fullScreenCover(isPresented: $showPlayer) { PlayerView(urls: stream.map { library.playbackURLs(for: $0) } ?? []) }
    }
}

private struct TeamLine: View {
    let name: String
    let abbreviation: String
    let league: SportsLeague
    let secondary: Bool
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(secondary ? NullSportsStyle.raised : league.color.opacity(0.75))
                Text(abbreviation).font(.system(size: 9, weight: .bold)).foregroundStyle(NullSportsStyle.text).lineLimit(1)
            }.frame(width: 34, height: 34)
            Text(name.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.headline).foregroundStyle(NullSportsStyle.text).lineLimit(1)
        }
    }
}

struct LeaguesView: View {
    @EnvironmentObject private var library: SportsLibrary
    @State private var selectedLeague: SportsLeague? = .nfl

    var body: some View {
        NavigationStack {
            HStack(alignment: .top, spacing: 54) {
                SportsSidebar(title: "LEAGUES", selectedLeague: $selectedLeague, includeAll: false).frame(width: 285)
                VStack(alignment: .leading, spacing: 24) {
                    ScreenHeading(title: selectedLeague?.fullName ?? "Leagues", detail: "Professional channels only")
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(selectedLeague.map { library.streams(for: $0) } ?? []) { ChannelRow(stream: $0) }
                        }.padding(.vertical, 8)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 66).padding(.vertical, 42).background(NullSportsStyle.background)
        }
    }
}

private struct ChannelRow: View {
    @EnvironmentObject private var library: SportsLibrary
    let stream: XtreamStream
    @State private var showPlayer = false

    var body: some View {
        Button { showPlayer = true } label: {
            HStack(spacing: 20) {
                ChannelLogo(url: stream.streamIcon)
                VStack(alignment: .leading, spacing: 6) {
                    Text(stream.name).font(.headline).foregroundStyle(NullSportsStyle.text).lineLimit(2)
                    if let program = library.program(for: stream) {
                        Text(program.title).font(.callout).foregroundStyle(NullSportsStyle.secondary).lineLimit(2)
                    }
                }
                Spacer()
                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(NullSportsStyle.text)
            }
            .padding(.horizontal, 22).frame(minHeight: 90).background(NullSportsStyle.surface)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(NullSportsStyle.line, lineWidth: 1))
        }
        .buttonStyle(.card)
        .fullScreenCover(isPresented: $showPlayer) { PlayerView(urls: library.playbackURLs(for: stream)) }
    }
}

private struct ChannelLogo: View {
    let url: String?
    var body: some View {
        AsyncImage(url: URL(string: url ?? "")) { $0.resizable().scaledToFit() } placeholder: {
            Image(systemName: "tv").font(.title2).foregroundStyle(NullSportsStyle.secondary)
        }
        .padding(8).frame(width: 68, height: 54).background(NullSportsStyle.raised)
    }
}

struct GuideView: View {
    @EnvironmentObject private var library: SportsLibrary
    @State private var query = ""
    private var filtered: [XtreamStream] {
        query.isEmpty ? library.professionalStreams : library.professionalStreams.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                ScreenHeading(title: "Channel guide", detail: "NFL, NBA, NHL and MLB")
                ScrollView { LazyVStack(spacing: 12) { ForEach(filtered) { ChannelRow(stream: $0) } }.padding(.vertical, 8) }
            }
            .padding(.horizontal, 120).padding(.vertical, 42).background(NullSportsStyle.background)
            .searchable(text: $query, prompt: "Search channels")
        }
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

private extension SportsLeague {
    var symbol: String {
        switch self { case .nfl: "american.football"; case .nba: "basketball"; case .nhl: "hockey.puck"; case .mlb: "baseball" }
    }
}
