import SwiftUI

private struct MobileScheduleRefreshContext: Equatable {
    let scenePhase: ScenePhase
    let tab: Int
}

struct MainView: View {
    @EnvironmentObject private var library: SportsLibrary
    @EnvironmentObject private var media: MediaLibrary
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tab = 0
    @State private var playing: XtreamStream?
    @State private var inlinePlayerFullscreen = false
    @AppStorage(LineupAccent.storageKey) private var accent = LineupAccent.red.hex

    var body: some View {
        // Each tab's content is redrawn in a new accent, not the TabView: the
        // bar and the selected tab survive the change. The guide keeps its
        // own identity on the active profile, which this sits outside of.
        TabView(selection: $tab) {
            MobileLiveView(isActive: tab == 0, onFullscreenChange: { setInlinePlayerFullscreen($0) }) { playing = $0 }
                .lineupAccentScope(accent)
                .tabItem { Label("Sports", image: tab == 0 ? "Tab-Live-Selected" : "Tab-Live") }.tag(0)
            MobileGuideView(isActive: tab == 1, onFullscreenChange: { setInlinePlayerFullscreen($0) }) { playing = $0 }
                .id(library.activeProfile?.id)
                .lineupAccentScope(accent)
                .tabItem { Label("TV Guide", image: tab == 1 ? "Tab-Guide-Selected" : "Tab-Guide") }.tag(1)
            MediaServersView()
                .lineupAccentScope(accent)
                .tabItem { Label("Library", systemImage: tab == 2 ? "play.square.stack.fill" : "play.square.stack") }.tag(2)
            // Everything at once -- the Library, live TV, the guide and VOD --
            // each result saying which of the other tabs it lives in.
            AppSearchView { playing = $0 }
                .lineupAccentScope(accent)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(4)
            MobileAccountView(selectedTab: $tab)
                .lineupAccentScope(accent)
                .tabItem { Label("Settings", image: tab == 3 ? "Tab-Account-Selected" : "Tab-Account") }.tag(3)
        }
        // Tab chrome stays neutral; the selected asset changes from outline
        // to fill, with white providing the quiet emphasis.
        .tint(.white)
        .lineupTabBarBackground(LineupStyle.background)
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
                }.listRowBackground(LineupRowBackground())
                Section("Your provider") {
                    TextField("Profile name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Server URL", text: $server)
                        .keyboardType(.URL).textContentType(.URL)
                    TextField("Username", text: $username).textContentType(.username)
                    SecureField("Password", text: $password).textContentType(.password)
                }.listRowBackground(LineupRowBackground())
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
                        .listRowBackground(LineupRowBackground())
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
            }.listRowBackground(LineupRowBackground())
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
            }.listRowBackground(LineupRowBackground())
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
            .listRowInsets(EdgeInsets(top: 6, leading: LineupPanelStyle.inset - 6,
                                      bottom: 10, trailing: LineupPanelStyle.inset - 6))
            .listRowBackground(LineupPanelStyle.fill)
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

