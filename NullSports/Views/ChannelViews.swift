import SwiftUI
import UIKit
import VLCKit

struct LiveView: View {
    @EnvironmentObject private var library: SportsLibrary

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 46) {
                    PageTitle(eyebrow: Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()), title: "Today", detail: "Live games and what’s coming up later.")
                    if library.isLoading {
                        ProgressView("Loading channels…").foregroundStyle(NullSportsStyle.secondary)
                    } else {
                        if library.isGuideLoading {
                            HStack(spacing: 12) { ProgressView(); Text("Updating today’s schedule") }
                                .font(.callout).foregroundStyle(NullSportsStyle.secondary)
                        }
                        ForEach(SportsLeague.allCases) { LeagueScheduleSection(league: $0) }
                    }
                }
                .padding(.horizontal, 70).padding(.vertical, 44)
            }
            .background(NullSportsStyle.background)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await library.reload() } } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
    }
}

private struct LeagueScheduleSection: View {
    @EnvironmentObject private var library: SportsLibrary
    let league: SportsLeague

    var body: some View {
        let live = library.liveEvents(for: league)
        let upcoming = library.upcomingEvents(for: league)
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                LeagueMark(league: league)
                Text(league.fullName).font(.title2.weight(.semibold)).foregroundStyle(NullSportsStyle.text)
            }
            if !live.isEmpty { ScheduleRail(label: "LIVE NOW", events: Array(live.prefix(12)), isLive: true) }
            if !upcoming.isEmpty { ScheduleRail(label: live.isEmpty ? "LATER TODAY" : "UP NEXT", events: Array(upcoming.prefix(12)), isLive: false) }
            if live.isEmpty && upcoming.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "calendar")
                    Text(library.isGuideLoading ? "Checking today’s schedule…" : "No games scheduled today")
                }
                .font(.callout).foregroundStyle(NullSportsStyle.secondary).frame(height: 62)
            }
        }
    }
}

private struct ScheduleRail: View {
    let label: String
    let events: [ScheduledStream]
    let isLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(label).font(.caption.weight(.bold)).tracking(1.5)
                .foregroundStyle(isLive ? NullSportsStyle.field : NullSportsStyle.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 22) { ForEach(events) { EventCard(event: $0, isLive: isLive) } }
                    .padding(.vertical, 8)
            }
        }
    }
}

private struct EventCard: View {
    @EnvironmentObject private var library: SportsLibrary
    let event: ScheduledStream
    let isLive: Bool
    @State private var showPlayer = false

    var body: some View {
        Button { showPlayer = true } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(isLive ? "LIVE" : event.program.start.formatted(date: .omitted, time: .shortened))
                        .font(.caption.weight(.bold)).foregroundStyle(isLive ? NullSportsStyle.field : NullSportsStyle.text)
                    Spacer()
                    Image(systemName: "play.fill").font(.caption).foregroundStyle(NullSportsStyle.secondary)
                }
                Text(event.program.title).font(.title3.weight(.semibold)).foregroundStyle(NullSportsStyle.text)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Text(event.stream.name).font(.callout).foregroundStyle(NullSportsStyle.secondary).lineLimit(2)
            }
            .padding(22).frame(width: 350, height: 190, alignment: .topLeading)
            .background(NullSportsStyle.surface)
            .overlay(alignment: .leading) { Rectangle().fill(isLive ? NullSportsStyle.field : NullSportsStyle.line).frame(width: 4) }
        }
        .buttonStyle(.card)
        .fullScreenCover(isPresented: $showPlayer) { PlayerView(urls: library.playbackURLs(for: event.stream)) }
    }
}

struct ChannelCard: View {
    @EnvironmentObject private var library: SportsLibrary
    let stream: XtreamStream
    @State private var showPlayer = false

    var body: some View {
        Button { showPlayer = true } label: {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top, spacing: 16) {
                    ChannelLogo(url: stream.streamIcon)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(stream.name).font(.headline).foregroundStyle(NullSportsStyle.text)
                            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        if let program = library.program(for: stream) {
                            Text(program.title).font(.callout).foregroundStyle(NullSportsStyle.secondary).lineLimit(2)
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack { Text("WATCH").font(.caption.weight(.bold)).tracking(1.2); Spacer(); Image(systemName: "play.fill") }
                    .foregroundStyle(NullSportsStyle.field)
            }
            .padding(22).frame(width: 350, height: 180, alignment: .topLeading).background(NullSportsStyle.surface)
        }
        .buttonStyle(.card)
        .fullScreenCover(isPresented: $showPlayer) { PlayerView(urls: library.playbackURLs(for: stream)) }
    }
}

