import SwiftUI
import UIKit
import VLCKit

struct LiveView: View {
    @EnvironmentObject private var library: SportsLibrary

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 42) {
                    PageTitle(eyebrow: "Now", title: "Live sports", detail: "Games airing right now. No network filler or upcoming listings.")
                    if library.isLoading {
                        ProgressView("Loading channels…")
                    } else {
                        if library.isGuideLoading {
                            ProgressView("Checking what’s live…")
                                .foregroundStyle(NullSportsStyle.secondary)
                        }
                        ForEach(SportsLeague.allCases) { league in
                            ChannelRail(league: league, streams: Array(library.liveStreams(for: league).prefix(20)))
                        }
                    }
                }
                .padding(.horizontal, 70)
                .padding(.vertical, 45)
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

struct ChannelRail: View {
    let league: SportsLeague
    let streams: [XtreamStream]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                LeagueMark(league: league)
                Text(league.fullName).font(.title2.bold()).foregroundStyle(NullSportsStyle.text)
                Spacer()
                Text("\(streams.count) live").foregroundStyle(NullSportsStyle.secondary)
            }
            if streams.isEmpty {
                Text("No live games right now.")
                    .foregroundStyle(NullSportsStyle.secondary)
                    .frame(height: 100)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 22) {
                        ForEach(streams) { stream in ChannelCard(stream: stream) }
                    }
                }
            }
        }
    }
}

struct ChannelCard: View {
    @EnvironmentObject private var library: SportsLibrary
    let stream: XtreamStream

    var body: some View {
        NavigationLink {
            if !library.playbackURLs(for: stream).isEmpty {
                PlayerView(title: stream.name, urls: library.playbackURLs(for: stream))
            } else {
                Text("Stream unavailable")
            }
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    NullSportsStyle.raised
                    AsyncImage(url: URL(string: stream.streamIcon ?? "")) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Image(systemName: "play.rectangle").font(.system(size: 42)).foregroundStyle(NullSportsStyle.secondary)
                    }
                    .padding(25)
                }
                .frame(width: 300, height: 165)
                Text(stream.name)
                    .font(.headline)
                    .foregroundStyle(NullSportsStyle.text)
                    .lineLimit(2)
                    .frame(width: 300, alignment: .leading)
                if let program = library.program(for: stream) {
                    Text(program.title)
                        .font(.caption)
                        .foregroundStyle(NullSportsStyle.secondary)
                        .lineLimit(1)
                        .frame(width: 300, alignment: .leading)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct PlayerView: View {
    let title: String
    let urls: [URL]
    @StateObject private var controller = VLCPlaybackController()

    init(title: String, urls: [URL]) {
        self.title = title
        self.urls = urls
    }

    var body: some View {
        VLCVideoSurface(player: controller.player)
            .background(Color.black)
            .ignoresSafeArea()
            .navigationTitle(title)
            .focusable()
            .onPlayPauseCommand { controller.togglePlayback() }
            .onAppear { controller.start(urls: urls) }
            .onDisappear { controller.stop() }
    }
}

@MainActor
private final class VLCPlaybackController: ObservableObject {
    let player = VLCMediaPlayer()

    func start(urls: [URL]) {
        guard let url = urls.last ?? urls.first else { return }
        stop()
        guard let media = VLCMedia(url: url) else { return }
        media.addOption(":network-caching=5000")
        media.addOption(":live-caching=5000")
        media.addOption(":http-reconnect=true")
        player.media = media
        player.play()
    }

    func togglePlayback() {
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }

    func stop() {
        player.stop()
        player.media = nil
    }
}

private struct VLCVideoSurface: UIViewRepresentable {
    let player: VLCMediaPlayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        player.drawable = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if player.drawable == nil { player.drawable = uiView }
    }
}

struct LeaguesView: View {
    @EnvironmentObject private var library: SportsLibrary

    var body: some View {
        NavigationStack {
            List(SportsLeague.allCases) { league in
                NavigationLink {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 24)], spacing: 32) {
                            ForEach(library.streams(for: league)) { ChannelCard(stream: $0) }
                        }
                        .padding(60)
                    }
                    .background(NullSportsStyle.background)
                    .navigationTitle(league.shortName)
                } label: {
                    HStack(spacing: 22) {
                        LeagueMark(league: league)
                        VStack(alignment: .leading) {
                            Text(league.fullName).font(.title2.bold())
                            Text("\(library.streams(for: league).count) matching channels").foregroundStyle(NullSportsStyle.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Leagues")
        }
    }
}

struct GuideView: View {
    @EnvironmentObject private var library: SportsLibrary
    @State private var query = ""

    var filtered: [XtreamStream] {
        query.isEmpty ? library.professionalStreams : library.professionalStreams.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { stream in ChannelCard(stream: stream) }
                .searchable(text: $query, prompt: "Search channels")
                .navigationTitle("Guide")
        }
    }
}

struct AccountView: View {
    @EnvironmentObject private var library: SportsLibrary

    var body: some View {
        NavigationStack {
            List {
                if let profile = library.activeProfile {
                    Section("Provider") {
                        AccountRow(label: "Profile", value: profile.name)
                        AccountRow(label: "Server", value: profile.serverURL)
                        AccountRow(label: "Username", value: profile.username)
                    }
                    Section {
                        Button("Remove profile", role: .destructive) { library.removeActiveProfile() }
                    }
                }
                Section("About") {
                    AccountRow(label: "Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.2")
                }
            }
            .navigationTitle("Account")
        }
    }
}

private struct AccountRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(NullSportsStyle.secondary)
        }
    }
}
