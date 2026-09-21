import SwiftUI

struct MainView: View {
    @EnvironmentObject private var library: SportsLibrary
    @EnvironmentObject private var media: MediaLibrary
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tab = 0
    @State private var playing: XtreamStream?
    @State private var inlinePlayerFullscreen = false
    @AppStorage(LineupTheme.storageKey) private var selectedTheme = LineupTheme.signal.rawValue

    var body: some View {
        // Each tab's content is scoped to the theme, not the TabView: the bar
        // and the selected tab survive a switch, and only what is painted is
        // redrawn. The guide keeps its own identity on the active profile,
        // which the theme scope sits outside of.
        TabView(selection: $tab) {
            MobileLiveView(isActive: tab == 0, onFullscreenChange: { setInlinePlayerFullscreen($0) }) { playing = $0 }
                .lineupThemeScope(selectedTheme)
                .tabItem { Label("Live", image: tab == 0 ? "Tab-Live-Selected" : "Tab-Live") }.tag(0)
            MobileGuideView(isActive: tab == 1, onFullscreenChange: { setInlinePlayerFullscreen($0) }) { playing = $0 }
                .id(library.activeProfile?.id)
                .lineupThemeScope(selectedTheme)
                .tabItem { Label("Guide", image: tab == 1 ? "Tab-Guide-Selected" : "Tab-Guide") }.tag(1)
            MediaServersView()
                .lineupThemeScope(selectedTheme)
                .tabItem { Label("Library", systemImage: tab == 2 ? "play.square.stack.fill" : "play.square.stack") }.tag(2)
            MobileAccountView(selectedTab: $tab)
                .lineupThemeScope(selectedTheme)
                .tabItem { Label("Account", image: tab == 3 ? "Tab-Account-Selected" : "Tab-Account") }.tag(3)
        }
        // Tab chrome remains neutral across themes; the selected asset changes
        // from outline to fill, with white providing the quiet emphasis.
        .tint(.white)
        .lineupTabBarBackground(LineupStyle.background)
        .animation(.easeInOut(duration: 0.22), value: selectedTheme)
        .preferredColorScheme(.dark)
        .ignoresSafeArea(inlinePlayerFullscreen ? .all : [], edges: .all)
        .onChange(of: library.activeProfile?.id) { _, _ in
            playing = nil
            inlinePlayerFullscreen = false
        }
        .statusBarHidden(inlinePlayerFullscreen)
        .persistentSystemOverlays(inlinePlayerFullscreen ? .hidden : .automatic)
        .fullScreenCover(item: $playing) { stream in
            MobilePlayerView(name: stream.name, urls: library.playbackURLs(for: stream), isLive: true)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                library.refreshSchedule(showsLoading: false, includeTomorrow: false)
            }
        }
    }

    // An inline player raises this from inside its own animated change, so the
    // tab bar and status bar leave in the same movement the video grows in.
    private func setInlinePlayerFullscreen(_ value: Bool) {
        guard inlinePlayerFullscreen != value else { return }
        let animation: Animation? = reduceMotion ? nil : .smooth(duration: 0.34)
        withAnimation(animation) { inlinePlayerFullscreen = value }
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
                }.listRowBackground(LineupGlassRow())
                Section("Your provider") {
                    TextField("Profile name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Server URL", text: $server)
                        .keyboardType(.URL).textContentType(.URL)
                    TextField("Username", text: $username).textContentType(.username)
                    SecureField("Password", text: $password).textContentType(.password)
                }.listRowBackground(LineupGlassRow())
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
                        .listRowBackground(LineupGlassRow())
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

/// The preferred-channel and recents lists, on a screen of their own.
///
/// They were rows in the Account form, where a viewer with a preference per
/// team turned the whole tab into a long scroll before reaching anything else.
/// Everything here is unchanged; it simply is not in the way any more.
private struct MobilePreferredChannelsView: View {
    @EnvironmentObject private var library: SportsLibrary
    @Binding var clearingPreferences: Bool