private struct ChannelLogo: View {
    let url: String?
    var body: some View {
        AsyncImage(url: URL(string: url ?? "")) { $0.resizable().scaledToFit() } placeholder: {
            Image(systemName: "play.rectangle").font(.system(size: 30)).foregroundStyle(NullSportsStyle.secondary)
        }
        .padding(10).frame(width: 76, height: 64).background(NullSportsStyle.raised)
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
        .onAppear { controller.start(urls: urls) }
        .onDisappear { controller.stop() }
    }
}

@MainActor private final class VLCPlaybackController: ObservableObject {
    let player = VLCMediaPlayer()
    func start(urls: [URL]) {
        guard let url = urls.last ?? urls.first else { return }
        stop()
        guard let media = VLCMedia(url: url) else { return }
        media.addOption(":network-caching=5000"); media.addOption(":live-caching=5000"); media.addOption(":http-reconnect=true")
        player.media = media; player.play()
    }
    func togglePlayback() { player.isPlaying ? player.pause() : player.play() }
    func stop() { player.stop(); player.media = nil }
}

private struct VLCVideoSurface: UIViewRepresentable {
    let player: VLCMediaPlayer
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.backgroundColor = .black; player.drawable = view; return view
    }
    func updateUIView(_ uiView: UIView, context: Context) { if player.drawable == nil { player.drawable = uiView } }
}

struct LeaguesView: View {
    private let columns = [GridItem(.flexible(), spacing: 28), GridItem(.flexible(), spacing: 28)]
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 38) {
                    PageTitle(eyebrow: "Browse", title: "Leagues", detail: "Four leagues. Nothing else.")
                    LazyVGrid(columns: columns, spacing: 28) { ForEach(SportsLeague.allCases) { LeagueTile(league: $0) } }
                }
                .padding(.horizontal, 70).padding(.vertical, 44)
            }
            .background(NullSportsStyle.background)
        }
    }
}

private struct LeagueTile: View {
    @EnvironmentObject private var library: SportsLibrary
    let league: SportsLeague
    var body: some View {
        NavigationLink { LeagueChannelsView(league: league) } label: {
            HStack(spacing: 24) {
                LeagueMark(league: league)
                VStack(alignment: .leading, spacing: 7) {
                    Text(league.fullName).font(.title2.weight(.semibold)).foregroundStyle(NullSportsStyle.text)
                    Text("\(library.streams(for: league).count) channels").foregroundStyle(NullSportsStyle.secondary)
                }
                Spacer(); Image(systemName: "chevron.right").foregroundStyle(NullSportsStyle.secondary)
            }
            .padding(26).frame(height: 128).background(NullSportsStyle.surface)
        }
        .buttonStyle(.card)
    }
}

private struct LeagueChannelsView: View {
    @EnvironmentObject private var library: SportsLibrary
    let league: SportsLeague
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 350), spacing: 24)], spacing: 28) {
                ForEach(library.streams(for: league)) { ChannelCard(stream: $0) }
            }.padding(60)
        }.background(NullSportsStyle.background).navigationTitle(league.fullName)
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
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 350), spacing: 24)], spacing: 28) {
                    ForEach(filtered) { ChannelCard(stream: $0) }
                }.padding(.horizontal, 70).padding(.vertical, 44)
            }
            .background(NullSportsStyle.background).searchable(text: $query, prompt: "Search channels").navigationTitle("Guide")
        }
    }
}

struct AccountView: View {
    @EnvironmentObject private var library: SportsLibrary
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    PageTitle(eyebrow: "NullSports", title: "Account", detail: "Your provider and app details.")
                    if let profile = library.activeProfile {
                        DetailPanel(title: "PROVIDER") {
                            AccountRow(label: "Profile", value: profile.name); Divider().overlay(NullSportsStyle.line)
                            AccountRow(label: "Server", value: profile.serverURL); Divider().overlay(NullSportsStyle.line)
                            AccountRow(label: "Username", value: profile.username)
                        }
                        Button("Remove provider", role: .destructive) { library.removeActiveProfile() }
                    }
                    DetailPanel(title: "ABOUT") {
                        AccountRow(label: "Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.0")
                    }
                }.padding(.horizontal, 70).padding(.vertical, 44)
            }.background(NullSportsStyle.background)
        }
    }
}

private struct DetailPanel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
        }.padding(.vertical, 20)
    }
}
