import SwiftUI

struct MainView: View {
    @EnvironmentObject private var library: SportsLibrary
    @EnvironmentObject private var media: MediaLibrary
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var playing: XtreamStream?
    @State private var guideFullscreen = false
    @AppStorage(LineupTheme.storageKey) private var selectedTheme = LineupTheme.signal.rawValue

    var body: some View {
        // Each tab's content is scoped to the theme, not the TabView: the bar
        // and the selected tab survive a switch, and only what is painted is
        // redrawn. The guide keeps its own identity on the active profile,
        // which the theme scope sits outside of.
        TabView(selection: $tab) {
            MobileLiveView(isActive: tab == 0) { playing = $0 }
                .lineupThemeScope(selectedTheme)
                .tabItem { Label("Live", image: tab == 0 ? "Tab-Live-Selected" : "Tab-Live") }.tag(0)
            MobileGuideView(isActive: tab == 1, onFullscreenChange: { guideFullscreen = $0 }) { playing = $0 }
                .id(library.activeProfile?.id)
                .lineupThemeScope(selectedTheme)
                .tabItem { Label("Guide", image: tab == 1 ? "Tab-Guide-Selected" : "Tab-Guide") }.tag(1)
            MediaServersView()
                .lineupThemeScope(selectedTheme)
                .tabItem { Label("Media Servers", systemImage: "play.square.stack") }.tag(2)
            MobileAccountView()
                .lineupThemeScope(selectedTheme)
                .tabItem { Label("Account", image: tab == 3 ? "Tab-Account-Selected" : "Tab-Account") }.tag(3)
        }
        .tint(LineupStyle.highlight)
        .lineupTabBarBackground(LineupStyle.background)
        .animation(.easeInOut(duration: 0.22), value: selectedTheme)
        .preferredColorScheme(.dark)
        .ignoresSafeArea(guideFullscreen ? .all : [], edges: .all)
        .onChange(of: library.activeProfile?.id) { _, _ in
            playing = nil
            guideFullscreen = false
        }
        .statusBarHidden(guideFullscreen)
        .persistentSystemOverlays(guideFullscreen ? .hidden : .automatic)
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
    @Environment(\.dismiss) private var dismiss
    var addingProvider = false
    @EnvironmentObject private var library: SportsLibrary
    @State private var name = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var connecting = false
    @State private var connectionError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("LINEUP").font(.inter(.caption, .bold)).tracking(3)
                        Text("Your games.\nAnywhere.").font(.inter(.largeTitle, .bold))
                        Text("Connect your provider to bring live sports to your iPhone.")
                    }.padding(.vertical, 16)
                }.listRowBackground(LineupStyle.surface)
                Section("Your provider") {
                    TextField("Profile name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Server URL", text: $server)
                        .keyboardType(.URL).textContentType(.URL)
                    TextField("Username", text: $username).textContentType(.username)
                    SecureField("Password", text: $password).textContentType(.password)
                }.listRowBackground(LineupStyle.surface)
                Section {
                    Button {
                        connecting = true
                        connectionError = nil
                        Task {
                            let added = await library.addProfile(name: name,
                                serverURL: server.trimmingCharacters(in: .whitespacesAndNewlines),
                                username: username, password: password)
                            connecting = false
                            if !added { connectionError = library.errorMessage }
                            if added && addingProvider { dismiss() }
                        }
                    } label: {
                        HStack {
                            Text(connecting ? "Connectingâ€¦" : "Connect")
                            Spacer()
                            if connecting { ProgressView() } else { Image(systemName: "arrow.right") }
                        }
                    }.disabled(connecting || server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || username.isEmpty || password.isEmpty)
                } footer: {
                    Text("Use your Xtream-compatible provider. Your password is stored securely in this iPhoneâ€™s Keychain.")
                }.listRowBackground(LineupStyle.raised)
                if let connectionError {
                    Section { Text(connectionError).foregroundStyle(.red) }
                        .listRowBackground(LineupStyle.surface)
                }
            }
            .navigationTitle(addingProvider ? "Add provider" : "")
            .toolbar {
                if addingProvider {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }.disabled(connecting)
                    }
                }
            }
            .interactiveDismissDisabled(connecting)
            .disabled(connecting)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .scrollContentBackground(.hidden)
            .background(LineupStyle.background)
        }
    }
}