/// A category's header, and the switch that folds it: what it is, a line on
/// what is in it, and a chevron that turns as it opens.
private struct SettingsCategoryHeader: View {
    let title: String
    let symbol: String
    let summary: String
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            // The panel's own header: icon and heavy caption in light grey,
            // with what is inside said quietly on the right while it is shut.
            LineupPanelHeader(title: title, systemImage: symbol) {
                HStack(spacing: 8) {
                    if !isOpen {
                        Text(summary).font(.inter(.footnote, .medium))
                            .foregroundStyle(LineupPanelStyle.quiet).lineLimit(1)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(LineupPanelStyle.quiet)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
        .accessibilityHint(isOpen ? "Collapses \(title)" : "Expands \(title)")
    }
}

/// A connected media server. The Library uses every one of them at once, so
/// the row says how its own server is doing rather than offering to switch.
private struct MediaServerRow: View {
    @EnvironmentObject private var media: MediaLibrary
    let profile: MediaServerProfile
    /// Nil where the row only shows what is connected.
    let remove: (() -> Void)?

    var body: some View {
        let state = media.state(of: profile)
        HStack(spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name).font(.inter(.body, .semibold)).lineLimit(1)
                    Text(profile.displayHost)
                        .font(.inter(.caption))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            } icon: {
                // The server's own mark. Whether it answers is said at the
                // end of the row.
                MediaServerLogo(brand: .of(profile)).frame(width: 26, height: 26)
            }
            Spacer(minLength: 8)
            Text(state.isLoading ? "Connecting…" : (state.isConnected ? "Connected" : "Offline"))
                .font(.inter(.caption)).foregroundStyle(.secondary)
            if let remove {
                Button(role: .destructive, action: remove) {
                    Image(systemName: "trash").frame(minWidth: 44, minHeight: 44)
                        .foregroundStyle(LineupStyle.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(profile.name)")
            }
        }
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
    /// Nil where the row only shows what is connected.
    var remove: (() -> Void)?

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
                        // The one accent on the tab: the tick on the
                        // provider in use.
                        Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isActive ? LineupStyle.liveDot : LineupStyle.secondary)
                    }
                    Spacer(minLength: 8)
                    if isActive {
                        Text("Active").font(.inter(.caption)).foregroundStyle(.secondary)
                    }
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(name), \(isActive ? "active \(kind)" : "switch \(kind)")")
            if let remove {
                Button(role: .destructive, action: remove) {
                    Image(systemName: "trash").frame(minWidth: 44, minHeight: 44)
                        .foregroundStyle(LineupStyle.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(name)")
            }
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
    @State private var configuringMDBList = false
    @State private var removingProfile: XtreamProfile?
    @State private var removingMediaProfile: MediaServerProfile?
    @State private var clearingPreferences = false
    @AppStorage(LineupAccent.storageKey) private var accentHex = LineupAccent.red.hex
    @State private var choosingAccent = false
    /// Done in the picker, applied once it has gone: the change redraws this
    /// screen, and a sheet should not be torn down from under itself.
    @State private var pendingAccent: String?
    @ObservedObject private var playbackDiagnostics = PlaybackDiagnostics.shared
    /// Which categories are open, kept between launches. All start folded.
    @AppStorage("lineup.settings.openCategories") private var openCategories = ""

    private enum Category: String {
        case iptv, media, library, appearance, about
    }

    private func isOpen(_ category: Category) -> Bool {
        openCategories.split(separator: ",").contains(Substring(category.rawValue))
    }

    private func toggle(_ category: Category) {
        var open = Set(openCategories.split(separator: ",").map(String.init))
        if open.contains(category.rawValue) { open.remove(category.rawValue) } else { open.insert(category.rawValue) }
        withAnimation(.snappy(duration: 0.3)) {
            openCategories = open.sorted().joined(separator: ",")
        }
    }

    /// Each provider, to switch to -- and, with the category open, to remove.
    @ViewBuilder
    private func providerRows(removable: Bool) -> some View {
        ForEach(library.profiles) { profile in
            AccountSourceRow(
                name: profile.name,
                detail: profile.username,
                isActive: library.activeProfile?.id == profile.id,
                kind: "provider",
                select: { Task { await library.selectProfile(profile) } },
                remove: removable ? { removingProfile = profile } : nil
            )
            .disabled(library.isSwitchingProfile || library.channelsAreSyncing)
        }
    }

    private var iptvSummary: String {
        guard let active = library.activeProfile else { return "No provider" }
        var parts = [active.name]
        if !library.streams.isEmpty { parts.append("\(library.streams.count.formatted()) channels") }
        if library.profiles.count > 1 { parts.append("\(library.profiles.count) providers") }
        return parts.joined(separator: " · ")
    }

    private var mediaSummary: String {
        let count = media.profiles.count
        guard count > 0 else { return "No servers" }
        let online = media.profiles.filter { media.state(of: $0).isConnected }.count
        let servers = count == 1 ? "1 server" : "\(count) servers"
        return online == count ? "\(servers) · connected" : "\(servers) · \(online) connected"
    }

    private var librarySummary: String {
        var parts = ["Hero: " + (media.heroCatalog?.title ?? "not chosen")]
        if media.isMDBListConnected { parts.append("MDBList") }
        return parts.joined(separator: " · ")
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "—") (\(info?["CFBundleVersion"] as? String ?? "—"))"
    }

    private var aboutSummary: String { "Version " + version + " · iCloud: " + cloud.status }

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
            // Each category folds away under a header that says what is in
            // it. Folded, the sources show just what is connected; open, they
            // carry everything for managing them.
            List {
                Section {
                    SettingsCategoryHeader(title: "IPTV", symbol: "antenna.radiowaves.left.and.right",
                                           summary: iptvSummary, isOpen: isOpen(.iptv)) { toggle(.iptv) }
                    if isOpen(.iptv) {
                        if let profile = library.activeProfile {
                            ProviderAccountCard(profile: profile) { selectedTab = 1 }
                                .lineupAccountCardRow()
                        }
                        providerRows(removable: true)
                        Button("Add provider", systemImage: "plus.circle") { addingProvider = true }
                            .disabled(library.isSwitchingProfile)
                        if library.isSwitchingProfile { ProgressView("Switching provider…") }
                        NavigationLink {
                            MobilePreferredChannelsView(clearingPreferences: $clearingPreferences)
                                .environmentObject(library)
                        } label: {
                            LabeledContent("Preferred channels & recents", value: preferencesSummary)
                        }
                    } else if library.profiles.isEmpty {
                        Button("Add IPTV provider", systemImage: "plus.circle") { addingProvider = true }
                    } else {
                        providerRows(removable: false)
                    }
                } footer: {
                    if isOpen(.iptv) {
                        Text("Each provider keeps its own favorites, preferred channels and recents. Games on those teams open on the saved channel.")
                    }
                }
                .lineupPanelRows()
                Section {
                    SettingsCategoryHeader(title: "Media Servers", symbol: "play.square.stack",
                                           summary: mediaSummary, isOpen: isOpen(.media)) { toggle(.media) }
                    if isOpen(.media) {
                        if media.hasAnySource {
                            MediaServerAccountCard { selectedTab = 2 }
                                .lineupAccountCardRow()
                        }
                        ForEach(media.profiles) { profile in
                            MediaServerRow(profile: profile, remove: { removingMediaProfile = profile })
                        }
                        Button("Add media server", systemImage: "plus.circle") { addingMediaServer = true }
                        if media.isAddingServer { ProgressView("Connecting…") }
                    } else if media.profiles.isEmpty {
                        Button("Add media server", systemImage: "plus.circle") { addingMediaServer = true }
                    } else {
                        ForEach(media.profiles) { profile in
                            MediaServerRow(profile: profile, remove: nil)
                        }
                    }
                } footer: {
                    if isOpen(.media) {
                        Text("Lineup uses every media server here together, Jellyfin, Emby and Plex alike: their shelves, search and streams all appear in one Library.")
                    }
                }
                .lineupPanelRows()
                Section {
                    SettingsCategoryHeader(title: "Library", symbol: "rectangle.stack",
                                           summary: librarySummary, isOpen: isOpen(.library)) { toggle(.library) }
                    if isOpen(.library) {
                        NavigationLink {
                            LibraryHeroSettingsView().environmentObject(media)
                        } label: {
                            LabeledContent("Library hero", value: media.heroCatalog?.title ?? "Choose catalog")
                        }
                        .disabled(!media.hasAnySource)
                        if let account = media.mdbListAccount {
                            LabeledContent("MDBList", value: "@\(account.username)")
                            LabeledContent("Catalogs", value: media.mdbListCatalogs.count.formatted())
                            if let remaining = account.requestsRemaining {
                                LabeledContent("API requests left", value: remaining.formatted())
                            }
                        } else {
                            LabeledContent("MDBList", value: media.isMDBListConnected ? "Connected" : "Not connected")
                        }
                        Button(media.isMDBListConnected ? "Configure MDBList" : "Connect MDBList",
                               systemImage: "rectangle.stack.badge.play") {
                            configuringMDBList = true
                        }
                        if media.isMDBListLoading { ProgressView("Updating MDBList…") }
                    }
                } footer: {
                    if isOpen(.library) {
                        Text("The hero shows the top ten titles of the catalog chosen here. MDBList adds your movie and show lists as Library shelves.")
                    }
                }
                .lineupPanelRows()
                Section {
                    SettingsCategoryHeader(title: "Appearance", symbol: "paintpalette",
                                           summary: "Accent · " + LineupAccent.accent(forHex: accentHex).name,
                                           isOpen: isOpen(.appearance)) { toggle(.appearance) }
                    if isOpen(.appearance) {
                        Button { choosingAccent = true } label: {
                            let accent = LineupAccent.accent(forHex: accentHex)
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(accent.color)
                                    .frame(width: 22, height: 22)
                                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                                Text("Accent Color").foregroundStyle(LineupStyle.text)
                                Spacer(minLength: 8)
                                Text(accent.name).foregroundStyle(LineupStyle.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(LineupStyle.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    if isOpen(.appearance) {
                        Text("The color that marks what's active. The dark and light greys and the white stay as they are. Syncs through iCloud.")
                    }
                }
                .lineupPanelRows()
                Section {
                    SettingsCategoryHeader(title: "About", symbol: "info.circle",
                                           summary: aboutSummary, isOpen: isOpen(.about)) { toggle(.about) }
                    if isOpen(.about) {
                        LabeledContent("iCloud", value: cloud.status)
                        NavigationLink("Diagnostics") {
                            MobileDiagnosticsView(playbackDiagnostics: playbackDiagnostics)
                                .environmentObject(library)
                        }
                        LabeledContent("Version", value: version)
                    }
                }
                .lineupPanelRows()
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(LineupPanelStyle.gap)
            .scrollContentBackground(.hidden).background(LineupStyle.background)
            .navigationTitle("Settings")
            .task {
                media.loadShelvesIfNeeded()
                media.loadMDBListIntegrationIfNeeded()
            }
            .sheet(isPresented: $choosingAccent, onDismiss: {
                guard let chosen = pendingAccent else { return }
                pendingAccent = nil
                guard chosen != accentHex else { return }
                accentHex = chosen
                CloudSettingsSync.shared.localSettingsChanged()
            }) {
                MobileAccentPicker(hex: accentHex) { pendingAccent = $0 }
            }
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
            .sheet(isPresented: $configuringMDBList) {
                MDBListIntegrationView()
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
            }.listRowBackground(LineupRowBackground())
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
