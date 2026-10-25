import SwiftUI
import LineupAetherPlayback
import LineupMPVPlayback

private struct MobileScheduleRefreshContext: Equatable {
    let scenePhase: ScenePhase
    let tab: Int
}

struct MainView: View {
    @Environment(SportsLibrary.self) private var library
    @Environment(MediaLibrary.self) private var media
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tab = 0
    @State private var playing: XtreamStream?
    @State private var inlinePlayerFullscreen = false
    @AppStorage(LineupAccent.storageKey) private var accent = LineupAccent.red.hex
    @AppStorage(MobileNavigationStyle.glassKey) private var navigationGlass = false
    @AppStorage(MobileNavigationOrder.storageKey) private var savedTabOrder = MobileNavigationOrder.defaultValue

    var body: some View {
        // Each tab's content is redrawn in a new accent, not the TabView: the
        // bar and the selected tab survive the change. The guide keeps its
        // own identity on the active profile, which this sits outside of.
        TabView(selection: $tab) {
            ForEach(MobileNavigationOrder.tabs(in: savedTabOrder)) { destination in
                tabContent(destination)
                    .lineupAccentScope(accent)
                    .mobileNativeTabBar(liquidGlass: navigationGlass, fullscreen: inlinePlayerFullscreen)
                    .tabItem { Label { Text(destination.title) } icon: { destination.icon(selected: tab == destination.rawValue) } }
                    .tag(destination.rawValue)
            }
        }
        // Both navigation styles share this TabView and its selection. The
        // selected icons and labels stay white in both appearances.
        .tint(.white)
        .mobileNavigationChrome(selection: $tab, liquidGlass: navigationGlass,
                                fullscreen: inlinePlayerFullscreen)
        // Over every tab while channels, the guide and the matches refresh.
        // Never over a picture: the full-screen player covers it, and it
        // stands aside while the inline player fills the screen.
        .overlay(alignment: .top) {
            if !inlinePlayerFullscreen {
                DataRefreshPopup()
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
            }
        }
        // Touch-and-hold choices anywhere in the tabs rise over all of them.
        .lineupHoldMenuHost()
        .preferredColorScheme(.dark)
        .ignoresSafeArea(inlinePlayerFullscreen ? .all : [], edges: .all)
        .onChange(of: library.activeProfile?.id) { _, _ in
            playing = nil
            inlinePlayerFullscreen = false
        }
        .statusBarHidden(inlinePlayerFullscreen)
        .persistentSystemOverlays(inlinePlayerFullscreen ? .hidden : .automatic)
        .lineupFullScreenCover(item: $playing) { stream in
            MobilePlayerView(name: stream.name, urls: library.playbackURLs(for: stream), isLive: true)
        }
        .task(id: MobileScheduleRefreshContext(scenePhase: scenePhase, tab: tab)) {
            // Live scores are only visible on the first two tabs. Keeping this
            // loop alive in Library or Account made those tabs absorb a full
            // schedule publication every 30 seconds for no visible benefit.
            guard scenePhase == .active, tab == 0 || tab == 1 else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                library.refreshSchedule(showsLoading: false, includeTomorrow: false)
            }
        }
    }

    @ViewBuilder private func tabContent(_ destination: MobileNavigationTab) -> some View {
        switch destination {
        case .sports:
            MobileLiveView(isActive: tab == 0, onFullscreenChange: { setInlinePlayerFullscreen($0) }) { playing = $0 }
        case .guide:
            MobileCombinedGuideView(isActive: tab == 1, onFullscreenChange: { setInlinePlayerFullscreen($0) }) { playing = $0 }
        case .library: MediaServersView()
        case .search: AppSearchView { playing = $0 }
        case .settings: MobileAccountView(selectedTab: $tab)
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
    @Environment(SportsLibrary.self) private var library
    @State private var name = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var connecting = false
    @State private var connectionError: String?
    @State private var playlistConnection = false
    @State private var guideURL = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("LINEUP").font(.inter(.caption, .bold)).tracking(3)
                        Text("Your games.\nAnywhere.").font(.inter(.largeTitle, .bold))
                        Text("Connect your provider to bring live sports to your iPhone.")
                    }.padding(.vertical, 16)
                }.lineupSettingsRows()
                Section {
                    Picker("Connection", selection: $playlistConnection) {
                        Label("Xtream", systemImage: "server.rack").tag(false)
                        Label("M3U / EPGenius", systemImage: "list.bullet.rectangle").tag(true)
                    }
                    TextField("Profile name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField(playlistConnection ? "Playlist URL" : "Server URL", text: $server)
                        .keyboardType(.URL).textContentType(.URL)
                    if playlistConnection {
                        TextField("XMLTV guide URL (optional)", text: $guideURL)
                            .keyboardType(.URL).textContentType(.URL)
                    } else {
                    TextField("Username", text: $username).textContentType(.username)
                    SecureField("Password", text: $password).textContentType(.password)
                    }
                } header: {
                    Text("Your provider").lineupSettingsHeader()
                }.lineupSettingsRows()
                Section {
                    Button {
                        connecting = true
                        connectionError = nil
                        Task {
                            let added: Bool
                            if playlistConnection {
                                added = await library.addPlaylist(name: name, playlist: server, guide: guideURL)
                            } else {
                                added = await library.addProfile(name: name,
                                    serverURL: server.trimmingCharacters(in: .whitespacesAndNewlines),
                                    username: username, password: password)
                            }
                            connecting = false
                            if !added { connectionError = library.errorMessage }
                            if added && addingProvider { dismiss() }
                        }
                    } label: {
                        HStack {
                            Text(connecting ? "Connecting…" : "Connect")
                            Spacer()
                            if connecting { ProgressView() } else { Image(systemName: "arrow.right") }
                        }
                    }.disabled(connecting || server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                               || (!playlistConnection && (username.isEmpty || password.isEmpty)))
                } footer: {
                    Text(playlistConnection
                         ? "Use the playlist and EPG URLs supplied by EPGenius or your provider. Connection URLs are stored securely in Keychain. Playlist connections provide live TV; Xtream is required for provider VOD and catch up."
                         : "Use your Xtream-compatible provider. Your password is stored securely in this iPhone’s Keychain.")
                        .lineupSettingsFooter()
                }.lineupSettingsRows()
                if let connectionError {
                    Section { Text(connectionError).foregroundStyle(.red) }
                        .lineupSettingsRows()
                }
            }
            .navigationTitle(addingProvider ? "Add provider" : "")
            .toolbar {
                if addingProvider {
                    LineupToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }.buttonStyle(LineupBarButtonStyle()).disabled(connecting)
                    }
                }
            }
            .interactiveDismissDisabled(connecting)
            .disabled(connecting)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .scrollContentBackground(.hidden)
            .background(LineupPanelStyle.listGround)
        }
    }
}

