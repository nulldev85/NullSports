import AVKit
import SwiftUI

struct LiveView: View {
    @EnvironmentObject private var library: SportsLibrary

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 42) {
                    PageTitle(eyebrow: "Now", title: "Live sports", detail: "Channels from your provider, organized for game night.")
                    if library.isLoading {
                        ProgressView("Loading channels…")
                    } else {
                        ForEach(SportsLeague.allCases) { league in
                            ChannelRail(league: league, streams: Array(library.streams(for: league).prefix(20)))
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
                Text("\(streams.count) channels").foregroundStyle(NullSportsStyle.secondary)
            }
            if streams.isEmpty {
                Text("No matching channels from this provider.")
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
            if let url = library.playbackURL(for: stream) {
                PlayerView(title: stream.name, url: url)
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
            }
        }
        .buttonStyle(.plain)
    }
}

struct PlayerView: View {
    let title: String
    let url: URL
    @State private var player: AVPlayer

    init(title: String, url: URL) {
        self.title = title
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea()
            .navigationTitle(title)
            .onAppear { player.play() }
            .onDisappear { player.pause() }
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
        query.isEmpty ? library.streams : library.streams.filter { $0.name.localizedCaseInsensitiveContains(query) }
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
                    AccountRow(label: "Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
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