    var body: some View {
        Form {
            Section {
                if library.teamPreferences.isEmpty {
                        Text("No preferred channels yet. Choose a channel for a game and Lineup can remember it for either team.")
                            .font(.inter(.caption)).foregroundStyle(.secondary)
                    } else {
                        ForEach(library.teamPreferences.listed()) { entry in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.preference.teamName.isEmpty ? entry.key.team : entry.preference.teamName)
                                        .font(.inter(.body, .semibold))
                                    HStack(spacing: 6) {
                                        Text(entry.preference.channelName)
                                            .font(.inter(.caption)).foregroundStyle(.secondary)
                                        // A provider can drop a channel and carry
                                        // it again later, so this is a note, not a
                                        // reason to delete the preference.
                                        if !library.preferenceChannelIsAvailable(entry.preference) {
                                            Text("UNAVAILABLE")
                                                .font(.inter(8, .bold)).tracking(0.6)
                                                .padding(.horizontal, 5).padding(.vertical, 2)
                                                .background(LineupStyle.raised, in: Capsule())
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                Spacer(minLength: 8)
                                Text(entry.key.league).font(.inter(.caption2)).foregroundStyle(.secondary)
                                Button(role: .destructive) {
                                    library.removePreference(for: entry.key)
                                } label: {
                                    Image(systemName: "trash").frame(minWidth: 44, minHeight: 44)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove preferred channel for \(entry.preference.teamName)")
                            }
                            .accessibilityElement(children: .combine)
                        }
                        Button("Remove all preferred channels", systemImage: "trash", role: .destructive) {
                            clearingPreferences = true
                        }
                    }
                    if !library.recentStreams.isEmpty {
                        LabeledContent("Recently watched", value: "\(library.recentStreams.count)")
                        Button("Clear recent channels", systemImage: "clock.arrow.circlepath",
                               role: .destructive) { library.clearRecentChannels() }
                    }
            } footer: {
                Text("Games on these teams open on the saved channel. If it is unavailable, Lineup uses its own match instead and keeps the preference. Both these lists and your favorites belong to this provider alone.")
            }.listRowBackground(LineupGlassRow())
        }
        .scrollContentBackground(.hidden).background(LineupStyle.background)
        .confirmationDialog("Remove every preferred channel?", isPresented: $clearingPreferences,
                            titleVisibility: .visible) {
            Button("Remove all", role: .destructive) { library.removeAllPreferences() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This clears the saved channels for \(library.activeProfile?.name ?? "this provider") only.")
        }
        .navigationTitle("Preferred channels")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Channel matching and playback diagnostics, which are read when something is
/// wrong rather than browsed, so they sit one tap in rather than inline.
private struct MobileDiagnosticsView: View {
    @EnvironmentObject private var library: SportsLibrary
    @ObservedObject var playbackDiagnostics: PlaybackDiagnostics

    var body: some View {
        Form {
            Section {
                NavigationLink("Channel matching") { MatchDiagnosticsView().environmentObject(library) }
                NavigationLink("Launch timing") { StartupTraceReportView() }
                Toggle("Playback diagnostics", isOn: $playbackDiagnostics.isEnabled)
                if playbackDiagnostics.isEnabled {
                    NavigationLink("Playback report") { PlaybackDiagnosticsReportView() }
                }
            } footer: {
                Text("Launch timing is always recorded and shows where the last start spent its time. Playback diagnostics records what the player does while it is on — leave that off unless you are chasing a problem.")
            }.listRowBackground(LineupGlassRow())
        }
        .scrollContentBackground(.hidden).background(LineupStyle.background)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One source the tab can switch to, with a way to remove it.
///
/// The Providers list and the Media Servers list say the same thing -- a mark,
/// a name, a second line and a trash button -- and they used to say it
/// differently: different stack spacing, only one of them naming the active
/// choice, only one of them labelled for VoiceOver. Two lists that mean the
/// same thing and do not look the same is what makes a screen read as sloppy,
/// so there is now one row and both lists use it.
extension View {
    /// How an account card sits in the Form.
    ///
    /// A card draws its own surface, so it takes the whole row rather than the
    /// inset the form gives text rows, and it carries the gap to whatever comes
    /// next: two surfaces of their own meeting on a shared edge read as one
    /// badly drawn shape, and a list puts no space between rows. The separator
    /// goes because there is nothing there to divide -- a hairline floating in
    /// the gap would be the sloppiest part of all. Written once so both cards
    /// sit the same way.
    func lineupAccountCardRow() -> some View {
        self
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0))
            .listRowBackground(LineupStyle.background)
            .listRowSeparator(.hidden)
    }

    /// A section title in the app's own voice rather than the system's grey.
    func lineupSectionHeader() -> some View {
        self
            .font(.inter(.caption2, .semibold))
            .tracking(1.1)
            .textCase(.uppercase)
            .foregroundStyle(LineupStyle.lightPurple.opacity(0.7))
    }
}

private struct AccountSourceRow: View {
    let name: String
    let detail: String
    let isActive: Bool
    /// Named in the VoiceOver label, so "switch provider" and "switch media
    /// server" come out of the same sentence.
    let kind: String
    let select: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: select) {
                HStack(spacing: 0) {
                    // A Label rather than an icon and a stack side by side.
                    // The "Add provider" and "Add media server" buttons under
                    // these rows are Labels, and a Label gets the platform's
                    // icon column -- so written this way every row in the
                    // section starts its text at the same x, at any type size,
                    // instead of the eleven points of ragged edge that hand
                    // spacing left. It also keeps the names still as the
                    // active mark changes between a filled and an empty
                    // circle, which are not the same width.
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name).font(.inter(.body, .semibold)).lineLimit(1)
                            Text(detail).font(.inter(.caption))
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                    } icon: {
                        Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    }
                    Spacer(minLength: 8)
                    if isActive {
                        Text("Active").font(.inter(.caption)).foregroundStyle(.secondary)
                    }
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(name), \(isActive ? "active \(kind)" : "switch \(kind)")")
            Button(role: .destructive, action: remove) {
                Image(systemName: "trash").frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(name)")
        }
    }
}

private struct MobileAccountView: View {
    @Binding var selectedTab: Int
    @EnvironmentObject private var library: SportsLibrary
    @EnvironmentObject private var media: MediaLibrary
    @EnvironmentObject private var cloud: CloudSettingsSync
    @State private var addingProvider = false
    @State private var addingMediaServer = false
    @State private var removingProfile: XtreamProfile?
    @State private var removingMediaProfile: MediaServerProfile?
    @State private var clearingPreferences = false
    @ObservedObject private var playbackDiagnostics = PlaybackDiagnostics.shared
    @AppStorage(LineupTheme.storageKey) private var selectedTheme = LineupTheme.signal.rawValue

    /// Counts rather than the lists themselves, so the row says whether there
    /// is anything behind it without reproducing it.
    private var preferencesSummary: String {
        let teams = library.teamPreferences.listed().count
        let recents = library.recentStreams.count
        if teams == 0 && recents == 0 { return "None yet" }
        var parts: [String] = []
        if teams > 0 { parts.append("\(teams) team\(teams == 1 ? "" : "s")") }
        if recents > 0 { parts.append("\(recents) recent") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let profile = library.activeProfile {
                        ProviderAccountCard(profile: profile) { selectedTab = 1 }
                            .lineupAccountCardRow()
                    }
                    ForEach(library.profiles) { profile in
                        AccountSourceRow(
                            name: profile.name,
                            detail: profile.username,
                            isActive: library.activeProfile?.id == profile.id,
                            kind: "provider",
                            select: { Task { await library.selectProfile(profile) } },
                            remove: { removingProfile = profile }
                        )
                        .disabled(library.isSwitchingProfile || library.channelsAreSyncing)
                    }
                    Button("Add provider", systemImage: "plus.circle") { addingProvider = true }
                        .disabled(library.isSwitchingProfile)
                    if library.isSwitchingProfile { ProgressView("Switching provider…") }
                    // Kept in this section rather than one of its own. It was
                    // the only section on the tab with no header, which read as
                    // a row that had come loose from something -- and it had:
                    // these lists belong to the provider above them, which is
                    // what the footer here already said.
                    NavigationLink {
                        MobilePreferredChannelsView(clearingPreferences: $clearingPreferences)
                            .environmentObject(library)
                    } label: {
                        LabeledContent("Preferred channels & recents",
                                       value: preferencesSummary)
                    }
                } header: {
                    Text("Providers").lineupSectionHeader()
                } footer: {
                    Text("Each provider keeps its own favorites, preferred channels and recents. Games on those teams open on the saved channel.")
                }.listRowBackground(LineupGlassRow())
                Section {
                    if let profile = media.activeProfile {
                        MediaServerAccountCard(profile: profile) { selectedTab = 2 }
                            .lineupAccountCardRow()
                    }
                    ForEach(media.profiles) { profile in
                        AccountSourceRow(
                            name: profile.name,
                            detail: URL(string: profile.serverURL)?.host ?? profile.serverURL,
                            isActive: media.activeProfile?.id == profile.id,
                            kind: "media server",
                            select: { Task { await media.select(profile) } },
                            remove: { removingMediaProfile = profile }
                        )
                    }
                    Button("Add media server", systemImage: "plus.circle") { addingMediaServer = true }
                    if media.isLoading { ProgressView("Connecting…") }
                } header: {
                    Text("Media Servers").lineupSectionHeader()
                } footer: {
                    Text("Jellyfin, Nullfin, and other Jellyfin-compatible servers.")
                }.listRowBackground(LineupGlassRow())
                Section {
                    // Collapsed rather than pushed. A theme screen of its own
                    // dismissed itself as the palette changed underneath it,
                    // which is why this picker stays inline; a disclosure row
                    // gives back the height without putting it on a screen that
                    // can be torn down mid-redraw.
                    DisclosureGroup {
                        Picker("Theme", selection: $selectedTheme) {
                            ForEach(LineupTheme.allCases) { theme in
                                HStack(spacing: 12) {
                                    LineupThemeSwatch(theme: theme)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(theme.name)
                                        Text(theme.detail).font(.inter(.caption))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .tag(theme.rawValue)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        LabeledContent("Theme", value: LineupTheme(rawValue: selectedTheme)?.name ?? "Signal")
                    }
                } header: {
                    Text("Appearance").lineupSectionHeader()
                } footer: {
                    Text("Syncs through iCloud.")
                }
                .listRowBackground(LineupGlassRow())
                // What is left once the provider card carries the channel
                // count, the sync state and the refresh button: three facts
                // about the app rather than a drawer of odds and ends, which
                // is what this section had turned into.
                Section {
                    LabeledContent("iCloud", value: cloud.status)
                    NavigationLink("Diagnostics") {
                        MobileDiagnosticsView(playbackDiagnostics: playbackDiagnostics)
                            .environmentObject(library)
                    }
                    LabeledContent("Version", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"))")
                } header: {
                    Text("About").lineupSectionHeader()
                }.listRowBackground(LineupGlassRow())
            }
            .scrollContentBackground(.hidden).background(LineupStyle.background)
            .navigationTitle("Account")
            .task {
                if media.activeProfile != nil && media.roots.isEmpty && !media.isLoading {
                    await media.reload()
                }
            }
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
            }.listRowBackground(LineupGlassRow())
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