/// The preferred-channel and recents lists, on a screen of their own.
///
/// They were rows in the Account form, where a viewer with a preference per
/// team turned the whole tab into a long scroll before reaching anything else.
/// Everything here is unchanged; it simply is not in the way any more.
private struct MobilePreferredChannelsView: View {
    @Environment(SportsLibrary.self) private var library
    @Binding var clearingPreferences: Bool

    var body: some View {
        Form {
            Section {
                if library.teamPreferences.isEmpty {
                        Text("No preferred channels yet. Choose a channel for a game and Lineup can remember it for either team.")
                            .font(.inter(15)).foregroundStyle(LineupPanelStyle.listValue)
                    } else {
                        ForEach(library.teamPreferences.listed()) { entry in
                            HStack(spacing: 14) {
                                LineupIconTile(symbol: "star", size: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.preference.teamName.isEmpty ? entry.key.team : entry.preference.teamName)
                                        .font(.inter(17, .medium))
                                    HStack(spacing: 6) {
                                        Text(entry.preference.channelName)
                                            .font(.inter(13)).foregroundStyle(LineupPanelStyle.listValue)
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
                                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                                Spacer(minLength: 8)
                                Text(entry.key.league).font(.inter(15)).foregroundStyle(LineupPanelStyle.listValue)
                                Button(role: .destructive) {
                                    library.removePreference(for: entry.key)
                                } label: {
                                    Image(systemName: "trash").frame(minWidth: 44, minHeight: 44)
                                        .foregroundStyle(LineupPanelStyle.listValue)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove preferred channel for \(entry.preference.teamName)")
                            }
                            .accessibilityElement(children: .combine)
                        }
                        Button(role: .destructive) { clearingPreferences = true } label: {
                            SettingsRow("Remove All", symbol: "trash",
                                        titleColor: LineupIconTile.red)
                        }
                    }
            } header: {
                Text("Teams").lineupSettingsHeader()
            } footer: {
                Text("Games on these teams open on the saved channel. If it is unavailable, Lineup uses its own match instead and keeps the preference. Both these lists and your favorites belong to this provider alone.")
                    .lineupSettingsFooter()
            }
            .lineupSettingsRows()
            if !library.recentStreams.isEmpty {
                Section {
                    SettingsRow("Recently Watched", symbol: "clock", value: library.recentStreams.count.formatted())
                    Button(role: .destructive) { library.clearRecentChannels() } label: {
                        SettingsRow("Clear Recent Channels", symbol: "clock.arrow.circlepath",
                                    titleColor: LineupIconTile.red)
                    }
                }
                .lineupSettingsRows()
            }
        }
        .lineupSettingsList()
        .lineupChoices("Remove every preferred channel?", symbol: "trash",
                       isPresented: $clearingPreferences,
                       message: "This clears the saved channels for \(library.activeProfile?.name ?? "this provider") only.") {
            [MobileMenuItem("Remove All", isDestructive: true) { library.removeAllPreferences() }]
        }
        .navigationTitle("Preferred Channels")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Channel matching and playback diagnostics, which are read when something is
/// wrong rather than browsed, so they sit one tap in rather than inline.
private struct MobileDiagnosticsView: View {
    @Environment(SportsLibrary.self) private var library
    @ObservedObject var playbackDiagnostics: PlaybackDiagnostics

    var body: some View {
        Form {
            Section {
                NavigationLink { MatchDiagnosticsView().environment(library) } label: {
                    SettingsRow("Channel Matching", symbol: "tv")
                }
                NavigationLink { StartupTraceReportView() } label: {
                    SettingsRow("Launch Timing", symbol: "timer")
                }
                NavigationLink { DeviceReportsView() } label: {
                    SettingsRow("Device Reports", symbol: "speedometer")
                }
            }
            .lineupSettingsRows()
            Section {
                Toggle(isOn: $playbackDiagnostics.isEnabled) {
                    SettingsRow("Playback Diagnostics", symbol: "waveform.path.ecg")
                }
                .tint(LineupIconTile.green)
                if playbackDiagnostics.isEnabled {
                    NavigationLink { PlaybackDiagnosticsReportView() } label: {
                        SettingsRow("Playback Report", symbol: "doc.text")
                    }
                }
            } footer: {
                Text("Launch timing is always recorded and shows where the last start spent its time. Device reports are Apple's daily account of launches, hangs, battery-heavy work and data use on this phone. Playback diagnostics records what the player does while it is on — leave that off unless you are chasing a problem.")
                    .lineupSettingsFooter()
            }
            .lineupSettingsRows()
        }
        .lineupSettingsList()
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A Settings row the way the reference app draws one: a coloured tile, the
/// name in white, and what it is set to in grey after it. A row that leads
/// somewhere gets the list's own chevron from its link; a row that opens a
/// sheet draws the same one itself.
private struct SettingsRow<Trailing: View>: View {
    let title: String
    let symbol: String
    var value: String?
    var tint: Color?
    var titleColor: Color = LineupStyle.text
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 14) {
            LineupIconTile(symbol: symbol, size: 30, tint: tint)
            Text(title)
                .font(.inter(17, .medium))
                .foregroundStyle(titleColor)
                .lineLimit(1)
                // The hairline under the row starts at the words, not at the
                // tile, as it does in Settings.
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(.inter(17))
                    .foregroundStyle(LineupPanelStyle.listValue)
                    .lineLimit(1)
            }
            trailing()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(_ title: String, symbol: String, value: String? = nil, tint: Color? = nil,
         titleColor: Color = LineupStyle.text) {
        self.init(title: title, symbol: symbol, value: value, tint: tint, titleColor: titleColor) { EmptyView() }
    }
}

/// The chevron a link row gets from the list, for rows that open a sheet.
private struct SettingsChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(LineupPanelStyle.listChevron)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Settings and the pages under it: a dark grey ground, the rows a step
    /// lighter and a little taller than the system's, hairlines between them.
    func lineupSettingsList() -> some View {
        modifier(MobileSettingsListStyle()).lineupPresentation()
    }

    func lineupSettingsRows() -> some View {
        modifier(MobileSettingsRowsStyle())
    }

    /// An account card as a row of its own: it brings its own padding, and
    /// its surface is the row's.
    func lineupAccountCardRow() -> some View {
        self.listRowInsets(EdgeInsets())
            .modifier(MobileSettingsRowsStyle())
            .listRowSeparator(.hidden)
    }

    /// A section title above a group of rows, small and grey.
    func lineupSettingsHeader() -> some View {
        self.font(.inter(13, .semibold))
            .foregroundStyle(LineupPresentationStyle.secondary)
    }

    /// The note under a group of rows.
    func lineupSettingsFooter() -> some View {
        self.font(.inter(13))
            .foregroundStyle(LineupPresentationStyle.secondary)
    }
}

private struct MobileSettingsListStyle: ViewModifier {
    @Environment(\.lineupIsPresentation) private var presentation
    func body(content: Content) -> some View {
        content.listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight, 58)
            .listSectionSpacing(24)
            .scrollContentBackground(.hidden)
            .background(presentation ? LineupPresentationStyle.ground : LineupPanelStyle.listGround)
    }
}

private struct MobileSettingsRowsStyle: ViewModifier {
    @Environment(\.lineupIsPresentation) private var presentation
    func body(content: Content) -> some View {
        content.listRowBackground(presentation ? LineupPresentationStyle.row : LineupPanelStyle.listCard)
            .listRowSeparatorTint(presentation ? LineupPresentationStyle.divider : LineupPanelStyle.listSeparator)
    }
}

/// A connected media server. The Library uses every one of them at once, so
/// the row says how its own server is doing rather than offering to switch.
private struct MediaServerRow: View {
    @Environment(MediaLibrary.self) private var media
    let profile: MediaServerProfile
    let remove: () -> Void

    var body: some View {
        let state = media.state(of: profile)
        HStack(spacing: 14) {
            // The server's own mark, on a tile like every other row's.
            MediaServerLogoTile(brand: .of(profile))
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.inter(17, .medium)).foregroundStyle(LineupStyle.text).lineLimit(1)
                Text(profile.displayHost).font(.inter(13))
                    .foregroundStyle(LineupPanelStyle.listValue).lineLimit(1)
            }
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            Spacer(minLength: 8)
            Text(state.isLoading ? "Connecting…" : (state.isConnected ? "Connected" : "Offline"))
                .font(.inter(15)).foregroundStyle(LineupPanelStyle.listValue)
            Button(role: .destructive, action: remove) {
                Image(systemName: "trash").frame(minWidth: 44, minHeight: 44)
                    .foregroundStyle(LineupPanelStyle.listValue)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(profile.name)")
        }
    }
}

/// A provider, to switch to and to remove. The one in use carries the
/// accent's tick, as a chosen row does in Settings.
private struct AccountSourceRow: View {
    let name: String
    let detail: String
    let isActive: Bool
    let selectionDisabled: Bool
    let removalDisabled: Bool
    let select: () -> Void
    let rename: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: select) {
                HStack(spacing: 14) {
                    LineupIconTile(symbol: "antenna.radiowaves.left.and.right", size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.inter(17, .medium)).foregroundStyle(LineupStyle.text).lineLimit(1)
                        Text(detail).font(.inter(13))
                            .foregroundStyle(LineupPanelStyle.listValue).lineLimit(1)
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    Spacer(minLength: 8)
                    if isActive {
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(LineupStyle.highlight)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(selectionDisabled)
            .accessibilityLabel("\(name), \(isActive ? "preferred provider" : "make preferred provider")")
            Button(action: rename) {
                Image(systemName: "pencil").frame(minWidth: 44, minHeight: 44)
                    .foregroundStyle(LineupPanelStyle.listValue)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Rename \(name)")
            Button(role: .destructive, action: remove) {
                Image(systemName: "trash").frame(minWidth: 44, minHeight: 44)
                    .foregroundStyle(LineupPanelStyle.listValue)
            }
            .buttonStyle(.borderless)
            .disabled(removalDisabled)
            .accessibilityLabel("Remove \(name)")
        }
    }
}

/// The choice sheet dismisses (and clears its selection) before running an
/// action. Retain the selected account when building its confirmation row.
@MainActor
enum MobileSettingsRemovalChoices {
    static func provider(_ selection: XtreamProfile?, library: SportsLibrary) -> [MobileMenuItem] {
        guard let profile = selection else { return [] }
        return [MobileMenuItem("Remove Provider", isDestructive: true) {
            Task { await library.removeProfile(profile) }
        }]
    }

    static func mediaServer(_ selection: MediaServerProfile?, media: MediaLibrary) -> [MobileMenuItem] {
        guard let profile = selection else { return [] }
        return [MobileMenuItem("Remove Media Server", isDestructive: true) {
            media.remove(profile)
        }]
    }
}

/// IPTV: the provider in use, every provider to switch between, and adding
/// one.
private struct MobileIPTVSettingsView: View {
    @Binding var selectedTab: Int
    @Environment(SportsLibrary.self) private var library
    @State private var addingProvider = false
    @State private var removingProfile: XtreamProfile?
    @State private var renamingProfile: XtreamProfile?
    @State private var providerName = ""

    var body: some View {
        List {
            if let profile = library.activeProfile {
                Section {
                    ProviderAccountCard(profile: profile) { selectedTab = 1 }
                        .lineupAccountCardRow()
                }
            }
            Section {
                ForEach(library.profiles) { profile in
                    VStack(alignment: .leading, spacing: 8) {
                    AccountSourceRow(
                        name: profile.name,
                        detail: profile.username,
                        isActive: library.activeProfile?.id == profile.id,
                        selectionDisabled: library.isSwitchingProfile || library.channelsAreSyncing || !library.isProviderEnabled(profile.id),
                        removalDisabled: library.isSwitchingProfile,
                        select: { Task { await library.selectProfile(profile) } },
                        rename: { providerName = profile.name; renamingProfile = profile },
                        remove: { removingProfile = profile }
                    )
                    Toggle("Enabled for Sports, TV Guide & Search", isOn: Binding(
                        get: { library.isProviderEnabled(profile.id) },
                        set: { library.setProviderEnabled(profile.id, enabled: $0) }))
                        .font(.inter(.caption)).tint(LineupStyle.highlight)
                        .accessibilityLabel("Enable \(profile.name)")
                    }
                }
                Button { addingProvider = true } label: {
                    SettingsRow("Add Provider", symbol: "plus")
                }
                .disabled(library.isSwitchingProfile)
                if library.isSwitchingProfile { ProgressView("Switching provider…") }
            } header: {
                Text("Providers").lineupSettingsHeader()
            } footer: {
                Text("Enable multiple providers together. Sports, TV Guide and Search combine their live channels. Each keeps its own login, favorites, preferred channels and recents. The checkmark selects the preferred provider for provider VOD and legacy defaults; selecting a feed does not change it. Use the pencil to rename a provider.")
                    .lineupSettingsFooter()
            }
            .lineupSettingsRows()
        }
        .lineupSettingsList()
        .navigationTitle("IPTV")
        .navigationBarTitleDisplayMode(.inline)
        .lineupTextPrompt("Rename Provider", symbol: "antenna.radiowaves.left.and.right",
            isPresented: Binding(get: { renamingProfile != nil }, set: { if !$0 { renamingProfile = nil } }),
            text: $providerName, prompt: "Provider name",
            message: "Choose a name to identify this service in Settings and Sports channel results.",
            canSave: !providerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && providerName.count <= 80,
            onSave: {
                if let profile = renamingProfile { library.renameProfile(id: profile.id, name: providerName) }
                renamingProfile = nil
            })
        .lineupSheet(isPresented: $addingProvider) {
            ProfileSetupView(addingProvider: true)
                .environment(library)
                .tint(LineupStyle.highlight)
                .preferredColorScheme(.dark)
        }
        .lineupChoices("Remove \(removingProfile?.name ?? "provider") and its saved password?",
                       symbol: "trash",
                       isPresented: Binding(get: { removingProfile != nil }, set: { if !$0 { removingProfile = nil } })) {
            MobileSettingsRemovalChoices.provider(removingProfile, library: library)
        } onCancel: { removingProfile = nil }
    }
}

/// Media servers: what they hold between them, each server, and adding one.
private struct MobileMediaServerSettingsView: View {
    @Binding var selectedTab: Int
    @Environment(MediaLibrary.self) private var media
    @State private var addingMediaServer = false
    @State private var removingMediaProfile: MediaServerProfile?

    var body: some View {
        List {
            if media.hasAnySource {
                Section {
                    MediaServerAccountCard { selectedTab = 2 }
                        .lineupAccountCardRow()
                }
            }
            Section {
                ForEach(media.profiles) { profile in
                    MediaServerRow(profile: profile, remove: { removingMediaProfile = profile })
                }
                Button { addingMediaServer = true } label: {
                    SettingsRow("Add Media Server", symbol: "plus")
                }
                if media.isAddingServer { ProgressView("Connecting…") }
            } header: {
                Text("Servers").lineupSettingsHeader()
            } footer: {
                Text("Lineup uses every media server here together, Jellyfin, Emby, Plex and Silo alike: their shelves, search and streams all appear in one Library.")
                    .lineupSettingsFooter()
            }
            .lineupSettingsRows()
        }
        .lineupSettingsList()
        .navigationTitle("Media Servers")
        .navigationBarTitleDisplayMode(.inline)
        .lineupSheet(isPresented: $addingMediaServer) {
            MediaServerSetupView()
                .environment(media)
                .tint(LineupStyle.highlight)
                .preferredColorScheme(.dark)
        }
        .lineupChoices("Remove \(removingMediaProfile?.name ?? "media server")?", symbol: "trash",
                       isPresented: Binding(get: { removingMediaProfile != nil }, set: { if !$0 { removingMediaProfile = nil } })) {
            MobileSettingsRemovalChoices.mediaServer(removingMediaProfile, media: media)
        } onCancel: { removingMediaProfile = nil }
    }
}

/// The Library's hero, and the MDBList lists that become its shelves.
private struct MobileLibrarySettingsView: View {
    @Environment(MediaLibrary.self) private var media
    @State private var configuringMDBList = false

    var body: some View {
        List {
            Section {
                NavigationLink { SeerrSettingsView().environment(media) } label: {
                    SettingsRow("Seerr", symbol: "tray.and.arrow.down", value: media.seerr.isConnected ? "Connected" : "Connect")
                }
            } footer: {
                Text("Request movies and series and manage their availability through your Seerr server.").lineupSettingsFooter()
            }
            .lineupSettingsRows()
            Section {
                NavigationLink {
                    LibraryHeroSettingsView().environment(media)
                } label: {
                    SettingsRow("Library Hero", symbol: "sparkles.rectangle.stack",
                                value: media.heroCatalog?.title ?? "Choose")
                }
                .disabled(!media.hasAnySource)
            } footer: {
                Text("The hero shows the top ten titles of the list chosen here.").lineupSettingsFooter()
            }
            .lineupSettingsRows()
            Section {
                if let account = media.mdbListAccount {
                    SettingsRow("Account", symbol: "list.star", value: "@\(account.username)")
                    SettingsRow("Catalogs", symbol: "square.stack", value: media.mdbListCatalogs.count.formatted())
                    if let remaining = account.requestsRemaining {
                        SettingsRow("API Requests Left", symbol: "number", value: remaining.formatted())
                    }
                } else {
                    SettingsRow("Account", symbol: "list.star",
                                value: media.isMDBListConnected ? "Connected" : "Not Connected")
                }
                Button { configuringMDBList = true } label: {
                    SettingsRow(title: media.isMDBListConnected ? "Configure MDBList" : "Connect MDBList",
                                symbol: "slider.horizontal.3") { SettingsChevron() }
                }
                if media.isMDBListLoading { ProgressView("Updating MDBList…") }
            } header: {
                Text("MDBList").lineupSettingsHeader()
            } footer: {
                Text("MDBList adds your movie and show lists as Library shelves.").lineupSettingsFooter()
            }
            .lineupSettingsRows()
        }
        .lineupSettingsList()
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        .lineupSheet(isPresented: $configuringMDBList) {
            MDBListIntegrationView()
                .environment(media)
                .tint(LineupStyle.highlight)
                .preferredColorScheme(.dark)
        }
    }
}

/// Settings, as the reference app lays its own out: short groups of rows,
/// each with a coloured tile, its name and what it is set to, leading to a
/// page of its own.
private struct MobileAccountView: View {
    @Binding var selectedTab: Int
    @State private var homeRevision = 0
    @Environment(SportsLibrary.self) private var library
    @Environment(MediaLibrary.self) private var media
    @EnvironmentObject private var cloud: CloudSettingsSync
    @State private var clearingPreferences = false
    @AppStorage(LineupAccent.storageKey) private var accentHex = LineupAccent.red.hex
    @AppStorage(MobileNavigationStyle.glassKey) private var navigationGlass = false
    @AppStorage(MobilePlaybackPreference.storageKey) private var playbackEngine = MobilePlaybackPreference.automatic.rawValue
    @State private var choosingAccent = false
    /// Done in the picker, applied once it has gone: the change redraws this
    /// screen, and a sheet should not be torn down from under itself.
    @State private var pendingAccent: String?
    @ObservedObject private var playbackDiagnostics = PlaybackDiagnostics.shared

    private var mediaValue: String {
        let count = media.profiles.count
        guard count > 0 else { return "None" }
        let online = media.profiles.filter { media.state(of: $0).isConnected }.count
        return online == count ? "\(count) Connected" : "\(online) of \(count)"
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "—") (\(info?["CFBundleVersion"] as? String ?? "—"))"
    }

    /// A count rather than the list, so the row says whether there is
    /// anything behind it without reproducing it.
    private var preferencesValue: String {
        let teams = library.teamPreferences.listed().count
        return teams == 0 ? "None" : teams.formatted()
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        MobileIPTVSettingsView(selectedTab: $selectedTab).environment(library)
                    } label: {
                        SettingsRow("IPTV", symbol: "antenna.radiowaves.left.and.right",
                                    value: library.activeProfile?.name ?? "Add")
                    }
                    NavigationLink {
                        MobileMediaServerSettingsView(selectedTab: $selectedTab).environment(media)
                    } label: {
                        SettingsRow("Media Servers", symbol: "play.square.stack", value: mediaValue)
                    }
                }
                .lineupSettingsRows()
                Section {
                    NavigationLink {
                        MobileLibrarySettingsView().environment(media)
                    } label: {
                        SettingsRow("Library", symbol: "rectangle.stack", value: media.heroCatalog?.title)
                    }
                    NavigationLink {
                        LibraryMetadataSettingsView().environment(media)
                    } label: {
                        SettingsRow("Metadata", symbol: "text.book.closed", value: media.metadataSource.title)
                    }
                    NavigationLink {
                        LibraryTrackingSettingsView().environment(media)
                    } label: {
                        SettingsRow("Tracking", symbol: "checkmark.circle", value: media.trackingSummary)
                    }
                    NavigationLink {
                        MobilePreferredChannelsView(clearingPreferences: $clearingPreferences)
                            .environment(library)
                    } label: {
                        SettingsRow("Preferred Channels", symbol: "star.square.on.square", value: preferencesValue)
                    }
                }
                .lineupSettingsRows()
                Section {
                    NavigationLink {
                        SportsTeamsSettingsView().environment(library)
                    } label: {
                        SettingsRow("My Teams", symbol: "star.fill", value: library.followedTeams.count.formatted())
                    }
                } header: {
                    Text("Sports").lineupSettingsHeader()
                } footer: {
                    Text("Find and follow your teams at any time. Their games appear in Sports.").lineupSettingsFooter()
                }
                .lineupSettingsRows()
                Section {
                    Button { choosingAccent = true } label: {
                        let accent = LineupAccent.accent(forHex: accentHex)
                        SettingsRow(title: "Accent Color", symbol: "paintpalette") {
                            HStack(spacing: 8) {
                                Circle().fill(accent.color).frame(width: 12, height: 12)
                                Text(accent.name).font(.inter(17))
                                    .foregroundStyle(LineupPanelStyle.listValue)
                                SettingsChevron()
                            }
                        }
                    }
                    Toggle(isOn: Binding(
                        get: { navigationGlass && MobileNavigationStyle.supportsGlass },
                        set: { navigationGlass = $0 }
                    )) {
                        SettingsRow("Liquid Glass", symbol: "sparkles")
                    }
                    .tint(LineupStyle.highlight)
                    .disabled(!MobileNavigationStyle.supportsGlass)
                    NavigationLink { MobileNavigationOrderView() } label: {
                        SettingsRow("Tab Order", symbol: "arrow.up.arrow.down")
                    }
                } footer: {
                    Text(MobileNavigationStyle.supportsGlass
                         ? "Off uses Lineup’s rectangular navigation bar. On uses Apple’s Liquid Glass."
                         : "Lineup’s rectangular navigation bar is enabled. Liquid Glass requires iOS 26 or later.")
                        .lineupSettingsFooter()
                }
                .lineupSettingsRows()
                Section {
                    SettingsRow("iCloud", symbol: "icloud", value: cloud.status)
                    NavigationLink { MobilePlaybackSettingsView() } label: {
                        SettingsRow(title: "Playback Engine", symbol: "play.rectangle") {
                            PlaybackEngineText((MobilePlaybackPreference(rawValue: playbackEngine) ?? .automatic).title, size: 17)
                                .font(.inter(17))
                                .foregroundStyle(LineupPanelStyle.listValue)
                                .lineLimit(1)
                        }
                    }
                    NavigationLink {
                        MobileDiagnosticsView(playbackDiagnostics: playbackDiagnostics)
                            .environment(library)
                    } label: {
                        SettingsRow("Diagnostics", symbol: "waveform.path.ecg")
                    }
                    SettingsRow("Version", symbol: "info.circle", value: version)
                    NavigationLink { MobilePlaybackAcknowledgementsView() } label: {
                        SettingsRow("Playback acknowledgements", symbol: "doc.text")
                    }
                }
                .lineupSettingsRows()
            }
            .lineupSettingsList()
            .navigationTitle("Settings")
            .task {
                media.loadShelvesIfNeeded()
                media.loadMDBListIntegrationIfNeeded()
            }
            .lineupSheet(isPresented: $choosingAccent, onDismiss: {
                guard let chosen = pendingAccent else { return }
                pendingAccent = nil
                guard chosen != accentHex else { return }
                accentHex = chosen
                CloudSettingsSync.shared.localSettingsChanged()
            }) {
                MobileAccentPicker(hex: accentHex) { pendingAccent = $0 }
            }
        }
        .id(homeRevision)
        .mobileTabHome(.settings) { homeRevision &+= 1 }
    }
}

