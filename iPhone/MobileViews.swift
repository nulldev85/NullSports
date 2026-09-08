import SwiftUI

struct MainView: View {
    @EnvironmentObject private var library: SportsLibrary
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var playing: XtreamStream?

    var body: some View {
        TabView(selection: $tab) {
            MobileLiveView { playing = $0 }
                .tabItem { Label("Live", systemImage: "play.rectangle.fill") }.tag(0)
            MobileGuideView { playing = $0 }
                .tabItem { Label("Guide", systemImage: "list.bullet.rectangle") }.tag(1)
            MobileAccountView()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }.tag(2)
        }
        .fullScreenCover(item: $playing) { stream in
            MobilePlayerView(name: stream.name, urls: library.playbackURLs(for: stream))
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                library.refreshSchedule(showsLoading: false, includeTomorrow: false)
            }
        }
    }
}

struct ProfileSetupView: View {
    @EnvironmentObject private var library: SportsLibrary
    @State private var name = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var connecting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("NULLSPORTS").font(.caption.bold()).tracking(3)
                        Text("Your games.\nAnywhere.").font(.largeTitle.bold())
                        Text("Connect your provider to bring live sports to your iPhone.")
                    }.padding(.vertical, 16)
                }.listRowBackground(NullSportsStyle.surface)
                Section("Your provider") {
                    TextField("Profile name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Server URL", text: $server)
                        .keyboardType(.URL).textContentType(.URL)
                    TextField("Username", text: $username).textContentType(.username)
                    SecureField("Password", text: $password).textContentType(.password)
                }.listRowBackground(NullSportsStyle.surface)
                Section {
                    Button {
                        connecting = true
                        Task {
                            _ = await library.addProfile(name: name,
                                serverURL: server.trimmingCharacters(in: .whitespacesAndNewlines),
                                username: username, password: password)
                            connecting = false
                        }
                    } label: {
                        HStack {
                            Text(connecting ? "Connecting…" : "Connect")
                            Spacer()
                            if connecting { ProgressView() } else { Image(systemName: "arrow.right") }
                        }
                    }.disabled(connecting || server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || username.isEmpty || password.isEmpty)
                } footer: {
                    Text("Use your Xtream-compatible provider. Your password is stored securely in this iPhone’s Keychain.")
                }.listRowBackground(NullSportsStyle.raised)
            }
            .disabled(connecting)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .scrollContentBackground(.hidden)
            .background(NullSportsStyle.background)
        }
    }
}

private struct MobileLiveView: View {
    @EnvironmentObject private var library: SportsLibrary
    @State private var league: SportsLeague?
    @State private var choosingChannel: SportsGame?
    @State private var pendingStream: XtreamStream?
    let onPlay: (XtreamStream) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            leagueButton("All sports", value: nil)
                            ForEach(SportsLeague.allCases) { league in
                                leagueButton(league.shortName, value: league)
                            }
                        }
                    }
                    if library.isScheduleLoading || library.isLoading {
                        ProgressView("Updating your sports…").frame(maxWidth: .infinity)
                    }
                    if let error = library.scheduleErrorMessage {
                        Label(error, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                            .font(.footnote)
                    }
                    if !library.scheduleAvailable(for: league) && !library.isScheduleLoading {
                        ContentUnavailableView("Schedule unavailable", systemImage: "calendar.badge.exclamationmark",
                            description: Text("Pull down to try again. You can still watch from Guide."))
                    } else if library.games(for: league).isEmpty && !library.isScheduleLoading {
                        ContentUnavailableView("No upcoming games", systemImage: "sportscourt",
                            description: Text("Your channels are always available in Guide."))
                    }
                    LazyVStack(spacing: 12) {
                        ForEach(library.games(for: league)) { game in
                            Button {
                                if let stream = library.verifiedStream(for: game) { onPlay(stream) }
                                else { choosingChannel = game }
                            } label: { MobileGameCard(game: game) }
                            .buttonStyle(.plain)
                        }
                    }
                }.padding(16)
            }
            .background(NullSportsStyle.background)
            .navigationTitle("Live")
            .refreshable { library.refreshSchedule(showsLoading: true) }
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

    private func leagueButton(_ title: String, value: SportsLeague?) -> some View {
        Button { league = value } label: {
            Text(title).font(.subheadline.bold())
                .padding(.horizontal, 16).frame(minHeight: 44)
                .background(league == value ? NullSportsStyle.focused : NullSportsStyle.surface, in: Capsule())
                .overlay(Capsule().stroke(league == value ? NullSportsStyle.lightPurple : .clear))
        }.buttonStyle(.plain)
        .accessibilityAddTraits(league == value ? .isSelected : [])
    }
}

private struct MobileGameCard: View {
    let game: SportsGame

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(game.league.shortName).font(.caption.bold())
                Spacer()
                if game.isLive { Label("LIVE", systemImage: "circle.fill").font(.caption.bold()) }
                else { Text(game.start, format: .dateTime.weekday(.abbreviated).hour().minute()).font(.caption) }
            }
            team(game.awayTeam, logo: game.awayLogo, record: game.awayRecord, score: game.awayScore)
            team(game.homeTeam, logo: game.homeLogo, record: game.homeRecord, score: game.homeScore)
            HStack {
                Text(game.isLive ? game.status : game.broadcast).font(.caption)
                Spacer()
                Label("Watch", systemImage: "play.fill").font(.subheadline.bold())
            }
        }
        .padding(18).background(NullSportsStyle.surface, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(NullSportsStyle.line))
        .contentShape(RoundedRectangle(cornerRadius: 20))
    }

    private func team(_ name: String, logo: String, record: String?, score: String) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: logo)) { image in image.resizable().scaledToFit() }
                placeholder: { Image(systemName: "sportscourt").foregroundStyle(.secondary) }
                .frame(width: 36, height: 36).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.headline).multilineTextAlignment(.leading)
                if let record = record?.trimmingCharacters(in: .whitespacesAndNewlines), !record.isEmpty {
                    Text(record).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .accessibilityLabel("Record: \(record)")
                }
            }
            Spacer(minLength: 6)
            if game.isLive { Text(score).font(.title2.bold()).monospacedDigit() }
        }
    }
}

private struct MobileAccountView: View {
    @EnvironmentObject private var library: SportsLibrary
    @State private var confirmingRemoval = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Connected provider") {
                    if let profile = library.activeProfile {
                        LabeledContent("Profile", value: profile.name)
                        LabeledContent("Username", value: profile.username)
                    }
                    LabeledContent("Channels", value: "\(library.streams.count)")
                    Button("Refresh channels and guide", systemImage: "arrow.clockwise") {
                        Task { await library.reload() }
                    }.disabled(library.channelsAreSyncing)
                    if library.channelsAreSyncing { ProgressView("Updating…") }
                }.listRowBackground(NullSportsStyle.surface)
                Section {
                    Button("Remove provider", role: .destructive) { confirmingRemoval = true }
                }.listRowBackground(NullSportsStyle.surface)
            }
            .scrollContentBackground(.hidden).background(NullSportsStyle.background)
            .navigationTitle("Account")
            .confirmationDialog("Remove this provider and its saved password?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
                Button("Remove provider", role: .destructive) { library.removeActiveProfile() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}