private struct MobileAccountView: View {
    @EnvironmentObject private var library: SportsLibrary
    @EnvironmentObject private var media: MediaLibrary
    @EnvironmentObject private var reminders: GameReminders
    @EnvironmentObject private var cloud: CloudSettingsSync
    @State private var addingProvider = false
    @State private var addingMediaServer = false
    @State private var removingProfile: XtreamProfile?
    @State private var removingMediaProfile: MediaServerProfile?
    @AppStorage(LineupTheme.storageKey) private var selectedTheme = LineupTheme.signal.rawValue

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(reminders.availableTeams(in: library.games(for: nil))) { team in
                        Button {
                            reminders.toggleTeam(team)
                        } label: {
                            HStack {
                                Text("\(team.name) · \(team.league.shortName)")
                                Spacer()
                                Image(systemName: reminders.follows(team) ? "checkmark.circle.fill" : "circle")
                            }
                        }
                    }
                    if reminders.availableTeams(in: library.games(for: nil)).isEmpty {
                        Text("Teams appear when a schedule is available.")
                            .foregroundStyle(.secondary)
                    }
                    if let message = reminders.authorizationMessage { Text(message).foregroundStyle(.secondary) }
                } header: {
                    Text("Follow Teams")
                } footer: {
                    Text("Lineup reminds you 15 minutes before each followed team's game. Choices sync through iCloud; each device schedules its own alerts.")
                }.listRowBackground(LineupStyle.surface)
                Section {
                    // Inline, not a pushed screen. Choosing a theme rebuilds
                    // this screen so it repaints in the new palette, which
                    // would pull a pushed picker out from under the tap. With
                    // two themes there is nothing to push for anyway.
                    Picker("Theme", selection: $selectedTheme) {
                        ForEach(LineupTheme.allCases) { theme in
                            HStack {
                                LineupThemeSwatch(theme: theme)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(theme.name)
                                    Text(theme.detail).font(.inter(.caption)).foregroundStyle(.secondary)
                                }
                            }
                            .tag(theme.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("A complete color treatment for Lineup. Your choice syncs through iCloud.")
                }
                .listRowBackground(LineupStyle.surface)
                Section {
                    ForEach(library.profiles) { profile in
                        HStack(spacing: 12) {
                            Button {
                                Task { await library.selectProfile(profile) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: library.activeProfile?.id == profile.id ? "checkmark.circle.fill" : "circle")
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(profile.name).font(.inter(.body, .semibold))
                                        Text(profile.username).font(.inter(.caption)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if library.activeProfile?.id == profile.id {
                                        Text("Active").font(.inter(.caption)).foregroundStyle(.secondary)
                                    }
                                }.contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(profile.name), \(library.activeProfile?.id == profile.id ? "active provider" : "switch provider")")
                            Button(role: .destructive) { removingProfile = profile } label: {
                                Image(systemName: "trash").frame(minWidth: 44, minHeight: 44)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(profile.name)")
                        }
                        .disabled(library.isSwitchingProfile || library.channelsAreSyncing)
                    }
                    Button("Add provider", systemImage: "plus.circle") { addingProvider = true }
                        .disabled(library.isSwitchingProfile)
                    if library.isSwitchingProfile { ProgressView("Switching provider…") }
                } header: {
                    Text("Providers")
                } footer: {
                    Text("Select a provider to use its channels and guide. Each provider keeps its own favorites.")
                }.listRowBackground(LineupStyle.surface)
                Section("Current library") {
                    LabeledContent("iCloud", value: cloud.status)
                    LabeledContent("App version", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"))")
                    LabeledContent("Channels", value: "\(library.streams.count)")
                    NavigationLink("Channel matching") { MatchDiagnosticsView().environmentObject(library) }
                    Button("Refresh channels and guide", systemImage: "arrow.clockwise") {
                        Task { await library.reload() }
                    }.disabled(library.channelsAreSyncing || library.isSwitchingProfile)
                    if library.channelsAreSyncing { ProgressView("Updating…") }
                }.listRowBackground(LineupStyle.surface)
                Section {
                    ForEach(media.profiles) { profile in
                        HStack {
                            Button {
                                Task { await media.select(profile) }
                            } label: {
                                HStack {
                                    Image(systemName: media.activeProfile?.id == profile.id ? "checkmark.circle.fill" : "circle")
                                    VStack(alignment: .leading) {
                                        Text(profile.name).font(.inter(.body, .semibold))
                                        Text(profile.serverURL).font(.inter(.caption)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                }
                            }.buttonStyle(.plain)
                            Button(role: .destructive) { removingMediaProfile = profile } label: {
                                Image(systemName: "trash").frame(minWidth: 44, minHeight: 44)
                            }.buttonStyle(.borderless)
                        }
                    }
                    Button("Add media server", systemImage: "plus.circle") { addingMediaServer = true }
                    if media.isLoading { ProgressView("Connecting…") }
                } header: {
                    Text("Media Servers")
                } footer: {
                    Text("Jellyfin and Nullfin servers. Nullfin libraries include the addon catalogs configured on your server.")
                }.listRowBackground(LineupStyle.surface)
            }
            .scrollContentBackground(.hidden).background(LineupStyle.background)
            .navigationTitle("Account")
            .onChange(of: selectedTheme) { _, _ in CloudSettingsSync.shared.localSettingsChanged() }
            .sheet(isPresented: $addingProvider) {
                ProfileSetupView(addingProvider: true)
                    .environmentObject(library)
                    .tint(LineupStyle.highlight)
                    .preferredColorScheme(.dark)
            }
            .sheet(isPresented: $addingMediaServer) {
                MediaServerSetupView()
                    .environmentObject(media)
                    .tint(LineupStyle.highlight)
                    .preferredColorScheme(.dark)
            }
            .confirmationDialog("Remove \(removingProfile?.name ?? "provider") and its saved password?",
                isPresented: Binding(get: { removingProfile != nil }, set: { if !$0 { removingProfile = nil } }),
                titleVisibility: .visible) {
                Button("Remove provider", role: .destructive) {
                    if let profile = removingProfile { Task { await library.removeProfile(profile) } }
                    removingProfile = nil
                }
                Button("Cancel", role: .cancel) { removingProfile = nil }
            }
            .confirmationDialog("Remove \(removingMediaProfile?.name ?? "media server")?",
                isPresented: Binding(get: { removingMediaProfile != nil }, set: { if !$0 { removingMediaProfile = nil } }),
                titleVisibility: .visible) {
                Button("Remove media server", role: .destructive) {
                    if let profile = removingMediaProfile { media.remove(profile) }
                    removingMediaProfile = nil
                }
                Button("Cancel", role: .cancel) { removingMediaProfile = nil }
            }
        }
    }
}

/// Why each game matched the channel it did. A game that opens the wrong feed
/// should be able to name the rule that chose it, without a device log.
private struct MatchDiagnosticsView: View {
    @EnvironmentObject private var library: SportsLibrary

    private var games: [SportsGame] {
        library.games(for: nil).filter { $0.isLive || $0.isUpcoming }
    }

    var body: some View {
        List {
            Section {
                if !library.automaticMatchingReady {
                    ProgressView("Matching\u{2026}")
                } else if games.isEmpty {
                    Text("No live or upcoming games to match.").foregroundStyle(.secondary)
                }
                ForEach(games) { game in
                    row(game)
                }
            } footer: {
                Text("A match needs a guide listing or a channel name that names both teams. Report a wrong game with the line shown under its channel.")
            }.listRowBackground(LineupStyle.surface)
        }
        .scrollContentBackground(.hidden)
        .background(LineupStyle.background)
        .navigationTitle("Channel matching")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ game: SportsGame) -> some View {
        let stream = library.stream(for: game)
        let evidence = library.matchEvidence(for: game)
        return VStack(alignment: .leading, spacing: 5) {
            Text("\(game.awayTeam) at \(game.homeTeam)").font(.inter(.subheadline, .semibold))
            Text("\(game.league.shortName) \u{00B7} \(game.broadcast.isEmpty ? "No network listed" : game.broadcast)")
                .font(.inter(.caption)).foregroundStyle(.secondary)
            if let stream {
                Text(stream.name).font(.inter(.caption, .medium))
                if let rejection = library.playbackRejection(for: game) {
                    Text(rejection.rawValue).font(.inter(.caption2)).foregroundStyle(LineupStyle.live)
                } else {
                    Text(evidence?.rawValue ?? "Matched earlier, evidence not recorded yet")
                        .font(.inter(.caption2))
                        .foregroundStyle(evidence == .dedicatedFeed ? Color.secondary : LineupStyle.warning)
                }
            } else {
                Text("No match \u{2014} opens the channel picker")
                    .font(.inter(.caption2)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