private struct MobilePlaybackSettingsView: View {
    @AppStorage(MobilePlaybackPreference.storageKey) private var preference = MobilePlaybackPreference.native.rawValue
    @AppStorage(MobilePlaybackPreference.nativeFallbackKey) private var nativeFallback = true
    private var selected: MobilePlaybackPreference {
        let value = MobilePlaybackPreference(rawValue: preference) ?? .native
        return value == .automatic ? .native : value
    }
    var body: some View {
        List {
            Section {
                ForEach(MobilePlaybackPreference.allCases) { choice in
                    Button { preference = choice.rawValue } label: {
                        HStack {
                            HStack(spacing: 8) {
                                if choice == .native {
                                    Image(systemName: "apple.logo").font(.system(size: 21)).frame(width: 24)
                                        .foregroundStyle(LineupPresentationStyle.text).accessibilityHidden(true)
                                }
                                PlaybackEngineText(choice.title, style: .body).foregroundStyle(LineupStyle.text)
                                if let version = choice.version {
                                    Text(version)
                                        .font(.inter(12, .medium))
                                        .foregroundStyle(LineupPanelStyle.quiet)
                                        .accessibilityLabel("version \(version)")
                                }
                            }
                            Spacer()
                            if choice == selected {
                                Image(systemName: "checkmark").foregroundStyle(LineupStyle.highlight)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("lineup.playback.preference.\(choice.rawValue)")
                }
            } footer: {
                PlaybackEngineText("Native player uses Apple’s AVPlayer for HLS and a compatibility layer around Apple’s native video pipeline for files and other containers. It retains Lineup’s track, subtitle and seeking controls. Sources that need another decoder can use the optional, clearly labeled AetherEngine/VLC fallback. AetherEngine, VLC and MPVKit remain separate choices. VLC and MPVKit do not support Picture in Picture.", size: 13)
                    .lineupSettingsFooter()
            }
            .lineupSettingsRows()
            if selected == .native {
                Section {
                    Toggle("Compatibility Fallback", isOn: $nativeFallback).tint(LineupStyle.highlight)
                } footer: {
                    Text("Keeps unsupported sources playable using AetherEngine, then VLC. Turn off to stay on Apple’s native video pipeline and show a compatibility message instead. Applies to the next video.").lineupSettingsFooter()
                }.lineupSettingsRows()
            }
        }
        .lineupSettingsList()
        .navigationTitle("Playback Engine")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MobilePlaybackAcknowledgementsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PlaybackEngineText("AetherEngine \(PlaybackEngineVersions.aether) and its decoder libraries", style: .subheadline)
                    .font(.inter(.subheadline, .semibold)).foregroundStyle(LineupStyle.text)
                Text(AetherPlaybackSession.openSourceNotices() + "\n\n" + MPVPlaybackSession.openSourceNotices())
                    .font(.inter(.caption)).frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(20)
        }
        .background(LineupStyle.background)
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Why each game matched the channel it did. A game that opens the wrong feed
/// should be able to name the rule that chose it, without a device log.
private struct MatchDiagnosticsView: View {
    @Environment(SportsLibrary.self) private var library

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
                    .lineupSettingsFooter()
            }
            .lineupSettingsRows()
        }
        .lineupSettingsList()
        .navigationTitle("Channel Matching")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ game: SportsGame) -> some View {
        let stream = library.stream(for: game)
        let evidence = library.matchEvidence(for: game)
        return VStack(alignment: .leading, spacing: 5) {
            Text(game.matchupLine).font(.inter(.subheadline, .semibold))
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
